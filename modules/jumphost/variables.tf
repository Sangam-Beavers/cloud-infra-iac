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
  description = "환경 CMK ARN — DB 부트스트랩 시 Secrets Manager 비밀 암복호화에 사용합니다"
  type        = string
}

variable "secret_prefix" {
  description = "점프 호스트가 생성/조회할 수 있는 Secrets Manager 비밀 접두사 (환경 격리, 예: sb/stage/) — 환경별로 반드시 지정 (default 없음: 누락 시 전 환경 비밀 노출 방지)"
  type        = string

  validation {
    condition     = var.secret_prefix != "sb/" && endswith(var.secret_prefix, "/")
    error_message = "secret_prefix는 환경 세그먼트를 포함해야 합니다 (예: sb/stage/). 'sb/' 단독은 환경 격리를 깨므로 금지합니다."
  }
}

variable "instance_extra_tags" {
  description = "점프 호스트 EC2/볼륨에 추가할 태그 (예: myApplications awsApplication)"
  type        = map(string)
  default     = {}
}
