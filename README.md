# global-bridge: Terraform 기반 AWS 인프라 (IaC)

[1. 개요](#1-개요)

[2. 저장소 구조와 설계 원칙](#2-저장소-구조와-설계-원칙)

[3. 시작하기](#3-시작하기)

[4. 명령어 레퍼런스](#4-명령어-레퍼런스)

[5. 운영 절차](#5-운영-절차)

[6. 아키텍처 정책](#6-아키텍처-정책)

[7. 체크리스트](#7-체크리스트)

[8. 라이선스](#8-라이선스)

[9. 환경 설정](#9-환경-설정)

## 1. 개요

1. **global-bridge** 프로젝트의 AWS 인프라 (네트워크, 데이터베이스, 캐시, EKS, 관리 통로, Site-to-Site VPN)를 Terraform 코드로 정의하고, production/staging 두 환경을 동일한 모듈로 재현 가능하게 관리합니다.

2. 전체 인프라는 `make up-all` / `make down-all` 한 줄로 생성·삭제할 수 있으며, 같은 코드로 몇 번을 재배포해도 동일한 상태가 만들어지는 것 (재현성)을 목표로 합니다.

3. 비밀번호·키 같은 민감 정보는 Terraform state와 git에 남기지 않고, Secrets Manager와 SSM Parameter Store로만 흐르도록 설계했습니다.

## 2. 저장소 구조와 설계 원칙

```
cloud-infra-iac/
├── application/      # myApplications (AppRegistry) 앱 — 환경보다 먼저 1회 apply
├── environments/
│   ├── production/   # 운영 환경 (독립 state)
│   └── staging/      # 스테이징 환경 (독립 state)
├── modules/          # vpc · kms · aurora · elasticache · eks · jumphost · vpn · route53-resolver · api-gateway · edge
├── scripts/          # 부트스트랩/터널/검증 스크립트 (Makefile이 호출)
└── Makefile          # 모든 운영 명령의 진입점 — `make help`
```

1. **결정값은 tfvars 한 곳에**: `main.tf`는 모듈 배선 (구조)만 담고, CIDR·인스턴스 사양·VPN 토폴로지 같은 결정값은 전부 `terraform.tfvars`로 주입합니다 (gitignore 대상, 커밋 템플릿은 `terraform.tfvars.example`). 인프라를 바꿀 때 tfvars 한 곳만 보면 됩니다.

2. **환경 간 참조는 remote state로**: 환경 스택은 `application/`이 만든 앱 ARN을 remote state로 자동 참조합니다. 앱을 재생성해도 환경 쪽 수동 갱신 없이 다음 apply에서 새 ARN이 반영됩니다.

3. **비밀은 Terraform을 거치지 않음**: AWS 관리형 통합 (예: Aurora `manage_master_user_password`)을 우선 쓰고, 그 외에는 스크립트가 생성 즉시 Secrets Manager/SSM에 저장합니다. 따라서 state와 git에 평문 비밀이 남지 않습니다.

## 3. 시작하기

> *클론 직후부터 전체 기동까지의 흐름입니다. 단계별 수동 절차가 필요하면 Makefile 상단 주석에 같은 순서로 정리되어 있습니다.*

### 3.1. 도구 설치

Terraform ≥ 1.15, AWS CLI, jq, make, session-manager-plugin이 필요합니다. EKS 내부 스택 (Cilium/ALB/ESO) 설치에는 `helm`, `kubectl`도 필요합니다 (`up-all`이 점프 호스트 터널 경유로 호출).

### 3.2. 자격 증명과 입력 파일 준비

> *커밋되지 않는 입력 (`tfvars` · `secrets/*` — 둘 다 `.example` 템플릿 제공)과 배포 대상 계정만 준비하면 됩니다.*

1. **배포 대상 계정 = `PROFILE` 한 줄**: 계정은 Makefile 상단 `PROFILE` (또는 `make PROFILE=..`)에서 정하며, 전환은 이 값만 바꾸면 끝납니다 (provider/backend/scripts에 자동 주입, 파일 수정 0). 버킷명도 사용자가 정하지 않습니다 — `make state-bucket`이 계정의 기존 버킷을 발견하거나 없으면 생성해 자동으로 씁니다.

2. **tfvars 채우기**: production/staging 각각 `terraform.tfvars.example`을 복사해 `<플레이스홀더>`를 내부 IP 교통 정리표 기준 실값으로 채웁니다 (`aws_profile`·`state_bucket`은 여기 없음 — make가 주입).

3. **secrets/ 입력 채우기**: `secrets/*.example`을 확장자 `.example`을 뗀 이름으로 복사해 값을 채웁니다 (`.example`만 커밋되고 실제 파일은 gitignore). 필요한 것:
   - `wg.prod.env` · `wg.stg.env` — WireGuard 키 (팀 비밀 채널로 수령 — apply 후 `make vpn-{prod,stage}`이 SSM에 등록)
   - `domain.env` — prod 커스텀 도메인 `GB_PROD_DOMAIN` (비우면 기본 `*.cloudfront.net`, stage는 항상 기본)
   - `sb.harbor.env` — 온프렘 연동 시 Harbor robot 자격증명 `NAME` / `SECRET` (이미지 pull용, 비연동이면 불필요)
   - `sb-local-ca.crt` — 사내 로컬 CA 인증서 (내부 TLS 신뢰 앵커 — 클러스터/온프렘 내부 통신 검증용)

```bash
aws configure --profile <PROFILE>               # 최초 1회 (Makefile의 PROFILE과 같은 이름)
aws sts get-caller-identity --profile <PROFILE> # 배포 대상 계정인지 확인

cp environments/production/terraform.tfvars.example environments/production/terraform.tfvars
cp environments/staging/terraform.tfvars.example   environments/staging/terraform.tfvars

for f in secrets/*.example; do cp -n "$f" "${f%.example}"; done   # 복사 후 각 파일에 값 채우기
```

> *S3 state 버킷은 `make state-bucket`으로 만듭니다 (멱등 — `up-all`이 시작 시 자동 호출하므로 보통 생략). backend는 make가 `-backend-config`로 주입하므로 backend.tf를 손댈 필요가 없습니다 ([5.4](#54-s3-백엔드와-계정-전환) 참고).*

### 3.3. 전체 기동 (~55분)

```bash
make up-all
```

CONFIRM을 입력하면 다음 순서로 자동 진행되며, 완료 후 pfSense Peer Endpoint를 `secrets/.wireguard-{env}-eip`의 EIP로 설정하면 터널이 올라옵니다.

1. **application apply**: myApplications 앱을 먼저 만들어, 환경이 앱 ARN을 remote state로 읽을 수 있게 합니다.

2. **환경 병렬 apply**: production/staging은 state가 분리돼 있어 동시에 apply합니다.

3. **k8s 스택 설치 (Cilium → ALB Controller → ESO)**: `cni = "cilium"`이라 EKS는 vpc-cni를 설치하지 않으므로, 이 단계가 Cilium을 올려 노드 네트워킹을 완성합니다 (이 단계 없이는 노드가 NotReady).

4. **부트스트랩 · VPN 키 등록 · 재기동 · EIP 기록**: Valkey AUTH와 논리 DB를 만들고, WG 키를 새 CMK로 등록한 뒤 라우터를 재기동하고 EIP를 기록합니다.

> *k8s 스택 단계가 터널/Helm 문제로 실패하면, 인프라는 그대로 두고 그 단계만 재실행하면 됩니다: `make k8s-stack-prod PHASE=all && make k8s-stack-stage PHASE=all` (포트 공유로 직렬). `PHASE=cilium|alb|eso`로 개별 단계만 재시도할 수도 있습니다.*

### 3.4. 배포 확인

```bash
make plan-prod plan-stage          # 둘 다 "No changes." 면 코드와 인프라가 일치하는 상태입니다
aws ssm describe-instance-information --profile woori-fisa-1k --region ap-northeast-2 \
  --query "InstanceInformationList[].PingStatus"   # 점프 호스트·VPN 라우터 Online 확인
```

1. **VPN 상태**: 라우터에서 `wg show`, `vtysh -c "show ip bgp summary"`로 확인합니다 (SSM send-command 사용). pfSense Endpoint를 설정하기 전에는 BGP가 Active/Idle로 보이는 것이 정상입니다.

2. **k8s 스택**: kubeconfig를 설정한 뒤 ([4](#4-명령어-레퍼런스)의 `kubeconfig-*` — 온프렘/Tailscale 경유 직접 주소) `kubectl get pods -A`에서 `cilium`/`aws-load-balancer-controller`/`external-secrets` 파드가 Running이고 노드가 모두 Ready면 정상입니다.

> *state는 S3 백엔드에 저장돼 협업/CI가 공유합니다. 이미 배포된 인프라가 있는 계정을 새로 클론했다면 `make init`으로 백엔드만 연결하면 되며, 빈 state로 apply해 중복 생성하는 일이 없습니다 ([5.4](#54-s3-백엔드와-계정-전환) 참고).*

## 4. 명령어 레퍼런스

### 4.1. make 타겟

> *`make help`*

| make 타겟 | 설명 |
|---|---|
| `fmt` / `validate` / `init` | 코드 포맷 / 3스택 검증 / 3스택 초기화 |
| `state-bucket` | state 버킷 발견·생성 후 캐시 기록 (멱등 — `up-all`이 자동 호출) |
| `plan-*` / `apply-*` / `destroy-*` | 스택별 plan/apply/destroy (`app`·`prod`·`stage`) |
| `k8s-stack-{prod,stage}` | Cilium / ALB Controller / ESO 설치 (apply 후 — `PHASE=cilium\|alb\|eso\|all`) |
| `bootstrap-{prod,stage}` | Valkey AUTH + 논리 DB/서비스 계정/비밀 생성 (apply 후) |
| `vpn-{prod,stage}` | VPN 셋업 통합 — WG키 SSM 등록 + 라우터 재기동 + EIP 기록 (apply 후 1회, 환경 CMK 필요) |
| `vpn-restart` / `vpn-eip` | 라우터 재기동 (키 반영, EIP 유지) / EIP를 `secrets/.wireguard-{env}-eip`에 기록 |
| `onprem-handoff-{prod,stage}` | 온프렘 산출물 기록 — `secrets/.eks-cp-{env}-dns-ip` (DNS forwarder용) 와 `secrets/.argocd-<env>-cluster.yaml` (ArgoCD에 바로 apply할 cluster Secret). `up-all`에 포함 |
| `kubeconfig-{prod,stage}` | EKS kubeconfig 설정 — 온프렘/Tailscale 경유 직접 주소 (터널 불필요; VPN 끊기면 AWS 콘솔 Session Manager로 break-glass) |
| `up-{prod,stage}` / `down-{prod,stage}` | 단일 env 전체 생성 / 삭제 — down-X는 `application` 스택 보존 ( 공유 ) |
| `up-all` / `down-all` | 전체 ( prod+stage ) 생성 / 삭제 — CONFIRM 입력 필요, 수행 절차는 Makefile 상단 주석 |
| `clean-secrets` | CLI 생성 비밀 (`sb/*`) 강제 삭제 — 전체 재배포 전 1단계 |

> *환경 apply (`apply-stage` / `apply-prod`)에는 **API Gateway origin과 엣지 (CloudFront + S3 + CLOUDFRONT-scope WAF)가 포함**됩니다 — 별도 스택이 아니라 환경 스택에 통합되어 있어, 환경을 올리면 엣지까지 함께 생성됩니다. prod 커스텀 도메인/ACM은 `secrets/domain.env`의 `GB_PROD_DOMAIN` (make가 주입)으로 켭니다 — 비우면 기본 `*.cloudfront.net`, stage는 항상 `*.cloudfront.net`.*

### 4.2. 스크립트

스크립트는 Makefile이 호출하므로 직접 실행은 디버깅할 때만 필요합니다.

| scripts/ | 실행 위치 | 역할 |
|---|---|---|
| `run-db-bootstrap.sh` | 로컬 | terraform output과 점프 호스트를 자동 조회한 뒤, SSM 원격 실행으로 논리 DB·서비스 계정을 만들고 비밀을 저장합니다 |
| `bootstrap-redis.sh` | 로컬 | Valkey AUTH 토큰을 무중단 (ROTATE→SET)으로 설정하고 `sb/{env}/redis/auth`에 저장합니다 — AWS API만 사용해 VPC 접근이 필요 없습니다 |
| `bootstrap-db.sh` | 점프 호스트 | `run-db-bootstrap.sh`가 원격 실행하는 로직의 수동판입니다 (SSM 세션 디버깅용) |
| `register-vpn-keys.sh` | 로컬 | `secrets/wg.{env}.env`의 키를 SSM SecureString (환경 CMK 암호화)으로 등록합니다 |
| `onprem-handoff.sh` | 로컬 | terraform output을 읽어 `secrets/.eks-cp-{env}-dns-ip` (pfSense DNS forwarder 안내 주석 포함, 환경별 파일) 와 `secrets/.argocd-<env>-cluster.yaml` (온프렘 ArgoCD devops-system NS에 바로 apply할 cluster Secret, 600 권한) 를 기록합니다 |
| `install-k8s-stack.sh` | 로컬 | 점프 호스트 SSM 터널 경유로 Cilium (CNI) · AWS Load Balancer Controller · External Secrets Operator를 Helm으로 설치하고, ArgoCD 배포 네임스페이스를 사전 생성합니다 — 클러스터 안엔 사전 설치물이 없어 로컬 `helm`/`kubectl`만 필요합니다 (`<prod\|stage> [cilium\|alb\|eso\|ns\|all]`) |
| `create-state-bucket.sh` | 로컬 | 계정의 state 버킷을 발견하거나 없으면 생성하고 (versioning·SSE-S3·public 차단·HTTPS 강제), 그 이름을 캐시에 기록합니다 — make가 자동 호출 ([5.4](#54-s3-백엔드와-계정-전환) 참고) |

모든 부트스트랩은 멱등입니다 — 재실행하면 비밀번호가 재발급되고 DB 계정 (`ALTER USER`)과 비밀이 함께 갱신되어 항상 일치합니다.

## 5. 운영 절차

### 5.1. 전체 재배포

```bash
make down-all     # 비밀 (sb/*)·SSM 파라미터 정리 → 환경 병렬 destroy → application
make up-all
# pfSense Peer Endpoint를 새 EIP로 갱신
```

1. **비밀까지 함께 정리**: `down-all`은 terraform destroy가 지우지 못하는 CLI 생성 비밀과 SSM 파라미터까지 정리합니다. 이를 생략하면 재배포 시 비밀 생성이 충돌하고, 옛 CMK 삭제 대기와 맞물려 복호화할 수 없는 고아 비밀이 남습니다.

2. **VPN 키 원본은 로컬**: 키 원본은 로컬 `secrets/wg.{env}.env`이며, `up-all`이 새 CMK로 재등록과 라우터 재기동까지 수행합니다. pfSense Endpoint를 갱신하기 전까지 터널이 미수립 상태인 것은 정상입니다.

3. **k8s 스택은 apply 직후 함께**: `up-all`은 환경 apply 직후 k8s 스택 (Cilium/ALB/ESO)까지 설치합니다 — `cni = "cilium"`이라 이 단계가 없으면 노드가 NotReady로 남습니다. 이 단계만 따로 돌리려면 `make k8s-stack-{prod,stage} PHASE=all` ([4](#4-명령어-레퍼런스) 참고).

4. **앱 LB는 destroy 전에 회수**: 클러스터에 앱 Ingress / LoadBalancer 타입 Service가 떠 있으면 ALB Controller가 만든 ALB/NLB를 Terraform이 모릅니다. `down-all` 전에 `kubectl delete ingress,svc --all -A`로 먼저 회수해야 ALB·관련 SG가 남아 VPC 삭제를 막는 일을 피합니다 (Cilium 보조 ENI는 `DeleteOnTermination=true`라 노드 종료 시 자동 정리).

### 5.2. 부분 작업

환경 하나만 다룰 때는 `destroy-*` / `apply-*` / `bootstrap-*` 개별 타겟을 사용합니다.

### 5.3. NAT AZ 장애 복구 (Single 전략 환경)

tfvars의 `vpc_config.single_nat_az`를 다른 public AZ로 바꿔 apply하면 NAT가 재배치됩니다 (복구 약 5분). per_az 전략 환경은 AZ별로 NAT가 분산되어 있어 복구 절차가 필요 없습니다.

### 5.4. S3 백엔드와 계정 전환

> *state는 S3 백엔드에 저장돼 협업/CI가 공유합니다. 계정 전환은 `PROFILE` 한 줄로 끝나며, 버킷·backend.tf·tfvars를 손댈 일이 없습니다.*

state 버킷은 Terraform이 관리하지 않습니다 (버킷을 만들 state를 둘 곳이 없는 닭-달걀 문제 회피). 대신 `make state-bucket`이 만들며, 동작은 세 가지입니다.

- **버킷명은 자동**: `make state-bucket` (create-state-bucket.sh)이 계정의 기존 `global-bridge-tfstate*` 버킷을 발견해 재사용하거나, 없으면 `global-bridge-tfstate-<계정ID>`로 생성하고, 그 이름을 캐시 `secrets/.state-bucket-<profile>` (gitignore)에 기록합니다. make의 `STATE_BUCKET`은 그 캐시를 읽습니다 (cat — aws 호출 없음).

- **backend 주입**: backend.tf엔 스택별 `key`만 있고, bucket/region/profile은 make가 `terraform init -backend-config`로 주입합니다 (backend 블록은 변수를 못 쓰므로). 즉 계정을 바꿔도 backend.tf·tfvars 수정이 없습니다.

- **멱등**: `make state-bucket`은 발견 시 재사용, 없을 때만 생성합니다. `up-all`이 시작 시 자동 호출하므로 보통 직접 실행할 일은 없습니다 (처음·계정 전환 시 캐시를 채우려면 그게 먼저 돌아야 함).

> ⚠️ state 버킷은 영속 리소스라 `down-all`도 지우지 않습니다. 같은 계정 재배포·협업·CI는 그냥 `make ...` (필요 시 `make init`)이면 됩니다.

**계정 전환 (예: 검증 `woori-fisa-1k` → 실배포 FISA) — `PROFILE` 하나만:**

```bash
make up-all PROFILE=<FISA-프로필>
#  → state-bucket이 그 계정의 기존 버킷을 발견하거나 없으면 global-bridge-tfstate-<계정ID>로 생성하고
#    캐시에 기록 → init이 -reconfigure로 그 백엔드를 가리킨다 (state 이전 아님 — 새 계정은 빈 상태).
#  state-bucket만 따로 채우려면: make state-bucket PROFILE=..
```

3개 스택은 같은 버킷 안에서 key로 구분됩니다 (`application/`·`production/`·`staging/`). 버킷은 versioning·SSE·public 차단·HTTPS 강제가 적용되며, 잠금은 S3 네이티브 락 (`use_lockfile`)을 씁니다.

## 6. 아키텍처 정책

### 6.1. 네트워크

사용자 트래픽은 CloudFront → API Gateway → 내부 ALB 경로로 들어오며, IGW만 타고 NAT를 지나지 않습니다. NAT는 private 구역의 아웃바운드 (패키지·이미지 풀) 전용입니다.

#### 6.1.1. 구역 모델

| 구역 | 인터넷 | 용도 |
|---|---|---|
| public | 인/아웃 (IGW) | VPN 라우터, NAT GW (인그레스용 ALB는 내부 전용) |
| private | 아웃바운드만 (NAT) | EKS 노드/파드 |
| db | 격리 | Aurora, Valkey |
| mgmt | 격리 | 점프 호스트 (SSM 엔드포인트 경유) |

#### 6.1.2. 공개 진입 경로 (엣지)

인그레스용 public ALB는 없습니다. ALB는 내부 전용이고, 사용자 요청은 다음 경로로 백엔드 파드에 닿습니다.

```
CloudFront ┬ /*      → 비공개 S3 (OAC)                          [SPA 정적 호스팅]
           └ /api/*  → API Gateway (HTTP API, X-Origin-Verify 주입)
                        → VPC Link → 내부 ALB (경로 라우팅)
                          → /api/v1/<서비스>/* → EKS 파드 (TargetGroupBinding)
```

방어는 2겹입니다. ① CloudFront 앞단 **CLOUDFRONT-scope WAF** (`modules/edge` — AWS 관리형 IpReputation·Common·KnownBadInputs + IP rate-limit), ② 내부 ALB의 **regional WAF** (`modules/api-gateway` — origin-lock: CloudFront가 넣는 `X-Origin-Verify` 헤더가 없으면 차단해 CloudFront 우회를 막음). 백엔드는 `/api/v1`을 네이티브로 노출하므로 CloudFront는 경로를 그대로 전달합니다.

#### 6.1.3. EKS API 접근 (private-only)

EKS API는 **private-only**입니다. 평소 접근은 `make kubeconfig-*` (온프렘 연동 시 직접 주소로 kubeconfig 설정)이고, VPN/온프렘이 끊긴 비상시엔 **AWS 콘솔 → Systems Manager → Session Manager로 점프 호스트 접속** 후 kubectl을 break-glass로 씁니다 (CLI 터널 스크립트는 두지 않음).

#### 6.1.4. 클러스터 내부 스택 (Cilium / ALB / ESO)

클러스터 내부 스택은 `scripts/install-k8s-stack.sh`로 Helm 설치합니다 (개발 스택과 동일하게 Cilium 채용).

| 구성요소 | 역할 | 비고 |
|---|---|---|
| Cilium 1.18.9 | CNI · kube-proxy 대체 · Hubble | ENI 모드 (파드가 VPC IP → ALB `target-type=ip` 직결) |
| AWS Load Balancer Controller v3.4.0 | Ingress → ALB 자동 프로비저닝 | IRSA로 `elasticloadbalancing` 권한 (서브넷은 `kubernetes.io/role/*` 태그로 자동 발견). IAM 정책은 컨트롤러 버전과 lockstep 유지 |
| External Secrets Operator v2.6.0 | Secrets Manager → k8s Secret 동기화 | IRSA가 `sb/{env}/*` + 환경 CMK `kms:Decrypt`/`DescribeKey`로 범위 제한 |

> 차트 버전은 `scripts/install-k8s-stack.sh`에 고정되어 있습니다 (재현성 · IAM 정책 버전 스큐 방지). 올릴 땐 ALB IAM 정책 (`modules/eks/policies/`) 도 함께 갱신할 것.

#### 6.1.5. 그린필드 부트스트랩 (vpc-cni → Cilium 교체)

EKS API가 private-only라 Terraform은 클러스터에 접근해 Cilium을 직접 깔 수 없습니다. 이 제약을 다음 순서로 우회합니다.

1. **EKS 기본 애드온으로 노드 Ready**: `cni = "cilium"`이어도 클러스터는 `bootstrap_self_managed_addons` 기본값 (true)으로 만들어, EKS가 기본 self-managed vpc-cni/kube-proxy를 깔아 노드를 Ready로 올립니다. 덕분에 terraform apply가 무인으로 완료됩니다 (Terraform은 vpc-cni/kube-proxy를 관리 애드온으로 채택만 안 함).

2. **Cilium으로 교체**: 이어서 `install-k8s-stack.sh`가 점프 호스트 터널로 그 기본 vpc-cni/kube-proxy DaemonSet을 지우고 Cilium으로 교체합니다.

3. **데드락 회피가 핵심**: 이 순서라 노드가 NotReady에 머물러 매니지드 노드그룹 생성이 데드락되는 일이 없습니다 (`bootstrap_self_managed_addons = false`로 두면 정확히 그 데드락이 발생).

#### 6.1.6. 온프렘 연동 (선택 — `onprem_integration.enabled`)

온프렘 ArgoCD/Harbor와 붙일 때 private/db 대역은 온프렘에 **광고·노출하지 않고** 두 경로만 비대칭으로 엽니다 (`enabled = false`면 아래 전부 미생성 — 기존 동작과 동일). 설정은 환경 tfvars의 `onprem_integration` 객체 하나로 주입합니다.

- **흐름 1 (온프렘 ArgoCD → EKS API)**: 컨트롤플레인 ENI를 **mgmt 서브넷**에 두고 (`control_plane_subnet_ids`), Route53 Resolver **inbound**로 온프렘이 private 엔드포인트 호스트명을 해석합니다. EKS SG는 pfSense NAT IP (`argocd_source_cidrs`)만 443 허용합니다. 인증은 `argocd-iam` 모듈이 만든 **전용 IAM User** (`sb-<env>-argocd`, 상시 AWS 권한 0) 를 access entry에 매핑하고, RBAC는 **네임스페이스 한정 Edit** (`argocd_namespaces`) 으로 좁힙니다 — principal ARN은 Terraform이 생성·배선하므로 tfvars에 직접 적지 않습니다.
- **흐름 2 (EKS 노드 → 온프렘 Harbor)**: private RT엔 Harbor `/32`만 라우터로 보내고 (`harbor_destinations`), 라우터가 터널 IP로 **SNAT (은닉)** 해 온프렘엔 단일 소스로만 보입니다 — private는 광고하지 않습니다. Route53 Resolver **outbound**로 Harbor 도메인을 온프렘 DNS로 포워딩 (`dns_forward_domains`). (노드 containerd의 사설 CA 신뢰는 노드 측 설정.)
- **VPN 라우터**: 인터넷 경유 터널이라 WG `MTU = 1420` + MSS clamp (점보프레임 8921이면 대용량 이미지 pull이 reset됨). forward SG는 흐름별 최소 포트만 — private→Harbor TCP 443, mgmt→DNS UDP 53.
- **배포 네임스페이스**: 네임스페이스 한정 Edit은 네임스페이스를 직접 생성하지 못하므로 (cluster-scoped), `install-k8s-stack.sh`의 `all`/`ns` phase가 `argocd_namespaces`를 사전 생성합니다.
- **핸드오프**: `up-all` (및 `onprem-handoff-*`) 이 두 산출물을 환경별로 기록합니다 — `secrets/.eks-cp-{env}-dns-ip` (pfSense conditional forwarder용 resolver inbound IP) 와 `secrets/.argocd-<env>-cluster.yaml` (ArgoCD에 바로 apply할 완성본 cluster Secret). 온프렘 ArgoCD (`devops-system` NS) 에 `kubectl apply` 하면 등록됩니다 (IAM이 네임스페이스 한정이라 Secret의 `namespaces`로 ArgoCD 관리 범위도 일치시킴).

### 6.2. 비밀/설정

| 종류 | 저장소 | 예시 |
|---|---|---|
| 로테이션이 필요한 비밀 | Secrets Manager | Aurora 마스터 암호 (AWS 관리형), Valkey AUTH 토큰 |
| 정적 비밀 | SSM Parameter Store (SecureString) | WG 키, 서드파티 API 키 |
| 비밀이 아닌 설정값 | SSM Parameter Store (String) | API URL, 기능 플래그 |
| 암호화 키 | KMS — 환경당 CMK 1개 (`alias/sb-{env}-cmk`) | Aurora/Valkey/EKS/위 저장소의 암호화 |

EKS 안에서의 주입은 External Secrets Operator (`ClusterSecretStore: aws-secrets-manager`)로 일관되게 적용합니다 — IRSA가 해당 환경 비밀 (`sb/{env}/*`)만 읽도록 제한됩니다.

### 6.3. 관측성

EKS 컨트롤플레인 감사 로그 (api, audit, authenticator)와 VPC Flow Logs를 CloudWatch로 보내며, 두 로그 그룹 모두 환경 CMK로 암호화합니다.

## 7. 체크리스트

### 7.1. 운영 전환 (실서비스 오픈 전)

- [x] Aurora: prod tfvars에서 `deletion_protection = true`, `skip_final_snapshot = false` 활성
- [x] Aurora prod: `serverless_min_acu = 1`로 상향 (콜드스타트 완화)
- [x] EKS API private-only (`eks_config.endpoint_public_access = false`)
- [x] EKS 노드: LT 태그 변경이 노드 롤링 교체를 유발함을 인지 (Name 태그는 고정값이라 평상시 롤링 없음 — 현상 유지)
- [x] state를 S3 백엔드로 전환 (버킷 `global-bridge-tfstate-*`, 네이티브 락 — 5.4 참고)
- [x] CloudTrail: 멀티리전 trail (SSE-KMS S3 + log_file_validation) — `modules/cloudtrail`, stage 적용·콘솔 trail 교체 완료 (계정별 org 트레일 있으면 `enable_cloudtrail=false`)
- [x] 내부 ALB access_logs: 전용 S3 로그 버킷 + `access_logs` 블록 (`modules/api-gateway`) — stage 적용
- [x] WAF logging_configuration: CloudFront·ALB 두 web ACL에 CW Logs 연결 (`modules/edge`·`modules/api-gateway`) — stage 적용
- [x] Aurora CW 로그 수출: `enabled_cloudwatch_logs_exports` + `server_audit` 파라미터그룹 (`modules/aurora`) — stage 적용 (audit는 재부팅 1회 필요할 수 있음)

### 7.2. Repo public 전환 전

- [x] 전 히스토리 비밀/식별자 스캔 — 계정 ID/ARN/비밀 클린 (orphan 재작성으로 옛 커밋 잔재 제거)
- [x] 계정 ID/ARN 하드코딩 금지 — 코드는 `data.aws_caller_identity` 동적 참조
- [x] 내부 CIDR 지문 제거 (VPN userdata 디버그 grep 일반화)
- [x] 온프렘 연동 주석의 예시값 제네릭화 (Harbor IP·도메인·pfSense NAT → 제네릭, 실값은 gitignored tfvars/secrets)
- [x] `.gitignore`에 `*.env` 안전망 추가 (secrets/ 단일 규칙 의존 해소)
- [x] LICENSE 추가 (MIT)

### 7.3. 팀 조율 필요

- [x] Cognito `custom:public_id` 사용자 쓰기 차단 — app client `write_attributes`를 표준 속성만 허용 (`custom:public_id` 제외). stage 적용·검증 완료 (프론트는 Cognito SDK 미사용이라 무영향, member는 Admin API로 set). 미차단 시 SRP 경로 `UpdateUserAttributes`로 public_id 위조 → 수평적 권한 상승
- [ ] (선택·defense-in-depth) 백엔드가 mutable claim(`public_id`)을 단독 신원으로 신뢰하는 구조 검토 — `sub`(불변) 기반 식별 + member DB의 sub→public_id 매핑을 권위 소스로 (백엔드 아키텍처, 팀 판단)

## 8. 라이선스

이 저장소는 [MIT License](LICENSE)로 배포됩니다.

## 9. 환경 설정

| 항목 | 값 |
|---|---|
| 리전 | ap-northeast-2 (서울) — `terraform.tfvars` |
| AWS 프로필 | Makefile `PROFILE` → `TF_VAR_aws_profile` 주입 (기본 `woori-fisa-1k`, 계정 전환 시 이 한 줄만) |
| 상태 저장 | S3 백엔드 — 버킷 `global-bridge-tfstate-*`, 네이티브 락 ([5.4](#54-s3-백엔드와-계정-전환) 참고) |
| 공통 태그 | `Environment` / `ManagedBy` / `Project` / `awsApplication` (provider `default_tags`) |
