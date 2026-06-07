output "key_id" {
  description = "KMS 키 ID"
  value       = aws_kms_key.this.key_id
}

output "key_arn" {
  description = "KMS 키 ARN (Aurora/ElastiCache/EKS 등에서 참조)"
  value       = aws_kms_key.this.arn
}

output "alias_name" {
  description = "KMS 키 별칭 (alias/...)"
  value       = aws_kms_alias.this.name
}
