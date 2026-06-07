provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = {
      ManagedBy = "terraform"
      Project   = var.project
    }
  }
}

# ---------------------------------------------------------------------------
# myApplications (AppRegistry) 애플리케이션 — 환경 스택보다 먼저 1회 apply.
# 환경 (environments/*)이 이 스택의 출력 (application_arns)을 remote state로 읽어
# 모든 리소스에 awsApplication 태그를 부여한다 → 환경 쪽 2단계 apply 불필요.
# ---------------------------------------------------------------------------

locals {
  applications = {
    production = "global-bridge-prod"
    staging    = "global-bridge-stage"
  }
}

resource "aws_servicecatalogappregistry_application" "this" {
  for_each = local.applications

  name        = each.value
  description = "global-bridge ${each.key} environment"

  tags = {
    Environment = each.key
  }
}
