#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# stage 엣지 검증용 더미 백엔드(4서비스 echo) + 테스트 프론트 배포/삭제.
#   실제 앱이 아니라 엣지 경로(CloudFront → API GW → ALB → Pod)와 /api/v1 라우팅 검증용.
#   traefik/whoami가 모든 경로에 200(=actuator/health 통과) + --name 으로 자기 서비스명 응답.
#
#   TG ARN·ALB SG·S3 버킷·CloudFront ID는 terraform output에서 "동적으로" 읽어 매니페스트를
#   생성한다 — 계정 종속 값을 파일에 박지 않는다 (repo public 안전).
#
# 선결: environments/staging + edge/staging 가 apply/init 되어 있어야 함 (output 참조).
#       로컬에 kubectl · session-manager-plugin · jq 필요.
# 사용법: PROFILE=<계정> ./edge-test.sh <deploy|clean> [stage]   (보통 make edge-test-*-stage)
# ---------------------------------------------------------------------------
set -euo pipefail

ACTION="${1:?usage: edge-test.sh <deploy|clean> [stage]}"
ENV="${2:-stage}"
PROFILE="${PROFILE:?PROFILE 미설정 — make 경유 또는 env로 전달}"
REGION="${REGION:-ap-northeast-2}"
cd "$(dirname "$0")/.."
export AWS_PROFILE="$PROFILE"

[ "$ENV" = "stage" ] || { echo "ERROR: 현재 stage만 지원"; exit 1; }
S=environments/staging # 엣지(CloudFront/S3)도 이 환경 스택에 통합됨
PORT=18443
SVCS="member:8081 community:8082 document:8083 wallet:8084" # name:port (TG output 키 = name)

out() { terraform -chdir="$1" output -raw "$2" 2>/dev/null || true; }
outj() { terraform -chdir="$1" output -json "$2" 2>/dev/null || true; }

ENDPOINT=$(out $S eks_cluster_endpoint)
HOST=${ENDPOINT#https://}
CLUSTER=$(out $S eks_cluster_name)
ALB_SG=$(out $S api_alb_security_group_id)
TG_JSON=$(outj $S api_target_group_arns)
[ -n "$HOST" ] && [ -n "$ALB_SG" ] && [ -n "$TG_JSON" ] || {
  echo "ERROR: environments/staging output을 못 읽음 — 먼저 apply/init 하세요"; exit 1; }

JUMP=$(aws ec2 describe-instances --profile "$PROFILE" --region "$REGION" \
  --filters "Name=tag:Name,Values=sb-${ENV}-jump" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text 2>/dev/null || true)
[ -n "$JUMP" ] && [ "$JUMP" != "None" ] || { echo "ERROR: sb-${ENV}-jump 실행 인스턴스 없음"; exit 1; }

# terraform output 값으로 4서비스 매니페스트를 동적 생성 (Deployment+Service+TargetGroupBinding)
manifest() {
  for sp in $SVCS; do
    local svc=${sp%:*} port=${sp#*:} tg
    tg=$(echo "$TG_JSON" | jq -r ".$svc")
    cat <<YAML
---
apiVersion: apps/v1
kind: Deployment
metadata: { name: $svc, namespace: default, labels: { app: $svc, fixture: edge-test } }
spec:
  replicas: 1
  selector: { matchLabels: { app: $svc } }
  template:
    metadata: { labels: { app: $svc, fixture: edge-test } }
    spec:
      containers:
        - name: whoami
          image: traefik/whoami:v1.10.2
          args: ["--port", "$port", "--name", "$svc"]
          ports: [{ containerPort: $port }]
          readinessProbe: { httpGet: { path: /actuator/health, port: $port }, initialDelaySeconds: 2, periodSeconds: 5 }
---
apiVersion: v1
kind: Service
metadata: { name: $svc, namespace: default, labels: { fixture: edge-test } }
spec:
  selector: { app: $svc }
  ports: [{ port: $port, targetPort: $port, protocol: TCP }]
---
apiVersion: elbv2.k8s.aws/v1beta1
kind: TargetGroupBinding
metadata: { name: $svc, namespace: default, labels: { fixture: edge-test } }
spec:
  serviceRef: { name: $svc, port: $port }
  targetGroupARN: $tg
  targetType: ip
  networking:
    ingress:
      - from: [{ securityGroup: { groupID: $ALB_SG } }]
        ports: [{ protocol: TCP, port: $port }]
YAML
  done
}

# 점프호스트 SSM 포트포워딩으로 private EKS API 터널을 열고 kubeconfig 설정
open_tunnel() {
  aws ssm start-session --target "$JUMP" --profile "$PROFILE" --region "$REGION" \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters host="$HOST",portNumber=443,localPortNumber=$PORT >/tmp/edge-test-pf.log 2>&1 &
  SSM_PID=$!
  # 각 명령에 || true — trap 안에서도 set -e가 살아있어, pkill이 자식 없을 때 반환하는 1이
  # 스크립트 종료코드를 오염시키는 것을 방지 (정리는 best-effort)
  trap 'kill $SSM_PID 2>/dev/null || true; pkill -P $SSM_PID 2>/dev/null || true' EXIT
  for i in $(seq 1 30); do
    if (exec 3<>/dev/tcp/127.0.0.1/$PORT) 2>/dev/null; then exec 3>&-; break; fi
    sleep 1
  done
  aws eks update-kubeconfig --name "$CLUSTER" --region "$REGION" --profile "$PROFILE" >/dev/null
  kubectl config set-cluster "$(kubectl config current-context)" \
    --server="https://localhost:$PORT" --tls-server-name="$HOST" >/dev/null
  for i in $(seq 1 30); do
    if kubectl get --raw=/readyz >/dev/null 2>&1; then break; fi
    sleep 2
  done
}

case "$ACTION" in
  deploy)
    open_tunnel
    manifest | kubectl apply -f -
    for sp in $SVCS; do kubectl -n default rollout status deploy/"${sp%:*}" --timeout=120s; done
    BUCKET=$(out $S spa_bucket_name)
    DIST=$(out $S cloudfront_distribution_id)
    DOMAIN=$(out $S cloudfront_domain_name)
    aws s3 cp scripts/edge-test/index.html "s3://$BUCKET/index.html" \
      --content-type text/html --profile "$PROFILE" --region "$REGION"
    aws cloudfront create-invalidation --distribution-id "$DIST" --paths "/" "/index.html" \
      --profile "$PROFILE" --query "Invalidation.Status" --output text >/dev/null
    echo "✔ 테스트 배포 완료 — 브라우저에서 https://$DOMAIN 열어 확인"
    ;;
  clean)
    open_tunnel
    manifest | kubectl delete --ignore-not-found -f -
    echo "✔ 더미 백엔드 4종 삭제 완료 (테스트 index.html은 S3에 남김 — 실 SPA 배포로 덮어쓰면 됨)"
    ;;
  *)
    echo "ERROR: action은 deploy|clean"; exit 1 ;;
esac
