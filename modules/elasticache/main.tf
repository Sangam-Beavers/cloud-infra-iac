resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-subnets"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.name}-subnets"
  }
}

resource "aws_security_group" "this" {
  name = "${var.name}-sg"
  # SG description은 ASCII만 허용하므로 한글을 쓸 수 없습니다.
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
    cidr_blocks = [var.vpc_cidr] # VPC 대역 한정 (관리평면 외 외부 exfil 차단 — 라우팅이 1차, SG가 2차 방어)
  }

  tags = {
    Name = "${var.name}-sg"
  }
}

resource "aws_elasticache_parameter_group" "this" {
  # 패밀리 변경 (엔진 메이저 업그레이드) 시 이름이 함께 바뀌어야 교체가 가능합니다.
  name        = "${var.name}-${var.parameter_group_family}"
  family      = var.parameter_group_family
  description = "Eviction policy for session/token workload"

  parameter {
    name  = "maxmemory-policy"
    value = var.maxmemory_policy
  }

  # 교체 시 "새 그룹 생성 → 복제 그룹 전환 → 옛 그룹 삭제" 순서를 보장합니다.
  # 기본 순서인 삭제-우선은 사용 중인 그룹이라 항상 실패하기 때문입니다.
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

  # 클러스터 모드를 비활성화하여 primary 1대와 replica (node_count - 1)대로 구성합니다.
  num_cache_clusters         = var.node_count
  automatic_failover_enabled = var.node_count > 1
  multi_az_enabled           = var.node_count > 1

  # 저장 데이터는 CMK로, 전송 구간은 TLS로 암호화합니다.
  # AUTH 토큰은 scripts/bootstrap-redis.sh로 설정하여 Terraform state에 남기지 않습니다.
  at_rest_encryption_enabled = true
  kms_key_id                 = var.kms_key_arn
  transit_encryption_enabled = true

  parameter_group_name = aws_elasticache_parameter_group.this.name
  subnet_group_name    = aws_elasticache_subnet_group.this.name
  security_group_ids   = [aws_security_group.this.id]

  snapshot_retention_limit = var.snapshot_retention
  # apply_immediately=true로 node_type/버전 등의 변경을 유지보수 창구 대기 없이 즉시 반영합니다 (순단 가능).
  apply_immediately = true

  lifecycle {
    # AUTH 토큰은 bootstrap-redis.sh가 API로 설정하므로, Terraform이 드리프트로 보지 않도록 무시합니다.
    ignore_changes = [auth_token]
  }

  tags = {
    Name = var.name
  }
}
