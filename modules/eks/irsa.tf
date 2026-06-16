data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# IRSA (IAM Role for Service Account) — OIDC 기반.
# 클러스터 내 ServiceAccount가 AWS API를 호출할 IAM 역할을 발급합니다.
#   - aws-load-balancer-controller: ALB/Target Group 생성·관리
#   - external-secrets:             Secrets Manager 읽기 + 환경 CMK decrypt
#   - cluster-autoscaler:           노드 그룹 ASG 용량 조정 (스케일 업/다운)
# ---------------------------------------------------------------------------

locals {
  oidc_provider = replace(aws_iam_openid_connect_provider.this.url, "https://", "")
}

# ---- AWS Load Balancer Controller ----

data "aws_iam_policy_document" "alb_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "alb_controller" {
  name               = "${var.name}-alb-controller"
  assume_role_policy = data.aws_iam_policy_document.alb_assume.json
}

resource "aws_iam_policy" "alb_controller" {
  name   = "${var.name}-alb-controller"
  policy = file("${path.module}/policies/alb-controller-iam-policy.json")
}

resource "aws_iam_role_policy_attachment" "alb_controller" {
  role       = aws_iam_role.alb_controller.name
  policy_arn = aws_iam_policy.alb_controller.arn
}

# ---- External Secrets Operator ----

data "aws_iam_policy_document" "eso_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:external-secrets:external-secrets"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eso" {
  name               = "${var.name}-eso"
  assume_role_policy = data.aws_iam_policy_document.eso_assume.json
}

resource "aws_iam_role_policy" "eso" {
  name = "${var.name}-eso"
  role = aws_iam_role.eso.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # 이 환경의 서비스 비밀만 (sb/{env}/*) 읽도록 제한합니다 — 환경 격리.
        Sid      = "ReadServiceSecrets"
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
        Resource = "arn:${data.aws_partition.current.partition}:secretsmanager:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:secret:${var.eso_secret_prefix}*"
      },
      {
        # 이 환경의 SSM Parameter Store 값만 (/sb/{env}/*) 읽도록 제한합니다 — ParameterStore
        # ClusterSecretStore용. 비밀이 아닌 인프라 동적값 (엔드포인트·버킷명·계정 B 핸드오프 등)을
        # 주입하는 경로입니다.
        Sid    = "ReadServiceParameters"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        # eso_secret_prefix "sb/{env}/" → SSM 경로 "/sb/{env}/*"
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:parameter/${trimsuffix(var.eso_secret_prefix, "/")}/*"
      },
      {
        # 비밀/SecureString이 환경 CMK로 암호화돼 있어 Decrypt가 필요합니다. DescribeKey는
        # ESO/Secrets Manager의 비-happy-path (키 메타데이터 조회)에서 호출될 수 있어 함께 허용합니다.
        Sid      = "DecryptWithEnvCmk"
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:DescribeKey"]
        Resource = var.kms_key_arn
      }
    ]
  })
}

# ---- Cluster Autoscaler ----

data "aws_iam_policy_document" "cluster_autoscaler_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.this.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:sub"
      values   = ["system:serviceaccount:kube-system:cluster-autoscaler"]
    }
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster_autoscaler" {
  name               = "${var.name}-cluster-autoscaler"
  assume_role_policy = data.aws_iam_policy_document.cluster_autoscaler_assume.json
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "${var.name}-cluster-autoscaler"
  role = aws_iam_role.cluster_autoscaler.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # ASG·인스턴스·시작 템플릿 조회는 전체 대상으로 필요합니다 (오토디스커버리가 태그로 후보 ASG를 추림).
        Sid    = "DescribeForDiscovery"
        Effect = "Allow"
        Action = [
          "autoscaling:DescribeAutoScalingGroups",
          "autoscaling:DescribeAutoScalingInstances",
          "autoscaling:DescribeLaunchConfigurations",
          "autoscaling:DescribeScalingActivities",
          "autoscaling:DescribeTags",
          "ec2:DescribeImages",
          "ec2:DescribeInstanceTypes",
          "ec2:DescribeLaunchTemplateVersions",
          "ec2:GetInstanceTypesFromInstanceRequirements",
          "eks:DescribeNodegroup"
        ]
        Resource = "*"
      },
      {
        # 실제 용량 변경 (desired 조정·노드 종료)은 이 클러스터 소유 태그가 붙은 ASG로만 제한합니다 — 환경 격리.
        Sid    = "MutateOwnedAsg"
        Effect = "Allow"
        Action = [
          "autoscaling:SetDesiredCapacity",
          "autoscaling:TerminateInstanceInAutoScalingGroup"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/k8s.io/cluster-autoscaler/${var.name}" = "owned"
          }
        }
      }
    ]
  })
}
