output "user_pool_id" {
  description = "Cognito User Pool ID"
  value       = aws_cognito_user_pool.this.id
}

output "user_pool_arn" {
  description = "Cognito User Pool ARN"
  value       = aws_cognito_user_pool.this.arn
}

output "client_id" {
  description = "프론트 App Client ID (public)"
  value       = aws_cognito_user_pool_client.frontend.id
}

output "issuer_url" {
  description = "OIDC issuer (백엔드 resource server가 JWT 검증에 사용)"
  value       = "https://cognito-idp.${data.aws_region.current.region}.amazonaws.com/${aws_cognito_user_pool.this.id}"
}

output "hosted_ui_domain" {
  description = "Hosted UI 도메인 (프론트 로그인 진입)"
  value       = "${aws_cognito_user_pool_domain.this.domain}.auth.${data.aws_region.current.region}.amazoncognito.com"
}

output "member_role_arn" {
  description = "member-service IRSA 역할 ARN (SA에 eks.amazonaws.com/role-arn으로 annotation)"
  value       = aws_iam_role.member.arn
}
