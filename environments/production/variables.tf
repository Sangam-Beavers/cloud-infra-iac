variable "project" {
  description = "프로젝트 이름 (리소스 태그 및 네이밍에 사용)"
  type        = string
}

variable "enable_cloudtrail" {
  description = "계정 CloudTrail 생성 여부 (org/ControlTower 트레일이 이미 있으면 false)"
  type        = bool
  default     = true
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
    single_nat_az        = optional(string) # single 전략에서 NAT AZ 장애 시 다른 AZ로 바꿔 apply하면 복구됩니다 (약 5분).
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
    instance_types               = list(string)
    desired_size                 = number
    min_size                     = number
    max_size                     = number
    endpoint_public_access       = optional(bool, false)      # 기본은 private-only입니다 (kubectl은 make kubeconfig-*, 끊기면 AWS 콘솔). true면 아래 cidrs가 필수입니다.
    endpoint_public_access_cidrs = optional(list(string), []) # public 활성 시 허용 CIDR입니다. 비우면 precondition이 막습니다 (빈 리스트 = 0.0.0.0/0).
  })
}

variable "aurora_config" {
  description = "Aurora 사양 — clusters: 클러스터명 → {논리 DB 목록 + 클러스터별 인스턴스 수·ACU 오버라이드}"
  type = object({
    clusters = map(object({
      databases      = list(string)
      instance_count = optional(number) # null이면 아래 공통 instance_count
      min_acu        = optional(number) # null이면 serverless_min_acu (0 = 유휴 시 auto-pause)
      max_acu        = optional(number) # null이면 serverless_max_acu
    }))
    instance_count          = number                # 클러스터 공통 기본 (1 = writer만, 2+ = writer + readers)
    serverless_min_acu      = optional(number, 0.5) # Serverless v2 최소 ACU (인스턴스당, 유휴 과금 기준)
    serverless_max_acu      = optional(number, 4)   # Serverless v2 최대 ACU (인스턴스당)
    backup_retention_period = optional(number, 1)
    deletion_protection     = optional(bool, false) # 운영 전환 시 true로 두어 destroy·콘솔 실수 삭제를 차단합니다.
    skip_final_snapshot     = optional(bool, true)  # 운영 전환 시 false로 두어 삭제 시 최종 스냅샷을 보존합니다.
  })
}

variable "api_gateway_config" {
  description = "API Gateway origin 사양 — services: 서비스명 → 경로/포트/헬스체크/우선순위, waf_rate_limit: 엣지 (CloudFront) WAF IP당 5분 상한"
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

# --- 온프렘 Harbor/ArgoCD 연동 (실값은 terraform.tfvars — 커밋되지 않음, example 참고) ---
# enabled=false면 연동 리소스를 만들지 않습니다 (EKS도 기존대로 private 컨트롤플레인을 유지).
# 대칭 은닉: private/db는 on-prem에 광고·노출하지 않으며, on-prem에는 mgmt/.253 단일 소스로만 보입니다.
variable "onprem_integration" {
  description = "온프렘 Harbor (이미지 Pull)·ArgoCD(EKS 배포) 연동 설정"
  type = object({
    enabled               = optional(bool, false)
    harbor_destinations   = optional(list(string), []) # 노드가 Pull할 Harbor IP /32 (예: ["10.0.0.10/32"])
    argocd_source_cidrs   = optional(list(string), []) # ArgoCD→EKS API 소스 = pfSense NAT IP /32 (예: ["10.0.0.1/32"])
    argocd_namespaces     = optional(list(string), []) # access policy 한정 네임스페이스 (비우면 cluster 범위). principal은 argocd-iam 모듈이 생성
    dns_resolver_ips      = optional(list(string), []) # on-prem DNS(pfSense) IP — outbound 포워딩 대상
    dns_forward_domains   = optional(list(string), []) # on-prem 도메인 (예: ["corp.example"])
    inbound_allowed_cidrs = optional(list(string), []) # inbound 엔드포인트 질의 허용 소스 (예: ["10.0.0.0/24"])
  })
  default = {}
}

# document-service IRSA가 접근할 자원 이름입니다. 동일 계정을 가정하므로 ARN은 caller identity로 동적 구성합니다.
# 외부 (app/AI팀) 소유 자원이라 external.auto.tfvars (외부 입력) 로 주입하며, prod 자원이 확정되면 채웁니다.
# null (기본) 이면 document_irsa 모듈을 만들지 않습니다 (코드만 반영). 값을 채우기 전에는 비활성이라 prod apply를 막지 않습니다.
variable "document_irsa" {
  description = "document-service IRSA 대상 자원 이름 (analysis SQS 큐 / 문서 S3 버킷 / 챗봇 Lambda). null이면 미생성"
  type = object({
    analysis_queue_name   = string
    document_bucket       = string
    chatbot_function_name = string
  })
  default = null
}

# community-service가 호출하는 번역 Lambda 함수 이름입니다. 외부 (AI팀) 소유이며, null이면 community_access를 만들지 않습니다 (코드만 반영).
variable "community_translator_function" {
  description = "community 번역 Lambda 함수 이름 (gb-community-translator). Pod Identity 정책 Resource ARN 구성용. null이면 미생성"
  type        = string
  default     = null
}
