#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# private-only EKS API에 점프 호스트 SSM 포트포워딩으로 kubectl 터널을 연다.
#
# 동작: 점프호스트 (mgmt, SSM Online)를 Name 태그로 자동 조회한 뒤
#   localhost:<port> → 점프호스트 → EKS private 엔드포인트:443 포워딩 세션 시작.
# 세션이 떠 있는 동안 별도 터미널에서 kubectl 사용 (Ctrl+C로 종료).
#
# 최초 1회 kubeconfig 설정 (스크립트가 명령을 출력해줌):
#   aws eks update-kubeconfig --name sb-{env}-eks --profile <profile>
#   kubectl config set-cluster <cluster-arn> --server=https://localhost:<port> \
#     --tls-server-name=<원래 엔드포인트 호스트>   # TLS SNI/SAN 검증 유지
#
# 사용법: ./kubectl-tunnel.sh <prod|stage> [local_port=8443] [profile]
# ---------------------------------------------------------------------------
set -euo pipefail

ENV=${1:?usage: kubectl-tunnel.sh <prod|stage> [local_port] [profile]}
PORT=${2:-8443}
PROFILE="${3:-${PROFILE:?PROFILE 미설정 — make 경유 또는 인자/env로 전달}}"
REGION="${REGION:-ap-northeast-2}"
cd "$(dirname "$0")/.."

case "$ENV" in
  prod)  TF_DIR=environments/production ;;
  stage) TF_DIR=environments/staging ;;
  *) echo "ERROR: env는 prod|stage"; exit 1 ;;
esac

ENDPOINT=$(cd "$TF_DIR" && terraform output -raw eks_cluster_endpoint)
HOST=${ENDPOINT#https://}
CLUSTER="sb-${ENV}-eks"

JUMP=$(aws ec2 describe-instances --profile "$PROFILE" --region $REGION \
  --filters "Name=tag:Name,Values=sb-${ENV}-jump" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
[ "$JUMP" != "None" ] || { echo "ERROR: sb-${ENV}-jump 실행 인스턴스 없음"; exit 1; }

cat <<GUIDE
─────────────────────────────────────────────────────────────
kubectl 터널: localhost:${PORT} → ${JUMP} → ${HOST}:443

최초 1회 kubeconfig 설정 (다른 터미널에서):
  aws eks update-kubeconfig --name ${CLUSTER} --region ${REGION} --profile ${PROFILE}
  kubectl config set-cluster \$(kubectl config current-context) \\
    --server=https://localhost:${PORT} --tls-server-name=${HOST}

세션 유지 중 kubectl 사용 가능. 종료: Ctrl+C
─────────────────────────────────────────────────────────────
GUIDE

exec aws ssm start-session --target "$JUMP" --profile "$PROFILE" --region $REGION \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters host="$HOST",portNumber="443",localPortNumber="$PORT"
