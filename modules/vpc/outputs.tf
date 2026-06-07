output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.this.id
}

output "vpc_cidr_block" {
  description = "VPC CIDR 블록"
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "Public 서브넷 ID (AZ 접미사 → ID)"
  value       = { for k, s in aws_subnet.public : k => s.id }
}

output "private_subnet_ids" {
  description = "Private 서브넷 ID (AZ 접미사 → ID)"
  value       = { for k, s in aws_subnet.private : k => s.id }
}

output "db_subnet_ids" {
  description = "DB 서브넷 ID (AZ 접미사 → ID)"
  value       = { for k, s in aws_subnet.db : k => s.id }
}

output "mgmt_subnet_ids" {
  description = "Mgmt 서브넷 ID (AZ 접미사 → ID)"
  value       = { for k, s in aws_subnet.mgmt : k => s.id }
}

output "nat_gateway_ids" {
  description = "NAT 게이트웨이 ID (AZ 접미사 → ID, 전략이 none이면 빈 맵)"
  value       = { for k, n in aws_nat_gateway.this : k => n.id }
}

output "public_route_table_id" {
  description = "Public 라우트 테이블 ID"
  value       = aws_route_table.public.id
}

output "private_route_table_ids" {
  description = "Private 라우트 테이블 ID (AZ 접미사 → ID)"
  value       = { for k, rt in aws_route_table.private : k => rt.id }
}

output "db_route_table_id" {
  description = "DB 라우트 테이블 ID"
  value       = aws_route_table.db.id
}

output "mgmt_route_table_id" {
  description = "Mgmt 라우트 테이블 ID (격리)"
  value       = aws_route_table.mgmt.id
}
