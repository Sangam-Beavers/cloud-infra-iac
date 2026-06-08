#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# private-only EKS에 Cilium + AWS Load Balancer Controller + External Secrets를
# 설치한다. 점프호스트 SSM 포트포워딩으로 클러스터 API에 접속하므로
# 로컬에 helm/kubectl 만 있으면 된다 (클러스터 안엔 아무것도 설치 안 함).
#
# 개발 스택과 동일: Cilium (kube-proxy replacement, Hubble). 단 IPAM은 ENI 모드
# (파드가 VPC IP → ALB target-type=ip 직접 연동). 비밀은 AWS Secrets Manager + ESO.
#
# 사용법: ./install-k8s-stack.sh <prod|stage> [phase] [profile]
#   phase: cilium | alb | eso | all (기본 all)
# 전제: 해당 환경 apply 완료(cni=cilium), terraform output 사용 가능
# ---------------------------------------------------------------------------
set -euo pipefail

ENV=${1:?usage: install-k8s-stack.sh <prod|stage> [phase] [profile]}
PHASE=${2:-all}
PROFILE="${3:-${PROFILE:?PROFILE 미설정 — make 경유 또는 인자/env로 전달}}"
REGION="${REGION:-ap-northeast-2}"
PORT=18443
cd "$(dirname "$0")/.."

case "$ENV" in
  prod)  TF_DIR=environments/production ;;
  stage) TF_DIR=environments/staging ;;
  *) echo "ERROR: env는 prod|stage"; exit 1 ;;
esac

CLUSTER="sb-${ENV}-eks"
ENDPOINT=$(cd "$TF_DIR" && terraform output -raw eks_cluster_endpoint)
HOST=${ENDPOINT#https://}
VPC_ID=$(cd "$TF_DIR" && terraform output -raw vpc_id)
ALB_ROLE_ARN=$(cd "$TF_DIR" && terraform output -raw alb_controller_role_arn 2>/dev/null || echo "")
ESO_ROLE_ARN=$(cd "$TF_DIR" && terraform output -raw eso_role_arn 2>/dev/null || echo "")

JUMP=$(aws ec2 describe-instances --profile "$PROFILE" --region $REGION \
  --filters "Name=tag:Name,Values=sb-${ENV}-jump" "Name=instance-state-name,Values=running" \
  --query "Reservations[0].Instances[0].InstanceId" --output text)
[ "$JUMP" != "None" ] || { echo "ERROR: sb-${ENV}-jump 실행 인스턴스 없음"; exit 1; }

# --- 점프호스트 SSM 터널 + 전용 kubeconfig ---
KUBECONFIG_FILE=$(mktemp)
export KUBECONFIG="$KUBECONFIG_FILE"
TUNNEL_PID=""
# 정리 훅을 즉시 등록 — 이후 어느 단계(터널 기동 전 update-kubeconfig 등)에서 실패해도
# kubeconfig 임시파일/터널이 누수되지 않도록. SSM 터널은 aws CLI가 session-manager-plugin
# 자식 프로세스를 fork하므로, 부모만 kill하면 포트가 고아로 남는다 → 자식까지 reap한다.
cleanup() {
  [ -n "$TUNNEL_PID" ] && { pkill -P "$TUNNEL_PID" 2>/dev/null; kill "$TUNNEL_PID" 2>/dev/null; }
  rm -f "$KUBECONFIG_FILE"
}
trap cleanup EXIT
aws eks update-kubeconfig --name "$CLUSTER" --region $REGION --profile "$PROFILE" \
  --kubeconfig "$KUBECONFIG_FILE" >/dev/null
# API 주소를 로컬 터널로, TLS SNI는 원래 호스트로 검증
kubectl config set-cluster "arn:aws:eks:${REGION}:$(aws sts get-caller-identity --profile $PROFILE --query Account --output text):cluster/${CLUSTER}" \
  --server="https://localhost:${PORT}" --tls-server-name="$HOST" >/dev/null

aws ssm start-session --target "$JUMP" --profile "$PROFILE" --region $REGION \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters host="$HOST",portNumber="443",localPortNumber="$PORT" >/tmp/k8s-tunnel.log 2>&1 &
TUNNEL_PID=$!

echo "[*] 터널 대기 (localhost:${PORT} → ${HOST})..."
for i in $(seq 1 20); do kubectl version >/dev/null 2>&1 && break; sleep 2; done
kubectl get nodes >/dev/null 2>&1 || { echo "ERROR: API 연결 실패 (/tmp/k8s-tunnel.log 확인)"; exit 1; }
echo "[*] API 연결 OK"

install_cilium() {
  echo "=== Cilium 설치 (ENI 모드, kube-proxy replacement, Hubble) ==="
  # vpc-cni/kube-proxy 잔여 DaemonSet 제거 (Terraform 애드온 제거 후 잔존 시)
  kubectl -n kube-system delete daemonset aws-node --ignore-not-found
  kubectl -n kube-system delete daemonset kube-proxy --ignore-not-found
  helm repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null
  helm upgrade --install cilium cilium/cilium --version 1.18.9 \
    --namespace kube-system \
    --set ipam.mode=eni \
    --set eni.enabled=true \
    --set egressMasqueradeInterfaces=eth0 \
    --set routingMode=native \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost="$HOST" \
    --set k8sServicePort=443 \
    --set hubble.enabled=true \
    --set hubble.relay.enabled=true \
    --set hubble.ui.enabled=true \
    --wait --timeout 5m
  echo "[*] 노드 Ready 대기..."
  kubectl wait --for=condition=Ready nodes --all --timeout=5m
  # coredns는 Terraform이 애드온으로 관리하므로 이미 존재한다. vpc-cni→Cilium 교체로 기존
  # coredns 파드가 옛 IP를 들고 있으니 재시작해 Cilium 네트워킹으로 다시 띄운다.
  kubectl -n kube-system rollout restart deployment coredns
  echo "[✔] Cilium 설치 완료"
}

install_alb() {
  echo "=== AWS Load Balancer Controller 설치 ==="
  [ -n "$ALB_ROLE_ARN" ] || { echo "ERROR: alb_controller_role_arn output 없음 (apply 필요)"; exit 1; }
  kubectl -n kube-system create serviceaccount aws-load-balancer-controller \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n kube-system annotate serviceaccount aws-load-balancer-controller \
    eks.amazonaws.com/role-arn="$ALB_ROLE_ARN" --overwrite
  helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
  helm repo update eks >/dev/null
  # 차트 버전 고정 — modules/eks/policies/alb-controller-iam-policy.json은 컨트롤러
  # v3.4.0 공식 IAM 정책과 동일하다. 차트를 올릴 땐 정책도 함께 갱신할 것 (버전 스큐 방지).
  helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
    --version 3.4.0 \
    --namespace kube-system \
    --set clusterName="$CLUSTER" \
    --set serviceAccount.create=false \
    --set serviceAccount.name=aws-load-balancer-controller \
    --set region="$REGION" \
    --set vpcId="$VPC_ID" \
    --wait --timeout 5m
  echo "[✔] ALB Controller 설치 완료"
}

install_eso() {
  echo "=== External Secrets Operator 설치 (AWS Secrets Manager) ==="
  [ -n "$ESO_ROLE_ARN" ] || { echo "ERROR: eso_role_arn output 없음 (apply 필요)"; exit 1; }
  helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
  helm repo update external-secrets >/dev/null
  kubectl create namespace external-secrets --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n external-secrets create serviceaccount external-secrets \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n external-secrets annotate serviceaccount external-secrets \
    eks.amazonaws.com/role-arn="$ESO_ROLE_ARN" --overwrite
  # 차트 버전 고정 — 아래 ClusterSecretStore가 external-secrets.io/v1을 쓰므로
  # v1을 served/stored 하는 버전(>=0.10, 여기선 v2.6.0)에 핀해야 apply가 깨지지 않는다.
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --version 2.6.0 \
    --namespace external-secrets \
    --set installCRDs=true \
    --set serviceAccount.create=false \
    --set serviceAccount.name=external-secrets \
    --wait --timeout 5m
  # 클러스터 전역 SecretStore — AWS Secrets Manager provider
  kubectl apply -f - <<EOF
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: aws-secrets-manager
spec:
  provider:
    aws:
      service: SecretsManager
      region: ${REGION}
      auth:
        jwt:
          serviceAccountRef:
            name: external-secrets
            namespace: external-secrets
EOF
  echo "[✔] ESO + ClusterSecretStore 설치 완료"
}

case "$PHASE" in
  cilium) install_cilium ;;
  alb)    install_alb ;;
  eso)    install_eso ;;
  all)    install_cilium; install_alb; install_eso ;;
  *) echo "ERROR: phase는 cilium|alb|eso|all"; exit 1 ;;
esac

echo "✔ ${ENV}: k8s 스택(${PHASE}) 설치 완료"
