data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# 온프렘 Jenkins 전용 IAM User — 정적 액세스 키 (클러스터/AWS 밖이라 IRSA 불가).
# 프론트 배포 파이프라인 최소권한: SPA 버킷 sync + 프론트 PS 읽기 + CloudFront 무효화.
# ---------------------------------------------------------------------------
resource "aws_iam_user" "this" {
  name          = var.name
  force_destroy = true # 액세스 키가 남아도 destroy가 막히지 않게

  tags = { Name = var.name }
}

resource "aws_iam_access_key" "this" {
  user = aws_iam_user.this.name
}

resource "aws_iam_user_policy" "this" {
  name = "${var.name}-deploy"
  user = aws_iam_user.this.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # aws s3 sync 비교용 (객체 목록)
        Sid      = "SpaBucketList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.spa_bucket}"
      },
      {
        # 빌드 산출물 업로드/삭제/조회 (read/write/delete)
        Sid      = "SpaObjectsRW"
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = "arn:${data.aws_partition.current.partition}:s3:::${var.spa_bucket}/*"
      },
      {
        # 빌드 타임에 VITE_OIDC_* 읽기 — 이 환경 프론트 파라미터만 (least-privilege)
        Sid      = "FrontendParamsRead"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter${var.frontend_ssm_prefix}/*"
      },
      {
        # 배포 후 캐시 무효화 (이 distribution만)
        Sid      = "CloudFrontInvalidate"
        Effect   = "Allow"
        Action   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
        Resource = "arn:${data.aws_partition.current.partition}:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/${var.cloudfront_distribution_id}"
      }
    ]
  })
}
