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
  description = "Valkey primary (쓰기) 엔드포인트"
  value       = module.redis.primary_endpoint
}

output "redis_reader_endpoint" {
  description = "Valkey reader (읽기) 엔드포인트"
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

output "api_origin_url" {
  description = "다음 단계 CloudFront에 등록할 origin URL (HTTP API)"
  value       = module.api_gateway.api_origin_url
}

output "api_target_group_arns" {
  description = "서비스 → Target Group ARN (TargetGroupBinding 작성용)"
  value       = module.api_gateway.target_group_arns
}

output "api_alb_security_group_id" {
  description = "내부 ALB SG (TargetGroupBinding spec.networking source)"
  value       = module.api_gateway.alb_security_group_id
}

output "api_origin_verify_ssm_param" {
  description = "origin-verify 비밀 SSM 파라미터 (값 아님)"
  value       = module.api_gateway.origin_verify_ssm_param
}

# 엣지 (환경 스택에 통합) — 운영 스크립트가 참조
output "cloudfront_domain_name" {
  description = "CloudFront 배포 도메인 (https://<이 값>으로 접속)"
  value       = module.edge.cloudfront_domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront 배포 ID (캐시 무효화에 사용)"
  value       = module.edge.cloudfront_distribution_id
}

output "spa_bucket_name" {
  description = "SPA 정적 자산 S3 버킷 (aws s3 cp 로 업로드)"
  value       = module.edge.spa_bucket_name
}

output "edge_route53_name_servers" {
  description = "엣지 커스텀 도메인 zone NS (도메인 지정 시) — 도메인 등록업체에 위임"
  value       = module.edge.route53_name_servers
}

output "resolver_inbound_ips" {
  description = "Route53 Resolver inbound 엔드포인트 IP — pfSense 조건부 포워더 (EKS 엔드포인트 도메인 → 이 IP)에 설정 (온프렘 연동 시)"
  value       = try(module.route53_resolver[0].inbound_endpoint_ip_addresses, [])
}

# --- 온프렘 ArgoCD 핸드오프 (onprem-handoff.sh가 exports/argocd-<env>-cluster.yaml로 기록) ---
output "eks_cluster_ca" {
  description = "EKS 클러스터 CA (base64) — ArgoCD cluster Secret의 tlsClientConfig.caData"
  value       = module.eks.cluster_certificate_authority_data
}

output "argocd_principal_arn" {
  description = "ArgoCD 전용 IAM User ARN (연동 시) — access entry에 매핑됨"
  value       = try(module.argocd_iam[0].principal_arn, "")
}

output "argocd_access_key_id" {
  description = "ArgoCD IAM 액세스 키 ID (연동 시)"
  value       = try(module.argocd_iam[0].access_key_id, "")
}

output "argocd_secret_access_key" {
  description = "ArgoCD IAM 시크릿 액세스 키 (연동 시) — 온프렘 ArgoCD 자격증명"
  value       = try(module.argocd_iam[0].secret_access_key, "")
  sensitive   = true
}

output "argocd_namespaces" {
  description = "ArgoCD access entry 한정 네임스페이스 — install-k8s-stack이 사전 생성 (한정 스코프는 네임스페이스를 못 만듦)"
  value       = var.onprem_integration.argocd_namespaces
}

# --- Cognito (운영/스테이징 IdP) ---
output "cognito_user_pool_id" {
  description = "Cognito User Pool ID (member COGNITO_USER_POOL_ID)"
  value       = module.cognito.user_pool_id
}

output "cognito_client_id" {
  description = "프론트 App Client ID (public)"
  value       = module.cognito.client_id
}

output "cognito_issuer_url" {
  description = "OIDC issuer — 백엔드 JWT 검증 issuer-uri"
  value       = module.cognito.issuer_url
}

output "cognito_hosted_ui_domain" {
  description = "Hosted UI 도메인 (프론트 로그인 진입)"
  value       = module.cognito.hosted_ui_domain
}

output "cognito_member_role_arn" {
  description = "member-service IRSA 역할 ARN (SA annotation용)"
  value       = module.cognito.member_role_arn
}

output "document_irsa_role_arn" {
  description = "document-service IRSA 역할 ARN (gb-infra document values-stage.yaml serviceAccount.roleArn에 기입)"
  value       = module.document_irsa.role_arn
}

output "eks_admin_role_arn" {
  description = "팀 공유 EKS cluster-admin 역할 ARN — make kubeconfig-stage가 --role-arn으로 assume (admin 그룹 멤버면 누구나 kubectl ClusterAdmin)"
  value       = aws_iam_role.eks_admin.arn
}

# --- 온프렘 Jenkins 프론트 배포 IAM (정적 키 → Jenkins credential) ---
output "frontend_deploy_principal_arn" {
  description = "Jenkins 배포 IAM User ARN"
  value       = module.frontend_deploy_iam.principal_arn
}

output "frontend_deploy_access_key_id" {
  description = "Jenkins 배포 IAM 액세스 키 ID"
  value       = module.frontend_deploy_iam.access_key_id
}

output "frontend_deploy_secret_access_key" {
  description = "Jenkins 배포 IAM 시크릿 액세스 키 (Jenkins credential에 등록)"
  value       = module.frontend_deploy_iam.secret_access_key
  sensitive   = true
}
