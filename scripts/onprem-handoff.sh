#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# 온프렘에서 후속 작업이 필요한 "배포 산출물"을 secrets/.* 파일로 기록한다.
# (VPN EIP를 secrets/.wireguard-<env>-eip로 기록하는 vpn-eip 타겟과 같은 취지 —
#  값만이 아니라 "온프렘에서 이 값으로 뭘 해야 하는지"를 주석으로 함께 남긴다.)
#
# 사용법: ./onprem-handoff.sh <prod|stage>
# 생성물:
#   secrets/.eks-cp-<env>-dns-ip           — pfSense DNS conditional forwarder 설정용
#   secrets/.argocd-<env>-cluster.yaml     — 온프렘 ArgoCD에 바로 apply할 cluster Secret (연동 시)
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
OUT="secrets/.eks-cp-${ENV}-dns-ip"

# 환경별 파일 — 매번 덮어쓰기 (prefix 공존 없음, .argocd-<env>-cluster.yaml와 동일 방식)
cat > "$OUT" <<HDR
# === EKS Control-Plane DNS ($ENV) — 온프렘 pfSense DNS Forwarding 설정 ===
# private-only EKS의 API 엔드포인트 호스트명은 VPC 내부 private IP로만 해석된다.
# 온프렘 ArgoCD가 이 API에 접속하려면, pfSense의 DNS Resolver (또는 Forwarder)에서
# EKS_ENDPOINT_HOST 도메인의 conditional forwarder를 EKS_RESOLVER_INBOUND_IPS로 향하게 설정한다.
# 그러면 온프렘이 호스트명을 private ENI IP로 해석하고, TLS (인증서 SAN=호스트명) 검증도 통과한다.
EKS_ENDPOINT_HOST=$HOST
EKS_RESOLVER_INBOUND_IPS=$IPS
HDR

echo "기록됨: $OUT ($ENV)"
cat "$OUT"

# ---------------------------------------------------------------------------
# ArgoCD cluster Secret — 온프렘 ArgoCD (devops-system NS) 에 바로 apply할 완성본 YAML.
# argocd-iam 모듈 (연동 시) 이 만든 전용 IAM User 키 + 클러스터 접속 정보를 채워 생성한다.
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

# 네임스페이스 한정 Edit이라 ArgoCD도 namespaces로 같은 범위로 묶는다 (clusterResources는
# namespaces 설정 시 기본 false라 생략). metadata.namespace는 ArgoCD가 도는 NS (고정),
# stringData.namespaces는 EKS 관리 대상 NS. $HOST는 상단에서 계산된 엔드포인트 호스트.
ARGO="secrets/.argocd-${ENV}-cluster.yaml"
cat > "$ARGO" <<YAML
apiVersion: v1
kind: Secret
metadata:
  name: ${CLUSTER}
  namespace: devops-system
  labels:
    argocd.argoproj.io/secret-type: cluster
type: Opaque
stringData:
  name: ${CLUSTER}
  server: https://${HOST}
  namespaces: "${NS}"
  config: |
    {
      "execProviderConfig": {
        "apiVersion": "client.authentication.k8s.io/v1beta1",
        "command": "argocd-k8s-auth",
        "args": ["aws", "--cluster-name", "${CLUSTER}"],
        "env": {
          "AWS_ACCESS_KEY_ID": "${AKID}",
          "AWS_SECRET_ACCESS_KEY": "${SECRET}",
          "AWS_REGION": "${REGION}"
        }
      },
      "tlsClientConfig": {
        "insecure": false,
        "caData": "${CA}"
      }
    }
YAML
chmod 600 "$ARGO"

echo "기록됨: $ARGO ($ENV) — 시크릿 포함, 600 권한 (git 무시됨)"
echo "  적용: kubectl -n devops-system apply -f $ARGO"
