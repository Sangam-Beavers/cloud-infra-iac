#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 로컬에서 실행: terraform output (엔드포인트/마스터비밀/CMK)을 읽어
# SSM send-command로 "점프 호스트에서" 클러스터별 논리 DB + 서비스 계정 생성과
# Secrets Manager 저장 (sb/{env}/{service}/db)을 원격 실행한다.
#
# 멱등: 재실행 시 비밀번호를 새로 발급해 DB 계정 (ALTER USER)과 비밀을 함께 갱신.
# 점프 호스트 ID는 Name 태그 (sb-{env}-jump)로 자동 조회한다.
#
# 사용법: ./run-db-bootstrap.sh <env-dir> <env-short> [jump-instance-id] [profile]
# 예시:   ./run-db-bootstrap.sh environments/production prod
# ---------------------------------------------------------------------------
set -euo pipefail

ENV_DIR=$1
ENV=$2
INSTANCE=${3:-}
PROFILE=${4:-woori-fisa-1k}
REGION=ap-northeast-2

cd "$(dirname "$0")/../$ENV_DIR"
KMS=$(terraform output -raw kms_key_arn)
EPS=$(terraform output -json aurora_endpoints)
ARNS=$(terraform output -json aurora_master_secret_arns)

# 점프 호스트 자동 조회 (ASG 재기동으로 ID가 바뀌어도 추적)
if [ -z "$INSTANCE" ]; then
  INSTANCE=$(aws ec2 describe-instances --profile "$PROFILE" --region $REGION \
    --filters "Name=tag:Name,Values=sb-${ENV}-jump" "Name=instance-state-name,Values=running" \
    --query "Reservations[0].Instances[0].InstanceId" --output text)
  [ "$INSTANCE" != "None" ] || { echo "ERROR: sb-${ENV}-jump 실행 인스턴스를 찾지 못함"; exit 1; }
  echo "[${ENV}] jump host: $INSTANCE"
fi

for CLUSTER in core content; do
  EP=$(jq -r ".$CLUSTER" <<<"$EPS")
  ARN=$(jq -r ".$CLUSTER" <<<"$ARNS")
  case "$CLUSTER" in
    core) SERVICES="wallet member" ;;
    content) SERVICES="community document" ;;
  esac

  # 점프 호스트에서 실행될 스크립트 (비밀번호는 호스트→SM 직행, 로컬 비노출)
  REMOTE=$(cat <<EOS
set -eu
MASTER_PW=\$(aws secretsmanager get-secret-value --secret-id '$ARN' --region $REGION --query SecretString --output text | jq -r .password)
for SVC in $SERVICES; do
  PW=\$(aws secretsmanager get-random-password --exclude-punctuation --password-length 32 --region $REGION --query RandomPassword --output text)
  MYSQL_PWD="\$MASTER_PW" mysql -h '$EP' -u admin <<SQL
CREATE DATABASE IF NOT EXISTS svc_\${SVC} CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '\${SVC}_svc'@'%';
ALTER USER '\${SVC}_svc'@'%' IDENTIFIED BY '\${PW}';
GRANT ALL PRIVILEGES ON svc_\${SVC}.* TO '\${SVC}_svc'@'%';
FLUSH PRIVILEGES;
SQL
  SJ="{\"username\":\"\${SVC}_svc\",\"password\":\"\${PW}\",\"host\":\"$EP\",\"port\":3306,\"dbname\":\"svc_\${SVC}\"}"
  aws secretsmanager create-secret --name "sb/$ENV/\${SVC}/db" --kms-key-id '$KMS' --region $REGION \
    --secret-string "\$SJ" --query ARN --output text 2>/dev/null ||
    aws secretsmanager put-secret-value --secret-id "sb/$ENV/\${SVC}/db" --region $REGION \
      --secret-string "\$SJ" --query ARN --output text
  echo "OK \$SVC"
done
EOS
)

  CMD_ID=$(aws ssm send-command --profile "$PROFILE" --region $REGION \
    --instance-ids "$INSTANCE" --document-name "AWS-RunShellScript" \
    --comment "db-bootstrap $ENV $CLUSTER" \
    --parameters "$(jq -n --arg c "$REMOTE" '{commands: ($c | split("\n"))}')" \
    --query "Command.CommandId" --output text)
  echo "[$ENV/$CLUSTER] command-id: $CMD_ID"

  ST=Pending
  for i in $(seq 1 36); do
    ST=$(aws ssm get-command-invocation --profile "$PROFILE" --region $REGION \
      --command-id "$CMD_ID" --instance-id "$INSTANCE" \
      --query Status --output text 2>/dev/null || echo Pending)
    case "$ST" in Success|Failed|TimedOut|Cancelled) break ;; esac
    sleep 5
  done

  echo "[$ENV/$CLUSTER] status: $ST"
  aws ssm get-command-invocation --profile "$PROFILE" --region $REGION \
    --command-id "$CMD_ID" --instance-id "$INSTANCE" \
    --query "StandardOutputContent" --output text
  if [ "$ST" != "Success" ]; then
    echo "--- stderr ---"
    aws ssm get-command-invocation --profile "$PROFILE" --region $REGION \
      --command-id "$CMD_ID" --instance-id "$INSTANCE" \
      --query "StandardErrorContent" --output text
    exit 1
  fi
done

echo "✔ $ENV 부트스트랩 완료"
