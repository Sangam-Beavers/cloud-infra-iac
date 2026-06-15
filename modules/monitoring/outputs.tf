output "role_arn" {
  description = "YACE IAM 역할 ARN (Pod Identity로 cloudwatch-exporter SA에 부여)"
  value       = module.identity.role_arn
}

output "vpc_endpoint_ids" {
  description = "생성된 인터페이스 엔드포인트 ID (monitoring/tagging)"
  value       = { for k, e in aws_vpc_endpoint.this : k => e.id }
}
