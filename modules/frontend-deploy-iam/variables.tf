variable "name" {
  description = "IAM User 이름 (예: sb-stage-frontend-deploy)"
  type        = string
}

variable "spa_bucket" {
  description = "프론트 정적 자산 S3 버킷 이름 (module.edge.spa_bucket_name)"
  type        = string
}

variable "cloudfront_distribution_id" {
  description = "프론트 CloudFront distribution ID (배포 후 무효화 대상)"
  type        = string
}

variable "frontend_ssm_prefix" {
  description = "Jenkins가 빌드 타임에 읽을 프론트 OIDC 파라미터 경로 접두사 (예: /sb/stage/frontend)"
  type        = string
}
