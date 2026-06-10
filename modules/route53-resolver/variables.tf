variable "name" {
  description = "네이밍 접두사 (예: sb-prod-resolver)"
  type        = string
}

variable "vpc_id" {
  description = "리졸버 엔드포인트/룰을 둘 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "리졸버 엔드포인트 ENI를 배치할 서브넷 (mgmt — on-prem 대면 tier). 최소 2개 (2 AZ) 필요"
  type        = list(string)

  validation {
    condition     = length(var.subnet_ids) >= 2
    error_message = "Route53 Resolver 엔드포인트는 서로 다른 AZ의 서브넷 2개 이상이 필요합니다."
  }
}

# --- INBOUND (on-prem → AWS): on-prem이 EKS private 엔드포인트 호스트명을 해석 ---
variable "inbound_allowed_cidrs" {
  description = "inbound 엔드포인트 (53)에 질의를 허용할 소스 — on-prem 리졸버/대역 (예: pfSense)"
  type        = list(string)
}

# --- OUTBOUND (AWS → on-prem): EKS 노드가 harbor.corp.example 등 on-prem 도메인을 해석 ---
variable "forward_domains" {
  description = "on-prem DNS로 포워딩할 도메인 목록 (예: [\"corp.example\"])"
  type        = list(string)
}

variable "forward_target_ips" {
  description = "포워딩 대상 on-prem DNS 서버 IP 목록 (예: pfSense DNS)"
  type        = list(string)

  validation {
    condition     = length(var.forward_target_ips) >= 1
    error_message = "outbound 포워딩 대상 on-prem DNS IP를 최소 1개 지정해야 합니다 (비우면 outbound SG egress가 빈 리스트가 돼 apply 실패)."
  }
}
