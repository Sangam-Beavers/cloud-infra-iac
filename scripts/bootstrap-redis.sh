#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# ElastiCache (Valkey) 복제 그룹에 AUTH 토큰을 설정하고
# Secrets Manager (sb/{env}/redis/auth)에 저장합니다.
#
# AWS API만 사용하므로 로컬에서 실행할 수 있습니다 (DB 부트스트랩과 달리 VPC 접근 불필요).
# ROTATE → SET 2단계로 동작합니다. 무중단으로 토큰을 추가한 뒤 새 토큰만 허용하도록 고정합니다.
#
# 사용법: ./bootstrap-redis.sh <env> <replication_group_id> [profile]
# 예시:   ./bootstrap-redis.sh prod sb-prod-redis
# KMS_KEY_ARN 환경변수를 주면 생성되는 비밀을 해당 CMK로 암호화합니다.
# ---------------------------------------------------------------------------
set -euo pipefail

if [ $# -lt 2 ]; then
  grep '^# ' "$0" | head -12
  exit 1
fi

ENV=$1
RG_ID=$2
PROFILE="${3:-${PROFILE:?PROFILE 미설정 — make 경유 또는 인자/env로 전달}}"
SECRET_NAME="sb/${ENV}/redis/auth"

TOKEN=$(aws secretsmanager get-random-password --exclude-punctuation \
  --password-length 48 --query RandomPassword --output text --profile "$PROFILE")

# 토큰을 CLI 인자로 주면 ps/셸 히스토리에 노출되므로 임시 파일 (--cli-input-json)로 전달합니다.
TMPJSON=$(mktemp); chmod 600 "$TMPJSON"
trap 'rm -f "$TMPJSON"' EXIT

modify_auth() { # $1 = ROTATE | SET
  jq -n --arg rg "$RG_ID" --arg t "$TOKEN" --arg s "$1" \
    '{ReplicationGroupId:$rg, AuthToken:$t, AuthTokenUpdateStrategy:$s, ApplyImmediately:true}' > "$TMPJSON"
  aws elasticache modify-replication-group --cli-input-json "file://$TMPJSON" --profile "$PROFILE" > /dev/null
  aws elasticache wait replication-group-available --replication-group-id "$RG_ID" --profile "$PROFILE"
}

# ROTATE는 토큰을 추가하고 (신규 그룹의 첫 토큰도 ROTATE로 추가), SET은 추가된 토큰만 허용하도록 고정합니다.
# 신규/기존 모두 ROTATE→SET 순서로 동작합니다 (SET을 먼저 하면 "no token to SET"으로 실패).
echo "1/2 AUTH 토큰 추가 (ROTATE)..."; modify_auth ROTATE
echo "2/2 새 토큰만 허용 (SET)...";    modify_auth SET

echo "3/3 Secrets Manager 저장..."
PRIMARY=$(aws elasticache describe-replication-groups --replication-group-id "$RG_ID" \
  --query "ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint.Address" --output text --profile "$PROFILE")
READER=$(aws elasticache describe-replication-groups --replication-group-id "$RG_ID" \
  --query "ReplicationGroups[0].NodeGroups[0].ReaderEndpoint.Address" --output text --profile "$PROFILE")

SECRET_JSON="{\"auth_token\":\"${TOKEN}\",\"primary_host\":\"${PRIMARY}\",\"reader_host\":\"${READER}\",\"port\":6379,\"tls\":true}"

# upsert 방식으로, 이미 존재하면 새 버전으로 갱신합니다 (재실행/재배포 충돌 제거).
aws secretsmanager create-secret --name "$SECRET_NAME" \
  ${KMS_KEY_ARN:+--kms-key-id "$KMS_KEY_ARN"} \
  --secret-string "$SECRET_JSON" --query ARN --output text --profile "$PROFILE" 2>/dev/null ||
  aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" \
    --secret-string "$SECRET_JSON" --query ARN --output text --profile "$PROFILE"

echo "✔ ${RG_ID}: AUTH 설정 + ${SECRET_NAME} 저장 완료"
