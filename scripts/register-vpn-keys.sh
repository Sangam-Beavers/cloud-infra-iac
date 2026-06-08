#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 로컬 secrets/wg.{env}.env의 WireGuard 키를 SSM Parameter Store에 등록한다.
#   /sb/{env}/vpn/ec2-private-key   (SecureString, 환경 CMK)
#   /sb/{env}/vpn/ec2-public-key    (String — pfSense 설정 참고용)
#   /sb/{env}/vpn/onprem-active-pub  /onprem-standby-pub (String)
#
# VPN 라우터 부팅 전에 반드시 실행할 것 (user_data가 이 파라미터를 fetch).
# 멱등: --overwrite로 재실행 시 값 갱신.
#
# 사용법: ./register-vpn-keys.sh <prod|stage> [profile]
# ---------------------------------------------------------------------------
set -euo pipefail

ENV=${1:?usage: register-vpn-keys.sh <prod|stage> [profile]}
PROFILE="${2:-${PROFILE:?PROFILE 미설정 — make 경유 또는 인자/env로 전달}}"
REGION="${REGION:-ap-northeast-2}"
cd "$(dirname "$0")/.."

case "$ENV" in
  prod)  FILE=secrets/wg.prod.env; P=PROD ;;
  stage) FILE=secrets/wg.stg.env;  P=STG ;;
  *) echo "ERROR: env는 prod|stage"; exit 1 ;;
esac
[ -f "$FILE" ] || { echo "ERROR: $FILE 없음"; exit 1; }

# shellcheck disable=SC1090
source "$FILE"
for v in "WG_${P}_EC2_PRV" "WG_${P}_EC2_PUB" "WG_${P}_ONPREM_ACT_PUB" "WG_${P}_ONPREM_STN_PUB"; do
  [ -n "${!v:-}" ] || { echo "ERROR: $FILE에 $v 누락"; exit 1; }
done

# CMK는 alias로 조회 — terraform output에 의존하지 않아 apply 완료 직후/병렬에도 등록 가능
KMS=$(aws kms describe-key --key-id "alias/sb-${ENV}-cmk" \
  --query KeyMetadata.Arn --output text --profile "$PROFILE" --region $REGION)
PREFIX="/sb/${ENV}/vpn"

prv="WG_${P}_EC2_PRV"; pub="WG_${P}_EC2_PUB"; act="WG_${P}_ONPREM_ACT_PUB"; stn="WG_${P}_ONPREM_STN_PUB"

aws ssm put-parameter --name "$PREFIX/ec2-private-key" --type SecureString --key-id "$KMS" \
  --value "${!prv}" --overwrite --profile "$PROFILE" --region $REGION > /dev/null
aws ssm put-parameter --name "$PREFIX/ec2-public-key" --type String \
  --value "${!pub}" --overwrite --profile "$PROFILE" --region $REGION > /dev/null
aws ssm put-parameter --name "$PREFIX/onprem-active-pub" --type String \
  --value "${!act}" --overwrite --profile "$PROFILE" --region $REGION > /dev/null
aws ssm put-parameter --name "$PREFIX/onprem-standby-pub" --type String \
  --value "${!stn}" --overwrite --profile "$PROFILE" --region $REGION > /dev/null

echo "✔ $ENV: $PREFIX/{ec2-private-key(SecureString), ec2-public-key, onprem-active-pub, onprem-standby-pub} 등록 완료"
