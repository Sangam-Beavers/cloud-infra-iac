data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

# ---------------------------------------------------------------------------
# 인터페이스 엔드포인트 — mgmt는 NAT 없는 격리 구역이므로 필수.
#   ssm/ssmmessages/ec2messages: Session Manager 접속용
#   secretsmanager: DB 부트스트랩 등 점프 호스트에서의 비밀 조회/생성용
# ASG가 어느 AZ에 점프 호스트를 띄워도 닿도록 전체 mgmt AZ에 ENI 분산.
# ---------------------------------------------------------------------------

resource "aws_security_group" "endpoints" {
  name = "${var.name}-vpce-sg"
  # 주의: SG description은 ASCII만 허용 (한글 불가)
  description = "SSM interface endpoints: allow 443 from VPC"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-vpce-sg"
  }
}

resource "aws_vpc_endpoint" "ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages", "secretsmanager"])

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = {
    Name = "${var.name}-vpce-${each.key}"
  }
}

# ---------------------------------------------------------------------------
# 점프 호스트 IAM — SSM 접속 + DB 부트스트랩 (Secrets Manager/KMS) 권한
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

# bootstrap-db.sh 실행에 필요한 최소 권한
resource "aws_iam_role_policy" "bootstrap" {
  name = "${var.name}-bootstrap"
  role = aws_iam_role.this.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ReadMasterAndServiceSecrets"
        Effect = "Allow"
        Action = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        # rds!* = RDS 관리형 마스터 비밀, sb/* = 서비스 비밀 — 그 외 비밀은 접근 불가
        Resource = [
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:rds!*",
          "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_prefix}*",
        ]
      },
      {
        Sid      = "UpsertServiceSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:CreateSecret", "secretsmanager:PutSecretValue", "secretsmanager:TagResource"]
        Resource = "arn:aws:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.secret_prefix}*"
      },
      {
        Sid      = "GetRandomPassword"
        Effect   = "Allow"
        Action   = "secretsmanager:GetRandomPassword"
        Resource = "*"
      },
      {
        Sid      = "UseEnvironmentCmk"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:GenerateDataKey"]
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
# 시작 템플릿 + ASG (min=max=desired=1) — AZ 장애 시 다른 AZ에 자동 재기동
# ---------------------------------------------------------------------------

data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

resource "aws_launch_template" "this" {
  name_prefix   = "${var.name}-"
  image_id      = data.aws_ssm_parameter.al2023_arm.value
  instance_type = var.instance_type

  iam_instance_profile {
    name = aws_iam_instance_profile.this.name
  }

  vpc_security_group_ids = [aws_security_group.jump.id]

  # 관리 도구 설치 (mysql/redis 클라이언트, jq)
  # 격리 서브넷의 dnf는 S3 게이트웨이 엔드포인트가 준비된 후에만 동작하므로
  # 네트워크 준비 지연에 대비해 재시도 루프로 감싼다
  user_data = base64encode(<<-EOT
    #!/bin/bash
    for i in $(seq 1 30); do
      dnf install -y mariadb105 jq && break
      echo "dnf retry $i" >> /var/log/bootstrap-tools.log
      sleep 10
    done
    dnf install -y redis6 || true
  EOT
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size = 20
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

resource "aws_security_group" "jump" {
  name = "${var.name}-sg"
  # 인바운드 불필요 — SSM은 아웃바운드 443으로만 동작 (SSH 미사용)
  description = "Jump host: no ingress, egress only (SSM outbound model)"
  vpc_id      = var.vpc_id

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
  health_check_grace_period = 120

  tag {
    key                 = "Name"
    value               = var.name
    propagate_at_launch = true
  }
}
