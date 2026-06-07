output "asg_name" {
  description = "점프 호스트 ASG 이름"
  value       = aws_autoscaling_group.this.name
}

output "role_arn" {
  description = "점프 호스트 IAM 역할 ARN"
  value       = aws_iam_role.this.arn
}

output "security_group_id" {
  description = "점프 호스트 보안 그룹 ID"
  value       = aws_security_group.jump.id
}

output "endpoint_ids" {
  description = "SSM 인터페이스 엔드포인트 ID (서비스명 → ID)"
  value       = { for k, e in aws_vpc_endpoint.ssm : k => e.id }
}
