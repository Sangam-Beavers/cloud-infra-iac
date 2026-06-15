variable "name" {
  description = "IAM 정책·역할 이름 (수동 생성분 흡수를 위해 gb-yace-cloudwatch-read 사용)"
  type        = string
}

variable "cluster_name" {
  description = "EKS 클러스터 이름 (module.eks.cluster_name) — YACE SA Pod Identity 연결용"
  type        = string
}

variable "namespace" {
  description = "YACE ServiceAccount 네임스페이스 (예: monitoring)"
  type        = string
}

variable "service_account" {
  description = "YACE ServiceAccount 이름 (예: cloudwatch-exporter) — gb-infra monitoring-stack 차트가 생성합니다. roleArn 어노테이션 불필요 (Pod Identity)"
  type        = string
}

variable "vpc_id" {
  description = "인터페이스 엔드포인트를 둘 VPC"
  type        = string
}

variable "subnet_ids" {
  description = "인터페이스 엔드포인트 서브넷 (mgmt 격리 구역)"
  type        = list(string)
}

variable "security_group_id" {
  description = "인터페이스 엔드포인트에 붙일 SG (mgmt 443 — jumphost endpoints SG 재사용)"
  type        = string
}
