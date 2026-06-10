output "principal_arn" {
  description = "Jenkins 배포 IAM User ARN"
  value       = aws_iam_user.this.arn
}

output "access_key_id" {
  description = "Jenkins 배포 IAM 액세스 키 ID"
  value       = aws_iam_access_key.this.id
}

output "secret_access_key" {
  description = "Jenkins 배포 IAM 시크릿 액세스 키 (생성 시점에만 획득 — Jenkins credential에 등록)"
  value       = aws_iam_access_key.this.secret
  sensitive   = true
}
