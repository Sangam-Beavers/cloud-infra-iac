output "cluster_id" {
  description = "클러스터 식별자"
  value       = aws_rds_cluster.this.cluster_identifier
}

output "endpoint" {
  description = "Writer 엔드포인트"
  value       = aws_rds_cluster.this.endpoint
}

output "reader_endpoint" {
  description = "Reader 엔드포인트"
  value       = aws_rds_cluster.this.reader_endpoint
}

output "port" {
  description = "포트"
  value       = aws_rds_cluster.this.port
}

output "master_user_secret_arn" {
  description = "AWS 관리형 마스터 비밀의 Secrets Manager ARN"
  value       = aws_rds_cluster.this.master_user_secret[0].secret_arn
}

output "security_group_id" {
  description = "클러스터 보안 그룹 ID"
  value       = aws_security_group.this.id
}

output "databases" {
  description = "이 클러스터의 논리 DB(서비스) 목록"
  value       = var.databases
}
