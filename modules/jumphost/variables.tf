variable "name" {
  description = "네이밍 접두사 (예: sb-prod-jump)"
  type        = string
}

variable "vpc_id" {
  description = "배치할 VPC ID"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR (SSM 엔드포인트 443 인바운드 허용 범위)"
  type        = string
}

variable "subnet_ids" {
  description = "mgmt 서브넷 ID 목록 — ASG와 SSM 엔드포인트가 전체 AZ에 분산"
  type        = list(string)
}

variable "instance_type" {
  description = "점프 호스트 인스턴스 타입 (ARM)"
  type        = string
  default     = "t4g.small"
}

variable "kms_key_arn" {
  description = "환경 CMK ARN — DB 부트스트랩 시 Secrets Manager 비밀 암복호화에 필요"
  type        = string
}

variable "secret_prefix" {
  description = "점프 호스트가 생성/조회할 수 있는 Secrets Manager 비밀 접두사"
  type        = string
  default     = "sb/"
}

variable "instance_extra_tags" {
  description = "점프 호스트 EC2/볼륨에 추가할 태그 (예: myApplications awsApplication)"
  type        = map(string)
  default     = {}
}
