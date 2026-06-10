variable "name" {
  description = "리소스 네이밍 접두사 (예: sb-prod → sb-prod-vpc, sb-prod-public-a)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC CIDR 블록"
  type        = string
}

variable "public_subnets" {
  description = "Public 서브넷: AZ 접미사 → CIDR (예: { a = \"10.100.11.0/24\" })"
  type        = map(string)
  default     = {}
}

variable "private_subnets" {
  description = "Private (앱) 서브넷: AZ 접미사 → CIDR"
  type        = map(string)
  default     = {}
}

variable "db_subnets" {
  description = "DB 서브넷: AZ 접미사 → CIDR (인터넷 라우트 없는 격리 서브넷)"
  type        = map(string)
  default     = {}
}

variable "mgmt_subnets" {
  description = "관리 (mgmt) 서브넷: AZ 접미사 → CIDR (격리, 점프 호스트는 SSM 엔드포인트로 접속)"
  type        = map(string)
  default     = {}
}

variable "public_subnet_extra_tags" {
  description = "Public 서브넷에 추가할 태그 (예: ALB용 kubernetes.io/role/elb)"
  type        = map(string)
  default     = {}
}

variable "private_subnet_extra_tags" {
  description = "Private 서브넷에 추가할 태그 (예: 내부 LB용 kubernetes.io/role/internal-elb)"
  type        = map(string)
  default     = {}
}

variable "nat_gateway_strategy" {
  description = "private 서브넷 아웃바운드용 NAT 전략: none (없음) | single(1개) | per_az(AZ별 1개)"
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "single", "per_az"], var.nat_gateway_strategy)
    error_message = "nat_gateway_strategy는 none, single, per_az 중 하나여야 합니다."
  }
}

variable "single_nat_az" {
  description = "single 전략에서 NAT를 배치할 AZ 접미사 (기본: public AZ 중 첫 번째). 해당 AZ 장애 시 이 값을 다른 AZ로 바꿔 apply하면 NAT가 재배치됨 (복구 약 5분). 반드시 public_subnets에 존재하는 AZ여야 함"
  type        = string
  default     = null

  validation {
    condition     = var.single_nat_az == null ? true : contains(keys(var.public_subnets), var.single_nat_az)
    error_message = "single_nat_az는 public_subnets에 존재하는 AZ 접미사여야 합니다 (NAT는 public 서브넷에 배치됨)."
  }
}

variable "enable_flow_logs" {
  description = "VPC Flow Logs 활성화 여부 (count 기준 — 정적 값이어야 plan이 개수를 정할 수 있음)"
  type        = bool
  default     = false
}

variable "flow_log_kms_key_arn" {
  description = "VPC Flow Logs CloudWatch 로그 그룹의 암호화 CMK ARN (enable_flow_logs = true일 때 사용)"
  type        = string
  default     = null
}

variable "flow_log_retention_days" {
  description = "VPC Flow Logs 보관 일수"
  type        = number
  default     = 14
}
