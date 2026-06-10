variable "name" {
  description = "클러스터 식별자 겸 네이밍 접두사 (예: sb-prod-core)"
  type        = string
}

variable "vpc_id" {
  description = "클러스터를 배치할 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "DB 서브넷 ID 목록 (격리 서브넷)"
  type        = list(string)
}

variable "allowed_cidrs" {
  description = "3306 포트 접근을 허용할 CIDR 목록 (private/mgmt 서브넷)"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "스토리지/마스터 비밀 암호화에 사용할 KMS 키 ARN"
  type        = string
}

variable "databases" {
  description = "이 클러스터에 들어갈 논리 DB (서비스) 목록 — scripts/bootstrap-db.sh가 생성"
  type        = list(string)
}

variable "engine_version" {
  description = "Aurora MySQL 엔진 버전 (null이면 AWS 기본값)"
  type        = string
  default     = null
}

variable "instance_class" {
  description = "인스턴스 클래스 (db.serverless = Aurora Serverless v2)"
  type        = string
  default     = "db.serverless"
}

variable "instance_count" {
  description = "인스턴스 수 (1 = writer만, 2+ = writer + reader들)"
  type        = number
  default     = 1
}

variable "serverless_min_acu" {
  description = "Serverless v2 최소 ACU (인스턴스당, 유휴 시 과금 기준). instance_class = db.serverless 일 때만 적용"
  type        = number
  default     = 0.5

  validation {
    condition     = var.serverless_min_acu > 0
    error_message = "serverless_min_acu는 0보다 커야 합니다."
  }
}

variable "serverless_max_acu" {
  description = "Serverless v2 최대 ACU (인스턴스당). instance_class = db.serverless 일 때만 적용"
  type        = number
  default     = 4
}

variable "backup_retention_period" {
  description = "자동 백업 보관 일수"
  type        = number
  default     = 1
}

variable "skip_final_snapshot" {
  description = "삭제 시 최종 스냅샷 생략 여부 (실 운영 전환 시 false 권장)"
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "삭제 방지 (실 운영 전환 시 true 권장)"
  type        = bool
  default     = false
}
