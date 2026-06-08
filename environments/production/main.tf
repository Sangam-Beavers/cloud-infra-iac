# myApplications 앱 ARN — application/ 스택이 먼저 apply되어 있어야 함 (README 참고)
data "terraform_remote_state" "application" {
  backend = "s3"

  config = {
    bucket  = "global-bridge-tfstate-396c9b"
    key     = "application/terraform.tfstate"
    region  = "ap-northeast-2"
    profile = "woori-fisa-1k"
  }
}

locals {
  application_arn = data.terraform_remote_state.application.outputs.application_arns[var.environment]
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      Environment    = var.environment
      ManagedBy      = "terraform"
      Project        = var.project
      awsApplication = local.application_arn
    }
  }
}

module "vpc" {
  source = "../../modules/vpc"

  name     = "sb-prod"
  vpc_cidr = var.network.vpc_cidr

  public_subnets  = var.network.public
  private_subnets = var.network.private
  db_subnets      = var.network.db
  mgmt_subnets    = var.network.mgmt

  # VPC Flow Logs를 환경 CMK로 암호화해 활성화
  enable_flow_logs     = true
  flow_log_kms_key_arn = module.kms.key_arn

  nat_gateway_strategy = var.vpc_config.nat_gateway_strategy
  single_nat_az        = var.vpc_config.single_nat_az

  # AWS Load Balancer Controller의 서브넷 자동 발견용 태그
  public_subnet_extra_tags  = { "kubernetes.io/role/elb" = "1" }
  private_subnet_extra_tags = { "kubernetes.io/role/internal-elb" = "1" }
}

# Valkey (Redis 호환) — 세션/토큰 저장소, Aurora처럼 AZ 분산 + 자동 failover
# AUTH 토큰은 생성 후 scripts/bootstrap-redis.sh로 설정 (Secrets Manager 저장)
module "redis" {
  source = "../../modules/elasticache"

  name        = "sb-prod-redis"
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = values(module.vpc.db_subnet_ids)
  kms_key_arn = module.kms.key_arn

  # private (EKS) + mgmt (점프 호스트)에서만 접근 가능
  allowed_cidrs = concat(values(var.network.private), values(var.network.mgmt))

  node_type          = var.redis_config.node_type
  node_count         = var.redis_config.node_count
  snapshot_retention = var.redis_config.snapshot_retention
}

# SSM 엔드포인트 + 점프 호스트 (mgmt 격리 구역의 유일한 관리 통로)
# Aurora/Valkey 관리, DB 부트스트랩, EKS private-only 전환 후엔 kubectl 경유지
module "jumphost" {
  source = "../../modules/jumphost"

  name       = "sb-prod-jump"
  vpc_id     = module.vpc.vpc_id
  vpc_cidr   = var.network.vpc_cidr
  subnet_ids = values(module.vpc.mgmt_subnet_ids)

  kms_key_arn = module.kms.key_arn

  instance_type = var.jumphost_config.instance_type

  instance_extra_tags = { awsApplication = local.application_arn }

  # 주의: module.vpc에 depends_on을 걸면 data 소스가 지연돼 엔드포인트가 매번 교체됨.
  # S3 엔드포인트 준비 전 부팅은 user_data의 dnf 재시도 루프가 흡수한다.
}

# 사이트-투-사이트 WireGuard + FRR (BGP) 라우터 — 온프렘 pfSense (active/standby) 연결
# 키는 `make vpn-keys-prod`로 SSM 등록 후 apply할 것 (user_data가 부팅 시 fetch)
module "vpn" {
  source = "../../modules/vpn"

  name       = "sb-prod-vpn"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = values(module.vpc.public_subnet_ids)

  kms_key_arn = module.kms.key_arn
  ssm_prefix  = "/sb/prod/vpn"

  # 터널/BGP 토폴로지는 terraform.tfvars에서 주입 (커밋되지 않음 — example 참고)
  tunnels       = var.vpn_tunnels
  bgp_router_id = var.vpn_bgp_router_id

  # mgmt 대역만 광고 + 온프렘 대역 return 라우트 (검증 구성 유지)
  advertise_cidrs        = values(var.network.mgmt)
  onprem_cidrs           = var.vpn_onprem_cidrs
  pfsense_nat_ip         = var.vpn_pfsense_nat_ip
  return_route_table_ids = [module.vpc.mgmt_route_table_id]

  instance_extra_tags = { awsApplication = local.application_arn }
}

module "eks" {
  source = "../../modules/eks"

  name        = "sb-prod-eks"
  subnet_ids  = values(module.vpc.private_subnet_ids)
  kms_key_arn = module.kms.key_arn

  # CNI는 Cilium (개발 스택과 동일) — vpc-cni/kube-proxy 제외 후 Helm 설치
  cni = "cilium"

  # ESO는 이 환경 비밀(sb/prod/*)만 읽도록 IRSA 제한
  eso_secret_prefix = "sb/prod/"

  # Graviton (ARM64) 노드면 컨테이너 이미지는 arm64로 빌드 필요
  instance_types = var.eks_config.instance_types
  desired_size   = var.eks_config.desired_size

  # private-only API + 점프호스트 (mgmt)에서의 kubectl 접근 허용
  endpoint_public_access = var.eks_config.endpoint_public_access
  api_allowed_cidrs      = values(var.network.mgmt)

  min_size = var.eks_config.min_size
  max_size = var.eks_config.max_size

  # 노드 EC2도 myApplications 비용/인벤토리에 포함
  instance_extra_tags = { awsApplication = local.application_arn }
}

module "kms" {
  source = "../../modules/kms"

  name                    = "sb-prod"
  deletion_window_in_days = var.kms_config.deletion_window_in_days
}

# 백엔드 진입점 — HTTP API → VPC Link → internal ALB → EKS 4서비스 (TargetGroupBinding).
# CloudFront 우회 차단(origin-lock)은 ALB의 regional WAF. 엣지(CloudFront/Route53/ACM/S3)는
# 같은 FISA 계정의 다음 단계 별도 스택에서 api_origin_url + origin-verify 시크릿을 소비.
module "api_gateway" {
  source = "../../modules/api-gateway"

  name        = "sb-prod-api"
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = values(module.vpc.private_subnet_ids)
  kms_key_arn = module.kms.key_arn
  ssm_prefix  = "/sb/prod/api-gateway"

  services       = var.api_gateway_config.services
  waf_rate_limit = var.api_gateway_config.waf_rate_limit
}

# ---------------------------------------------------------------------------
# Aurora MySQL — blast radius 분리를 위해 2개 클러스터
#   core:    wallet, member       (트랜잭션·핵심)
#   content: community, document  (읽기 중심·트래픽 스파이크)
# 논리 DB/서비스 계정은 scripts/bootstrap-db.sh로 생성 (mgmt 점프 호스트에서 실행)
# ---------------------------------------------------------------------------


module "aurora" {
  source   = "../../modules/aurora"
  for_each = var.aurora_config.clusters

  name        = "sb-prod-${each.key}"
  vpc_id      = module.vpc.vpc_id
  subnet_ids  = values(module.vpc.db_subnet_ids)
  kms_key_arn = module.kms.key_arn
  databases   = each.value

  # private (EKS) + mgmt (점프 호스트)에서만 접근 가능
  allowed_cidrs = concat(values(var.network.private), values(var.network.mgmt))

  instance_count          = var.aurora_config.instance_count
  serverless_max_acu      = var.aurora_config.serverless_max_acu
  backup_retention_period = var.aurora_config.backup_retention_period
  deletion_protection     = var.aurora_config.deletion_protection
  skip_final_snapshot     = var.aurora_config.skip_final_snapshot
}
