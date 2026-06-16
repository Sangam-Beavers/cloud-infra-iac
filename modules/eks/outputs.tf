output "cluster_name" {
  description = "클러스터 이름"
  value       = aws_eks_cluster.this.name
}

output "cluster_endpoint" {
  description = "API 서버 엔드포인트"
  value       = aws_eks_cluster.this.endpoint
}

output "cluster_certificate_authority_data" {
  description = "클러스터 CA 인증서 (base64) — kubeconfig·ArgoCD cluster Secret의 caData"
  value       = aws_eks_cluster.this.certificate_authority[0].data
}

output "cluster_security_group_id" {
  description = "클러스터 보안 그룹 ID (EKS 자동 생성)"
  value       = aws_eks_cluster.this.vpc_config[0].cluster_security_group_id
}

output "oidc_provider_arn" {
  description = "IRSA용 OIDC 프로바이더 ARN"
  value       = aws_iam_openid_connect_provider.this.arn
}

output "oidc_issuer_url" {
  description = "IRSA용 OIDC issuer URL"
  value       = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

output "node_role_arn" {
  description = "노드 IAM 역할 ARN"
  value       = aws_iam_role.node.arn
}

output "alb_controller_role_arn" {
  description = "AWS Load Balancer Controller IRSA 역할 ARN"
  value       = aws_iam_role.alb_controller.arn
}

output "eso_role_arn" {
  description = "External Secrets Operator IRSA 역할 ARN"
  value       = aws_iam_role.eso.arn
}

output "cluster_autoscaler_role_arn" {
  description = "Cluster Autoscaler IRSA 역할 ARN"
  value       = aws_iam_role.cluster_autoscaler.arn
}
