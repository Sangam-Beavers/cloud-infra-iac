#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Terraform S3 백엔드 버킷을 발견하거나 생성하고, 그 이름을 캐시 파일에 기록합니다.
# Makefile은 이 캐시 (exports/state-bucket-<profile>)를 읽어 STATE_BUCKET으로 사용합니다.
# 따라서 사용자가 버킷명을 직접 정할 필요가 없습니다 (PROFILE만 바꾸면 계정별로 자동 결정됩니다).
#
#   · 계정에 global-bridge-tfstate* 버킷이 이미 있으면 재사용하여 마이그레이션을 피합니다.
#   · 없으면 global-bridge-tfstate-<계정ID> 로 생성합니다 (계정 ID 기반이라 전역 유일·결정론적이며 하드코딩이 아닙니다).
# 버킷에는 versioning·암호화 (SSE-S3)·public 차단·HTTPS 강제를 적용하며, 멱등이라 이미 있으면 생성을 건너뜁니다.
#
# 사용법: PROFILE=<계정> ./create-state-bucket.sh   (보통 make state-bucket / up-all이 자동 호출합니다)
# ---------------------------------------------------------------------------
set -euo pipefail

PROFILE="${1:-${PROFILE:?PROFILE 미설정 — make 경유 또는 인자/env로 전달}}"
REGION="${REGION:-ap-northeast-2}"
CACHE="exports/state-bucket-${PROFILE}"
mkdir -p exports # 생성물 폴더 (gitkeep로 추적되지만 수동 삭제에 대비해 방어적으로 생성합니다)

# 1) 계정 내 기존 state 버킷 발견 (있으면 재사용합니다)
BUCKET=$(aws s3api list-buckets --profile "$PROFILE" \
  --query "Buckets[?starts_with(Name,'global-bridge-tfstate')].Name | [0]" --output text 2>/dev/null || true)

if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  echo "✔ 기존 state 버킷 발견: $BUCKET (재사용)"
else
  # 2) 없으면 계정ID 기반으로 생성합니다 (전역 유일)
  ACCOUNT=$(aws sts get-caller-identity --profile "$PROFILE" --query Account --output text)
  BUCKET="global-bridge-tfstate-${ACCOUNT}"
  echo "state 버킷 생성: $BUCKET ($REGION)"

  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" --profile "$PROFILE" >/dev/null
  aws s3api put-bucket-versioning --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled --profile "$PROFILE"
  aws s3api put-bucket-encryption --bucket "$BUCKET" --profile "$PROFILE" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
  aws s3api put-public-access-block --bucket "$BUCKET" --profile "$PROFILE" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
  aws s3api put-bucket-policy --bucket "$BUCKET" --profile "$PROFILE" --policy \
    "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"DenyInsecureTransport\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::${BUCKET}\",\"arn:aws:s3:::${BUCKET}/*\"],\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}"
  echo "✔ state 버킷 생성 완료: $BUCKET"
fi

# 3) 이름을 캐시에 기록합니다 (make의 STATE_BUCKET이 이 파일을 읽으며 '#' 주석·빈 줄은 무시합니다). secrets/* 는 gitignore 대상입니다.
mkdir -p secrets
{
  printf '# === Terraform state 백엔드 버킷 캐시 (자동 생성되므로 편집·온프렘 작업이 필요 없습니다) ===\n'
  printf '# make state-bucket (create-state-bucket.sh)이 계정의 state 버킷을 발견·생성해 여기에 기록합니다.\n'
  printf '# make는 마지막 비주석 줄을 STATE_BUCKET으로 읽어 terraform init -backend-config에 주입합니다.\n'
  printf '# 계정 (PROFILE)마다 별도 파일이며, 지우면 다음 make 호출이 재생성합니다.\n'
  printf '%s\n' "$BUCKET"
} > "$CACHE"
