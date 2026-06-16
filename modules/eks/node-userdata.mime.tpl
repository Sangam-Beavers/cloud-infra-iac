MIME-Version: 1.0
Content-Type: multipart/mixed; boundary="//"

--//
Content-Type: text/x-shellscript; charset="us-ascii"

#!/bin/bash
# 사내 Harbor( harbor.sb.fisa )의 CA 를 노드 부팅 시점에 시스템 신뢰스토어에 심습니다. containerd 가 기동되기
# 전 ( 혹은 직후 1회 재시작 )에 신뢰가 서므로, Cluster Autoscaler 가 동적으로 띄운 새 노드에서도
# 'pull-before-trust' x509 윈도우 ( ImagePullBackOff )가 생기지 않습니다.
# certs.d/hosts.toml 은 containerd 2.1+ 에서 무시될 수 있어, 버전 무관하게 동작하는 /etc/pki/ca-trust 에 둡니다.
# harbor-ca-trust DaemonSet 은 안전망 + 인증서 로테이션 경로로 유지됩니다 ( 이미 신뢰된 노드에선 skip ).
# EKS 관리형 노드그룹은 이 MIME 뒤에 자체 nodeadm 부트스트랩을 덧붙여 노드를 정상 조인시킵니다.
set -euo pipefail
cat > /etc/pki/ca-trust/source/anchors/sb-local-ca.crt <<'SBCACERT'
${harbor_ca_pem}
SBCACERT
update-ca-trust
# 이 스크립트가 containerd 기동보다 늦게 실행될 수도 있으므로, 이미 떠 있으면 1회만 재시작해 신뢰를 반영합니다
# ( 실행 중 컨테이너는 shim 이 유지하므로 살아남음 ). 순서와 무관하게 결과적으로 신뢰가 서도록 보장합니다.
systemctl is-active --quiet containerd && systemctl restart containerd || true
# Spegel( 노드 간 이미지 P2P 미러 )의 QUIC 전송이 큰 UDP 버퍼( ~7 MiB )를 요구하는데 노드 기본값( ~208 KiB )이
# 작아 "failed to increase receive buffer size" 경고가 납니다. 부팅 시점에 상향해 P2P 처리량을 확보합니다 ( 영속 + 즉시 적용 ).
cat > /etc/sysctl.d/99-spegel-quic.conf <<'SYSCTL'
net.core.rmem_max = 8388608
net.core.wmem_max = 8388608
SYSCTL
sysctl -p /etc/sysctl.d/99-spegel-quic.conf || true
# Spegel( P2P 미러 )의 '새 노드 블라인드 윈도우' 제거: Spegel 이미지를 부팅 시점에 미리 pull 합니다.
# CA 가 띄운 새 노드는 Spegel 이 떠야 peer 에서 이미지를 받는데, Spegel 자기 이미지 콜드풀이 버스트 때
# 수 분 걸려( 측정 ~3m20s ) 그 사이 앱 파드가 Spegel 을 우회해 Harbor(VPN)로 직행했습니다. 미리 받아 두면
# kubelet 이 IfNotPresent 로 Spegel 을 즉시 기동합니다. systemd oneshot 으로 두어 cloud-init 종료와 무관하게
# containerd 이후 실행·재시도되며, --no-block 으로 노드 부팅(조인)은 절대 막지 않습니다(실패해도 성공 종료).
cat > /etc/systemd/system/spegel-prepull.service <<'UNIT'
[Unit]
Description=Pre-pull Spegel image to remove P2P blind window on new nodes
After=containerd.service
Wants=containerd.service
[Service]
Type=oneshot
ExecStart=/usr/bin/bash -c 'for i in $(seq 1 30); do /usr/bin/ctr -n k8s.io image pull ${spegel_image} && exit 0; sleep 10; done; exit 0'
[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable spegel-prepull.service || true
systemctl start --no-block spegel-prepull.service || true

--//
Content-Type: application/node.eks.aws

---
apiVersion: node.eks.aws/v1alpha1
kind: NodeConfig
spec:
  # Spegel( 노드 간 이미지 P2P 미러 )이 레이어를 peer 에 공유하려면 압축 레이어를 보관해야 하므로 EKS 기본
  # discard_unpacked_layers=true( 디스크 절약 )를 false 로 덮어씁니다.
  #
  # 그러나 containerd 2.1+ 에서 discard_unpacked_layers=false 는 CRI 풀을 'transfer service' 모드로 전환시키고,
  # transfer service 는 registry config_path 를 '단일 디렉터리'로만 해석합니다. EKS 기본 config_path 는 콜론 구분
  # 리스트( '/etc/containerd/certs.d:/etc/docker/certs.d' )라, transfer service 가 이를 존재하지 않는 한 개 디렉터리로
  # 취급해 certs.d 를 아예 안 읽습니다 → Spegel 미러가 무시되고 모든 pull 이 upstream(Harbor)로 직행합니다
  # ( containerd #12415/#12636/#12808, amazon-eks-ami #2494; 2026-06-16 Spegel 서빙 0건의 진짜 원인 ).
  #
  # 해결: use_local_image_pull=true 로 CRI 를 local-pull 모드에 고정합니다( 이 모드는 config_path 를 콜론 리스트로
  # 정상 파싱하고, Spegel 이 의존하는 검증된 경로입니다 ). 추가로 config_path 를 단일 디렉터리로 명시해 어느 모드든
  # 안전하게 둡니다. 관리형 노드그룹은 이 NodeConfig 를 자체 생성 NodeConfig 와 머지하므로 오버라이드할 값만 둡니다.
  containerd:
    config: |
      [plugins.'io.containerd.cri.v1.images']
      discard_unpacked_layers = false
      use_local_image_pull = true

      [plugins.'io.containerd.cri.v1.images'.registry]
      config_path = '/etc/containerd/certs.d'

--//--
