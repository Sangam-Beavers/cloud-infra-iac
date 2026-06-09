variable "project" {
  description = "프로젝트 이름 (리소스 태그 및 네이밍에 사용)"
  type        = string
}

variable "environment" {
  description = "환경 이름"
  type        = string
  default     = "production"
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

variable "state_bucket" {
  description = "remote_state(application)를 읽을 S3 백엔드 버킷. make의 TF_VAR_state_bucket로 주입"
  type        = string
}

# --- 자원 사양/결정값 (실값은 terraform.tfvars — 커밋되지 않음, example 참고) ---

variable "vpc_config" {
  description = "VPC 결정값 (NAT 전략, NAT 장애 시 재배치 AZ)"
  type = object({
    nat_gateway_strategy = string           # none | single | per_az
    single_nat_az        = optional(string) # single 전략에서 NAT AZ 장애 시 다른 AZ로 바꿔 apply (복구 ~5분)
  })
}

variable "kms_config" {
  description = "KMS 결정값"
  type = object({
    deletion_window_in_days = number # 키 삭제 예약 시 취소 가능 대기 기간 (일), AWS 허용 범위 7~30
  })
}

variable "redis_config" {
  description = "Valkey 사양"
  type = object({
    node_type          = string
    node_count         = number              # 1 = primary만, 2+ = Multi-AZ 자동 failover
    snapshot_retention = optional(number, 1) # 스냅샷 보관 일수, 0 = 비활성
  })
}

variable "jumphost_config" {
  description = "점프 호스트 사양"
  type = object({
    instance_type = string
  })
}

variable "eks_config" {
  description = "EKS 노드 그룹 사양 (Graviton이면 이미지 arm64 빌드 필요)"
  type = object({
    instance_types         = list(string)
    desired_size           = number
    min_size               = number
    max_size               = number
    endpoint_public_access = optional(bool, true) # false = private-only (kubectl은 점프호스트 터널 경유)
  })
}

variable "aurora_config" {
  description = "Aurora 사양 — clusters: 클러스터명 → 논리 DB(서비스) 목록"
  type = object({
    clusters                = map(list(string))
    instance_count          = number              # 1 = writer만, 2+ = writer + readers
    serverless_max_acu      = optional(number, 4) # Serverless v2 최대 ACU (인스턴스당)
    backup_retention_period = optional(number, 1)
    deletion_protection     = optional(bool, false) # 운영 전환 시 true — destroy/콘솔 실수 삭제 차단
    skip_final_snapshot     = optional(bool, true)  # 운영 전환 시 false — 삭제 시 최종 스냅샷 보존
  })
}

variable "api_gateway_config" {
  description = "API Gateway origin 사양 — services: 서비스명 → 경로/포트/헬스체크/우선순위, waf_rate_limit: IP당 5분 상한"
  type = object({
    waf_rate_limit = optional(number, 2000)
    services = map(object({
      path_patterns     = list(string)
      port              = number
      health_check_path = optional(string, "/healthz")
      priority          = number
    }))
  })
}

variable "edge_domain" {
  description = "엣지 커스텀 도메인 — make가 secrets/domain.env(GB_PROD_DOMAIN)에서 TF_VAR_edge_domain로 주입. 비우면 기본 *.cloudfront.net (지정 시 Route53 zone + ACM apex/와일드카드)"
  type        = string
  default     = ""
}

# --- 네트워크 설계 (실값은 terraform.tfvars — 커밋되지 않음, example 참고) ---

variable "network" {
  description = "VPC CIDR과 4계층 서브넷 설계 (AZ 접미사 → CIDR)"
  type = object({
    vpc_cidr = string
    public   = map(string)
    private  = map(string)
    db       = map(string)
    mgmt     = map(string)
  })
}

# --- VPN 토폴로지 (실값은 terraform.tfvars — 커밋되지 않음, example 참고) ---

variable "vpn_tunnels" {
  description = "WG 터널 정의: 인터페이스 이름 → {address, peer_ip, listen_port, peer_pubkey_ssm}"
  type = map(object({
    address         = string
    peer_ip         = string
    listen_port     = number
    peer_pubkey_ssm = string
  }))
}

variable "vpn_bgp_router_id" {
  description = "FRR BGP router-id (관례: wg0active의 EC2 터널 IP)"
  type        = string
}

variable "vpn_pfsense_nat_ip" {
  description = "pfSense NAT source IP (policy routing 대상)"
  type        = string
}

variable "vpn_onprem_cidrs" {
  description = "온프렘이 광고하는 대역 — AllowedIPs + return 라우트 대상"
  type        = list(string)
}
