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
├── modules/          # vpc · kms · aurora · elasticache · eks · jumphost · vpn
├── scripts/          # 부트스트랩/터널 스크립트 (Makefile이 호출)
└── Makefile          # 모든 운영 명령의 진입점 — `make help`
```

1. `main.tf`는 구조 (모듈 배선)만 담습니다. CIDR·인스턴스 사양·VPN 토폴로지 같은 **모든 결정값은 `terraform.tfvars`로 주입**되며 (gitignore 대상), 커밋되는 템플릿은 `terraform.tfvars.example`입니다. 인프라 변경 시 tfvars 한 곳만 보면 됩니다.

2. 환경 스택은 `application/`이 만든 앱 ARN을 **remote state로 자동 참조**합니다. 앱을 재생성해도 환경 쪽 수동 갱신 없이 다음 apply에서 새 ARN이 반영됩니다.

3. 비밀은 Terraform을 거치지 않습니다. AWS 관리형 통합 (예: Aurora `manage_master_user_password`)을 우선 사용하고, 그 외에는 스크립트가 생성 즉시 Secrets Manager/SSM에 저장합니다.

## 3. 시작하기

> *클론 직후부터 전체 기동까지의 흐름입니다. 단계별 수동 절차가 필요하면 Makefile 상단 주석에 같은 순서로 정리되어 있습니다.*

### 3.1. 도구 설치

Terraform ≥ 1.15, AWS CLI, jq, make, session-manager-plugin이 필요합니다.

### 3.2. 자격 증명과 입력 파일 준비

배포 계정 프로필을 등록하고, 커밋되지 않는 입력 파일 두 종류 (tfvars, WG 키)를 준비합니다.

```bash
aws configure --profile woori-fisa-1k                  # 최초 1회
aws sts get-caller-identity --profile woori-fisa-1k    # 배포 대상 계정인지 확인

cp environments/production/terraform.tfvars.example environments/production/terraform.tfvars
cp environments/staging/terraform.tfvars.example   environments/staging/terraform.tfvars
# <플레이스홀더>를 내부 IP 교통 정리표 기준 실값으로 채웁니다

# secrets/wg.prod.env, secrets/wg.stg.env  ← WG 키 파일 배치 (팀 비밀 채널로 수령)
```

### 3.3. 전체 기동 (~40분)

```bash
make up-all
```

CONFIRM을 입력하면 app → 환경 병렬 apply → 부트스트랩 → VPN 키 등록·재기동 → EIP 기록까지 자동으로 진행됩니다. 완료 후 pfSense Peer Endpoint를 `secrets/eip.env`의 EIP로 설정하면 터널이 올라옵니다.

### 3.4. 배포 확인

```bash
make plan-prod plan-stage          # 둘 다 "No changes." 면 코드와 인프라가 일치하는 상태입니다
aws ssm describe-instance-information --profile woori-fisa-1k --region ap-northeast-2 \
  --query "InstanceInformationList[].PingStatus"   # 점프호스트·VPN 라우터 Online 확인
```

VPN 상태는 라우터에서 `wg show`, `vtysh -c "show ip bgp summary"`로 확인합니다 (SSM send-command 사용). pfSense Endpoint를 설정하기 전에는 BGP가 Active/Idle로 보이는 것이 정상입니다.

> *state는 로컬 파일입니다. 이미 배포된 인프라가 있는 상태에서 새로 클론했다면 apply하지 마세요 — state 없이 apply하면 중복 생성과 충돌이 발생합니다 (S3 백엔드 전환 전까지의 제약).*

## 4. 명령어 레퍼런스

| make 타겟 | 설명 |
|---|---|
| `up-all` / `down-all` | 전체 생성 / 전체 삭제 — CONFIRM 입력 필요, 수행 절차는 Makefile 상단 주석 |
| `plan-*` / `apply-*` / `destroy-*` | 스택별 plan/apply/destroy (`app`·`prod`·`stage`) |
| `bootstrap-{prod,stage}` | Redis AUTH + 논리 DB/서비스 계정/비밀 생성 (apply 후) |
| `vpn-keys-{prod,stage}` | WG 키를 SSM에 등록 — apply 후에만 가능 (환경 CMK 필요) |
| `vpn-restart` / `vpn-eip` | 라우터 재기동 (키 반영, EIP 유지) / EIP를 `secrets/eip.env`에 기록 |
| `kubectl-tunnel-{prod,stage}` | private-only EKS API로 kubectl 터널 (점프호스트 경유) |
| `fmt` / `validate` / `init` | 코드 포맷 / 3스택 검증 / 3스택 초기화 |

스크립트는 Makefile이 호출하므로 직접 실행은 디버깅할 때만 필요합니다.

| scripts/ | 실행 위치 | 역할 |
|---|---|---|
| `run-db-bootstrap.sh` | 로컬 | terraform output과 점프호스트를 자동 조회한 뒤, SSM 원격 실행으로 논리 DB·서비스 계정을 만들고 비밀을 저장합니다 |
| `bootstrap-redis.sh` | 로컬 | Valkey AUTH 토큰을 무중단 (ROTATE→SET)으로 설정하고 `sb/{env}/redis/auth`에 저장합니다 — AWS API만 사용해 VPC 접근이 필요 없습니다 |
| `bootstrap-db.sh` | 점프호스트 | `run-db-bootstrap.sh`가 원격 실행하는 로직의 수동판입니다 (SSM 세션 디버깅용) |
| `register-vpn-keys.sh` | 로컬 | `secrets/wg.{env}.env`의 키를 SSM SecureString (환경 CMK 암호화)으로 등록합니다 |
| `kubectl-tunnel.sh` | 로컬 | 점프호스트 SSM 포트포워딩으로 EKS API 터널을 열고, kubeconfig (`tls-server-name`) 설정 방법을 안내합니다 |

모든 부트스트랩은 멱등입니다 — 재실행하면 비밀번호가 재발급되고 DB 계정 (`ALTER USER`)과 비밀이 함께 갱신되어 항상 일치합니다.

## 5. 운영 절차

### 5.1. 전체 재배포

```bash
make down-all     # 비밀 (sb/*)·SSM 파라미터 정리 → 환경 병렬 destroy → application
make up-all
# pfSense Peer Endpoint를 새 EIP로 갱신
```

1. `down-all`은 terraform destroy가 지우지 못하는 CLI 생성 비밀과 SSM 파라미터까지 정리합니다. 이를 생략하면 재배포 시 비밀 생성이 충돌하고, 옛 CMK 삭제 대기와 맞물려 복호화할 수 없는 고아 비밀이 남습니다.

2. VPN 키의 원본은 로컬 `secrets/wg.{env}.env`입니다. `up-all`이 새 CMK로 재등록과 라우터 재기동까지 수행하며, pfSense Endpoint를 갱신하기 전까지 터널이 미수립 상태인 것은 정상입니다.

### 5.2. 부분 작업

환경 하나만 다룰 때는 `destroy-*` / `apply-*` / `bootstrap-*` 개별 타겟을 사용합니다.

### 5.3. NAT AZ 장애 복구 (Single 전략 환경)

tfvars의 `vpc_config.single_nat_az`를 다른 public AZ로 바꿔 apply하면 NAT가 재배치됩니다 (복구 약 5분). per_az 전략 환경은 AZ별로 NAT가 분산되어 있어 복구 절차가 필요 없습니다.

## 6. 아키텍처 정책

### 6.1. 네트워크

사용자 트래픽 (WAF + CloudFront + ALB)은 IGW 경로만 타며 NAT를 지나지 않습니다. NAT는 private 구역의 아웃바운드 (패키지·이미지 풀) 전용입니다.

| 구역 | 인터넷 | 용도 |
|---|---|---|
| public | 인/아웃 (IGW) | DMZ — ALB, VPN 라우터 |
| private | 아웃바운드만 (NAT) | EKS 노드/파드 |
| db | 격리 | Aurora, Valkey |
| mgmt | 격리 | 점프 호스트 (SSM 엔드포인트 경유) |

EKS API는 **private-only**입니다. 접근 경로는 점프호스트 SSM 포트포워딩 (`make kubectl-tunnel-*`) 하나로 통제됩니다.

### 6.2. 비밀/설정

| 종류 | 저장소 | 예시 |
|---|---|---|
| 로테이션이 필요한 비밀 | Secrets Manager | Aurora 마스터 암호 (AWS 관리형), Redis AUTH 토큰 |
| 정적 비밀 | SSM Parameter Store (SecureString) | WG 키, 서드파티 API 키 |
| 비밀이 아닌 설정값 | SSM Parameter Store (String) | API URL, 기능 플래그 |
| 암호화 키 | KMS — 환경당 CMK 1개 (`alias/sb-{env}-cmk`) | Aurora/Valkey/EKS/위 저장소의 암호화 |

EKS 안에서의 주입은 External Secrets Operator로 일관되게 적용할 예정입니다.

### 6.3. 관측성

EKS 컨트롤플레인 감사 로그 (api, audit, authenticator)와 VPC Flow Logs를 CloudWatch로 보내며, 두 로그 그룹 모두 환경 CMK로 암호화합니다.

## 7. 체크리스트

### 7.1. 운영 전환 (실서비스 오픈 전)

- [ ] Aurora: tfvars에서 `deletion_protection = true`, `skip_final_snapshot = false`로 활성 (모듈 배선 완료, 기본은 비활성)
- [ ] Aurora prod: `serverless_min_acu` 상향 검토 (현재 0.5 — 콜드 응답 지연 가능)
- [x] EKS API private-only (`eks_config.endpoint_public_access = false`)
- [x] EKS 노드: LT 태그 변경이 노드 롤링 교체를 유발함을 인지 (Name 태그는 고정값이라 평상시 롤링 없음 — 현상 유지)
- [ ] state를 S3 백엔드로 전환 (`backend.tf` 주석 참고)
- [ ] AWS Budgets 알림 설정 (크레딧 소진 추적)

### 7.2. 리포 public 전환 전

- [x] 전 히스토리 비밀/식별자 스캔 — 계정 ID/ARN/비밀 클린 (orphan 재작성으로 옛 커밋 잔재 제거)
- [x] 계정 ID/ARN 하드코딩 금지 — 코드는 `data.aws_caller_identity` 동적 참조
- [x] 내부 CIDR 지문 제거 (VPN userdata 디버그 grep 일반화)
- [x] `.gitignore`에 `*.env` 안전망 추가 (secrets/ 단일 규칙 의존 해소)
- [x] LICENSE 추가 (MIT)
- [ ] (선택) 프로필명 `woori-fisa-1k` 노출 — 조직 맥락이나 비밀 아님, 유지 결정
- [ ] (선택) 커밋 author 실명/이메일 노출 — 유지 결정

## 8. 라이선스

이 저장소는 [MIT License](LICENSE)로 배포됩니다.

## 9. 환경 설정

| 항목 | 값 |
|---|---|
| 리전 | ap-northeast-2 (서울) — `terraform.tfvars` |
| AWS 프로필 | `woori-fisa-1k` (`aws_profile` 변수) |
| 상태 저장 | 로컬 (S3 백엔드 전환 시 각 스택 `backend.tf` 참고) |
| 공통 태그 | `Environment` / `ManagedBy` / `Project` / `awsApplication` (provider `default_tags`) |
