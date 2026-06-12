#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Aurora 클러스터에 서비스별 논리 DB와 전용 계정을 만들고, 자격증명을
# Secrets Manager에 저장합니다 (sb/{env}/{service}/db).
#
# 멱등하게 동작합니다. 재실행 시 비밀번호를 새로 발급해 DB 계정 (ALTER USER)과
# 비밀을 함께 갱신합니다.
# ⚠️ DB 서브넷은 격리되어 있으므로, 클러스터에 네트워크로 도달 가능한
#    호스트 (예: mgmt 점프 호스트, SSM 세션)에서 실행해야 합니다.
# 필요: aws cli, mysql client, jq + Secrets Manager/KMS IAM 권한
#
# 사용법:
#   ./bootstrap-db.sh <env> <endpoint> <master_secret_arn> <svc1> [svc2 ...]
# 값은 terraform output (aurora_endpoints, aurora_master_secret_arns)에서 확인합니다.
# KMS_KEY_ARN 환경변수를 주면 신규 생성되는 비밀을 해당 CMK로 암호화합니다.
# ---------------------------------------------------------------------------
set -euo pipefail

if [ $# -lt 4 ]; then
  grep '^# ' "$0" | head -16
  exit 1
fi

ENV=$1
ENDPOINT=$2
MASTER_SECRET_ARN=$3
shift 3
SERVICES=("$@")

MASTER_PW=$(aws secretsmanager get-secret-value --secret-id "$MASTER_SECRET_ARN" \
  --query SecretString --output text | jq -r .password)

for SVC in "${SERVICES[@]}"; do
  # 서비스명은 SQL·시크릿 경로에 삽입되므로 삽입 전 화이트리스트로 검증합니다 (메타문자 주입 차단).
  [[ "$SVC" =~ ^[a-z][a-z0-9_]*$ ]] || { echo "ERROR: 잘못된 서비스명 '$SVC' (허용: ^[a-z][a-z0-9_]*\$)"; exit 1; }
  # 스키마/유저는 언더스코어 (svc_app_admin / app_admin_svc), 시크릿 경로만 하이픈 (sb/.../app-admin/db)을 써서 백엔드 ESO 표기와 일치시킵니다.
  SECRET_NAME="sb/${ENV}/${SVC//_/-}/db"
  PW=$(aws secretsmanager get-random-password --exclude-punctuation \
    --password-length 32 --query RandomPassword --output text)

  # 논리 DB와 자기 DB만 보이는 전용 계정을 만듭니다 (GRANT로 MSA 데이터 소유권을 강제).
  # ALTER USER로 매 실행마다 비밀번호를 재설정해 비밀과 DB 상태를 항상 일치시킵니다.
  # 비밀번호는 인자 (-p) 대신 MYSQL_PWD 환경변수로 전달해 ps 노출을 방지합니다.
  MYSQL_PWD="$MASTER_PW" mysql -h "$ENDPOINT" -u admin <<SQL
CREATE DATABASE IF NOT EXISTS svc_${SVC} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${SVC}_svc'@'%';
ALTER USER '${SVC}_svc'@'%' IDENTIFIED BY '${PW}';
GRANT ALL PRIVILEGES ON svc_${SVC}.* TO '${SVC}_svc'@'%';
FLUSH PRIVILEGES;
SQL

  SECRET_JSON="{\"username\":\"${SVC}_svc\",\"password\":\"${PW}\",\"host\":\"${ENDPOINT}\",\"port\":3306,\"dbname\":\"svc_${SVC}\"}"

  # upsert 방식으로, 이미 존재하면 새 버전으로 갱신합니다 (재실행/재배포 충돌 제거).
  aws secretsmanager create-secret --name "$SECRET_NAME" \
    ${KMS_KEY_ARN:+--kms-key-id "$KMS_KEY_ARN"} \
    --secret-string "$SECRET_JSON" --query ARN --output text 2>/dev/null ||
    aws secretsmanager put-secret-value --secret-id "$SECRET_NAME" \
      --secret-string "$SECRET_JSON" --query ARN --output text

  echo "✔ ${SVC}: DB=svc_${SVC}, user=${SVC}_svc, secret=${SECRET_NAME}"
done
