#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Terraform S3 백엔드용 state 버킷을 생성한다 (Terraform 밖 — 닭-달걀 회피).
# versioning + 암호화(SSE-S3) + public 차단 + HTTPS 강제까지 설정.
#
# ⚠️ 조직에 단 한 번만 실행한다. state 버킷은 영속 리소스이며,
#    재배포(down-all/up-all)나 협업 시에는 절대 새로 만들지 않는다.
#    이미 backend.tf에 버킷이 박혀 있으면 'terraform init' 으로 연결만 하면 된다.
#    새로 만들면 state가 분산되어 인프라를 추적할 수 없게 된다.
#
# 생성 후 출력된 버킷명을 각 스택 backend.tf의 bucket 값에 넣고
# 주석을 해제한 뒤 `terraform init -migrate-state` 로 전환한다.
#
# 사용법: ./create-state-bucket.sh [profile]
# ---------------------------------------------------------------------------
set -euo pipefail

PROFILE=${1:-woori-fisa-1k}
REGION=ap-northeast-2

# 이미 state 버킷이 있으면 중복 생성을 막는다 (사용자 우려: 누구나 또 만들면 안 됨)
EXISTING=$(aws s3api list-buckets --profile "$PROFILE" \
  --query "Buckets[?starts_with(Name,'global-bridge-tfstate')].Name" --output text)
if [ -n "$EXISTING" ]; then
  echo "⚠️  이미 state 버킷이 존재합니다: $EXISTING"
  echo "    재배포/협업 시에는 새로 만들지 마세요 — backend.tf에 이 버킷을 쓰고 'terraform init' 만 하면 됩니다."
  printf "    그래도 새 버킷을 만들려면 CREATE 입력: "
  read -r ans; [ "$ans" = "CREATE" ] || { echo "취소됨."; exit 1; }
fi

SUFFIX=$(openssl rand -hex 3)
BUCKET="global-bridge-tfstate-${SUFFIX}"

aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration LocationConstraint="$REGION" \
  --profile "$PROFILE" > /dev/null

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

echo "✔ state 버킷 생성: ${BUCKET}"
echo "  → 각 스택 backend.tf의 bucket 값을 이 이름으로 바꾸고 주석 해제 후 'terraform init -migrate-state'"
