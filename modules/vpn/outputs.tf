output "eip_public_ip" {
  description = "VPN 라우터 고정 공인 IP — pfSense Peer Endpoint에 설정할 주소"
  value       = aws_eip.this.public_ip
}

output "asg_name" {
  description = "라우터 ASG 이름"
  value       = aws_autoscaling_group.this.name
}

output "security_group_id" {
  description = "라우터 보안 그룹 ID"
  value       = aws_security_group.this.id
}

output "role_arn" {
  description = "라우터 IAM 역할 ARN"
  value       = aws_iam_role.this.arn
}
