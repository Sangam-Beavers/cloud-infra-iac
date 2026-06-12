variable "name" {
  description = "네이밍 접두사 (예: sb-stage-gb)"
  type        = string
}

variable "domain_prefix" {
  description = "Cognito Hosted UI 프리픽스 도메인 (전역 유일, 예: sb-stage-gb-auth) → <prefix>.auth.<region>.amazoncognito.com"
  type        = string
}

variable "callback_urls" {
  description = "OAuth code 플로우 redirect_uri 허용 목록 (프론트 CloudFront 도메인 등 — PoC의 localhost 교정)"
  type        = list(string)

  validation {
    condition     = length(var.callback_urls) >= 1
    error_message = "callback_urls를 최소 1개 지정해야 합니다 (OAuth code 플로우 redirect_uri)."
  }
}

variable "logout_urls" {
  description = "로그아웃 후 redirect 허용 목록"
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  description = "풀 삭제 보호. stage는 INACTIVE (destroy 가능), prod는 ACTIVE를 권장합니다"
  type        = string
  default     = "INACTIVE"

  validation {
    condition     = contains(["ACTIVE", "INACTIVE"], var.deletion_protection)
    error_message = "deletion_protection은 ACTIVE 또는 INACTIVE."
  }
}

# --- member-service IRSA (Cognito 관리 API 호출) ---
variable "oidc_provider_arn" {
  description = "EKS IRSA용 OIDC 프로바이더 ARN (module.eks.oidc_provider_arn)"
  type        = string
}

variable "oidc_issuer_url" {
  description = "EKS OIDC issuer URL (module.eks.oidc_issuer_url) — IRSA trust의 sub/aud 조건에 사용"
  type        = string
}

variable "member_service_account" {
  description = "member-service 파드의 ServiceAccount (이 SA만 Cognito 관리 역할을 assume). 앱 Deployment의 SA와 정확히 일치해야 합니다"
  type = object({
    namespace = string
    name      = string
  })
}

variable "member_ssm_prefix" {
  description = "member 백엔드용 Cognito 값(issuer/region/pool-id)을 기록할 SSM 경로 접두사 (예: /sb/stage/member). ESO가 읽어 파드에 주입합니다"
  type        = string
}

variable "frontend_ssm_prefix" {
  description = "프론트(빌드 타임)용 OIDC 값을 기록할 SSM 경로 접두사 (예: /sb/stage/frontend). Jenkins가 vite build 전에 읽어 VITE_OIDC_* 환경변수를 주입합니다"
  type        = string
}
