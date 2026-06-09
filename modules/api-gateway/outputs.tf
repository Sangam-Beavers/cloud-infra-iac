output "api_origin_url" {
  description = "HTTP API invoke URL (CloudFront 오리진)"
  value       = aws_apigatewayv2_stage.default.invoke_url
}

output "target_group_arns" {
  description = "서비스 → Target Group ARN (앱의 TargetGroupBinding에서 참조)"
  value       = { for k, tg in aws_lb_target_group.this : k => tg.arn }
}

output "alb_security_group_id" {
  description = "내부 ALB SG (TargetGroupBinding spec.networking의 source securityGroup)"
  value       = aws_security_group.alb.id
}

output "alb_arn" {
  description = "내부 ALB ARN (WAF 연결 확인용)"
  value       = aws_lb.this.arn
}

output "origin_verify_ssm_param" {
  description = "origin-verify 비밀이 저장된 SSM 파라미터 (값 아님)"
  value = {
    name = aws_ssm_parameter.origin_verify.name
    arn  = aws_ssm_parameter.origin_verify.arn
  }
}

# 같은 스택에 통합된 edge 모듈이 CloudFront 헤더 주입에 직접 소비 (스택 출력으로는 재노출하지 않음)
output "origin_verify_secret" {
  description = "origin-verify 비밀 값 (sensitive) — 동일 스택 edge 모듈 전용"
  value       = random_password.origin_verify.result
  sensitive   = true
}
