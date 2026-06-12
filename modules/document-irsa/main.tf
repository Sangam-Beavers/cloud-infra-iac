data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# document-service IRSA — member 패턴 (OIDC 동적 참조 + sub/aud 조건) 입니다. 액세스 키 없이
# ServiceAccount만으로 SQS (분석 결과 consume)·S3 (원본 presign PUT/조회·마스킹본 조회)·
# Lambda (챗봇 호출) 에 접근합니다. 대상 리소스는 IaC 범위 밖 (app/AI팀 소유) 이고 동일 계정에
# 존재하므로, ARN을 caller identity로 동적 구성해 계정 ID를 하드코딩하지 않습니다 (퍼블릭 안전).
# ---------------------------------------------------------------------------
locals {
  oidc_provider = replace(var.oidc_issuer_url, "https://", "")
  partition     = data.aws_partition.current.partition
  region        = data.aws_region.current.region
  account_id    = data.aws_caller_identity.current.account_id

  queue_arn    = "arn:${local.partition}:sqs:${local.region}:${local.account_id}:${var.analysis_queue_name}"
  bucket_arn   = "arn:${local.partition}:s3:::${var.document_bucket}"
  function_arn = "arn:${local.partition}:lambda:${local.region}:${local.account_id}:function:${var.chatbot_function_name}"
}

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:${var.service_account.namespace}:${var.service_account.name}"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name}-irsa"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = { Name = "${var.name}-irsa" }
}

resource "aws_iam_role_policy" "this" {
  name = "${var.name}-irsa"
  role = aws_iam_role.this.id

  # 권한 내용 (statement) 은 policies/document-irsa-policy.json.tftpl로 분리하고, .tf에서는 ARN만 주입합니다.
  # (modules/eks의 alb-controller-iam-policy.json 선례를 따릅니다. 동적 ARN이라 file 대신 templatefile을 씁니다.)
  policy = templatefile("${path.module}/policies/document-irsa-policy.json.tftpl", {
    queue_arn    = local.queue_arn
    bucket_arn   = local.bucket_arn
    function_arn = local.function_arn
  })
}
