variable "name" {
  description = "네이밍 접두사 (예: sb-stage-document) — 역할명은 <name>-irsa"
  type        = string
}

variable "oidc_provider_arn" {
  description = "EKS OIDC provider ARN (module.eks.oidc_provider_arn)"
  type        = string
}

variable "oidc_issuer_url" {
  description = "EKS OIDC issuer URL (module.eks.oidc_issuer_url) — sub/aud 조건 키 구성용"
  type        = string
}

variable "service_account" {
  description = "document Pod의 ServiceAccount — 앱 Deployment의 serviceAccountName과 글자까지 일치해야 assume 성립."
  type = object({
    namespace = string
    name      = string
  })
}

# 아래 리소스는 모두 IaC 범위 밖(app/AI팀 소유)이며 동일계정에 존재한다.
# ARN은 caller identity로 동적 구성하므로 계정 ID를 하드코딩하지 않는다(퍼블릭 안전).
variable "analysis_queue_name" {
  description = "AI 분석 결과 SQS 큐 이름 (consume 대상)"
  type        = string
}

variable "document_bucket" {
  description = "문서 S3 버킷 이름 — original/* presign PUT·조회, masked/* 조회"
  type        = string
}

variable "chatbot_function_name" {
  description = "챗봇 Lambda 함수 이름 — InvokeFunctionUrl (URL AuthType=AWS_IAM일 때만 효력)"
  type        = string
}
