resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-subnets"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.name}-subnets"
  }
}

resource "aws_security_group" "this" {
  name = "${var.name}-aurora-sg"
  # 주의: SG description은 ASCII만 허용 (한글 불가)
  description = "Aurora ${var.name}: allow 3306 from private/mgmt subnets only"
  vpc_id      = var.vpc_id

  ingress {
    description = "MySQL from private(app)/mgmt subnets"
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-aurora-sg"
  }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = var.name
  engine             = "aurora-mysql"
  engine_version     = var.engine_version

  # 마스터 암호는 AWS가 생성·저장·로테이션 — Terraform state에 남지 않음
  master_username               = "admin"
  manage_master_user_password   = true
  master_user_secret_kms_key_id = var.kms_key_arn

  storage_encrypted = true
  kms_key_id        = var.kms_key_arn

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.this.id]

  backup_retention_period   = var.backup_retention_period
  skip_final_snapshot       = var.skip_final_snapshot
  final_snapshot_identifier = "${var.name}-final"
  deletion_protection       = var.deletion_protection
  # apply_immediately=true: 스펙/버전 변경을 유지보수 창구 대기 없이 즉시 반영 (운영 중 순단 가능)
  apply_immediately = true

  # Serverless v2: 인스턴스 클래스가 db.serverless일 때 ACU 범위 지정
  dynamic "serverlessv2_scaling_configuration" {
    for_each = var.instance_class == "db.serverless" ? [1] : []
    content {
      min_capacity = var.serverless_min_acu
      max_capacity = var.serverless_max_acu
    }
  }

  tags = {
    Name = var.name
    # 논리 DB 목록 (부트스트랩 스크립트 참고용) — RDS 태그 값에 쉼표 불허, 공백 구분
    Databases = join(" ", var.databases)
  }
}

resource "aws_rds_cluster_instance" "this" {
  count = var.instance_count

  identifier         = "${var.name}-${count.index + 1}"
  cluster_identifier = aws_rds_cluster.this.id
  engine             = aws_rds_cluster.this.engine
  engine_version     = aws_rds_cluster.this.engine_version
  instance_class     = var.instance_class

  tags = {
    Name = "${var.name}-${count.index + 1}"
  }
}
