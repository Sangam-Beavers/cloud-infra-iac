output "inbound_endpoint_ip_addresses" {
  description = "inbound 엔드포인트 IP 목록입니다. pfSense 조건부 포워더가 EKS 엔드포인트 도메인을 이 IP로 보내도록 설정합니다."
  value       = [for ip in aws_route53_resolver_endpoint.inbound.ip_address : ip.ip]
}
