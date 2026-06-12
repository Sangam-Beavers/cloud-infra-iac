# ---------------------------------------------------------------------------
# 백엔드 진입점: HTTP API (public) → VPC Link → internal ALB (경로 라우팅)
#   → EKS 4서비스 (TargetGroupBinding으로 파드 등록).
# CloudFront 우회 차단 (origin-lock)은 internal ALB에 붙인 regional WAF가
# X-Origin-Verify 헤더를 검사해 수행합니다. WAF는 HTTP API에 직접 붙일 수 없으므로
# ALB에 연결합니다.
# ---------------------------------------------------------------------------

# 리전별 ELB 로그 전송 계정 (AWS 소유) — ALB access_logs 버킷 정책에 사용하며 계정 ID 하드코딩을 피합니다.
data "aws_elb_service_account" "current" {}

# origin-verify 비밀 — CloudFront가 origin 요청에 넣는 헤더 값이며 WAF가 이 값과 대조합니다.
# special=false 로 두면 헤더/URL 이스케이프 없이 WAF byte-match와 바이트 단위로 일치합니다.
resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

# 비밀은 SSM SecureString에 저장합니다 (회전·운영 참조용). 같은 스택의 edge 모듈은 origin_verify_secret 출력으로 받습니다.
resource "aws_ssm_parameter" "origin_verify" {
  name   = "${var.ssm_prefix}/origin-verify"
  type   = "SecureString"
  key_id = var.kms_key_arn
  value  = random_password.origin_verify.result

  tags = {
    Name = "${var.name}-origin-verify"
  }
}

# TargetGroupBinding용 정보 (서비스별 target group ARN + 컨테이너 포트)를 SSM (Parameter Store)에 게시합니다.
# TGB의 targetGroupARN은 CR spec 필드라 ESO (Secret)로 채울 수 없으므로 PS에 두고, install-k8s-stack의
# tgb phase (terraform↔cluster 글루)가 끌어와 TargetGroupBinding을 만듭니다. 비밀이 아니므로 String 입니다.
resource "aws_ssm_parameter" "tgb" {
  for_each = var.tgb_ssm_prefix == "" ? {} : var.services
  name     = "${var.tgb_ssm_prefix}/${each.key}"
  type     = "String"
  value    = jsonencode({ arn = aws_lb_target_group.this[each.key].arn, port = each.value.port })

  tags = {
    Name = "${var.name}-tgb-${each.key}"
  }
}

resource "aws_ssm_parameter" "tgb_alb_sg" {
  count = var.tgb_ssm_prefix == "" ? 0 : 1
  name  = "${var.tgb_ssm_prefix}/alb_sg"
  type  = "String"
  value = aws_security_group.alb.id

  tags = {
    Name = "${var.name}-tgb-alb-sg"
  }
}

# ---------------------------------------------------------------------------
# 보안 그룹 — VPC Link ENI → 내부 ALB
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name = "${var.name}-vpclink-sg"
  # 주의: SG description은 ASCII만 허용되며 한글은 사용할 수 없습니다.
  description = "API Gateway VPC Link ENIs for ${var.name}: egress to internal ALB"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-vpclink-sg"
  }
}

resource "aws_security_group" "alb" {
  name = "${var.name}-alb-sg"
  # 주의: SG description은 ASCII만 허용되며 한글은 사용할 수 없습니다.
  description = "Internal ALB for ${var.name}: listener port from VPC Link SG only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP from API Gateway VPC Link"
    from_port       = var.listener_port
    to_port         = var.listener_port
    protocol        = "tcp"
    security_groups = [aws_security_group.vpc_link.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-alb-sg"
  }
}

# ---------------------------------------------------------------------------
# 내부 ALB + 서비스별 타깃 그룹 (target-type=ip 로 Cilium ENI 파드 IP에 직결)
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # 헤더 스무글링을 방지하기 위해 잘못된 헤더 필드를 제거합니다.
  drop_invalid_header_fields = true

  # per-target 백엔드 포렌식을 위해 전용 버킷에 액세스 로그를 남깁니다 (ALB는 SSE-S3만 지원).
  access_logs {
    bucket  = aws_s3_bucket.alb_logs.id
    prefix  = var.name
    enabled = true
  }

  # 버킷 정책이 먼저 있어야 ALB 생성 시 로그 쓰기 검증을 통과합니다.
  depends_on = [aws_s3_bucket_policy.alb_logs]

  tags = {
    Name = "${var.name}-alb"
  }
}

# 타깃은 Terraform이 등록하지 않습니다 — 클러스터 내 ALB Controller가 TargetGroupBinding으로 채웁니다.
resource "aws_lb_target_group" "this" {
  for_each = var.services

  name        = "${var.name}-${each.key}"
  port        = each.value.port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = each.value.health_check_path
    port                = "traffic-port"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 15
    timeout             = 5
    matcher             = "200-399"
  }

  tags = {
    Name = "${var.name}-${each.key}"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = var.listener_port
  protocol          = "HTTP"

  # 매칭되는 경로 룰이 없으면 404를 반환합니다 (라우팅 누락을 명확히 드러냄).
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "application/json"
      message_body = "{\"error\":\"no route\"}"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener_rule" "this" {
  for_each = var.services

  listener_arn = aws_lb_listener.http.arn
  priority     = each.value.priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }

  condition {
    path_pattern {
      values = each.value.path_patterns
    }
  }
}

# ---------------------------------------------------------------------------
# VPC Link + HTTP API (public) → 내부 ALB 리스너
# ---------------------------------------------------------------------------

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${var.name}-vpclink"
  subnet_ids         = var.subnet_ids
  security_group_ids = [aws_security_group.vpc_link.id]

  tags = {
    Name = "${var.name}-vpclink"
  }
}

resource "aws_apigatewayv2_api" "this" {
  name          = "${var.name}-http-api"
  protocol_type = "HTTP"

  tags = {
    Name = "${var.name}-http-api"
  }
}

resource "aws_apigatewayv2_integration" "this" {
  api_id           = aws_apigatewayv2_api.this.id
  integration_type = "HTTP_PROXY"
  # ALB private 통합 — integration_uri는 ALB "리스너" ARN 입니다 (LB ARN이 아님).
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  integration_uri        = aws_lb_listener.http.arn
  payload_format_version = "1.0" # ALB VPC_LINK HTTP_PROXY는 1.0이 필수입니다.
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.this.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.this.id}"
}

resource "aws_cloudwatch_log_group" "access" {
  name              = "/aws/apigateway/${var.name}"
  retention_in_days = var.log_retention_in_days
  kms_key_id        = var.kms_key_arn

  tags = {
    Name = "${var.name}-access-logs"
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.this.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.access.arn
    format = jsonencode({
      requestId        = "$context.requestId"
      ip               = "$context.identity.sourceIp"
      requestTime      = "$context.requestTime"
      httpMethod       = "$context.httpMethod"
      routeKey         = "$context.routeKey"
      path             = "$context.path"
      status           = "$context.status"
      integrationError = "$context.integrationErrorMessage"
    })
  }

  tags = {
    Name = "${var.name}-stage"
  }
}

# ---------------------------------------------------------------------------
# regional WAF (origin-lock) — 내부 ALB에 연결합니다.
#   rule1: IP당 rate-limit 백스톱
#   rule2: X-Origin-Verify 헤더가 비밀과 정확히 일치하지 않으면 차단
# ---------------------------------------------------------------------------

resource "aws_wafv2_web_acl" "this" {
  name  = "${var.name}-origin-lock"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  rule {
    name     = "rate-limit"
    priority = 1

    action {
      block {}
    }

    statement {
      rate_based_statement {
        limit              = var.waf_rate_limit
        aggregate_key_type = "IP"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-rate-limit"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "origin-verify"
    priority = 2

    action {
      block {}
    }

    # 헤더가 비밀과 "일치하지 않으면" 차단합니다 (not + EXACTLY). 헤더명은 반드시 소문자여야 합니다.
    statement {
      not_statement {
        statement {
          byte_match_statement {
            positional_constraint = "EXACTLY"
            search_string         = random_password.origin_verify.result

            field_to_match {
              single_header {
                name = "x-origin-verify"
              }
            }

            text_transformation {
              priority = 0
              type     = "NONE"
            }
          }
        }
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-origin-verify"
      sampled_requests_enabled   = true
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-web-acl"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.name}-origin-lock"
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.this.arn
  web_acl_arn  = aws_wafv2_web_acl.this.arn
}

# ---------------------------------------------------------------------------
# ALB access_logs 전용 S3 버킷 — SSE-S3 (AES256, ALB는 CMK 미지원) 적용, public 차단
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "alb_logs" {
  bucket_prefix = "${var.name}-alb-logs-"

  tags = { Name = "${var.name}-alb-logs" }
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256" # ALB access_logs는 SSE-KMS 미지원
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.log_retention_in_days
    }
  }
}

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowELBLogDelivery"
      Effect    = "Allow"
      Principal = { AWS = data.aws_elb_service_account.current.arn }
      Action    = "s3:PutObject"
      Resource  = "${aws_s3_bucket.alb_logs.arn}/*"
    }]
  })
}

# ---------------------------------------------------------------------------
# ALB WAF 로깅 — 차단/탐지 전수 로그를 CW Logs로 보냅니다 (CMK 암호화, 민감 헤더 redact)
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "waf_alb" {
  name              = "aws-waf-logs-${var.name}-alb" # WAF 로깅은 이름 접두사 aws-waf-logs- 가 필수입니다.
  retention_in_days = var.log_retention_in_days
  kms_key_id        = var.kms_key_arn

  tags = { Name = "aws-waf-logs-${var.name}-alb" }
}

resource "aws_wafv2_web_acl_logging_configuration" "alb" {
  log_destination_configs = [aws_cloudwatch_log_group.waf_alb.arn]
  resource_arn            = aws_wafv2_web_acl.this.arn

  redacted_fields {
    single_header {
      name = "x-origin-verify"
    }
  }
  redacted_fields {
    single_header {
      name = "authorization"
    }
  }
}
