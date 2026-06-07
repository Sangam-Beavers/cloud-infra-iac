# 현재는 로컬 상태 (terraform.tfstate)를 사용합니다.
# 팀 협업 또는 CI/CD 도입 시 아래 S3 백엔드 설정의 주석을 해제하고 사용하세요.
#
# terraform {
#   backend "s3" {
#     bucket       = "global-bridge-tfstate"
#     key          = "staging/terraform.tfstate"
#     region       = "ap-northeast-2"
#     profile      = "woori-fisa-1k"
#     encrypt      = true
#     use_lockfile = true # S3 네이티브 락 (Terraform 1.10+)
#   }
# }
