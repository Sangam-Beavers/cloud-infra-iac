data "aws_region" "current" {}
data "aws_partition" "current" {}

# ---------------------------------------------------------------------------
# Pre-Token Generation Lambda — custom:public_id를 토큰 클레임에 주입합니다 (V3).
# ---------------------------------------------------------------------------
data "archive_file" "pretoken" {
  type        = "zip"
  source_file = "${path.module}/lambda/index.mjs"
  output_path = "${path.module}/lambda/pretoken.zip"
}

resource "aws_iam_role" "pretoken" {
  name = "${var.name}-pretoken-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "pretoken_logs" {
  role       = aws_iam_role.pretoken.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "pretoken" {
  function_name = "${var.name}-pretoken-public-id"
  role          = aws_iam_role.pretoken.arn
  runtime       = "nodejs24.x"
  handler       = "index.handler"
  architectures = ["x86_64"]
  timeout       = 3
  memory_size   = 128

  filename         = data.archive_file.pretoken.output_path
  source_code_hash = data.archive_file.pretoken.output_base64sha256

  tags = { Name = "${var.name}-pretoken-public-id" }
}

# Cognito가 트리거를 invoke할 수 있게 허용하되 이 풀로만 제한합니다.
resource "aws_lambda_permission" "cognito" {
  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.pretoken.function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.this.arn
}

# ---------------------------------------------------------------------------
# User Pool — email 로그인, custom:public_id, pre-token Lambda
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool" "this" {
  name = var.name

  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  password_policy {
    minimum_length                   = 8
    require_uppercase                = true
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    temporary_password_validity_days = 7
  }

  mfa_configuration = "OFF"

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
    recovery_mechanism {
      name     = "verified_phone_number"
      priority = 2
    }
  }

  # 백엔드 공개 식별자입니다. pre-token Lambda가 토큰 클레임 public_id로 승격합니다.
  schema {
    name                     = "public_id"
    attribute_data_type      = "String"
    mutable                  = true
    required                 = false
    developer_only_attribute = false

    string_attribute_constraints {
      min_length = 0
      max_length = 2048
    }
  }

  email_configuration {
    email_sending_account = "COGNITO_DEFAULT"
  }

  lambda_config {
    pre_token_generation_config {
      lambda_arn     = aws_lambda_function.pretoken.arn
      lambda_version = "V3_0" # 코드가 claimsAndScopeOverrideDetails를 사용하기 때문입니다.
    }
  }

  deletion_protection = var.deletion_protection

  tags = { Name = var.name }
}

resource "aws_cognito_user_pool_domain" "this" {
  domain       = var.domain_prefix
  user_pool_id = aws_cognito_user_pool.this.id
}

# ---------------------------------------------------------------------------
# User Group — 관리자 인가용입니다. 사용자가 속한 그룹은 토큰의 cognito:groups 클레임으로
# 노출되어 API Gateway/ALB 인가나 백엔드 권한 평가에 사용됩니다 (콘솔 수동 생성분은 import로 흡수).
# ---------------------------------------------------------------------------
resource "aws_cognito_user_group" "this" {
  for_each = var.user_groups

  name         = each.key
  user_pool_id = aws_cognito_user_pool.this.id
  description  = each.value.description
  precedence   = each.value.precedence
}

# ---------------------------------------------------------------------------
# App Client — 프론트 SPA (public, OAuth code + Hosted UI)용입니다. callback은 CloudFront를 가리킵니다.
# ---------------------------------------------------------------------------
resource "aws_cognito_user_pool_client" "frontend" {
  name         = "${var.name}-frontend"
  user_pool_id = aws_cognito_user_pool.this.id

  generate_secret = false # public client (SPA, PKCE)이므로 시크릿을 발급하지 않습니다.

  explicit_auth_flows = [
    "ALLOW_REFRESH_TOKEN_AUTH",
    "ALLOW_USER_AUTH",
    "ALLOW_USER_SRP_AUTH",
  ]

  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["email", "openid", "phone", "profile"]
  supported_identity_providers         = ["COGNITO"]

  # custom:public_id 쓰기를 차단합니다. 사용자가 UpdateUserAttributes (SRP 경로 포함)로 위조하면 신원 도용으로 이어집니다.
  # 표준 속성만 허용하며, public_id는 member가 Admin API로만 설정합니다 (write_attributes와 무관).
  write_attributes = [
    "address", "birthdate", "email", "family_name", "gender", "given_name",
    "locale", "middle_name", "name", "nickname", "phone_number", "picture",
    "preferred_username", "profile", "updated_at", "website", "zoneinfo",
  ]

  callback_urls = var.callback_urls
  logout_urls   = var.logout_urls

  access_token_validity  = 60
  id_token_validity      = 60
  refresh_token_validity = 5
  token_validity_units {
    access_token  = "minutes"
    id_token      = "minutes"
    refresh_token = "days"
  }

  prevent_user_existence_errors = "ENABLED"
}

# ---------------------------------------------------------------------------
# member-service Pod Identity — Cognito 사용자 관리 API (provisioning)용입니다. SA에 권한을 부여하며
# IRSA와 달리 sts SDK 의존성·OIDC 트러스트가 필요 없습니다 (community/document와 동일 메커니즘으로 수렴).
# ---------------------------------------------------------------------------
data "aws_iam_policy_document" "member_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]

    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "member" {
  name               = "${var.name}-member-cognito"
  assume_role_policy = data.aws_iam_policy_document.member_assume.json
}

# SA (member) ↔ 역할을 Pod Identity로 연결합니다. SA는 차트가 생성하며 roleArn 어노테이션이 불필요합니다 (이름 기반 바인딩).
resource "aws_eks_pod_identity_association" "member" {
  cluster_name    = var.cluster_name
  namespace       = var.member_service_account.namespace
  service_account = var.member_service_account.name
  role_arn        = aws_iam_role.member.arn
}

resource "aws_iam_role_policy" "member" {
  name = "${var.name}-member-cognito"
  role = aws_iam_role.member.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "MemberCognitoUserAdmin"
      Effect = "Allow"
      Action = [
        "cognito-idp:AdminCreateUser",
        "cognito-idp:AdminSetUserPassword",
        "cognito-idp:AdminDeleteUser",
        "cognito-idp:AdminDisableUser",
        "cognito-idp:ListUsers",
      ]
      Resource = aws_cognito_user_pool.this.arn
    }]
  })
}

# ---------------------------------------------------------------------------
# Cognito 식별자/주소를 SSM Parameter Store에 기록합니다 (인프라가 생성한 값이며 비밀은 아닙니다). 소비처별로 분리합니다.
#   member 백엔드 (JWT 검증 + admin API): issuer/region/pool-id — ESO가 런타임에 주입합니다.
#   프론트 (OAuth 직접 수행): client-id + 엔드포인트 + redirect/logout — Jenkins가 빌드 타임에 주입합니다.
# client secret이 없는 public client이므로 Secrets Manager는 필요하지 않습니다.
# ---------------------------------------------------------------------------
locals {
  hosted_ui = "https://${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
  issuer    = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"

  member_params = {
    AUTH_ISSUER_URI      = local.issuer
    COGNITO_REGION       = data.aws_region.current.region
    COGNITO_USER_POOL_ID = aws_cognito_user_pool.this.id
  }

  # 첫 요소는 prod CloudFront URL이며, Cognito client에 등록한 callback/logout과 동일해야 합니다.
  frontend_params = {
    VITE_OIDC_CLIENT_ID                = aws_cognito_user_pool_client.frontend.id
    VITE_OIDC_AUTHORIZE_ENDPOINT       = "${local.hosted_ui}/oauth2/authorize"
    VITE_OIDC_TOKEN_ENDPOINT           = "${local.hosted_ui}/oauth2/token"
    VITE_OIDC_END_SESSION_ENDPOINT     = "${local.hosted_ui}/logout"
    VITE_OIDC_REDIRECT_URI             = var.callback_urls[0]
    VITE_OIDC_POST_LOGOUT_REDIRECT_URI = var.logout_urls[0]
  }
}

resource "aws_ssm_parameter" "member" {
  for_each = local.member_params

  name  = "${var.member_ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value

  tags = { Name = "${var.name}-member-${each.key}" }
}

resource "aws_ssm_parameter" "frontend" {
  for_each = local.frontend_params

  name  = "${var.frontend_ssm_prefix}/${each.key}"
  type  = "String"
  value = each.value

  tags = { Name = "${var.name}-frontend-${each.key}" }
}
