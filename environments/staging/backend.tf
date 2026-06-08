# state는 S3 백엔드에 저장됩니다 (버킷 생성·전환은 README 5.4 참고).
# bucket/region/profile은 계정 종속이라 make의 -backend-config로 주입한다 (backend 블록은 변수 불가).
terraform {
  backend "s3" {
    key          = "staging/terraform.tfstate"
    encrypt      = true
    use_lockfile = true # S3 네이티브 락 (Terraform 1.10+)
  }
}
