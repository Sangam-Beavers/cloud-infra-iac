data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  create = var.enabled ? 1 : 0
  # 이름이 결정값이라 trail ARN을 미리 조립 — 버킷정책↔trail 순환참조 회피
  trail_arn = "arn:${data.aws_partition.current.partition}:cloudtrail:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:trail/${var.name}"
}

# ---------------------------------------------------------------------------
# 로그 버킷 — SSE-KMS(환경 CMK), 버전·public 차단·수명주기
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "trail" {
  count         = local.create
  bucket_prefix = "${var.name}-logs-"

  tags = { Name = "${var.name}-logs" }
}

resource "aws_s3_bucket_public_access_block" "trail" {
  count                   = local.create
  bucket                  = aws_s3_bucket.trail[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "trail" {
  count  = local.create
  bucket = aws_s3_bucket.trail[0].id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "trail" {
  count  = local.create
  bucket = aws_s3_bucket.trail[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "trail" {
  count  = local.create
  bucket = aws_s3_bucket.trail[0].id
  rule {
    id     = "expire"
    status = "Enabled"
    filter {}
    expiration {
      days = var.log_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }
}

# CloudTrail이 버킷에 쓰도록 허용 (서비스 프린시펄 + aws:SourceArn 조건)
resource "aws_s3_bucket_policy" "trail" {
  count  = local.create
  bucket = aws_s3_bucket.trail[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AWSCloudTrailAclCheck"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.trail[0].arn
        Condition = { StringEquals = { "aws:SourceArn" = local.trail_arn } }
      },
      {
        Sid       = "AWSCloudTrailWrite"
        Effect    = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.trail[0].arn}/AWSLogs/${data.aws_caller_identity.current.account_id}/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"  = "bucket-owner-full-control"
            "aws:SourceArn" = local.trail_arn
          }
        }
      },
    ]
  })
}

# ---------------------------------------------------------------------------
# 멀티리전 trail — 전역 서비스 이벤트 포함, 로그파일 무결성 검증, CMK 암호화
# ---------------------------------------------------------------------------
resource "aws_cloudtrail" "this" {
  count = local.create

  name           = var.name
  s3_bucket_name = aws_s3_bucket.trail[0].id

  is_multi_region_trail         = true
  include_global_service_events = true
  enable_log_file_validation    = true
  kms_key_id                    = var.kms_key_arn

  # 버킷정책이 먼저 있어야 trail 생성 시 쓰기검증 통과
  depends_on = [aws_s3_bucket_policy.trail]

  tags = { Name = var.name }
}
