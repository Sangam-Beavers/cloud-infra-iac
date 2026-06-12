variable "name" {
  description = "IAM 역할 이름 겸 네이밍 (예: sb-stage-community-translator)"
  type        = string
}

variable "cluster_name" {
  description = "EKS 클러스터 이름 (Pod Identity 연결 대상)"
  type        = string
}

variable "namespace" {
  description = "ServiceAccount 네임스페이스 (앱 파드가 실행되는 곳)"
  type        = string
}

variable "service_account" {
  description = "역할을 받을 ServiceAccount 이름 — 앱 Deployment의 serviceAccountName과 글자까지 일치해야 함"
  type        = string
}

variable "policy" {
  description = "역할에 붙일 IAM 정책 (JSON 문자열). 모듈은 메커니즘만 제공하고, 호출 측이 jsonencode로 구성합니다"
  type        = string
}
