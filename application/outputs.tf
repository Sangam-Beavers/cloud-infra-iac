output "application_arns" {
  description = "환경 이름 → awsApplication 태그 값 (resource-groups ARN)"
  value       = { for k, a in aws_servicecatalogappregistry_application.this : k => a.application_tag["awsApplication"] }
}
