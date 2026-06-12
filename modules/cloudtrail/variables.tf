variable "name" {
  description = "네이밍 접두사 (예: sb-prod-trail)"
  type        = string
}

variable "kms_key_arn" {
  description = "로그 파일 SSE-KMS 암호화에 쓸 환경 CMK ARN (키 정책에 cloudtrail.amazonaws.com 위임이 필요합니다)"
  type        = string
}

variable "log_retention_days" {
  description = "S3 로그 객체 보관 일수 (lifecycle expiration)"
  type        = number
  default     = 365
}

variable "enabled" {
  description = "false면 trail·버킷을 생성하지 않습니다 (org/ControlTower 트레일이 이미 있는 계정)"
  type        = bool
  default     = true
}
