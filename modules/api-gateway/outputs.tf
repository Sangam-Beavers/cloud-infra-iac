output "api_origin_url" {
  description = "HTTP API invoke URL — 다음 단계 CloudFront origin으로 등록"
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
  description = "origin-verify 비밀이 저장된 SSM 파라미터 (값 아님 — 엣지 스택이 읽음)"
  value = {
    name = aws_ssm_parameter.origin_verify.name
    arn  = aws_ssm_parameter.origin_verify.arn
  }
}
