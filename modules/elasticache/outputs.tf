output "replication_group_id" {
  description = "복제 그룹 ID (bootstrap-redis.sh에서 사용)"
  value       = aws_elasticache_replication_group.this.replication_group_id
}

output "primary_endpoint" {
  description = "Primary(쓰기) 엔드포인트"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "reader_endpoint" {
  description = "Reader(읽기) 엔드포인트"
  value       = aws_elasticache_replication_group.this.reader_endpoint_address
}

output "port" {
  description = "포트"
  value       = aws_elasticache_replication_group.this.port
}

output "security_group_id" {
  description = "보안 그룹 ID"
  value       = aws_security_group.this.id
}
