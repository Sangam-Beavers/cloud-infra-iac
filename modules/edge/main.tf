# ---------------------------------------------------------------------------
# 엣지: 비공개 S3 (정적 SPA) + CloudFront + CLOUDFRONT-scope WAF.
# CloudFront는 OAC로 S3를 읽고, api_origin이 있으면 /api/* 를 API Gateway로 보냅니다.
# 이때 X-Origin-Verify 헤더를 주입해 ALB regional WAF의 origin-lock을 통과합니다.
# ---------------------------------------------------------------------------

locals {
  use_domain = var.domain != ""
}

# SPA 정적 자산 버킷 (비공개). 버킷명은 전역 유일이어야 하므로 prefix만 주고 suffix는 AWS가 붙입니다.
resource "aws_s3_bucket" "spa" {
  bucket_prefix = "${var.name}-spa-"
  force_destroy = true # 정적 SPA 자산은 재배포 가능하므로 destroy 시 객체째 삭제합니다 (down-*가 비어있지 않은 버킷에 막히지 않도록).
}

resource "aws_s3_bucket_public_access_block" "spa" {
  bucket                  = aws_s3_bucket.spa.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 정적 자산 롤백에 대비한 버전 관리
resource "aws_s3_bucket_versioning" "spa" {
  bucket = aws_s3_bucket.spa.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3 (AES256) — 자산은 비밀이 아니므로 CMK가 필요 없습니다. OAC에 CMK Decrypt 권한이 따라붙는 복잡도를 피합니다.
resource "aws_s3_bucket_server_side_encryption_configuration" "spa" {
  bucket = aws_s3_bucket.spa.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# CloudFront가 비공개 S3를 읽는 통로 (OAC) — 요청을 SigV4로 서명합니다.
resource "aws_cloudfront_origin_access_control" "spa" {
  name                              = "${var.name}-spa-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# 관리형 캐시 정책 (CachingOptimized) — 정적 자산 권장값
data "aws_cloudfront_cache_policy" "optimized" {
  name = "Managed-CachingOptimized"
}

# API behavior용 — 캐시를 끄고 Host를 제외한 전체 뷰어 헤더를 전달합니다 (API GW는 자기 execute-api Host를 요구).
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# CloudFront 앞단 방어 (CLOUDFRONT scope = us-east-1 전용): AWS 관리형 3종 + IP당 rate-limit.
# ALB regional WAF는 origin-lock 전용이고, 무거운 방어 룰셋은 여기 엣지에서 담당합니다.
resource "aws_wafv2_web_acl" "cf" {
  provider = aws.us_east_1
  name     = "${var.name}-cf-waf"
  scope    = "CLOUDFRONT"

  default_action {
    allow {}
  }

  rule {
    name     = "ip-reputation"
    priority = 1
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesAmazonIpReputationList"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-ip-reputation"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "common"
    priority = 2
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-common"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "known-bad-inputs"
    priority = 3
    override_action {
      none {}
    }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesKnownBadInputsRuleSet"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name}-known-bad-inputs"
      sampled_requests_enabled   = true
    }
  }

  rule {
    name     = "rate-limit"
    priority = 4
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

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name}-cf-waf"
    sampled_requests_enabled   = true
  }

  tags = {
    Name = "${var.name}-cf-waf"
  }
}

# ---------------------------------------------------------------------------
# 커스텀 도메인 (domain 지정 시): Route53 zone + ACM 인증서 (apex + 와일드카드).
# zone은 prevent_destroy로 보호합니다. 도메인 등록업체에 route53_name_servers를 1회 위임해야
# ACM DNS 검증이 통과하며, 위임 전에는 검증이 대기 상태로 남습니다.
# ---------------------------------------------------------------------------
resource "aws_route53_zone" "this" {
  count = local.use_domain ? 1 : 0
  name  = var.domain

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_acm_certificate" "this" {
  count    = local.use_domain ? 1 : 0
  provider = aws.us_east_1

  domain_name               = var.domain
  subject_alternative_names = ["*.${var.domain}"]
  validation_method         = "DNS"

  lifecycle {
    create_before_destroy = true
  }
}

# DNS 검증 레코드 — apex와 와일드카드가 같은 레코드를 공유할 수 있으므로 allow_overwrite를 둡니다.
resource "aws_route53_record" "cert_validation" {
  for_each = local.use_domain ? {
    for dvo in aws_acm_certificate.this[0].domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      type   = dvo.resource_record_type
      record = dvo.resource_record_value
    }
  } : {}

  zone_id         = aws_route53_zone.this[0].zone_id
  name            = each.value.name
  type            = each.value.type
  records         = [each.value.record]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "this" {
  count    = local.use_domain ? 1 : 0
  provider = aws.us_east_1

  certificate_arn         = aws_acm_certificate.this[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# SPA 라우팅 — viewer-request 함수로 확장자 없는 경로를 루트 객체로 rewrite합니다 (S3 behavior 한정).
# 이전에는 분배 전역 custom_error_response 403/404→index.html을 썼으나, 그 방식이 /api/* behavior의
# 백엔드 정상 403/404까지 index.html 200으로 삼켜 프론트 envelope 검사를 깨뜨렸습니다. 그래서 함수 방식으로 교체했습니다.
resource "aws_cloudfront_function" "spa_router" {
  name    = "${var.name}-spa-router"
  runtime = "cloudfront-js-2.0"
  comment = "${var.name} SPA fallback (확장자 없는 경로 → ${var.default_root_object}). /api/*는 별도 behavior이므로 적용되지 않습니다."
  publish = true
  code    = <<-EOT
    function handler(event) {
      var request = event.request;
      var uri = request.uri;
      var lastSegment = uri.substring(uri.lastIndexOf('/') + 1);
      // 확장자 있는 정적 자산은 그대로, 그 외(SPA 클라이언트 라우트)는 루트 객체로 rewrite
      if (lastSegment.indexOf('.') === -1) {
        request.uri = '/${var.default_root_object}';
      }
      return request;
    }
  EOT
}

# CloudFront 액세스 로깅 (logging_config)은 설정하지 않았습니다. 현재 가시성은 WAF CloudWatch 메트릭과
# sampled_requests뿐이며 (전수 로그는 아님), 전수 가시성이 필요하면 WAF logging_configuration과
# CloudFront S3 로그 버킷을 추가합니다.
resource "aws_cloudfront_distribution" "this" {
  enabled             = true
  comment             = "${var.name} SPA"
  default_root_object = var.default_root_object
  price_class         = var.price_class
  web_acl_id          = aws_wafv2_web_acl.cf.arn

  origin {
    origin_id                = "s3-spa"
    domain_name              = aws_s3_bucket.spa.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.spa.id
  }

  # API Gateway 오리진 (api_origin 지정 시) — X-Origin-Verify를 주입해 ALB regional WAF의 origin-lock을 통과합니다.
  dynamic "origin" {
    for_each = var.api_origin != null ? [var.api_origin] : []
    content {
      origin_id   = "api-gw"
      domain_name = origin.value.domain_name

      custom_origin_config {
        http_port              = 80
        https_port             = 443
        origin_protocol_policy = "https-only"
        origin_ssl_protocols   = ["TLSv1.2"]
      }

      # 뷰어가 같은 헤더를 보내도 origin custom header가 우선해 덮어씁니다 (위조 방지).
      custom_header {
        name  = "X-Origin-Verify"
        value = origin.value.origin_verify_secret
      }
    }
  }

  default_cache_behavior {
    target_origin_id       = "s3-spa"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    cache_policy_id        = data.aws_cloudfront_cache_policy.optimized.id

    # SPA 라우팅 (S3 behavior 한정) — /api/* behavior에는 적용하지 않으므로 백엔드 403/404가 그대로 전달됩니다.
    dynamic "function_association" {
      for_each = var.spa_fallback ? [1] : []
      content {
        event_type   = "viewer-request"
        function_arn = aws_cloudfront_function.spa_router.arn
      }
    }
  }

  # /api/* → API Gateway 오리진 — 백엔드가 /api/v1 네이티브라 경로 재작성을 하지 않습니다.
  dynamic "ordered_cache_behavior" {
    for_each = var.api_origin != null ? [var.api_origin] : []
    content {
      path_pattern             = var.api_path_pattern
      target_origin_id         = "api-gw"
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      compress                 = true
      cache_policy_id          = data.aws_cloudfront_cache_policy.disabled.id
      origin_request_policy_id = data.aws_cloudfront_origin_request_policy.all_viewer_except_host.id
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  aliases = local.use_domain ? [var.domain] : null

  # domain 지정 시 검증을 마친 ACM 인증서를, 아니면 기본 *.cloudfront.net 인증서를 사용합니다.
  viewer_certificate {
    cloudfront_default_certificate = local.use_domain ? null : true
    acm_certificate_arn            = local.use_domain ? aws_acm_certificate_validation.this[0].certificate_arn : null
    ssl_support_method             = local.use_domain ? "sni-only" : null
    minimum_protocol_version       = local.use_domain ? "TLSv1.2_2021" : null
  }

  tags = {
    Name = "${var.name}-cf"
  }
}

# 이 배포 (OAC)가 보낸 요청에만 S3 읽기를 허용합니다 — SourceArn 조건으로 다른 배포를 차단합니다.
resource "aws_s3_bucket_policy" "spa" {
  bucket = aws_s3_bucket.spa.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowCloudFrontOAC"
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.spa.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.this.arn
        }
      }
    }]
  })
}

# apex A 레코드 → CloudFront (domain 지정 시)
resource "aws_route53_record" "alias" {
  count   = local.use_domain ? 1 : 0
  zone_id = aws_route53_zone.this[0].zone_id
  name    = var.domain
  type    = "A"

  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

# ---------------------------------------------------------------------------
# CloudFront WAF 로깅 — 차단/탐지 전수 로그를 CW Logs (us-east-1)로 보냅니다.
# CLOUDFRONT scope WAF 로깅은 반드시 us-east-1이어야 합니다. 환경 CMK는 ap-northeast-2라
# 여기서는 못 쓰므로 AWS 관리형 키를 씁니다 (로그는 비밀이 아님).
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "waf_cf" {
  provider          = aws.us_east_1
  name              = "aws-waf-logs-${var.name}-cf" # WAF 로깅은 이름 접두사 aws-waf-logs- 가 필수입니다.
  retention_in_days = var.log_retention_in_days

  tags = { Name = "aws-waf-logs-${var.name}-cf" }
}

resource "aws_wafv2_web_acl_logging_configuration" "cf" {
  provider                = aws.us_east_1
  log_destination_configs = [aws_cloudwatch_log_group.waf_cf.arn]
  resource_arn            = aws_wafv2_web_acl.cf.arn
}
