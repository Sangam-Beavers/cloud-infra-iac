resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-subnets"
  subnet_ids = var.subnet_ids

  tags = {
    Name = "${var.name}-subnets"
  }
}

resource "aws_security_group" "this" {
  name = "${var.name}-aurora-sg"
  # SG description 필드는 ASCII만 허용하므로 영문으로 작성합니다 (한글 불가).
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
    cidr_blocks = [var.vpc_cidr] # VPC 대역 한정 — 관리평면 외 외부 exfil 차단 (라우팅이 1차, SG가 2차 방어)
  }

  tags = {
    Name = "${var.name}-aurora-sg"
  }
}

# RDS가 자동 생성하는 export 로그그룹을 Terraform이 명시적으로 소유합니다. destroy 시 함께 삭제해 고아를
# 방지하고 retention/CMK도 코드로 통제하며, 클러스터가 이 그룹을 채택하도록 depends_on으로 먼저 생성합니다.
resource "aws_cloudwatch_log_group" "exports" {
  for_each = toset(["audit", "error", "slowquery"])

  name              = "/aws/rds/cluster/${var.name}/${each.value}"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = "${var.name}-${each.value}-logs"
  }
}

resource "aws_rds_cluster" "this" {
  cluster_identifier = var.name
  engine             = "aurora-mysql"
  engine_version     = var.engine_version

  # 마스터 암호는 AWS가 생성·저장·로테이션하므로 Terraform state에 남지 않습니다.
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
  # apply_immediately=true: 스펙/버전 변경을 유지보수 창 대기 없이 즉시 반영합니다 (운영 중 순단 가능).
  apply_immediately = true

  # 감사/포렌식 로그를 CloudWatch Logs로 내보냅니다 (audit는 아래 파라미터그룹의 server_audit 플러그인 필요).
  enabled_cloudwatch_logs_exports = ["audit", "error", "slowquery"]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.this.name

  # 위 export 로그그룹을 먼저 생성해 RDS가 이를 채택하도록 보장합니다.
  depends_on = [aws_cloudwatch_log_group.exports]

  # Serverless v2: 인스턴스 클래스가 db.serverless일 때 ACU 범위를 지정합니다.
  dynamic "serverlessv2_scaling_configuration" {
    for_each = var.instance_class == "db.serverless" ? [1] : []
    content {
      min_capacity = var.serverless_min_acu
      max_capacity = var.serverless_max_acu
    }
  }

  tags = {
    Name = var.name
    # 논리 DB 목록 (부트스트랩 스크립트 참고용). RDS 태그 값은 쉼표를 허용하지 않아 공백으로 구분합니다.
    Databases = join(" ", var.databases)
  }
}

# 클러스터 파라미터그룹 — server_audit 플러그인으로 audit 로그를 생성합니다 (위 CW exports의 "audit"가 이를 사용).
resource "aws_rds_cluster_parameter_group" "this" {
  # 패밀리 변경 (엔진 메이저 업그레이드) 시 이름이 함께 바뀌어야 교체할 수 있습니다 (create_before_destroy 동명 충돌 방지).
  name        = "${var.name}-cluster-${var.parameter_group_family}"
  family      = var.parameter_group_family
  description = "${var.name} aurora-mysql cluster params (server_audit logging)"

  parameter {
    name  = "server_audit_logging"
    value = "1"
  }
  parameter {
    # QUERY 전체를 남기면 볼륨이 폭증하므로 연결·DDL·DCL만 기록합니다 (접속·스키마 변경·권한 변경 추적).
    name  = "server_audit_events"
    value = "CONNECT,QUERY_DDL,QUERY_DCL"
  }

  tags = { Name = "${var.name}-cluster-${var.parameter_group_family}" }

  # 교체 시 "새 그룹 생성 → 클러스터 전환 → 옛 그룹 삭제" 순서를 보장합니다 (기본 삭제-우선 순서는 사용 중인 그룹이라 항상 실패).
  lifecycle {
    create_before_destroy = true
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
