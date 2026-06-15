data "aws_region" "current" {}

# ---------------------------------------------------------------------------
# YACE (CloudWatch exporter) IAM — Aurora/ElastiCache 매니지드 전용 지표를 Prometheus로 끌어옵니다.
# 신원은 Pod Identity이며 community/document와 동일하게 modules/pod-identity를 재사용합니다 (수렴 원칙).
# CloudWatch read 액션(GetMetricData·GetMetricStatistics·ListMetrics)과 tag:GetResources는 IAM 리소스
# 스코핑을 지원하지 않아 Resource="*"가 필수입니다 (read 전용이라 blast radius는 지표 조회로 한정).
# YACE 차트·대시보드 자체는 gb-infra(monitoring-stack)가 배포하고, 여기서는 IAM + VPC 엔드포인트만 관리합니다.
# ---------------------------------------------------------------------------
module "identity" {
  source = "../pod-identity"

  name            = var.name
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "CloudWatchReadOnly"
      Effect   = "Allow"
      Action   = ["cloudwatch:GetMetricData", "cloudwatch:GetMetricStatistics", "cloudwatch:ListMetrics", "tag:GetResources"]
      Resource = "*"
    }]
  })
}

# ---------------------------------------------------------------------------
# VPC 인터페이스 엔드포인트 — private-only 클러스터(인터넷 egress 없음)라 YACE가 CloudWatch/태그 API에
# 나가려면 필요합니다. mgmt 서브넷 + 재사용 SG(jumphost endpoints), Private DNS 활성.
# ---------------------------------------------------------------------------
resource "aws_vpc_endpoint" "this" {
  for_each = toset(["monitoring", "tagging"])

  vpc_id              = var.vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.subnet_ids
  security_group_ids  = [var.security_group_id]
  private_dns_enabled = true

  tags = { Name = "${var.name}-${each.key}" }
}
