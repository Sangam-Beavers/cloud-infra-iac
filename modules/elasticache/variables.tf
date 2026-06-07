variable "name" {
  description = "복제 그룹 식별자 겸 네이밍 접두사 (예: sb-prod-redis)"
  type        = string
}

variable "vpc_id" {
  description = "배치할 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "캐시 서브넷 ID 목록 (격리된 db 서브넷)"
  type        = list(string)
}

variable "allowed_cidrs" {
  description = "6379 포트 접근을 허용할 CIDR 목록 (private/mgmt 서브넷)"
  type        = list(string)
}

variable "kms_key_arn" {
  description = "저장 데이터 암호화에 사용할 KMS 키 ARN"
  type        = string
}

variable "engine_version" {
  description = "Valkey 엔진 버전 (parameter_group_family와 메이저가 일치해야 함, 예: 9.0 ↔ valkey9)"
  type        = string
  default     = "9.0"
}

variable "parameter_group_family" {
  description = "파라미터 그룹 패밀리 (engine_version과 일치해야 함)"
  type        = string
  default     = "valkey9"
}

variable "node_type" {
  description = "노드 타입"
  type        = string
}

variable "node_count" {
  description = "총 노드 수 (primary 포함). 2 이상이면 Multi-AZ 자동 failover 활성화"
  type        = number
}

variable "maxmemory_policy" {
  description = "메모리 가득 찼을 때의 eviction 정책 (세션/토큰 용도 = volatile-lru)"
  type        = string
  default     = "volatile-lru"
}

variable "snapshot_retention" {
  description = "스냅샷 보관 일수 (0 = 비활성)"
  type        = number
  default     = 1
}
