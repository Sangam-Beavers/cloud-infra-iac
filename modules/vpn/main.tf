data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# 검증된 구성과 동일한 Ubuntu (apt 기반 user_data — AL2023엔 frr 패키지 없음)
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
# EIP — 고정 공인 IP (pfSense가 이 주소로 연결). ASG 재기동 시 user_data가 재연결
# ---------------------------------------------------------------------------

resource "aws_eip" "this" {
  domain = "vpc"

  tags = {
    Name = "${var.name}-eip"
  }
}

# ---------------------------------------------------------------------------
# SG — WireGuard UDP만 인바운드 (SSH 없음, 관리는 SSM)
# ---------------------------------------------------------------------------

resource "aws_security_group" "this" {
  name = "${var.name}-sg"
  # 주의: SG description은 ASCII만 허용 (한글 불가)
  description = "WireGuard VPN router: UDP tunnel ports only"
  vpc_id      = var.vpc_id

  dynamic "ingress" {
    for_each = var.tunnels
    content {
      description = "WireGuard ${ingress.key}"
      from_port   = ingress.value.listen_port
      to_port     = ingress.value.listen_port
      protocol    = "udp"
      cidr_blocks = ["0.0.0.0/0"] # 온프렘 공인 IP 유동 — WG는 무키 패킷에 무응답이라 노출 위험 낮음
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
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "self_healing" {
  name = "${var.name}-self-healing"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 가장 위험한 액션 (라우트 변경 = 트래픽 하이재킹)은 우리 return 라우트 테이블로만 제한
        Sid    = "ManageReturnRoutes"
        Effect = "Allow"
        Action = ["ec2:ReplaceRoute", "ec2:CreateRoute"]
        Resource = [
          for rtb in var.return_route_table_ids :
          "arn:aws:ec2:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:route-table/${rtb}"
        ]
      },
      {
        # EIP 재연결·src/dst check 해제 — EC2가 리소스 레벨 제약을 충분히 지원하지 않아
        # Resource=*이나, 최소한 배포 리전으로 한정
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
        Resource = "arn:aws:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/*"
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
# Launch Template + ASG (min=max=desired=1) — AZ 장애 시 자동 재기동 + 셀프힐링
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
    allocation_id          = aws_eip.this.allocation_id
    return_route_table_ids = var.return_route_table_ids
    onprem_cidrs           = var.onprem_cidrs
    advertise_cidrs        = var.advertise_cidrs
    tunnels                = var.tunnels
    ssm_prefix             = var.ssm_prefix
    bgp_router_id          = var.bgp_router_id
    bgp_local_as           = var.bgp_local_as
    bgp_peer_as            = var.bgp_peer_as
    pfsense_nat_ip         = var.pfsense_nat_ip
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
