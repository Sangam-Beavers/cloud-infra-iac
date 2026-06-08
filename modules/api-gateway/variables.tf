variable "name" {
  description = "네이밍 접두사 (예: sb-prod-api)"
  type        = string
}

variable "vpc_id" {
  description = "ALB/VPC Link를 배치할 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "내부 ALB·VPC Link를 배치할 서브넷 ID 목록 (private 서브넷, 최소 2 AZ)"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "origin-verify 비밀 (SSM SecureString) 과 액세스 로그 그룹 암호화에 쓸 환경 CMK ARN"
  type        = string
}

variable "ssm_prefix" {
  description = "origin-verify 비밀을 저장할 SSM 파라미터 접두사 (예: /sb/prod/api-gateway)"
  type        = string
}

variable "listener_port" {
  description = "내부 ALB HTTP 리스너 포트"
  type        = number
  default     = 80
}

variable "log_retention_in_days" {
  description = "API Gateway 액세스 로그 보관 일수"
  type        = number
  default     = 30
}

variable "waf_rate_limit" {
  description = "IP당 5분 윈도우 요청 상한 (rate-limit 백스톱). WAFv2 최소 100"
  type        = number
  default     = 2000

  validation {
    condition     = var.waf_rate_limit >= 100
    error_message = "waf_rate_limit은 100 이상이어야 합니다 (WAFv2 최소값)."
  }
}

variable "services" {
  description = "백엔드 서비스 → 내부 ALB 경로/포트/헬스체크/우선순위 매핑. 각 서비스는 TargetGroupBinding으로 파드를 등록한다"
  type = map(object({
    path_prefix       = string                       # 예: /community/*
    port              = number                       # 컨테이너/Service targetPort
    health_check_path = optional(string, "/healthz") # TG 헬스체크 경로
    priority          = number                       # 리스너 룰 우선순위 (서비스별 고유, 낮을수록 먼저)
  }))
}
