output "cloudfront_domain_name" {
  description = "CloudFront 배포 도메인 (*.cloudfront.net)"
  value       = aws_cloudfront_distribution.this.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront 배포 ID (캐시 무효화·자산 배포에 사용)"
  value       = aws_cloudfront_distribution.this.id
}

output "cloudfront_distribution_arn" {
  description = "CloudFront 배포 ARN"
  value       = aws_cloudfront_distribution.this.arn
}

output "spa_bucket_name" {
  description = "SPA 정적 자산 S3 버킷 (aws s3 cp 로 업로드)"
  value       = aws_s3_bucket.spa.id
}

output "spa_bucket_arn" {
  description = "SPA 정적 자산 S3 버킷 ARN"
  value       = aws_s3_bucket.spa.arn
}

output "cf_waf_arn" {
  description = "CloudFront WAF (CLOUDFRONT scope, us-east-1) ARN"
  value       = aws_wafv2_web_acl.cf.arn
}
