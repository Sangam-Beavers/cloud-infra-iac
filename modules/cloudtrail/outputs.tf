output "trail_arn" {
  description = "CloudTrail ARN (enabled=false면 빈 문자열)"
  value       = var.enabled ? aws_cloudtrail.this[0].arn : ""
}

output "log_bucket" {
  description = "CloudTrail 로그 S3 버킷 이름 (enabled=false면 빈 문자열)"
  value       = var.enabled ? aws_s3_bucket.trail[0].id : ""
}
