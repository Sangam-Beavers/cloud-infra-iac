#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Terraform S3 백엔드 버킷을 "발견 또는 생성"하고, 그 이름을 캐시 파일에 기록한다.
# Makefile은 이 캐시 (secrets/.state-bucket-<profile>)를 읽어 STATE_BUCKET으로 쓴다.
# → 사용자는 버킷명을 정할 필요가 없다 (PROFILE만 바꾸면 계정별로 자동).
#
#   · 계정에 global-bridge-tfstate* 버킷이 이미 있으면 그걸 재사용 (마이그레이션 불필요).
#   · 없으면 global-bridge-tfstate-<계정ID> 로 생성 (전역 유일·결정론적, 하드코딩 아님).
# versioning + 암호화 (SSE-S3) + public 차단 + HTTPS 강제. 멱등 — 있으면 생성 skip.
#
# 사용법: PROFILE=<계정> ./create-state-bucket.sh   (보통 make state-bucket / up-all이 자동 호출)
# ---------------------------------------------------------------------------
set -euo pipefail

PROFILE="${1:-${PROFILE:?PROFILE 미설정 — make 경유 또는 인자/env로 전달}}"
REGION="${REGION:-ap-northeast-2}"
CACHE="secrets/.state-bucket-${PROFILE}"

# 1) 계정 내 기존 state 버킷 발견 (있으면 재사용)
BUCKET=$(aws s3api list-buckets --profile "$PROFILE" \
  --query "Buckets[?starts_with(Name,'global-bridge-tfstate')].Name | [0]" --output text 2>/dev/null || true)

if [ -n "$BUCKET" ] && [ "$BUCKET" != "None" ]; then
  echo "✔ 기존 state 버킷 발견: $BUCKET (재사용)"
else
  # 2) 없으면 계정ID 기반으로 생성 (전역 유일)
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

# 3) 이름을 캐시에 기록 (make의 STATE_BUCKET이 이 파일을 읽음 — '#' 주석/빈 줄은 무시). secrets/* 는 gitignore.
mkdir -p secrets
{
  printf '# === Terraform state 백엔드 버킷 캐시 (자동 생성 — 편집/온프렘 작업 불필요) ===\n'
  printf '# make state-bucket(create-state-bucket.sh)이 계정의 state 버킷을 발견·생성해 여기 기록한다.\n'
  printf '# make가 마지막 비주석 줄을 STATE_BUCKET으로 읽어 terraform init -backend-config에 주입.\n'
  printf '# 계정 (PROFILE)마다 별도 파일이며, 지우면 다음 make 호출이 재생성한다.\n'
  printf '%s\n' "$BUCKET"
} > "$CACHE"
