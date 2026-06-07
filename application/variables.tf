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
  description = "사용할 AWS CLI 프로필 (~/.aws/config 기준)"
  type        = string
  default     = "woori-fisa-1k"
}
