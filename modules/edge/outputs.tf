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

output "route53_name_servers" {
  description = "도메인 등록업체에 위임할 NS (domain 지정 시) — 위임해야 ACM DNS 검증·도메인이 작동"
  value       = local.use_domain ? aws_route53_zone.this[0].name_servers : null
}

output "acm_certificate_arn" {
  description = "ACM 인증서 ARN (domain 지정 시)"
  value       = local.use_domain ? aws_acm_certificate.this[0].arn : null
}

output "custom_domain" {
  description = "적용된 커스텀 도메인 (없으면 빈 문자열 — 기본 *.cloudfront.net)"
  value       = var.domain
}
