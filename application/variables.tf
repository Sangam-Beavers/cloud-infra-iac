variable "project" {
  description = "프로젝트 이름"
  type        = string
  default     = "global-bridge"
}

variable "aws_region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI 프로필 = 배포 대상 계정. make의 TF_VAR_aws_profile로 주입 (default 없음 — 미설정 시 에러로 개인계정 폴백 차단)"
  type        = string
}
