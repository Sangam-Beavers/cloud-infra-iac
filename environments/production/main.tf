# myApplications 앱 ARN입니다. application/ 스택이 먼저 apply되어 있어야 합니다 (README 참고).
data "terraform_remote_state" "application" {
  backend = "s3"

  config = {
    bucket  = var.state_bucket
    key     = "application/terraform.tfstate"
    region  = var.aws_region
    profile = var.aws_profile
  }
}

locals {
  application_arn = data.terraform_remote_state.application.outputs.application_arns[var.environment]
  onprem_enabled  = var.onprem_integration.enabled
  # Harbor 경로/SNAT는 목적지가 실제로 있을 때만 켭니다 (빈 목적지로 켜면 user_data가 깨지므로 방지).
  harbor_enabled = var.onprem_integration.enabled && length(var.onprem_integration.harbor_destinations) > 0
  # Cognito OAuth callback 호스트입니다. 커스텀 도메인을 지정하면 그 도메인을, 없으면 CloudFront 기본 도메인을 씁니다.
  edge_primary_host = var.edge_domain != "" ? var.edge_domain : module.edge.cloudfront_domain_name
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Environment    = var.environment
      ManagedBy      = "terraform"
      Project        = var.project
      awsApplication = local.application_arn
    }
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name     = "sb-prod"
  vpc_cidr = var.network.vpc_cidr

  public_subnets  = var.network.public
  private_subnets = var.network.private
  db_subnets      = var.network.db
  mgmt_subnets    = var.network.mgmt

  # VPC Flow Logs를 환경 CMK로 암호화해 활성화합니다 (prod는 포렌식을 위해 90일 보존 — staging은 모듈 기본 14일).
  enable_flow_logs        = true
  flow_log_kms_key_arn    = module.kms.key_arn
  flow_log_retention_days = 90

  nat_gateway_strategy = var.vpc_config.nat_gateway_strategy
  single_nat_az        = var.vpc_config.single_nat_az

  # AWS Load Balancer Controller의 서브넷 자동 발견용 태그입니다.
  public_subnet_extra_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_extra_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

# Valkey (Redis 호환) 세션/토큰 저장소입니다. Aurora처럼 AZ 분산 + 자동 failover를 둡니다.
# AUTH 토큰은 생성 후 scripts/bootstrap-redis.sh로 설정합니다 (Secrets Manager 저장).
module "redis" {
  source = "../../modules/elasticache"

  name        = "sb-prod-redis"
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = var.network.vpc_cidr
  subnet_ids  = values(module.vpc.db_subnet_ids)
  kms_key_arn = module.kms.key_arn

  # private (EKS) 와 mgmt (점프 호스트) 에서만 접근할 수 있습니다.
  allowed_cidrs = concat(values(var.network.private), values(var.network.mgmt))

  node_type          = var.redis_config.node_type
  node_count         = var.redis_config.node_count
  snapshot_retention = var.redis_config.snapshot_retention
}

# SSM 엔드포인트와 점프 호스트입니다 (mgmt 격리 구역의 유일한 관리 통로).
# Aurora/Valkey 관리, DB 부트스트랩에 쓰며, EKS를 private-only로 전환한 후에는 kubectl 경유지로 씁니다.
module "jumphost" {
  source = "../../modules/jumphost"

  name       = "sb-prod-jump"
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = var.network.vpc_cidr
  subnet_ids = values(module.vpc.mgmt_subnet_ids)

  kms_key_arn   = module.kms.key_arn
  secret_prefix = "sb/prod/"

  instance_type = var.jumphost_config.instance_type

  instance_extra_tags = { awsApplication = local.application_arn }

  # 주의: module.vpc에 depends_on을 걸면 data 소스가 지연돼 엔드포인트가 매번 교체됩니다.
  # S3 엔드포인트 준비 전에 부팅하는 경우는 user_data의 dnf 재시도 루프가 흡수합니다.
}

# 사이트-투-사이트 WireGuard + FRR (BGP) 라우터입니다. 온프렘 pfSense (active/standby) 와 연결합니다.
# 키는 `make vpn-prod`로 SSM에 등록한 뒤 apply합니다 (user_data가 부팅 시 fetch).
module "vpn" {
  source = "../../modules/vpn"

  name       = "sb-prod-vpn"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = values(module.vpc.public_subnet_ids)

  kms_key_arn = module.kms.key_arn
  ssm_prefix  = "/sb/prod/vpn"

  # 터널/BGP 토폴로지는 terraform.tfvars에서 주입합니다 (커밋되지 않음 — example 참고).
  tunnels       = var.vpn_tunnels
  bgp_router_id = var.vpn_bgp_router_id

  # mgmt 대역만 광고하고 온프렘 대역은 return 라우트로 둡니다.
  advertise_cidrs        = values(var.network.mgmt)
  onprem_cidrs           = var.vpn_onprem_cidrs
  pfsense_nat_ip         = var.vpn_pfsense_nat_ip
  return_route_table_ids = [module.vpc.mgmt_route_table_id]

  # private (EKS 노드) 가 Harbor에만 닿도록 private RT에 Harbor /32 경로를 두고 터널 IP로 SNAT합니다 (은닉).
  # private는 광고하지 않으므로 on-prem에는 라우터 단일 소스로만 보입니다.
  app_route_table_ids     = local.harbor_enabled ? values(module.vpc.private_route_table_ids) : []
  app_onprem_destinations = var.onprem_integration.harbor_destinations
  snat_source_cidrs       = local.harbor_enabled ? values(var.network.private) : []

  # forward 트래픽 SG ingress입니다. private→Harbor (TCP 443) 와 mgmt→DNS (UDP 53) 만 최소로 허용합니다.
  forward_harbor_cidrs = local.harbor_enabled ? values(var.network.private) : []
  forward_dns_cidrs    = local.onprem_enabled ? values(var.network.mgmt) : []

  instance_extra_tags = { awsApplication = local.application_arn }
}

# 온프렘 ArgoCD가 EKS API에 인증할 전용 IAM User입니다 (연동 시에만 생성). 출력 ARN을 eks access
# entry에 매핑하고, 액세스 키는 onprem-handoff가 exports/argocd-<env>-cluster.yaml로 넘깁니다.
module "argocd_iam" {
  source = "../../modules/argocd-iam"
  count  = local.onprem_enabled ? 1 : 0

  name = "sb-prod-argocd"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# 팀 공유 EKS admin 역할입니다. 계정 내 admin이 assume하면 EKS access entry로 kubectl ClusterAdmin을 얻습니다.
# 신뢰 주체는 계정 루트 (동적) 이며 MFA를 강제합니다. 그룹 멤버십으로 접근을 제어하므로 계정 ID 하드코딩이 없고, 권한 정책도 불필요합니다 (authz는 access entry가 담당).
resource "aws_iam_role" "eks_admin" {
  name = "sb-prod-eks-admin"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "arn:${data.aws_partition.current.partition}:iam::${data.aws_caller_identity.current.account_id}:root" }
      Action    = "sts:AssumeRole"
      Condition = {
        Bool = { "aws:MultiFactorAuthPresent" = "true" }
      }
    }]
  })

  tags = { Name = "sb-prod-eks-admin" }
}

module "eks" {
  source = "../../modules/eks"

  name        = "sb-prod-eks"
  subnet_ids  = values(module.vpc.private_subnet_ids)
  kms_key_arn = module.kms.key_arn

  # CNI는 Cilium입니다 (개발 스택과 동일). vpc-cni/kube-proxy를 제외한 뒤 Helm으로 설치합니다.
  cni = "cilium"

  # ESO가 이 환경의 비밀 (sb/prod/*) 만 읽도록 IRSA를 제한합니다.
  eso_secret_prefix = "sb/prod/"

  # Graviton (ARM64) 노드를 쓰면 컨테이너 이미지를 arm64로 빌드해야 합니다.
  instance_types = var.eks_config.instance_types
  desired_size   = var.eks_config.desired_size

  # 연동 시에는 컨트롤플레인 ENI를 mgmt에 두어 on-prem (ArgoCD) 이 private 광고 없이 API에 닿게 합니다.
  # 비연동 시에는 빈 목록을 주면 모듈이 subnet_ids (private) 로 폴백합니다 (기존 동작).
  control_plane_subnet_ids = local.onprem_enabled ? values(module.vpc.mgmt_subnet_ids) : []

  # private-only API에 점프 호스트 (mgmt) kubectl과 (연동 시) ArgoCD 소스 (.253) 를 허용합니다.
  endpoint_public_access       = var.eks_config.endpoint_public_access
  endpoint_public_access_cidrs = var.eks_config.endpoint_public_access_cidrs
  api_allowed_cidrs            = concat(values(var.network.mgmt), local.onprem_enabled ? var.onprem_integration.argocd_source_cidrs : [])

  # ArgoCD용 access entry입니다 (연동 시 argocd-iam 모듈이 만든 전용 User를 매핑).
  # count 게이트는 plan 시점 bool로 둡니다 (ARN은 apply 시점 값이라 count에 쓸 수 없습니다).
  argocd_enabled           = local.onprem_enabled
  argocd_principal_arn     = local.onprem_enabled ? module.argocd_iam[0].principal_arn : ""
  argocd_access_namespaces = var.onprem_integration.argocd_namespaces

  # 팀 공유 cluster-admin 역할 (sb-prod-eks-admin) 을 ClusterAdmin access entry로 매핑합니다. kubeconfig-prod가 assume합니다.
  cluster_admin_enabled  = true
  cluster_admin_role_arn = aws_iam_role.eks_admin.arn

  min_size = var.eks_config.min_size
  max_size = var.eks_config.max_size

  # 사내 Harbor CA를 노드 부팅 시점에 신뢰스토어에 심습니다 (CA가 증설한 새 노드의 pull-before-trust 윈도우 제거). harbor 연동 시에만.
  harbor_ca_pem = local.harbor_enabled && fileexists("${path.module}/../../secrets/sb-local-ca.crt") ? file("${path.module}/../../secrets/sb-local-ca.crt") : ""

  # 노드 EC2도 myApplications 비용/인벤토리에 포함합니다.
  instance_extra_tags = { awsApplication = local.application_arn }
}

module "kms" {
  source = "../../modules/kms"

  name                    = "sb-prod"
  deletion_window_in_days = var.kms_config.deletion_window_in_days
}

# 계정 API 평면 감사 추적용 멀티리전 CloudTrail입니다 (org 트레일이 있으면 enable_cloudtrail=false).
module "cloudtrail" {
  source = "../../modules/cloudtrail"

  name        = "sb-prod-trail"
  kms_key_arn = module.kms.key_arn
  enabled     = var.enable_cloudtrail
}

# 하이브리드 DNS입니다. 엔드포인트는 mgmt에 두며 연동 (enabled) 시에만 생성합니다.
#   inbound : on-prem이 EKS private 엔드포인트 호스트명을 해석합니다 (pfSense 조건부 포워더 대상).
#   outbound: EKS 노드가 harbor.corp.example 등 on-prem 도메인을 해석합니다.
module "route53_resolver" {
  source = "../../modules/route53-resolver"
  count  = local.onprem_enabled ? 1 : 0

  name       = "sb-prod"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = values(module.vpc.mgmt_subnet_ids)

  inbound_allowed_cidrs = var.onprem_integration.inbound_allowed_cidrs
  forward_domains       = var.onprem_integration.dns_forward_domains
  forward_target_ips    = var.onprem_integration.dns_resolver_ips
}

# 백엔드 진입점입니다. HTTP API → VPC Link → internal ALB → EKS 4서비스 (TargetGroupBinding) 로 이어집니다.
# CloudFront 우회 차단 (origin-lock) 은 ALB의 regional WAF가 X-Origin-Verify로 수행합니다.
module "api_gateway" {
  source = "../../modules/api-gateway"

  name        = "sb-prod-api"
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = values(module.vpc.private_subnet_ids)
  kms_key_arn = module.kms.key_arn
  ssm_prefix  = "/sb/prod/api-gateway"
  # 서비스별 TG ARN/포트와 ALB SG를 PS에 게시합니다. install-k8s-stack의 tgb phase가 이를 읽어 TargetGroupBinding을 생성합니다.
  tgb_ssm_prefix = "/sb/prod/tgb"

  waf_rate_limit = var.api_gateway_config.waf_rate_limit
  services       = var.api_gateway_config.services
}

# ---------------------------------------------------------------------------
# 엣지 (CloudFront + S3 + CLOUDFRONT-scope WAF) 입니다. api_gateway 출력 (오리진 URL·origin-verify
# 비밀) 을 같은 그래프에서 직접 참조합니다. prod 도메인은 secrets/domain.env (GB_PROD_DOMAIN), stage는 기본 인증서를 씁니다.
# ---------------------------------------------------------------------------
# CLOUDFRONT scope WAF/ACM은 us-east-1 전용이라 별칭 provider를 둡니다.
provider "aws" {
  alias   = "us_east_1"
  region  = "us-east-1"
  profile = var.aws_profile

  default_tags {
    tags = {
      Environment    = var.environment
      ManagedBy      = "terraform"
      Project        = var.project
      awsApplication = local.application_arn
    }
  }
}

module "edge" {
  source = "../../modules/edge"

  providers = {
    aws           = aws
    aws.us_east_1 = aws.us_east_1
  }

  name   = "sb-prod-edge"
  domain = var.edge_domain

  waf_rate_limit = var.api_gateway_config.waf_rate_limit

  api_origin = {
    domain_name          = trimsuffix(trimprefix(module.api_gateway.api_origin_url, "https://"), "/")
    origin_verify_secret = module.api_gateway.origin_verify_secret
  }
}

# ---------------------------------------------------------------------------
# Aurora MySQL입니다. blast radius 분리를 위해 클러스터를 2개로 나눕니다.
#   core:    wallet, member       (트랜잭션·핵심)
#   content: community, document  (읽기 중심·트래픽 스파이크)
# 논리 DB/서비스 계정은 scripts/bootstrap-db.sh로 생성합니다 (mgmt 점프 호스트에서 실행).
# ---------------------------------------------------------------------------


module "aurora" {
  source   = "../../modules/aurora"
  for_each = var.aurora_config.clusters

  name        = "sb-prod-${each.key}"
  vpc_id      = module.vpc.vpc_id
  vpc_cidr    = var.network.vpc_cidr
  subnet_ids  = values(module.vpc.db_subnet_ids)
  kms_key_arn = module.kms.key_arn
  databases   = each.value.databases

  # private (EKS) 와 mgmt (점프 호스트) 에서만 접근할 수 있습니다.
  allowed_cidrs = concat(values(var.network.private), values(var.network.mgmt))

  instance_count          = each.value.instance_count != null ? each.value.instance_count : var.aurora_config.instance_count
  serverless_min_acu      = each.value.min_acu != null ? each.value.min_acu : var.aurora_config.serverless_min_acu
  serverless_max_acu      = each.value.max_acu != null ? each.value.max_acu : var.aurora_config.serverless_max_acu
  backup_retention_period = var.aurora_config.backup_retention_period
  deletion_protection     = var.aurora_config.deletion_protection
  skip_final_snapshot     = var.aurora_config.skip_final_snapshot
}

# Cognito (운영 IdP) 입니다. 프론트는 Hosted UI OAuth code 플로우를, member는 provisioning (Admin*) 과 JWT 검증을 씁니다.
# callback은 엣지 도메인입니다 (커스텀 도메인 지정 시 그 도메인, 없으면 CloudFront 기본). prod는 localhost를 허용하지 않습니다.
module "cognito" {
  source = "../../modules/cognito"

  name          = "sb-prod-gb"
  domain_prefix = "sb-prod-gb-auth"

  # 프론트 (../frontend) OIDC 설정과 일치시킵니다: redirect=/auth/callback, post-logout=/login.
  callback_urls = ["https://${local.edge_primary_host}/auth/callback"]
  logout_urls   = ["https://${local.edge_primary_host}/login"]

  deletion_protection = "ACTIVE" # prod는 실수 삭제를 방지하므로 destroy 시 콘솔/CLI로 수동 해제해야 합니다.

  cluster_name = module.eks.cluster_name

  # member 파드 SA입니다. 앱 Deployment의 ServiceAccount와 정확히 일치해야 합니다.
  member_service_account = { namespace = "sb-prod-app-ns", name = "member" }

  member_ssm_prefix   = "/sb/prod/member"   # issuer/region/pool-id → ESO 런타임
  frontend_ssm_prefix = "/sb/prod/frontend" # VITE_OIDC_* → Jenkins 빌드 타임

  # 관리자 인가용 그룹 (stage와 동형). prod는 수동 생성분이 없어 apply 시 신규 생성됩니다.
  user_groups = {
    admin = {}
  }
}

# document-service Pod Identity (IRSA→PI 수렴, stage와 동형). SQS/S3/Lambda 권한. 대상 자원은 var.document_irsa (external.auto.tfvars) 로 주입합니다.
# prod 배포 시 production/external.auto.tfvars에 document_irsa 값을 채웁니다 (미정이면 prod apply 전에 확정).
module "document_access" {
  source = "../../modules/pod-identity"
  count  = var.document_irsa != null ? 1 : 0 # 값 (tfvars) 을 채우기 전에는 생성하지 않습니다.

  name            = "sb-prod-document"
  cluster_name    = module.eks.cluster_name
  namespace       = "sb-prod-app-ns"
  service_account = "document" # gb-infra document 차트의 serviceAccountName과 일치

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ConsumeAnalysisResultQueue"
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes", "sqs:GetQueueUrl"]
        Resource = "arn:${data.aws_partition.current.partition}:sqs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:${var.document_irsa.analysis_queue_name}"
      },
      {
        Sid    = "DocumentBucketRead"
        Effect = "Allow"
        Action = "s3:GetObject"
        Resource = [
          "arn:${data.aws_partition.current.partition}:s3:::${var.document_irsa.document_bucket}/original/*",
          "arn:${data.aws_partition.current.partition}:s3:::${var.document_irsa.document_bucket}/masked/*",
        ]
      },
      {
        Sid      = "DocumentBucketWrite"
        Effect   = "Allow"
        Action   = "s3:PutObject"
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.document_irsa.document_bucket}/original/*"
      },
      {
        Sid      = "InvokeChatbot"
        Effect   = "Allow"
        Action   = "lambda:InvokeFunction"
        Resource = "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.document_irsa.chatbot_function_name}"
      },
    ]
  })
}

# community-service가 gb-community-translator (번역 Lambda) 를 호출하기 위한 IAM 역할입니다. EKS Pod Identity를 씁니다 (stage와 동형).
# 대상 Lambda는 IaC 밖에 있으므로 (AI팀 소유) prod 함수명이 확정되면 production/external.auto.tfvars에 채웁니다.
module "community_access" {
  source = "../../modules/pod-identity"
  count  = var.community_translator_function != null ? 1 : 0 # 함수명 (tfvars) 을 채우기 전에는 생성하지 않습니다.

  name            = "sb-prod-community-translator"
  cluster_name    = module.eks.cluster_name
  namespace       = "sb-prod-app-ns"
  service_account = "community" # gb-infra community 차트의 serviceAccountName과 일치시킵니다.

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "InvokeCommunityTranslator"
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = "arn:${data.aws_partition.current.partition}:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.community_translator_function}"
    }]
  })
}

# 온프렘 Jenkins 프론트 배포용 IAM User (정적 키) 입니다. SPA 버킷 sync, 프론트 PS 읽기, CloudFront 무효화에 씁니다.
module "frontend_deploy_iam" {
  source = "../../modules/frontend-deploy-iam"

  name                       = "sb-prod-frontend-deploy"
  spa_bucket                 = module.edge.spa_bucket_name
  cloudfront_distribution_id = module.edge.cloudfront_distribution_id
  frontend_ssm_prefix        = "/sb/prod/frontend"
}

# 프론트 배포 대상 (비밀 아님) 을 PS에 둡니다. Jenkins가 빌드/배포 시 읽어 하드코딩을 피합니다.
# 같은 /sb/prod/frontend 경로지만 VITE_OIDC_* 는 cognito 모듈이 소유하고, 배포 타겟 (버킷·distribution) 은 edge 산출이라 여기서 기입합니다.
resource "aws_ssm_parameter" "frontend_deploy_targets" {
  for_each = {
    SPA_BUCKET                 = module.edge.spa_bucket_name
    CLOUDFRONT_DISTRIBUTION_ID = module.edge.cloudfront_distribution_id
  }

  name  = "/sb/prod/frontend/${each.key}"
  type  = "String"
  value = each.value

  tags = { Name = "sb-prod-frontend-${each.key}" }
}

# apply 시 Jenkins 배포 자격증명을 exports/frontend-deploy-prod 에 자동으로 기록합니다
# (exports/eks-cp-<env>-dns-ip 등 다른 핸드오프와 같은 형식 — gitignored, 600).
resource "local_sensitive_file" "frontend_deploy_handoff" {
  filename        = "${path.root}/../../exports/frontend-deploy-prod"
  file_permission = "0600"

  content = join("\n", [
    "# === 프론트 배포 (온프렘 Jenkins) — AWS 자격증명 (prod) ===",
    "# Vault에 넣어 Jenkins credential로 사용합니다. 배포 대상 (버킷·distribution) 은 SSM /sb/prod/frontend/* 에서 읽습니다.",
    "# 키 회전: terraform apply -replace='module.frontend_deploy_iam.aws_iam_access_key.this'",
    "PROD_FRONTEND_DEPLOY_ACCESS_KEY_ID=${module.frontend_deploy_iam.access_key_id}",
    "PROD_FRONTEND_DEPLOY_SECRET_ACCESS_KEY=${module.frontend_deploy_iam.secret_access_key}",
    "# PRINCIPAL_ARN은 식별·감사 참조용입니다. Jenkins credential에는 위 ACCESS/SECRET만 등록합니다.",
    "PROD_FRONTEND_DEPLOY_PRINCIPAL_ARN=${module.frontend_deploy_iam.principal_arn}",
    "",
  ])
}

# 온프렘 ArgoCD cluster Secret입니다. apply 시 자동 기록되고 destroy 시 자동 삭제됩니다.
# argocd-iam 키 등 민감값을 담아 terraform이 라이프사이클을 관리하므로 (스크립트 산출물처럼 잔재로 남지 않습니다).
# 온프렘 연동 시에만 생성합니다. 적용: kubectl -n devops-system apply -f exports/argocd-prod-cluster.yaml
resource "local_sensitive_file" "argocd_cluster_handoff" {
  count = local.onprem_enabled ? 1 : 0

  filename        = "${path.root}/../../exports/argocd-prod-cluster.yaml"
  file_permission = "0600"

  content = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = module.eks.cluster_name
      namespace = "devops-system"
      labels    = { "argocd.argoproj.io/secret-type" = "cluster" }
    }
    type = "Opaque"
    stringData = {
      name       = module.eks.cluster_name
      server     = module.eks.cluster_endpoint
      namespaces = join(",", var.onprem_integration.argocd_namespaces)
      config = jsonencode({
        execProviderConfig = {
          apiVersion = "client.authentication.k8s.io/v1beta1"
          command    = "argocd-k8s-auth"
          args       = ["aws", "--cluster-name", module.eks.cluster_name]
          env = {
            AWS_ACCESS_KEY_ID     = module.argocd_iam[0].access_key_id
            AWS_SECRET_ACCESS_KEY = module.argocd_iam[0].secret_access_key
            AWS_REGION            = var.aws_region
          }
        }
        tlsClientConfig = {
          insecure = false
          caData   = module.eks.cluster_certificate_authority_data
        }
      })
    }
  })
}
