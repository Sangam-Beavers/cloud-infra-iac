output "role_arn" {
  description = "생성된 IAM 역할 ARN"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "생성된 IAM 역할 이름"
  value       = aws_iam_role.this.name
}

output "pod_identity_association_id" {
  description = "Pod Identity 연결 ID"
  value       = aws_eks_pod_identity_association.this.association_id
}
