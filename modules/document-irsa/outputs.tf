output "role_arn" {
  description = "document-service IRSA 역할 ARN (gb-infra values-stage.yaml serviceAccount.roleArn에 기입)"
  value       = aws_iam_role.this.arn
}

output "role_name" {
  description = "document-service IRSA 역할 이름 (리소스 정책에서 principal 참조용)"
  value       = aws_iam_role.this.name
}
