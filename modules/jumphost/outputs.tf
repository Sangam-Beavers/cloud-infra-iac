output "endpoints_security_group_id" {
  description = "VPC 인터페이스 엔드포인트용 SG (mgmt에서 443). SSM·secretsmanager 엔드포인트가 쓰며, 모니터링(YACE) VPCe 등이 재사용합니다."
  value       = aws_security_group.endpoints.id
}
