variable "name" {
  description = "네이밍 접두사 (예: sb-stage-vpn)"
  type        = string
}

variable "vpc_id" {
  description = "배치할 VPC ID"
  type        = string
}

variable "subnet_ids" {
  description = "public 서브넷 ID 목록 — ASG가 전체 AZ에 분산 (AZ 장애 시 자동 재기동)"
  type        = list(string)
}

variable "instance_type" {
  description = "라우터 인스턴스 타입 (WG+FRR은 가벼움)"
  type        = string
  default     = "t4g.micro"
}

variable "kms_key_arn" {
  description = "SSM SecureString(WG 키) 복호화에 필요한 환경 CMK ARN"
  type        = string
}

variable "ssm_prefix" {
  description = "WG 키가 저장된 SSM 파라미터 경로 접두사 (예: /sb/stage/vpn)"
  type        = string
}

variable "tunnels" {
  description = "WG 터널 정의 — 키는 인터페이스 이름(wg0active/wg1standby) 그대로 사용"
  type = map(object({
    address         = string # EC2 측 터널 IP/프리픽스 (예: 10.255.0.1/28)
    peer_ip         = string # pfSense 측 터널 IP (BGP 네이버)
    listen_port     = number
    peer_pubkey_ssm = string # 피어 공개키 SSM 파라미터 이름 (ssm_prefix 하위)
  }))
}

variable "bgp_router_id" {
  description = "FRR BGP router-id (관례: wg0active의 EC2 터널 IP)"
  type        = string
}

variable "bgp_local_as" {
  description = "EC2 측 ASN"
  type        = number
  default     = 65001
}

variable "bgp_peer_as" {
  description = "pfSense 측 ASN"
  type        = number
  default     = 65003
}

variable "advertise_cidrs" {
  description = "BGP로 온프렘에 광고할 VPC 대역 (mgmt 서브넷들)"
  type        = list(string)
}

variable "onprem_cidrs" {
  description = "온프렘이 광고하는 대역 — AllowedIPs + VPC return 라우트 대상"
  type        = list(string)
}

variable "return_route_table_ids" {
  description = "온프렘 대역 return 경로를 갱신할 VPC 라우트 테이블 ID 목록 (mgmt RT)"
  type        = list(string)
}

variable "pfsense_nat_ip" {
  description = "pfSense NAT source IP — policy routing(비대칭 방지) 대상"
  type        = string
}

variable "instance_extra_tags" {
  description = "라우터 EC2/볼륨에 추가할 태그"
  type        = map(string)
  default     = {}
}
