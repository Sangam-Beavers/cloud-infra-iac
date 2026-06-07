resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-subnets"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.name}-subnets"
  }
}

resource "aws_security_group" "this" {
  name = "${var.name}-sg"
  # 주의: SG description은 ASCII만 허용 (한글 불가)
  description = "Valkey ${var.name}: allow 6379 from private/mgmt subnets only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Valkey from private(app)/mgmt subnets"
    from_port   = 6379
    to_port     = 6379
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
    Name = "${var.name}-sg"
  }
}

resource "aws_elasticache_parameter_group" "this" {
  # 패밀리 변경 (엔진 메이저 업그레이드) 시 이름이 함께 바뀌어야 교체 가능
  name        = "${var.name}-${var.parameter_group_family}"
  family      = var.parameter_group_family
  description = "Eviction policy for session/token workload"

  parameter {
    name  = "maxmemory-policy"
    value = var.maxmemory_policy
  }

  # 교체 시 "새 그룹 생성 → 복제 그룹 전환 → 옛 그룹 삭제" 순서 보장
  # (기본 순서인 삭제-우선은 사용 중인 그룹이라 항상 실패)
  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = var.name
  description          = "Shared Valkey for MSA services (session/token store)"

  engine         = "valkey"
  engine_version = var.engine_version
  node_type      = var.node_type
  port           = 6379

  # 클러스터 모드 비활성: primary 1 + replica (node_count - 1)
  num_cache_clusters         = var.node_count
  automatic_failover_enabled = var.node_count > 1
  multi_az_enabled           = var.node_count > 1

  # 암호화: 저장 (CMK) + 전송 (TLS).
  # AUTH 토큰은 scripts/bootstrap-redis.sh로 설정 — Terraform state에 남기지 않음
  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true

  parameter_group_name = aws_elasticache_parameter_group.this.name
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.this.id]

  snapshot_retention_limit = var.snapshot_retention
  # apply_immediately=true: node_type/버전 등 변경을 유지보수 창구 대기 없이 즉시 반영 (순단 가능)
  apply_immediately = true

  tags = {
    Name = var.name
  }
}
