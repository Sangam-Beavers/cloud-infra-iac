#!/bin/bash
# =============================================================================
# VPN Router Auto-Provisioning (Self-Healing / AZ Failover)
# 기존 검증된 VPN 라우터 프로비저닝 스크립트의 Terraform 템플릿판.
# 변경점: S3 설정 다운로드 → SSM Parameter Store에서 키만 fetch해 conf를 생성,
#         [CHANGE ME] 값/CIDR → Terraform templatefile 주입, FRR static GW 동적 계산.
# =============================================================================
# -u: 미정의 변수 즉시 실패, pipefail: 파이프 상류 실패 포착.
# -e는 쓰지 않는다 — apt/sed 등 의도적으로 실패를 허용하는 줄이 많고, 핵심 명령은
# retry 헬퍼와 ssm_get_required (빈값 가드)로 개별 보호한다.
set -uo pipefail

exec > >(tee /var/log/user-data.log | logger -t user-data -s 2>/dev/console) 2>&1
echo "=== VPN Router Auto-Provisioning Start: $(date -u) ==="

retry() {
  local max="$1"; shift
  local n=1
  until "$@"; do
    if [ "$n" -ge "$max" ]; then
      echo "[ERROR] failed after $max attempts: $*"
      return 1
    fi
    echo "[WARN] retry $n/$max: $*"
    n=$((n+1)); sleep 5
  done
}

# ==========================================
# 1. 패키지 설치
# ==========================================
export DEBIAN_FRONTEND=noninteractive
retry 5 apt-get update -y
apt-get upgrade -y
retry 5 apt-get install -y wireguard frr frr-pythontools iproute2 iptables conntrack curl unzip

# AWS CLI v2 — Ubuntu 24.04 (noble)에는 awscli apt 패키지가 없음 (검증 당시 22.04와의 차이)
# awscli가 깨지면 이후 모든 aws 호출이 실패하므로 설치 실패 시 부팅 중단
if ! command -v aws > /dev/null 2>&1; then
  ARCH=$(uname -m)
  retry 5 curl -sf "https://awscli.amazonaws.com/awscli-exe-linux-$ARCH.zip" -o /tmp/awscliv2.zip
  unzip -q -o /tmp/awscliv2.zip -d /tmp || { echo "[ERROR] awscli unzip 실패"; exit 1; }
  /tmp/aws/install || { echo "[ERROR] awscli install 실패"; exit 1; }
  rm -rf /tmp/aws /tmp/awscliv2.zip
  command -v aws > /dev/null 2>&1 || { echo "[ERROR] awscli 설치 후에도 미발견"; exit 1; }
fi

modprobe nf_conntrack || true
echo "nf_conntrack" > /etc/modules-load.d/conntrack.conf

# 참고: frr.conf의 정적 경로 (ip route)는 staticd가 처리하지만, noble의 FRR 패키징은
# watchfrr/zebra/staticd를 항상 기동하므로 별도 활성화가 불필요 (daemons 파일 주석 참조)
sed -i 's/^bgpd=no/bgpd=yes/'   /etc/frr/daemons
sed -i 's/^zebra=no/zebra=yes/' /etc/frr/daemons

# ==========================================
# 2. IMDSv2 메타데이터
# ==========================================
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")
imds() { curl -s -H "X-aws-ec2-metadata-token: $TOKEN" "http://169.254.169.254/latest/meta-data/$1"; }

INSTANCE_ID=$(imds instance-id)
REGION=$(imds placement/region)
MAC_ADDR=$(imds mac)
INTERFACE_ID=$(imds "network/interfaces/macs/$MAC_ADDR/interface-id")
echo "[INFO] INSTANCE_ID=$INSTANCE_ID REGION=$REGION ENI=$INTERFACE_ID"
if [ -z "$INSTANCE_ID" ] || [ -z "$REGION" ] || [ -z "$INTERFACE_ID" ]; then
  echo "[ERROR] metadata fetch incomplete - aborting"; exit 1
fi

# ==========================================
# 3. EIP 재연결 & Source/Dest Check 해제
# ==========================================
retry 5 aws ec2 associate-address --instance-id "$INSTANCE_ID" \
  --allocation-id "${allocation_id}" --region "$REGION" --allow-reassociation
retry 5 aws ec2 modify-network-interface-attribute \
  --network-interface-id "$INTERFACE_ID" --no-source-dest-check --region "$REGION"

# ==========================================
# 4. VPC Route Table 갱신 (온프렘 대역 return 경로 → 이 인스턴스 ENI)
# ==========================================
%{ for rtb in return_route_table_ids ~}
for CIDR in %{ for c in onprem_cidrs }${c} %{ endfor }; do
  echo "[INFO] ${rtb} <- $CIDR"
  retry 5 bash -c "aws ec2 replace-route --route-table-id '${rtb}' --destination-cidr-block \"$CIDR\" \
      --network-interface-id '$INTERFACE_ID' --region '$REGION' \
    || aws ec2 create-route --route-table-id '${rtb}' --destination-cidr-block \"$CIDR\" \
      --network-interface-id '$INTERFACE_ID' --region '$REGION'"
done
%{ endfor ~}

# ==========================================
# 4b. App(private) RT — Harbor 등 한정 목적지만 이 ENI로 (private 대역은 광고하지 않음)
# ==========================================
%{ for rtb in app_route_table_ids ~}
for CIDR in %{ for d in app_onprem_destinations }${d} %{ endfor }; do
  echo "[INFO] app ${rtb} <- $CIDR"
  retry 5 bash -c "aws ec2 replace-route --route-table-id '${rtb}' --destination-cidr-block \"$CIDR\" \
      --network-interface-id '$INTERFACE_ID' --region '$REGION' \
    || aws ec2 create-route --route-table-id '${rtb}' --destination-cidr-block \"$CIDR\" \
      --network-interface-id '$INTERFACE_ID' --region '$REGION'"
done
%{ endfor ~}

# ==========================================
# 5. 커널 파라미터 (forwarding + rp_filter 완화)
# ==========================================
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=2
sysctl -w net.ipv4.conf.default.rp_filter=2
cat > /etc/sysctl.d/99-vpn-router.conf << 'EOF'
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
EOF

# ==========================================
# 6. SSM에서 WG 키 fetch → conf 생성 (키는 디스크 600 외 비노출)
# ==========================================
ssm_get() { aws ssm get-parameter --name "$1" --with-decryption --region "$REGION" --query Parameter.Value --output text; }

# 빈 값이 conf에 들어가면 터널이 조용히 죽으므로, retry로 받고 비어있으면 부팅 실패시킴.
# retry 90회 (약 15분): up-all이 apply 완료 후 vpn-keys로 키를 등록할 때까지 첫 부팅이 대기
# → 별도 재기동 없이 멱등하게 기동
ssm_get_required() {
  local val
  retry 90 bash -c "aws ssm get-parameter --name '$1' --with-decryption --region '$REGION' >/dev/null 2>&1"
  val=$(ssm_get "$1")
  [ -n "$val" ] || { echo "[ERROR] empty SSM value: $1"; exit 1; }
  printf '%s' "$val"
}

EC2_PRV=$(ssm_get_required "${ssm_prefix}/ec2-private-key")

mkdir -p /etc/wireguard
%{ for ifname, t in tunnels ~}
PEER_PUB=$(ssm_get_required "${ssm_prefix}/${t.peer_pubkey_ssm}")
cat > /etc/wireguard/${ifname}.conf << EOF
[Interface]
Address = ${t.address}
PrivateKey = $EC2_PRV
ListenPort = ${t.listen_port}
Table = off
MTU = ${wg_mtu}

[Peer]
PublicKey = $PEER_PUB
AllowedIPs = ${t.peer_ip}/32%{ for c in onprem_cidrs }, ${c}%{ endfor }
EOF
chmod 600 /etc/wireguard/${ifname}.conf
%{ endfor ~}
unset EC2_PRV PEER_PUB

# ==========================================
# 7. FRR 설정 생성 (광고 대역 static next-hop은 자기 서브넷 GW로 동적 계산)
# ==========================================
GW=$(ip route | awk '/default/ {print $3; exit}')
echo "[INFO] VPC subnet gateway: $GW"
cat > /etc/frr/frr.conf << EOF
!
%{ for c in advertise_cidrs ~}
ip route ${c} $GW
%{ endfor ~}
!
router bgp ${bgp_local_as}
 bgp router-id ${bgp_router_id}
 no bgp ebgp-requires-policy
%{ for ifname, t in tunnels ~}
 neighbor ${t.peer_ip} remote-as ${bgp_peer_as}
 neighbor ${t.peer_ip} description ${ifname}
 neighbor ${t.peer_ip} ebgp-multihop 2
 neighbor ${t.peer_ip} soft-reconfiguration inbound
%{ endfor ~}
 address-family ipv4 unicast
%{ for c in advertise_cidrs ~}
  network ${c}
%{ endfor ~}
 exit-address-family
!
EOF
chown frr:frr /etc/frr/frr.conf

# ==========================================
# 8. WireGuard 기동 + 터널 endpoint 정적 route
# ==========================================
%{ for ifname, t in tunnels ~}
systemctl enable wg-quick@${ifname}
systemctl restart wg-quick@${ifname}
ip route replace ${t.peer_ip}/32 dev ${ifname}
%{ endfor ~}

# ==========================================
# 9. Policy Routing (비대칭 방지 — 들어온 터널로 reply 회송)
# ==========================================
MGMT_DEV=$(ip route | awk '/default/ {print $5; exit}')
%{ for idx, ifname in keys(tunnels) ~}
ip route replace ${pfsense_nat_ip}/32 dev ${ifname} table ${100 + idx}
iptables -t mangle -C PREROUTING -i ${ifname} -j CONNMARK --set-mark ${idx + 1} 2>/dev/null \
  || iptables -t mangle -A PREROUTING -i ${ifname} -j CONNMARK --set-mark ${idx + 1}
ip rule add fwmark ${idx + 1} table ${100 + idx} priority ${100 + idx} 2>/dev/null || true
%{ endfor ~}
iptables -t mangle -C PREROUTING -i "$MGMT_DEV" -j CONNMARK --restore-mark 2>/dev/null \
  || iptables -t mangle -A PREROUTING -i "$MGMT_DEV" -j CONNMARK --restore-mark

# ==========================================
# 9b. SNAT — private (app) → on-prem 목적지를 터널 IP로 가장 (private 대역 은닉)
#   on-prem(Harbor)엔 라우터 터널 IP 단일 소스로만 보이고, 회신은 BGP 네이버 (터널)로 되돌아온다.
# ==========================================
%{ for ifname in keys(tunnels) ~}
%{ for src in snat_source_cidrs ~}
%{ for dst in app_onprem_destinations ~}
iptables -t nat -C POSTROUTING -s ${src} -d ${dst} -o ${ifname} -j MASQUERADE 2>/dev/null \
  || iptables -t nat -A POSTROUTING -s ${src} -d ${dst} -o ${ifname} -j MASQUERADE
%{ endfor ~}
%{ endfor ~}
%{ endfor ~}

# ==========================================
# 9c. MSS clamping — forward TCP 세그먼트를 경로 MTU(WG 1420)에 맞춰 줄인다.
#   인터넷 경유 터널이라 PMTU 발견이 막히면 큰 세그먼트가 drop/reset된다 (이미지 pull 등 대용량 실패).
#   SYN에 clamp하면 양 끝이 처음부터 작은 MSS로 협상해 fragment 없이 전송된다.
# ==========================================
iptables -t mangle -C FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
  || iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# ==========================================
# 10. FRR 기동 + 상태 로그
# ==========================================
systemctl enable frr
systemctl restart frr

wg show || true
ip route show || true
ip rule show || true
vtysh -c "show ip bgp summary" || true
echo "=== VPN Router Auto-Provisioning Complete: $(date -u) ==="
