# ---------------------------------------------------------------------------
# 백엔드 진입점: HTTP API (public) → VPC Link → internal ALB (경로 라우팅)
#   → EKS 4서비스 (TargetGroupBinding으로 파드 등록).
# CloudFront 우회 차단 (origin-lock)은 internal ALB에 붙인 regional WAF가
# X-Origin-Verify 헤더를 검사해 수행한다 (WAF는 HTTP API에 직접 못 붙으므로 ALB에).
# ---------------------------------------------------------------------------

# origin-verify 비밀 — CloudFront가 origin 요청에 넣는 헤더 값. WAF가 이 값과 대조.
# special=false: 헤더/URL 이스케이프 없이 WAF byte-match와 바이트 단위로 일치
resource "random_password" "origin_verify" {
  length  = 40
  special = false
}

# 비밀은 SSM SecureString에 저장 (회전·운영 참조용). 같은 스택의 edge 모듈은 origin_verify_secret 출력으로 받는다
resource "aws_ssm_parameter" "origin_verify" {
  name   = "${var.ssm_prefix}/origin-verify"
  type   = "SecureString"
  key_id = var.kms_key_arn
  value  = random_password.origin_verify.result

  tags = {
    Name = "${var.name}-origin-verify"
  }
}

# ---------------------------------------------------------------------------
# 보안 그룹 — VPC Link ENI → 내부 ALB
# ---------------------------------------------------------------------------

resource "aws_security_group" "vpc_link" {
  name = "${var.name}-vpclink-sg"
  # 주의: SG description은 ASCII만 허용 (한글 불가)
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
  # 주의: SG description은 ASCII만 허용 (한글 불가)
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
# 내부 ALB + 서비스별 타깃 그룹 (target-type=ip, Cilium ENI 파드 IP 직결)
# ---------------------------------------------------------------------------

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  internal           = true
  load_balancer_type = "application"
  subnets            = var.subnet_ids
  security_groups    = [aws_security_group.alb.id]

  # 헤더 스무글링 방지 — 잘못된 헤더 필드 제거
  drop_invalid_header_fields = true

  tags = {
    Name = "${var.name}-alb"
  }
}

# 타깃은 Terraform이 등록하지 않는다 — 클러스터 내 ALB Controller가 TargetGroupBinding으로 채움
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

  # 매칭되는 경로 룰이 없으면 404 (라우팅 누락을 명확히)
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
  # ALB private 통합 — integration_uri는 ALB "리스너" ARN (LB ARN 아님)
  integration_method     = "ANY"
  connection_type        = "VPC_LINK"
  connection_id          = aws_apigatewayv2_vpc_link.this.id
  integration_uri        = aws_lb_listener.http.arn
  payload_format_version = "1.0" # ALB VPC_LINK HTTP_PROXY는 1.0 필수
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
# regional WAF (origin-lock) — 내부 ALB에 연결
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
    name     = "origin-verify"
    priority = 2

    action {
      block {}
    }

    # 헤더가 비밀과 "일치하지 않으면" 차단 (not + EXACTLY). 헤더명은 반드시 소문자
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
