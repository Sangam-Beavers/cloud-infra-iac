terraform {
  required_version = ">= 1.15.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
      # CLOUDFRONT scope WAFv2·ACM은 us-east-1 전용이라 별칭 provider를 받는다
      configuration_aliases = [aws.us_east_1]
    }
  }
}
