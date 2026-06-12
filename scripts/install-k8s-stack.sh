#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# private-only EKS에 Cilium + AWS Load Balancer Controller + External Secrets를
# 설치합니다. 점프 호스트 SSM 포트포워딩으로 클러스터 API에 접속하므로 로컬에
# helm/kubectl 만 있으면 됩니다 (클러스터 안에는 아무것도 설치하지 않습니다).
#
# 개발 스택과 동일하게 Cilium (kube-proxy replacement, Hubble)을 쓰되 IPAM은 ENI 모드입니다
# (파드가 VPC IP를 받아 ALB target-type=ip 로 직접 연동). 비밀은 AWS Secrets Manager + ESO 로 관리합니다.
#
# 사용법: ./install-k8s-stack.sh <prod|stage> [phase] [profile]
#   phase: cilium | alb | eso | ns | harbor | kafka | tgb | all (기본 all). ns=ArgoCD 배포 네임스페이스
#          사전 생성, harbor=노드 사내 CA 신뢰 (DaemonSet) + harbor-dockercfg (ExternalSecret),
#          kafka=Strimzi 단일 브로커 (gb-kafka) + 토픽 + bootstrap 을 Parameter Store 에 게시,
#          tgb=내부 ALB target group 에 백엔드 파드 등록 (TargetGroupBinding, PS /sb/{env}/tgb/* 참조)
# 전제: 해당 환경 apply 완료 (cni=cilium), terraform output 사용 가능
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

# k8s 매니페스트는 scripts/manifests/*.yaml 로 분리합니다. 정적 매니페스트는 그대로 apply 하고,
# 템플릿 (${VAR})은 envsubst 로 지정 변수만 렌더해 apply 합니다 (cd 로 cwd 가 repo 루트라 상대경로 사용 가능).
MF="scripts/manifests"
command -v envsubst >/dev/null 2>&1 || { echo "ERROR: envsubst 필요 — brew install gettext (mac) / apt-get install gettext-base (linux)"; exit 1; }

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

# --- 점프 호스트 SSM 터널 + 전용 kubeconfig ---
KUBECONFIG_FILE=$(mktemp)
export KUBECONFIG="$KUBECONFIG_FILE"
TUNNEL_PID=""
# 정리 훅을 즉시 등록합니다. 이후 어느 단계 (터널 기동 전 update-kubeconfig 등)에서 실패해도
# kubeconfig 임시파일이나 터널이 누수되지 않도록 하기 위함입니다. SSM 터널은 aws CLI 가
# session-manager-plugin 자식 프로세스를 fork 하므로, 부모만 kill 하면 포트가 고아로 남습니다.
# 따라서 자식 프로세스까지 reap 합니다.
cleanup() {
  [ -n "$TUNNEL_PID" ] && { pkill -P "$TUNNEL_PID" 2>/dev/null; kill "$TUNNEL_PID" 2>/dev/null; }
  rm -f "$KUBECONFIG_FILE"
}
trap cleanup EXIT
aws eks update-kubeconfig --name "$CLUSTER" --region $REGION --profile "$PROFILE" \
  --kubeconfig "$KUBECONFIG_FILE" >/dev/null
# API 주소는 로컬 터널을 가리키되, TLS SNI 는 원래 호스트로 검증합니다.
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
  # vpc-cni/kube-proxy 잔여 DaemonSet 을 제거합니다 (Terraform 애드온 제거 후 잔존하는 경우 대비).
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
  # coredns 는 Terraform 이 애드온으로 관리하므로 이미 존재합니다. vpc-cni 에서 Cilium 으로
  # 교체하면서 기존 coredns 파드가 옛 IP 를 들고 있으므로, 재시작해 Cilium 네트워킹으로 다시 띄웁니다.
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
  # 차트 버전을 고정합니다. modules/eks/policies/alb-controller-iam-policy.json 은 컨트롤러
  # v3.4.0 공식 IAM 정책과 동일하므로, 차트를 올릴 때는 정책도 함께 갱신해야 합니다 (버전 스큐 방지).
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
  # 차트 버전을 고정합니다. 아래 ClusterSecretStore 가 external-secrets.io/v1 을 쓰므로,
  # v1 을 served/stored 하는 버전 (>=0.10, 여기서는 v2.6.0)에 핀해야 apply 가 깨지지 않습니다.
  helm upgrade --install external-secrets external-secrets/external-secrets \
    --version 2.6.0 \
    --namespace external-secrets \
    --set installCRDs=true \
    --set serviceAccount.create=false \
    --set serviceAccount.name=external-secrets \
    --wait --timeout 5m
  # 클러스터 전역 SecretStore 2종 (scripts/manifests/cluster-secret-stores.yaml). 비밀은 Secrets
  # Manager 에서, 비밀이 아닌 인프라 동적값은 Parameter Store 에서 가져옵니다. 같은 ESO ServiceAccount (IRSA)를 씁니다.
  REGION="$REGION" envsubst '${REGION}' < "$MF/cluster-secret-stores.yaml" | kubectl apply -f -
  echo "[✔] ESO + ClusterSecretStore(SecretsManager·ParameterStore) 설치 완료"
}

ensure_app_namespaces() {
  # 온프렘 ArgoCD 는 네임스페이스 한정 Edit 으로 접근합니다. 한정 스코프로는 네임스페이스를
  # '생성'할 수 없으므로 (cluster-scoped), 배포 대상 네임스페이스를 미리 만들어 둡니다 (멱등).
  # 또 ArgoCD 캐시 동기화 (drift 감지)는 네임스페이스의 '모든' 리소스 타입을 list 하는데,
  # AmazonEKSEditPolicy (edit 롤)는 일부 타입 (CRD·CSIStorageCapacity 등)에 read 를 주지 않아
  # forbidden 이 납니다. 타입을 그룹별로 추가하는 건 whack-a-mole 이라, 네임스페이스 read-all 과
  # stack CRD 쓰기 보충 RBAC 를 적용합니다. access entry 의 K8s username 이 곧 principal ARN 이라 그 User 에 바인딩합니다.
  local ns_csv argo_arn
  ns_csv=$(cd "$TF_DIR" && terraform output -json argocd_namespaces 2>/dev/null | tr -d '[]" ' || true)
  [ -n "$ns_csv" ] || { echo "=== ArgoCD 배포 네임스페이스 없음 (argocd_namespaces 비어있음) — 생략 ==="; return 0; }
  argo_arn=$(cd "$TF_DIR" && terraform output -raw argocd_principal_arn 2>/dev/null || true)
  echo "=== ArgoCD 배포 네임스페이스 사전 생성 + CRD RBAC 보충 ==="
  local ns
  for ns in ${ns_csv//,/ }; do
    [ -n "$ns" ] || continue
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
    # 보충 RBAC (scripts/manifests/argocd-namespace-rbac.yaml): read-all + stack CRD 쓰기
    [ -n "$argo_arn" ] && ns="$ns" argo_arn="$argo_arn" \
      envsubst '${ns} ${argo_arn}' < "$MF/argocd-namespace-rbac.yaml" | kubectl apply -f -
  done
  # member-service Cognito IRSA: SA 'member' (앱 ns)이 cognito 관리 역할 (AdminCreateUser 등)을 assume 합니다.
  # 차트 Deployment 의 serviceAccountName: member 와 일치해야 합니다 (stage). 역할 ARN 은 cognito 모듈 출력이며 (없으면 생략).
  local cognito_arn m_ns
  cognito_arn=$(cd "$TF_DIR" && terraform output -raw cognito_member_role_arn 2>/dev/null || true)
  if [ -n "$cognito_arn" ]; then
    m_ns="${ns_csv%%,*}"
    kubectl -n "$m_ns" create serviceaccount member --dry-run=client -o yaml | kubectl apply -f -
    kubectl -n "$m_ns" annotate serviceaccount member \
      eks.amazonaws.com/role-arn="$cognito_arn" --overwrite
    echo "[✔] member SA IRSA ($m_ns/member → cognito 관리 역할)"
  fi
}

install_harbor() {
  # 온프렘 Harbor 에서 이미지를 pull 하려면 두 가지가 필요합니다 (aa6f6b6 이 경로/DNS/prep 까지만 하고
  # 노드 측 설정으로 남겨둔 부분). ① 노드 containerd 가 사내 CA 로 서명된 Harbor TLS 를 신뢰하고,
  # ② robot 자격증명으로 만든 dockerconfigjson pull secret 이 필요합니다. 둘 다 멱등합니다.
  echo "=== Harbor pull 활성화 (노드 CA 신뢰 DaemonSet + harbor-dockercfg ExternalSecret) ==="
  local ca_file="secrets/sb-local-ca.crt" env_file="secrets/sb.harbor.env"
  [ -f "$ca_file" ]  || { echo "ERROR: $ca_file 없음 (사내 로컬 CA prep 필요)"; exit 1; }
  [ -f "$env_file" ] || { echo "ERROR: $env_file 없음 (Harbor robot 자격증명 prep 필요)"; exit 1; }

  # --- ① 노드 사내 CA 신뢰 (Harbor TLS x509 해소) — 상세는 매니페스트 헤더 참조 ---
  # CA 를 ConfigMap harbor-ca 로 주입하고, DaemonSet 이 노드 시스템 신뢰스토어에 넣어 containerd 가 신뢰하게 합니다.
  kubectl -n kube-system create configmap harbor-ca \
    --from-file=sb-local-ca.crt="$ca_file" --dry-run=client -o yaml | kubectl apply -f -
  kubectl apply -f "$MF/harbor-ca-daemonset.yaml"

  # --- ② Harbor robot 자격증명 → SM 등록 → ExternalSecret 으로 harbor-dockercfg 생성 ---
  # 파일을 source 하지 않습니다. NAME 에 '$'·'+' 가 포함되면 셸 확장 사고가 날 수 있어 cut 으로 안전하게 추출합니다.
  local hname hsecret hhost
  hname=$(grep -E '^NAME='   "$env_file" | head -1 | cut -d= -f2-)
  hsecret=$(grep -E '^SECRET=' "$env_file" | head -1 | cut -d= -f2-)
  hhost=$(grep -E '^HOST='   "$env_file" | head -1 | cut -d= -f2-)
  [ -n "$hname" ] && [ -n "$hsecret" ] && [ -n "$hhost" ] || {
    echo "ERROR: $env_file에 NAME/SECRET/HOST 모두 필요"; exit 1; }

  local sm_name="sb/${ENV}/harbor/robot" sm_json
  sm_json=$(jq -nc --arg u "$hname" --arg p "$hsecret" '{username:$u,password:$p}')
  echo "[*] SM 등록: $sm_name (ESO 스코프 sb/${ENV}/* 내)"
  aws secretsmanager put-secret-value --secret-id "$sm_name" --secret-string "$sm_json" \
    --profile "$PROFILE" --region "$REGION" >/dev/null 2>&1 || \
  aws secretsmanager create-secret --name "$sm_name" --secret-string "$sm_json" \
    --description "Harbor robot 자격증명 (ESO → harbor-dockercfg)" \
    --profile "$PROFILE" --region "$REGION" >/dev/null

  # harbor-dockercfg 는 앱이 imagePullSecrets 로 참조하는 네임스페이스 (=ArgoCD 배포 대상)에 생성합니다.
  local ns_csv ns
  ns_csv=$(cd "$TF_DIR" && terraform output -json argocd_namespaces 2>/dev/null | tr -d '[]" ' || true)
  [ -n "$ns_csv" ] || { echo "=== 앱 네임스페이스 없음 (argocd_namespaces 비어있음) — ExternalSecret 생략 ==="; return 0; }
  for ns in ${ns_csv//,/ }; do
    [ -n "$ns" ] || continue
    # harbor-dockercfg ExternalSecret (scripts/manifests/harbor-dockercfg-externalsecret.yaml)
    ns="$ns" hhost="$hhost" sm_name="$sm_name" \
      envsubst '${ns} ${hhost} ${sm_name}' < "$MF/harbor-dockercfg-externalsecret.yaml" | kubectl apply -f -
  done
  echo "[✔] Harbor pull 활성화 완료 (CA DaemonSet + harbor-dockercfg)"
}

install_kafka() {
  # 백엔드 4서비스 (member 등)의 마일스톤 이벤트용 Kafka 로, Strimzi 단일 브로커 (gb-kafka, KRaft)입니다.
  # 인증은 A안 (PLAINTEXT + NetworkPolicy 격리)을 씁니다. 접속 주소는 Parameter Store 에 게시해 앱이 ESO 로
  # 끌어가게 합니다 (서비스명 하드코딩을 피하려는 의도로, redis/harbor 가 SM 에 쓰는 것과 동일한 취지).
  echo "=== Kafka 설치 (Strimzi gb-kafka 단일 브로커, KRaft) ==="
  helm repo add strimzi https://strimzi.io/charts/ >/dev/null 2>&1 || true
  helm repo update strimzi >/dev/null
  kubectl create namespace kafka --dry-run=client -o yaml | kubectl apply -f -
  # 차트 버전을 고정합니다. Strimzi 1.0.0 이 Kafka 4.1.2 를 지원하며 (온프렘 gb-kafka 와 동일), 기본 watch 는 설치 ns (kafka)입니다.
  helm upgrade --install strimzi-kafka-operator strimzi/strimzi-kafka-operator \
    --version 1.0.0 \
    --namespace kafka \
    --wait --timeout 5m
  kubectl apply -f "$MF/kafka-cluster.yaml"
  echo "[*] Kafka 클러스터 Ready 대기 (브로커 기동·스토리지 포맷)..."
  kubectl -n kafka wait kafka/gb-kafka --for=condition=Ready --timeout=10m
  kubectl apply -f "$MF/kafka-topics.yaml"
  # A안 NetworkPolicy: 백엔드 네임스페이스 (argocd_namespaces 첫 항목)에만 9092 를 허용합니다.
  local app_ns
  app_ns=$(cd "$TF_DIR" && terraform output -json argocd_namespaces 2>/dev/null | tr -d '[]" ' | cut -d, -f1 || true)
  app_ns="${app_ns:-sb-${ENV}-app-ns}"
  APP_NS="$app_ns" envsubst '${APP_NS}' < "$MF/kafka-networkpolicy.yaml" | kubectl apply -f -
  # 격리가 이 NetworkPolicy 단일 통제에 의존하므로 (PLAINTEXT·무인증) 실제 적용 여부를 검증합니다. 미적용 시 평문 리스너가 무방비라 중단합니다.
  kubectl -n kafka get networkpolicy kafka-allow-backend >/dev/null 2>&1 || {
    echo "ERROR: kafka NetworkPolicy(kafka-allow-backend) 미적용 — 평문 리스너 무방비, 중단"
    exit 1
  }
  # 접속 주소를 Parameter Store 에 게시합니다 (비밀이 아닌 엔드포인트라 String 타입, /sb/${ENV}/* 경로라 ESO IRSA 가 커버).
  local boot="gb-kafka-kafka-bootstrap.kafka.svc.cluster.local:9092"
  echo "[*] PS 게시: /sb/${ENV}/kafka/bootstrap_servers = $boot"
  aws ssm put-parameter --name "/sb/${ENV}/kafka/bootstrap_servers" --type String \
    --value "$boot" --overwrite --profile "$PROFILE" --region "$REGION" >/dev/null
  echo "[✔] Kafka 설치 완료 (bootstrap: $boot, NetworkPolicy: ${app_ns}→9092)"
}

install_tgb() {
  # 내부 ALB (api-gateway, terraform)의 target group 에 백엔드 서비스 파드를 등록합니다.
  # TGB 의 targetGroupARN 은 CR spec 필드라 ESO (Secret)로 채울 수 없으므로, terraform 이 PS /sb/{env}/tgb/* 에
  # 게시한 {arn, port} 와 alb_sg 를 여기서 읽어 TargetGroupBinding 을 만듭니다 (terraform 과 cluster 를 잇는 글루).
  echo "=== TargetGroupBinding 생성 (내부 ALB ↔ 백엔드, PS /sb/${ENV}/tgb/*) ==="
  local app_ns alb_sg names
  app_ns=$(cd "$TF_DIR" && terraform output -json argocd_namespaces 2>/dev/null | tr -d '[]" ' | cut -d, -f1 || true)
  app_ns="${app_ns:-sb-${ENV}-app-ns}"
  alb_sg=$(aws ssm get-parameter --name "/sb/${ENV}/tgb/alb_sg" --query Parameter.Value --output text \
    --profile "$PROFILE" --region "$REGION" 2>/dev/null || true)
  [ -n "$alb_sg" ] && [ "$alb_sg" != "None" ] || { echo "ERROR: /sb/${ENV}/tgb/alb_sg 없음 — api-gateway tgb_ssm_prefix apply 확인"; exit 1; }
  names=$(aws ssm get-parameters-by-path --path "/sb/${ENV}/tgb" --query "Parameters[].Name" --output text \
    --profile "$PROFILE" --region "$REGION" 2>/dev/null || true)
  local n svc val arn port
  for n in $names; do
    svc="${n##*/}"
    [ "$svc" = "alb_sg" ] && continue
    val=$(aws ssm get-parameter --name "$n" --query Parameter.Value --output text --profile "$PROFILE" --region "$REGION" 2>/dev/null || true)
    arn=$(echo "$val" | jq -r .arn)
    port=$(echo "$val" | jq -r .port)
    echo "[*] TGB: $svc (port $port)"
    SVC="$svc" APP_NS="$app_ns" TG_ARN="$arn" PORT="$port" ALB_SG="$alb_sg" \
      envsubst '${SVC} ${APP_NS} ${TG_ARN} ${PORT} ${ALB_SG}' < "$MF/targetgroupbinding.yaml" | kubectl apply -f -
  done
  echo "[✔] TargetGroupBinding 생성 완료 (ns: $app_ns)"
}

case "$PHASE" in
  cilium) install_cilium ;;
  alb)    install_alb ;;
  eso)    install_eso ;;
  ns)     ensure_app_namespaces ;;
  harbor) install_harbor ;;
  kafka)  install_kafka ;;
  tgb)    install_tgb ;;
  all)    install_cilium; install_alb; install_eso; ensure_app_namespaces; install_harbor; install_kafka; install_tgb ;;
  *) echo "ERROR: phase는 cilium|alb|eso|ns|harbor|kafka|tgb|all"; exit 1 ;;
esac

echo "✔ ${ENV}: k8s 스택 (${PHASE}) 설치 완료"
