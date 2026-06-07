variable "name" {
  description = "리소스 네이밍 접두사 (예: sb-prod → alias/sb-prod-cmk)"
  type        = string
}

variable "description" {
  description = "키 설명"
  type        = string
  default     = "환경 공용 CMK (Aurora/ElastiCache/EKS/SSM/Secrets Manager 암호화용)"
}

variable "deletion_window_in_days" {
  description = "키 삭제 예약 시 대기 기간 (일, 7~30). 이 기간 안에는 삭제 취소 가능. 변경 시 in-place 갱신(키 교체 아님)"
  type        = number
  default     = 7
}
