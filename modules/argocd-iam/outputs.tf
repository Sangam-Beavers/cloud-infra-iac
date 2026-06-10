output "principal_arn" {
  description = "ArgoCD IAM User ARN — EKS access entry의 principal_arn에 매핑"
  value       = aws_iam_user.this.arn
}

output "access_key_id" {
  description = "ArgoCD IAM 액세스 키 ID"
  value       = aws_iam_access_key.this.id
}

output "secret_access_key" {
  description = "ArgoCD IAM 시크릿 액세스 키 (온프렘 ArgoCD에 자격증명으로 주입)"
  value       = aws_iam_access_key.this.secret
  sensitive   = true
}
