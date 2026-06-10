#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 온프렘에서 후속 작업이 필요한 "배포 산출물"을 secrets/.* 파일로 기록한다.
# (VPN EIP를 secrets/.wireguard-eip로 기록하는 vpn-eip 타겟과 같은 취지 —
#  값만이 아니라 "온프렘에서 이 값으로 뭘 해야 하는지"를 주석으로 함께 남긴다.)
#
# 사용법: ./onprem-handoff.sh <prod|stage>
# 생성물:
#   secrets/.eks-control-plane-dns-ip  — pfSense DNS conditional forwarder 설정용
#   secrets/.argocd-cluster            — 온프렘 ArgoCD cluster 등록 자격증명 (연동 시)
# ---------------------------------------------------------------------------
set -euo pipefail

ENV=${1:?usage: onprem-handoff.sh <prod|stage>}
REGION="${REGION:-ap-northeast-2}"
cd "$(dirname "$0")/.."

case "$ENV" in
  prod)  TF_DIR=environments/production ;;
  stage) TF_DIR=environments/staging ;;
  *) echo "ERROR: env는 prod|stage"; exit 1 ;;
esac

ENVUP=$(printf '%s' "$ENV" | tr '[:lower:]' '[:upper:]')
HOST=$(cd "$TF_DIR" && terraform output -raw eks_cluster_endpoint 2>/dev/null | sed 's#^https://##')
IPS=$(cd "$TF_DIR" && terraform output -json resolver_inbound_ips 2>/dev/null | tr -d '[] "' )

# resolver 출력이 비면 온프렘 미연동 (onprem_integration.enabled=false) — 핸드오프할 게 없으니 생략.
# (up-all에서 무조건 호출돼도 비연동 환경은 깨지 않도록 exit 0)
if [ -z "$IPS" ]; then
  echo "온프렘 미연동 ($ENV) — resolver 없음, 핸드오프 생략"
  exit 0
fi
if [ -z "$HOST" ]; then
  echo "ERROR: eks_cluster_endpoint 출력이 비어 있음 (apply 완료 확인)"
  exit 1
fi

mkdir -p secrets
OUT="secrets/.eks-control-plane-dns-ip"

# 헤더 (환경 무관 설명)는 1회만 생성 — prod/stage가 한 파일에 prefix로 공존 (.wireguard-eip와 동일 방식)
if [ ! -f "$OUT" ]; then
  cat > "$OUT" <<'HDR'
# === EKS Control-Plane DNS — 온프렘 pfSense DNS Forwarding 설정 (prod/stage 공존) ===
# private-only EKS의 API 엔드포인트 호스트명은 VPC 내부 private IP로만 해석된다.
# 온프렘 ArgoCD가 이 API에 접속하려면, pfSense의 DNS Resolver (또는 Forwarder)에서
# <ENV>_EKS_ENDPOINT_HOST 도메인의 conditional forwarder를 같은 환경의
# <ENV>_EKS_RESOLVER_INBOUND_IPS로 향하게 설정한다 (PROD_*는 prod, STAGE_*는 stage).
# 그러면 온프렘이 호스트명을 private ENI IP로 해석하고, TLS (인증서 SAN=호스트명) 검증도 통과한다.
HDR
fi

# 이 환경 줄만 갱신하고 다른 환경 (prefix) 줄은 보존 — 둘을 같은 파일에 구분 기록 (덮어쓰기 X)
tmp=$(mktemp)
grep -v "^${ENVUP}_EKS_" "$OUT" > "$tmp" || true
{
  echo "${ENVUP}_EKS_ENDPOINT_HOST=$HOST"
  echo "${ENVUP}_EKS_RESOLVER_INBOUND_IPS=$IPS"
} >> "$tmp"
mv "$tmp" "$OUT"

echo "기록됨: $OUT ($ENV)"
cat "$OUT"

# ---------------------------------------------------------------------------
# ArgoCD cluster 등록 자격증명 — 온프렘 ArgoCD가 이 EKS를 배포 대상으로 등록할 때 쓰는 값.
# argocd-iam 모듈 (연동 시) 이 만든 전용 IAM User 키 + 클러스터 접속 정보를 한 파일에 모은다.
# ---------------------------------------------------------------------------
ARN=$(cd "$TF_DIR" && terraform output -raw argocd_principal_arn 2>/dev/null || true)

# principal이 비면 ArgoCD 미연동 (argocd-iam 모듈 미생성) — 핸드오프할 게 없으니 생략.
if [ -z "$ARN" ]; then
  echo "ArgoCD 미연동 ($ENV) — argocd-iam 없음, cluster 핸드오프 생략"
  exit 0
fi

AKID=$(cd "$TF_DIR" && terraform output -raw argocd_access_key_id)
SECRET=$(cd "$TF_DIR" && terraform output -raw argocd_secret_access_key)
CLUSTER=$(cd "$TF_DIR" && terraform output -raw eks_cluster_name)
CA=$(cd "$TF_DIR" && terraform output -raw eks_cluster_ca)
NS=$(cd "$TF_DIR" && terraform output -json argocd_namespaces 2>/dev/null | tr -d '[] "')

ARGO="secrets/.argocd-cluster"

# 헤더 (환경 무관 설명)는 1회만 생성 — prod/stage가 한 파일에 prefix로 공존
if [ ! -f "$ARGO" ]; then
  cat > "$ARGO" <<'HDR'
# === ArgoCD Cluster 등록 자격증명 (prod/stage 공존) ===
# 온프렘 ArgoCD에서 이 값으로 cluster Secret을 조립해 등록한다.
# manifests/argocd/cluster-secret.yaml.example 한 파일에 모두 채워 ArgoCD 네임스페이스에 apply:
#   server ← <ENV>_EKS_ENDPOINT_HOST, clusterName ← <ENV>_EKS_CLUSTER_NAME, caData ← <ENV>_EKS_CA_DATA
#   execProviderConfig.env ← <ENV>_ARGOCD_ACCESS_KEY_ID / _SECRET_ACCESS_KEY / <ENV>_EKS_REGION
# 주의: <ENV>_ARGOCD_NAMESPACES는 한정 스코프라 ArgoCD가 직접 못 만든다 → install-k8s-stack이 사전 생성.
# 키 회전: terraform taint module.argocd_iam[0].aws_iam_access_key.this && apply 후 이 스크립트 재실행.
HDR
fi

# 이 환경 줄만 갱신하고 다른 환경 (prefix) 줄은 보존 ($HOST는 상단에서 계산된 엔드포인트 호스트)
tmp=$(mktemp)
grep -v "^${ENVUP}_" "$ARGO" > "$tmp" || true
{
  echo "${ENVUP}_ARGOCD_PRINCIPAL_ARN=$ARN"
  echo "${ENVUP}_ARGOCD_ACCESS_KEY_ID=$AKID"
  echo "${ENVUP}_ARGOCD_SECRET_ACCESS_KEY=$SECRET"
  echo "${ENVUP}_ARGOCD_NAMESPACES=$NS"
  echo "${ENVUP}_EKS_CLUSTER_NAME=$CLUSTER"
  echo "${ENVUP}_EKS_ENDPOINT_HOST=$HOST"
  echo "${ENVUP}_EKS_REGION=$REGION"
  echo "${ENVUP}_EKS_CA_DATA=$CA"
} >> "$tmp"
mv "$tmp" "$ARGO"
chmod 600 "$ARGO"

echo "기록됨: $ARGO ($ENV) — 시크릿 포함, 600 권한 (git 무시됨)"
