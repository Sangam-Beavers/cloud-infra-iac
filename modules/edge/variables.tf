variable "name" {
  description = "네이밍 접두사 (예: sb-stage-edge)"
  type        = string
}

variable "price_class" {
  description = "CloudFront 가격 등급 (PriceClass_100=NA+EU 최저가, _200, _All)"
  type        = string
  default     = "PriceClass_100"
}

variable "default_root_object" {
  description = "루트 (/) 요청 시 반환할 객체"
  type        = string
  default     = "index.html"
}

variable "spa_fallback" {
  description = "SPA 라우팅: S3에 객체가 없어 생기는 403/404를 /index.html 200으로 치환 (클라이언트 라우터가 경로 처리)"
  type        = bool
  default     = true
}

variable "api_origin" {
  description = "(선택) CloudFront api_path_pattern을 보낼 API Gateway 오리진. null이면 정적 (S3) 전용. domain_name=execute-api 호스트, origin_verify_secret=X-Origin-Verify 헤더 값 (ALB regional WAF origin-lock과 대조)"
  type = object({
    domain_name          = string
    origin_verify_secret = string
  })
  default   = null
  sensitive = true
}

variable "api_path_pattern" {
  description = "API 오리진으로 보낼 CloudFront 경로 패턴 (백엔드가 /api/v1 네이티브라 strip 없이 /api/*)"
  type        = string
  default     = "/api/*"
}

variable "waf_rate_limit" {
  description = "CloudFront WAF IP당 5분 윈도우 요청 상한 (rate-limit). WAFv2 최소 100"
  type        = number
  default     = 2000

  validation {
    condition     = var.waf_rate_limit >= 100
    error_message = "waf_rate_limit은 100 이상이어야 합니다 (WAFv2 최소값)."
  }
}

variable "domain" {
  description = "커스텀 도메인 (설정 시 ACM/Route53로 연결). 비우면 기본 *.cloudfront.net 인증서"
  type        = string
  default     = ""
}
