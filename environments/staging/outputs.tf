output "vpc_id" {
  description = "VPC ID"
  value       = module.vpc.vpc_id
}

output "vpc_cidr" {
  description = "VPC CIDR 블록"
  value       = module.vpc.vpc_cidr_block
}

output "public_subnet_ids" {
  description = "Public 서브넷 ID"
  value       = module.vpc.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private 서브넷 ID"
  value       = module.vpc.private_subnet_ids
}

output "db_subnet_ids" {
  description = "DB 서브넷 ID"
  value       = module.vpc.db_subnet_ids
}

output "mgmt_subnet_ids" {
  description = "Mgmt 서브넷 ID"
  value       = module.vpc.mgmt_subnet_ids
}

output "kms_key_arn" {
  description = "환경 공용 CMK ARN"
  value       = module.kms.key_arn
}

output "aurora_endpoints" {
  description = "Aurora writer 엔드포인트 (클러스터별)"
  value       = { for k, m in module.aurora : k => m.endpoint }
}

output "aurora_reader_endpoints" {
  description = "Aurora reader 엔드포인트 (클러스터별)"
  value       = { for k, m in module.aurora : k => m.reader_endpoint }
}

output "aurora_master_secret_arns" {
  description = "클러스터별 마스터 비밀 ARN (Secrets Manager)"
  value       = { for k, m in module.aurora : k => m.master_user_secret_arn }
}

output "eks_cluster_name" {
  description = "EKS 클러스터 이름"
  value       = module.eks.cluster_name
}

output "eks_cluster_endpoint" {
  description = "EKS API 엔드포인트"
  value       = module.eks.cluster_endpoint
}

output "eks_oidc_provider_arn" {
  description = "IRSA용 OIDC 프로바이더 ARN"
  value       = module.eks.oidc_provider_arn
}

output "vpn_eip" {
  description = "VPN 라우터 고정 공인 IP — pfSense Peer Endpoint에 설정"
  value       = module.vpn.eip_public_ip
}

output "redis_primary_endpoint" {
  description = "Valkey primary(쓰기) 엔드포인트"
  value       = module.redis.primary_endpoint
}

output "redis_reader_endpoint" {
  description = "Valkey reader(읽기) 엔드포인트"
  value       = module.redis.reader_endpoint
}

output "alb_controller_role_arn" {
  description = "ALB Controller IRSA 역할 ARN"
  value       = module.eks.alb_controller_role_arn
}

output "eso_role_arn" {
  description = "External Secrets Operator IRSA 역할 ARN"
  value       = module.eks.eso_role_arn
}
