variable "name" {
  description = "클러스터 이름 겸 네이밍 접두사 (예: sb-prod-eks)"
  type        = string
}

variable "cluster_version" {
  description = "Kubernetes 버전 (null이면 AWS 기본 최신 버전). 상향 변경은 컨트롤플레인 in-place 업그레이드이며 마이너 버전은 한 단계씩만 가능"
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "노드 그룹을 배치할 서브넷 ID 목록 (private 서브넷)"
  type        = list(string)
}

variable "control_plane_subnet_ids" {
  description = "컨트롤플레인 (API 엔드포인트) ENI를 둘 서브넷 — 비우면 subnet_ids와 동일합니다. on-prem ArgoCD가 API에 닿아야 하면 mgmt 서브넷을 넘겨 private를 광고 없이 숨깁니다. 최소 2 AZ."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "Kubernetes Secrets 봉투 암호화에 사용할 KMS 키 ARN"
  type        = string
}

variable "api_allowed_cidrs" {
  description = "private API 엔드포인트 (443)에 접근을 허용할 CIDR (예: mgmt 서브넷 — 점프 호스트 경유 kubectl). 클러스터 SG에 인그레스 규칙 추가"
  type        = list(string)
  default     = []
}

variable "endpoint_public_access" {
  description = "퍼블릭 API 엔드포인트 활성화 여부. 기본 false(fail-safe, private-only) — 퍼블릭이 필요한 환경에서만 명시적으로 켜고 CIDR로 좁혀야 합니다"
  type        = bool
  default     = false
}

variable "endpoint_public_access_cidrs" {
  description = "퍼블릭 API 엔드포인트 접근 허용 CIDR. 주의: 퍼블릭 활성 시 빈 리스트는 0.0.0.0/0 (전체 허용)이 됩니다 — 퍼블릭을 켜면 사무실/VPN IP로 반드시 좁혀야 합니다 (모듈 precondition이 빈 리스트+public을 차단)"
  type        = list(string)
  default     = []
}

variable "cni" {
  description = "CNI 선택: vpc-cni(EKS 기본) 또는 cilium(vpc-cni/kube-proxy 제거 후 Helm 설치)"
  type        = string
  default     = "vpc-cni"

  validation {
    condition     = contains(["vpc-cni", "cilium"], var.cni)
    error_message = "cni는 vpc-cni 또는 cilium 이어야 합니다."
  }
}

variable "log_retention_in_days" {
  description = "컨트롤플레인 감사 로그 보관 일수"
  type        = number
  default     = 30
}

variable "instance_types" {
  description = "노드 인스턴스 타입 목록"
  type        = list(string)
}

variable "ami_type" {
  description = "노드 AMI 타입 (Graviton 인스턴스는 ARM_64 유지)"
  type        = string
  default     = "AL2023_ARM_64_STANDARD"
}

variable "disk_size" {
  description = "노드 루트 볼륨 크기 (GB). 시작 템플릿 block_device_mappings로 주입되므로 변경 시 LT 새 버전 → 노드 롤링 교체 발생"
  type        = number
  default     = 50
}

variable "instance_extra_tags" {
  description = "노드 EC2/볼륨에 추가할 태그 (예: myApplications의 awsApplication). 변경 시 노드 롤링 교체 발생"
  type        = map(string)
  default     = {}
}

variable "desired_size" {
  description = "노드 희망 수 (개수). 오토스케일러 도입 시 main.tf의 lifecycle ignore_changes를 복원해 Terraform이 되돌리지 않게 해야 합니다"
  type        = number
}

variable "min_size" {
  description = "노드 최소 수"
  type        = number
}

variable "max_size" {
  description = "노드 최대 수"
  type        = number
}

variable "eso_secret_prefix" {
  description = "External Secrets가 읽을 Secrets Manager 비밀 접두사 (환경 격리, 예: sb/stage/) — 환경별로 반드시 지정 (default 없음: 누락 시 전 환경 비밀 노출 방지)"
  type        = string

  validation {
    condition     = var.eso_secret_prefix != "sb/" && endswith(var.eso_secret_prefix, "/")
    error_message = "eso_secret_prefix는 환경 세그먼트를 포함해야 합니다 (예: sb/stage/). 'sb/' 단독은 환경 격리를 깨므로 금지합니다."
  }
}

# --- on-prem ArgoCD용 access entry ---
variable "argocd_enabled" {
  description = "ArgoCD access entry 생성 여부 — count 게이트. principal ARN은 모듈이 만드는 IAM User의 apply 시점 값이라 count로 못 쓰므로, plan 시점에 아는 bool (onprem_integration.enabled)로 고정합니다"
  type        = bool
  default     = false
}

variable "argocd_principal_arn" {
  description = "on-prem ArgoCD가 assume하는 IAM principal ARN — argocd_enabled=true일 때 access entry로 RBAC에 매핑"
  type        = string
  default     = ""
}

variable "argocd_access_policy_arn" {
  description = "ArgoCD principal에 부여할 EKS access policy (기본: Edit). 더 좁히려면 View, 더 넓히려면 Admin/ClusterAdmin"
  type        = string
  default     = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"
}

variable "argocd_access_namespaces" {
  description = "ArgoCD access policy를 한정할 네임스페이스 목록 (비우면 cluster 범위). least-privilege로 배포 대상 네임스페이스만 두길 권장합니다"
  type        = list(string)
  default     = []
}

variable "cluster_admin_enabled" {
  description = "팀 공유 cluster-admin access entry 생성 여부 — count 게이트. ARN은 apply 시점 값이라 count로 못 쓰므로 plan 시점 bool로 분리 (argocd_enabled와 동일 패턴)"
  type        = bool
  default     = false
}

variable "cluster_admin_role_arn" {
  description = "팀 공유 cluster-admin 역할 ARN — ClusterAdmin access entry로 매핑. 이 역할을 assume할 수 있는 사람 (예: AdministratorAccess 그룹)이 kubectl admin이 됩니다"
  type        = string
  default     = ""
}
