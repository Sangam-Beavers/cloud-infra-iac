# ---------------------------------------------------------------------------
# 클러스터 IAM 역할
# ---------------------------------------------------------------------------

resource "aws_iam_role" "cluster" {
  name = "${var.name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy",
    "arn:aws:iam::aws:policy/AmazonEKSVPCResourceController",
  ])

  role       = aws_iam_role.cluster.name
  policy_arn = each.value
}

# ---------------------------------------------------------------------------
# EKS 클러스터
# ---------------------------------------------------------------------------

# 컨트롤플레인 감사 로그 그룹입니다. EKS가 만드는 기본 이름 규칙 (/aws/eks/<cluster>/cluster)을
# 그대로 쓰되 CMK 암호화·보관 기간은 우리가 직접 관리합니다.
resource "aws_cloudwatch_log_group" "eks" {
  name              = "/aws/eks/${var.name}/cluster"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = "${var.name}-logs"
  }
}

resource "aws_eks_cluster" "this" {
  name     = var.name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  # bootstrap_self_managed_addons는 기본값 (true) 을 유지합니다. EKS가 클러스터 생성 시 기본
  # self-managed vpc-cni/kube-proxy/coredns를 설치하므로, cni="cilium"이어도 이 기본 CNI가
  # 노드를 Ready로 만들어 apply가 무인으로 완료됩니다 (private-only API라 Terraform은 클러스터에
  # 접근해 Cilium을 직접 설치할 수 없습니다). apply 이후 install-k8s-stack.sh가 점프 호스트 터널로
  # vpc-cni를 Cilium으로 교체합니다. false로 두면 노드가 NotReady라 매니지드 노드그룹 생성이
  # 데드락됩니다.

  # api/audit/authenticator 감사 로그를 CloudWatch로 보냅니다 (인증 실패·권한 변경 추적).
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  # 컨트롤플레인 ENI는 control_plane_subnet_ids (지정 시 mgmt)에, 노드 그룹은 subnet_ids (private)에
  # 배치합니다. 분리하면 on-prem (ArgoCD)이 mgmt 경유로 API에 닿으면서 private는 광고 없이 숨길 수 있습니다.
  vpc_config {
    subnet_ids              = length(var.control_plane_subnet_ids) > 0 ? var.control_plane_subnet_ids : var.subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.endpoint_public_access_cidrs : null
  }

  # 퍼블릭 엔드포인트를 켜면서 CIDR을 비우면 0.0.0.0/0 (전세계)로 열리므로 precondition으로 차단합니다.
  lifecycle {
    precondition {
      condition     = !var.endpoint_public_access || length(var.endpoint_public_access_cidrs) > 0
      error_message = "endpoint_public_access=true면 endpoint_public_access_cidrs를 반드시 지정해야 합니다 (빈 리스트는 0.0.0.0/0 = 전세계 노출)."
    }
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Kubernetes Secrets 봉투 암호화 (환경 CMK)
  encryption_config {
    resources = ["secrets"]
    provider {
      key_arn = var.kms_key_arn
    }
  }

  # 로그 그룹을 먼저 만들어 EKS가 자체 생성하지 않도록 합니다 (암호화/보관 정책을 우리가 소유).
  depends_on = [
    aws_iam_role_policy_attachment.cluster,
    aws_cloudwatch_log_group.eks,
  ]

  tags = {
    Name = var.name
  }
}

# private 엔드포인트 접근을 허용합니다. EKS가 만드는 클러스터 SG는 기본적으로 클러스터/노드 간
# 트래픽만 허용하므로, 점프 호스트 (mgmt) 등의 443 접근은 별도로 명시해야 합니다.
resource "aws_security_group_rule" "api_ingress" {
  count = length(var.api_allowed_cidrs) > 0 ? 1 : 0

  type              = "ingress"
  from_port         = 443
  to_port           = 443
  protocol          = "tcp"
  cidr_blocks       = var.api_allowed_cidrs
  security_group_id = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
  description       = "kubectl via jump host (mgmt subnets)"
}

# ---------------------------------------------------------------------------
# IRSA용 OIDC 프로바이더 (External Secrets, LB Controller 등에서 사용)
# ---------------------------------------------------------------------------

data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer

  tags = {
    Name = "${var.name}-oidc"
  }
}

# ---------------------------------------------------------------------------
# 노드 IAM 역할 + 관리형 노드 그룹
# ---------------------------------------------------------------------------

resource "aws_iam_role" "node" {
  name = "${var.name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore", # 노드 디버깅용 SSM 접속
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

# 노드 EC2/볼륨에 Name 태그를 붙이기 위한 시작 템플릿입니다
# (관리형 노드 그룹은 자체 태그를 인스턴스로 전파하지 않습니다).
resource "aws_launch_template" "node" {
  name_prefix = "${var.name}-node-"

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = var.disk_size
      volume_type = "gp3"
      encrypted   = true
    }
  }

  # IMDSv2를 강제합니다 (hop limit 2: 파드에서 노드 메타데이터 접근 허용).
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      { Name = "${var.name}-node" },
      var.instance_extra_tags
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      { Name = "${var.name}-node" },
      var.instance_extra_tags
    )
  }
}

resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.subnet_ids

  instance_types = var.instance_types
  ami_type       = var.ami_type
  capacity_type  = "ON_DEMAND"

  # disk_size는 시작 템플릿 (block_device_mappings)으로 옮겼습니다 (LT와 동시 지정 불가).
  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  scaling_config {
    desired_size = var.desired_size
    min_size     = var.min_size
    max_size     = var.max_size
  }

  update_config {
    max_unavailable = 1
  }

  # Cluster Autoscaler가 desired_size를 직접 조정하므로, Terraform이 apply 때마다
  # var.desired_size로 되돌리지 않도록 무시합니다 (min/max는 계속 Terraform이 관리).
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }

  # 노드 부트스트랩 전에 IAM 권한과 (vpc-cni 모드면) 네트워킹 애드온이 준비되도록 보장합니다.
  # cni = "cilium"이면 이 의존성은 pod-identity-agent만 보장하고, CNI는 apply 이후
  # Helm (Cilium)으로 설치됩니다. 그린필드에선 Cilium 설치 전까지 노드가 NotReady 상태입니다.
  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_eks_addon.this,
  ]

  tags = {
    Name = "${var.name}-default"
  }
}

# ---------------------------------------------------------------------------
# Cluster Autoscaler 오토디스커버리 태그.
# CA는 --node-group-auto-discovery로 이 두 태그가 함께 붙은 ASG만 후보로 잡습니다. 관리형 노드
# 그룹의 tags나 시작 템플릿 tag_specifications는 ASG 자체엔 전파되지 않으므로 (EKS가 만든 ASG에)
# 직접 태그를 답니다. 키의 클러스터명은 곧 var.name이며, IRSA 정책의 쓰기 조건 (owned)과 짝을 이룹니다.
# ---------------------------------------------------------------------------
resource "aws_autoscaling_group_tag" "ca_enabled" {
  autoscaling_group_name = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "k8s.io/cluster-autoscaler/enabled"
    value               = "true"
    propagate_at_launch = false
  }
}

resource "aws_autoscaling_group_tag" "ca_owned" {
  autoscaling_group_name = aws_eks_node_group.this.resources[0].autoscaling_groups[0].name

  tag {
    key                 = "k8s.io/cluster-autoscaler/${var.name}"
    value               = "owned"
    propagate_at_launch = false
  }
}

# ---------------------------------------------------------------------------
# 애드온 (coredns는 노드가 있어야 기동되므로 노드 그룹 이후에 생성합니다).
# cni = "cilium"이면 vpc-cni/kube-proxy를 Terraform 관리 애드온으로 채택하지 않습니다.
#   단, bootstrap_self_managed_addons=true라 EKS가 기본 self-managed vpc-cni/kube-proxy를
#   설치해 노드를 Ready로 만들고, apply 완료 후 install-k8s-stack.sh가 그 둘을 지우고 Cilium을
#   설치합니다.
# coredns는 cni와 무관하게 Terraform이 관리합니다 (기본 vpc-cni 위에서 정상 기동).
# ---------------------------------------------------------------------------

locals {
  eks_addons = var.cni == "cilium" ? ["eks-pod-identity-agent"] : ["vpc-cni", "kube-proxy", "eks-pod-identity-agent"]
}

resource "aws_eks_addon" "this" {
  for_each = toset(local.eks_addons)

  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = each.value
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "coredns" {
  cluster_name                = aws_eks_cluster.this.name
  addon_name                  = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_node_group.this]
}

# ---------------------------------------------------------------------------
# on-prem ArgoCD용 access entry — IAM principal을 RBAC에 매핑합니다 (authentication_mode=API).
# argocd_enabled=false면 생성하지 않습니다. RBAC는 argocd_access_policy_arn (기본 Edit)으로
# 부여하고, argocd_access_namespaces 지정 시 해당 네임스페이스로 한정합니다 (least-privilege).
# ---------------------------------------------------------------------------

resource "aws_eks_access_entry" "argocd" {
  count = var.argocd_enabled ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.argocd_principal_arn
  type          = "STANDARD"

  tags = {
    Name = "${var.name}-argocd"
  }
}

resource "aws_eks_access_policy_association" "argocd" {
  count = var.argocd_enabled ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.argocd_principal_arn
  policy_arn    = var.argocd_access_policy_arn

  access_scope {
    type       = length(var.argocd_access_namespaces) > 0 ? "namespace" : "cluster"
    namespaces = length(var.argocd_access_namespaces) > 0 ? var.argocd_access_namespaces : null
  }

  depends_on = [aws_eks_access_entry.argocd]
}

# ---------------------------------------------------------------------------
# 팀 공유 cluster-admin access entry — cluster_admin_role_arn을 ClusterAdmin으로 매핑합니다.
# 그 역할을 assume할 수 있는 사람 (예: AdministratorAccess 그룹)이 make kubeconfig-stage (--role-arn)로
# kubectl admin이 됩니다. 접근 제어를 '역할 assume 가능 여부' (=그룹 멤버십)로 두었으므로 IaC 변경
# 없이 가입/탈퇴할 수 있습니다.
# ---------------------------------------------------------------------------
resource "aws_eks_access_entry" "cluster_admin" {
  count = var.cluster_admin_enabled ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.cluster_admin_role_arn
  type          = "STANDARD"

  tags = {
    Name = "${var.name}-cluster-admin"
  }
}

resource "aws_eks_access_policy_association" "cluster_admin" {
  count = var.cluster_admin_enabled ? 1 : 0

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = var.cluster_admin_role_arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.cluster_admin]
}
