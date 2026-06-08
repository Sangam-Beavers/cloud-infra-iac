# state는 S3 백엔드에 저장됩니다 (버킷 생성·전환은 README 5.4 참고).
terraform {
  backend "s3" {
    bucket       = "global-bridge-tfstate-396c9b"
    key          = "production/terraform.tfstate"
    region       = "ap-northeast-2"
    profile      = "woori-fisa-1k"
    encrypt      = true
    use_lockfile = true # S3 네이티브 락 (Terraform 1.10+)
  }
}
