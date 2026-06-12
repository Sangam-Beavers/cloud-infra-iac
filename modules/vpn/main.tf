data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# 검증된 구성과 동일한 Ubuntu를 사용합니다. user_data가 apt 기반이라 AL2023은 쓸 수 없습니다 (AL2023에는 frr 패키지가 없습니다).
data "aws_ami" "ubuntu_arm" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-arm64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# ---------------------------------------------------------------------------
# EIP — 고정 공인 IP (pfSense가 이 주소로 연결합니다). ASG 재기동 시 user_data가 다시 연결합니다.
# ---------------------------------------------------------------------------

resource "aws_eip" "this" {
  domain = "vpc"

  tags = {
    Name = "${var.name}-eip"
  }
}

# ---------------------------------------------------------------------------
# SG — WireGuard UDP만 인바운드로 허용합니다 (SSH는 열지 않고 관리는 SSM으로 합니다).
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name = "${var.name}-sg"
  # SG description은 ASCII만 허용하므로 한글을 쓸 수 없습니다.
  description = "WireGuard VPN router: UDP tunnel ports only"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.tunnels
    content {
      description = "WireGuard ${ingress.key}"
      from_port   = ingress.value.listen_port
      to_port     = ingress.value.listen_port
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"] # 온프렘 공인 IP가 유동이라 전체를 열지만, WG는 유효 키 없는 패킷에 응답하지 않아 노출 위험이 낮습니다.
    }
  }

  # forward 트래픽 ingress — 흐름별로 최소 포트만 엽니다. 허용하지 않으면 ENI에서 drop되어 AWS→on-prem 경로가 막힙니다.
  # private (EKS 노드) → Harbor 이미지 pull (TCP 443)
  dynamic "ingress" {
    for_each = length(var.forward_harbor_cidrs) > 0 ? [1] : []
    content {
      description = "forward: private to on-prem Harbor (TCP)"
      from_port   = var.forward_harbor_port
      to_port     = var.forward_harbor_port
      protocol    = "tcp"
      cidr_blocks = var.forward_harbor_cidrs
    }
  }

  # mgmt (resolver outbound 엔드포인트) → on-prem DNS (UDP 53 + TCP 53)
  # TCP는 512B 초과 응답과 DNSSEC truncate 재시도를 위한 것으로, resolver outbound SG와 대칭을 이룹니다.
  dynamic "ingress" {
    for_each = length(var.forward_dns_cidrs) > 0 ? ["udp", "tcp"] : []
    content {
      description = "forward: mgmt to on-prem DNS (${ingress.value})"
      from_port   = 53
      to_port     = 53
      protocol    = ingress.value
      cidr_blocks = var.forward_dns_cidrs
    }
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-sg"
  }
}

# ---------------------------------------------------------------------------
# IAM — SSM 접속 + 셀프힐링 (EIP/RT 조작) + WG 키 조회
# ---------------------------------------------------------------------------

resource "aws_iam_role" "this" {
  name = "${var.name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "self_healing" {
  name = "${var.name}-self-healing"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 가장 위험한 액션 (라우트 변경은 트래픽 하이재킹으로 이어질 수 있습니다)은 우리 return 라우트 테이블로만 제한합니다.
        Sid    = "ManageReturnRoutes"
        Effect = "Allow"
        Action = ["ec2:ReplaceRoute", "ec2:CreateRoute"]
        Resource = [
          for rtb in concat(var.return_route_table_ids, var.app_route_table_ids) :
          "arn:${data.aws_partition.current.partition}:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:route-table/${rtb}"
        ]
      },
      {
        # EIP 재연결과 src/dst check 해제용입니다. EC2가 리소스 레벨 제약을 충분히 지원하지 않아
        # Resource=*로 두되, 최소한 배포 리전으로 한정합니다.
        Sid      = "SelfHealingEipEni"
        Effect   = "Allow"
        Action   = ["ec2:AssociateAddress", "ec2:ModifyNetworkInterfaceAttribute"]
        Resource = "*"
        Condition = {
          StringEquals = { "aws:RequestedRegion" = data.aws_region.current.region }
        }
      },
      {
        Sid      = "DescribeRoutes"
        Effect   = "Allow"
        Action   = ["ec2:DescribeRouteTables"]
        Resource = "*"
      },
      {
        Sid      = "ReadWireguardKeys"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/*"
      },
      {
        Sid      = "DecryptWithEnvCmk"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.kms_key_arn
      }
    ]
  })
}

resource "aws_iam_instance_profile" "this" {
  name = "${var.name}-profile"
  role = aws_iam_role.this.name
}

# ---------------------------------------------------------------------------
# Launch Template + ASG (min=max=desired=1) — AZ 장애 시 자동으로 재기동하고 셀프힐링합니다.
# ---------------------------------------------------------------------------

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ami.ubuntu_arm.id
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  vpc_security_group_ids = [aws_security_group.this.id]

  user_data = base64encode(templatefile("${path.module}/userdata.sh.tpl", {
    allocation_id           = aws_eip.this.allocation_id
    return_route_table_ids  = var.return_route_table_ids
    onprem_cidrs            = var.onprem_cidrs
    advertise_cidrs         = var.advertise_cidrs
    tunnels                 = var.tunnels
    ssm_prefix              = var.ssm_prefix
    bgp_router_id           = var.bgp_router_id
    bgp_local_as            = var.bgp_local_as
    bgp_peer_as             = var.bgp_peer_as
    pfsense_nat_ip          = var.pfsense_nat_ip
    app_route_table_ids     = var.app_route_table_ids
    app_onprem_destinations = var.app_onprem_destinations
    snat_source_cidrs       = var.snat_source_cidrs
    wg_mtu                  = var.wg_mtu
  }))

  block_device_mappings {
    device_name = "/dev/sda1" # Ubuntu 루트 디바이스
    ebs {
      volume_size = 16
      volume_type = "gp3"
      encrypted   = true
    }
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  tag_specifications {
    resource_type = "instance"
    tags = merge(
      { Name = var.name },
      var.instance_extra_tags
    )
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(
      { Name = var.name },
      var.instance_extra_tags
    )
  }
}

resource "aws_autoscaling_group" "this" {
  name                = "${var.name}-asg"
  min_size            = 1
  max_size            = 1
  desired_capacity    = 1
  vpc_zone_identifier = var.subnet_ids

  launch_template {
    id      = aws_launch_template.this.id
    version = aws_launch_template.this.latest_version
  }

  health_check_type         = "EC2"
  health_check_grace_period = 180

  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }
}
