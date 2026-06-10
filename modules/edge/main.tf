# ---------------------------------------------------------------------------
# 엣지: 비공개 S3 (정적 SPA) + CloudFront + CLOUDFRONT-scope WAF.
#   CloudFront는 OAC로 S3를 읽고, api_origin이 있으면 /api/* 를 API Gateway로 보낸다
#   (X-Origin-Verify 헤더 주입으로 ALB regional WAF의 origin-lock 통과).
# ---------------------------------------------------------------------------

locals {
  use_domain = var.domain != ""
}

# SPA 정적 자산 버킷 — 비공개. 버킷명은 전역 유일이어야 해 prefix로 AWS가 suffix를 붙인다
resource "aws_s3_bucket" "spa" {
  bucket_prefix = "${var.name}-spa-"
  force_destroy = true # 정적 SPA 자산 (재배포 가능) — destroy 시 객체째 삭제 (down-*가 비어있지 않은 버킷에 막히지 않게)
}

resource "aws_s3_bucket_public_access_block" "spa" {
  bucket                  = aws_s3_bucket.spa.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# 정적 자산 롤백 대비 버전 관리
resource "aws_s3_bucket_versioning" "spa" {
  bucket = aws_s3_bucket.spa.id
  versioning_configuration {
    status = "Enabled"
  }
}

# SSE-S3(AES256) — 자산은 비밀이 아니므로 CMK 불필요 (OAC가 CMK Decrypt 권한 필요해지는 복잡도 회피)
resource "aws_s3_bucket_server_side_encryption_configuration" "spa" {
  bucket = aws_s3_bucket.spa.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
    bucket_key_enabled = true
  }
}

# CloudFront가 비공개 S3를 읽는 통로 (OAC, 요청을 SigV4로 서명)
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

# API 동작용 — 캐시 비활성 + Host 제외 전체 뷰어 헤더 전달 (API GW는 자기 execute-api Host 필요)
data "aws_cloudfront_cache_policy" "disabled" {
  name = "Managed-CachingDisabled"
}

data "aws_cloudfront_origin_request_policy" "all_viewer_except_host" {
  name = "Managed-AllViewerExceptHostHeader"
}

# CloudFront 앞단 방어 (CLOUDFRONT scope = us-east-1 전용): AWS 관리형 3종 + IP당 rate-limit.
# ALB regional WAF는 origin-lock 전용이고, 무거운 방어 룰셋은 여기 (엣지)서 담당한다.
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
# zone은 prevent_destroy로 보호 — 도메인 등록업체에 route53_name_servers를 1회 위임해야
# ACM DNS 검증이 통과한다 (위임 전에는 검증이 대기).
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

# DNS 검증 레코드 (apex·와일드카드가 같은 레코드를 공유할 수 있어 allow_overwrite)
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

# CloudFront 액세스 로깅 (logging_config) 은 미설정 — 현재 가시성은 WAF CloudWatch 메트릭·sampled_requests 뿐 (전수 로그 아님, WAF logging_configuration 미설정).
# 전수 가시성이 필요하면 WAF logging_configuration + CloudFront S3 로그 버킷을 추가한다.
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

  # API Gateway 오리진 (api_origin 지정 시) — X-Origin-Verify를 주입해 ALB regional WAF의 origin-lock 통과
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

      # 뷰어가 같은 헤더를 보내도 origin custom header가 우선해 덮어쓴다 (위조 방지)
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
  }

  # /api/* → API Gateway 오리진 (백엔드가 /api/v1 네이티브라 경로 재작성 없음)
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

  # SPA: 객체 없는 경로의 403/404를 index.html 200으로 (클라이언트 라우터가 처리)
  dynamic "custom_error_response" {
    for_each = var.spa_fallback ? toset([403, 404]) : toset([])
    content {
      error_code            = custom_error_response.value
      response_code         = 200
      response_page_path    = "/${var.default_root_object}"
      error_caching_min_ttl = 10
    }
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  aliases = local.use_domain ? [var.domain] : null

  # domain 지정 시 ACM 인증서 (검증 완료분), 아니면 기본 *.cloudfront.net
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

# 이 배포 (OAC)가 보낸 요청에만 S3 읽기 허용 (SourceArn 조건으로 다른 배포 차단)
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
