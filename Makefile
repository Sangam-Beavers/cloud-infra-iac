# ---------------------------------------------------------------------------
# global-bridge 인프라 운영 명령 모음 — `make help`로 타겟 확인
#
# ── 계정 전환은 PROFILE 한 줄만 (또는 make PROFILE=..) ── REGION은 tfvars의 aws_region과 같게 유지.
#   STATE_BUCKET은 자동이다 (state-bucket이 계정의 버킷을 발견·생성→캐시, make가 읽음). 파일 수정 없이 끝난다.
#   PROFILE 미설정 시 terraform이 에러 (개인계정 폴백 차단).
#
# ── `make up-all` 이 자동 수행하는 전 과정 (수동으로 할 땐 이 순서 그대로) ──
#   0. (선행) environments/*/terraform.tfvars 준비 (example 참고)
#      + secrets/wg.{prod,stg}.env WG 키 파일 배치
#      + (계정 전환만) PROFILE을 새 계정으로 — up-all이 make state-bucket으로 버킷 발견·생성 (멱등)
#   1. make state-bucket → cd application && terraform init && terraform apply
#        # myApplications 앱 — 환경이 remote state로 ARN을 읽으므로 반드시 먼저
#   2. cd environments/production && terraform init && terraform apply
#      cd environments/staging    && terraform init && terraform apply
#        # 두 환경은 state가 분리돼 있어 병렬 실행 가능 (~20분)
#   3. make bootstrap-prod bootstrap-stage
#        # Redis AUTH (ROTATE→SET) + 논리 DB/서비스 계정/비밀 — 점프호스트 SSM 원격 실행
#   4. make vpn-keys-prod vpn-keys-stage
#        # WG 키를 SSM SecureString으로 등록 — apply 후에만 가능 (CMK 필요)
#   5. make vpn-restart
#        # 라우터 재기동으로 키 반영 (ASG 교체, EIP 유지)
#   6. make vpn-eip
#        # 고정 EIP를 secrets/eip.env 에 기록
#   7. pfSense Peer Endpoint를 secrets/eip.env 의 EIP로 갱신
#
# ── `make down-all` 이 자동 수행하는 전 과정 ──
#   1. Secrets Manager sb/* 강제 삭제   # destroy가 못 지우는 CLI 생성 비밀 (충돌/고아 방지)
#   2. 환경 2개 terraform destroy (병렬)
#   3. application terraform destroy
#   4. SSM /sb/* 파라미터 삭제          # 완전 제로 — VPN 키 원본은 로컬 secrets/ 에 보존
# ---------------------------------------------------------------------------
# ── 계정 전환은 PROFILE 한 줄만 (또는 make PROFILE=..) ──
#   PROFILE = ~/.aws/config 프로필 = 배포 대상 계정 (default 없음 → 미설정 시 terraform 에러로 개인계정 폴백 차단)
#   REGION  = 리전 (tfvars의 aws_region과 같게 유지)
# 주의: 값 줄에 인라인 주석 금지 — Make는 # 앞 공백을 값에 포함한다 (프로필명 오염).
PROFILE ?= woori-fisa-1k
REGION  ?= ap-northeast-2

# STATE_BUCKET은 사용자가 정하지 않는다. create-state-bucket.sh가 계정의 기존 버킷을 발견(or 생성)해
# 캐시(secrets/.state-bucket-<profile>)에 기록하고, make는 그 캐시를 읽는다 (cat — aws 호출 없음).
# up-all/state-bucket이 캐시를 채우므로, 처음/계정전환 시엔 그게 먼저 돌아야 한다.
STATE_BUCKET = $(shell cat secrets/.state-bucket-$(PROFILE) 2>/dev/null)

# terraform provider/remote_state는 TF_VAR_로 자동 주입. REGION은 tfvars의 aws_region이 소스라
# export하지 않고(우선순위), 백엔드 region만 -backend-config로 맞춘다. PROFILE/REGION은 스크립트가 env로 상속.
# TF_VAR_state_bucket은 캐시를 늦게 읽도록 재귀(=) — state-bucket이 채운 뒤 init이 읽는다.
export TF_VAR_aws_profile  := $(PROFILE)
export TF_VAR_state_bucket  = $(STATE_BUCKET)
export PROFILE
export REGION

# backend 블록은 변수를 못 쓰므로 init 때 -backend-config로 주입한다 (key는 각 backend.tf).
# -reconfigure: 계정/버킷을 바꿔 init하면 새 백엔드를 가리킨다 (state 이전 아님 — 새 계정은 빈 상태).
TF_INIT := terraform init -input=false -reconfigure \
  -backend-config=bucket=$(STATE_BUCKET) \
  -backend-config=region=$(REGION) \
  -backend-config=profile=$(PROFILE)

PROD  := environments/production
STAGE := environments/staging

.DEFAULT_GOAL := help
.PHONY: help fmt validate state-bucket init plan-app apply-app plan-prod apply-prod destroy-prod \
        plan-stage apply-stage destroy-stage bootstrap-prod bootstrap-stage clean-secrets \
        vpn-keys-prod vpn-keys-stage vpn-restart vpn-eip kubectl-tunnel-prod kubectl-tunnel-stage \
        k8s-stack-prod k8s-stack-stage up-all down-all

help: ## 타겟 목록 출력
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---------- 공통 ----------
fmt: ## 전체 Terraform 코드 포맷
	terraform fmt -recursive

validate: ## 3개 스택 (application/prod/stage) validate
	cd application && terraform validate
	cd $(PROD) && terraform validate
	cd $(STAGE) && terraform validate

state-bucket: ## state 버킷 발견·생성 후 캐시 기록 (멱등 — up-all이 자동 호출)
	./scripts/create-state-bucket.sh

init: ## 3개 스택 init (현재 PROFILE/STATE_BUCKET 백엔드로 — 계정 전환 후 1회)
	cd application && $(TF_INIT)
	cd $(PROD) && $(TF_INIT)
	cd $(STAGE) && $(TF_INIT)

# ---------- application (myApplications 앱 — 환경보다 먼저 1회) ----------
plan-app: ## application 스택 plan
	cd application && $(TF_INIT) >/dev/null && terraform plan

apply-app: ## application 스택 apply
	cd application && $(TF_INIT) >/dev/null && terraform apply

# ---------- production ----------
plan-prod: ## production plan
	cd $(PROD) && $(TF_INIT) >/dev/null && terraform plan

apply-prod: ## production apply
	cd $(PROD) && $(TF_INIT) >/dev/null && terraform apply

destroy-prod: ## production 전체 삭제 (확인 입력 필요)
	@printf "⚠️  production 전체를 삭제합니다. 계속하려면 'prod' 입력: " && read ans && [ "$$ans" = "prod" ]
	cd $(PROD) && $(TF_INIT) >/dev/null && terraform destroy

# ---------- staging ----------
plan-stage: ## staging plan
	cd $(STAGE) && $(TF_INIT) >/dev/null && terraform plan

apply-stage: ## staging apply
	cd $(STAGE) && $(TF_INIT) >/dev/null && terraform apply

destroy-stage: ## staging 전체 삭제 (확인 입력 필요)
	@printf "⚠️  staging 전체를 삭제합니다. 계속하려면 'stage' 입력: " && read ans && [ "$$ans" = "stage" ]
	cd $(STAGE) && $(TF_INIT) >/dev/null && terraform destroy

# ---------- 부트스트랩 (apply 완료 후 실행) ----------
bootstrap-prod: ## prod: Redis AUTH 설정 + 논리 DB/계정/비밀 생성
	KMS_KEY_ARN=$$(cd $(PROD) && terraform output -raw kms_key_arn) ./scripts/bootstrap-redis.sh prod sb-prod-redis
	./scripts/run-db-bootstrap.sh $(PROD) prod

bootstrap-stage: ## stage: Redis AUTH 설정 + 논리 DB/계정/비밀 생성
	KMS_KEY_ARN=$$(cd $(STAGE) && terraform output -raw kms_key_arn) ./scripts/bootstrap-redis.sh stage sb-stage-redis
	./scripts/run-db-bootstrap.sh $(STAGE) stage

# ---------- VPN ----------
vpn-keys-prod: ## prod WG 키를 secrets/wg.prod.env → SSM 등록 (apply 후 실행 — CMK 필요)
	./scripts/register-vpn-keys.sh prod

vpn-keys-stage: ## stage WG 키를 secrets/wg.stg.env → SSM 등록 (apply 후 실행 — CMK 필요)
	./scripts/register-vpn-keys.sh stage

kubectl-tunnel-prod: ## prod EKS (private-only)로 kubectl 터널 (점프호스트 SSM 포트포워딩, Ctrl+C 종료)
	./scripts/kubectl-tunnel.sh prod

kubectl-tunnel-stage: ## stage EKS (private-only)로 kubectl 터널
	./scripts/kubectl-tunnel.sh stage

k8s-stack-prod: ## prod: Cilium + ALB Controller + ESO 설치 (apply 후 — phase 인자: PHASE=cilium|alb|eso|all)
	./scripts/install-k8s-stack.sh prod $(PHASE)

k8s-stack-stage: ## stage: Cilium + ALB Controller + ESO 설치 (apply 후 — phase 인자: PHASE=cilium|alb|eso|all)
	./scripts/install-k8s-stack.sh stage $(PHASE)

vpn-restart: ## VPN 라우터 재기동 (키 등록/변경 반영 — ASG가 새 인스턴스로 교체, EIP 유지)
	-@IDS=$$(aws ec2 describe-instances --profile $(PROFILE) --region $(REGION) \
	  --filters "Name=tag:Name,Values=sb-prod-vpn,sb-stage-vpn" "Name=instance-state-name,Values=running" \
	  --query "Reservations[].Instances[].InstanceId" --output text); \
	  [ -n "$$IDS" ] && aws ec2 terminate-instances --profile $(PROFILE) --region $(REGION) --instance-ids $$IDS --query "TerminatingInstances[].InstanceId" --output text || echo "(실행 중인 VPN 라우터 없음)"

vpn-eip: ## VPN 라우터 EIP를 secrets/eip.env에 기록 (pfSense Endpoint 설정용)
	@mkdir -p secrets
	@echo "PROD_VPN_EIP=$$(cd $(PROD) && terraform output -raw vpn_eip)" > secrets/eip.env
	@echo "STAGE_VPN_EIP=$$(cd $(STAGE) && terraform output -raw vpn_eip)" >> secrets/eip.env
	@cat secrets/eip.env

# ---------- 전체 생성/삭제 한 줄 명령 (CONFIRM 타이핑 필요) ----------
up-all: ## 전체 인프라 생성: app→환경 병렬 apply→k8s 스택→부트스트랩→VPN 키/재기동 (~55분)
	@printf "전체 인프라를 생성합니다 (약 55분, NAT/EKS/Aurora 과금 시작). 로컬에 helm/kubectl 필요. 계속하려면 CONFIRM 입력: " && read ans && [ "$$ans" = "CONFIRM" ]
	$(MAKE) state-bucket # 백엔드 버킷 보장 (멱등 — 새 계정이면 생성, 있으면 skip)
	cd application && $(TF_INIT) > /dev/null && terraform apply -input=false -auto-approve
	@echo "--- production / staging 병렬 apply (로그: /tmp/up-*.log) ---"
	@( cd $(PROD) && $(TF_INIT) > /dev/null && terraform apply -input=false -auto-approve > /tmp/up-prod.log 2>&1 && echo "[prod] apply 완료" || { echo "[prod] 실패 — /tmp/up-prod.log 확인"; exit 1; } ) & \
	( cd $(STAGE) && $(TF_INIT) > /dev/null && terraform apply -input=false -auto-approve > /tmp/up-stage.log 2>&1 && echo "[stage] apply 완료" || { echo "[stage] 실패 — /tmp/up-stage.log 확인"; exit 1; } ) & \
	wait
	@echo "--- k8s 스택 설치 (Cilium→ALB→ESO) — cni=cilium이라 apply 직후 CNI 공백을 곧바로 닫는다. SSM 터널 포트 공유로 prod→stage 직렬 ---"
	$(MAKE) k8s-stack-prod PHASE=all
	$(MAKE) k8s-stack-stage PHASE=all
	$(MAKE) bootstrap-prod bootstrap-stage
	@echo "--- VPN 키 등록(새 CMK) + 라우터 재기동 ---"
	$(MAKE) vpn-keys-prod vpn-keys-stage
	$(MAKE) vpn-restart
	$(MAKE) vpn-eip
	@echo "✔ 전체 생성 완료 — 다음 절차: pfSense Peer Endpoint를 secrets/eip.env 의 EIP로 갱신"

down-all: ## 전체 인프라 삭제: 비밀 정리→환경 병렬 destroy→application (복구 불가)
	@printf "⚠️  전체 인프라를 삭제합니다 (복구 불가, CMK 삭제 대기 진입). 계속하려면 CONFIRM 입력: " && read ans && [ "$$ans" = "CONFIRM" ]
	$(MAKE) state-bucket # 백엔드 버킷 캐시 보장 (destroy가 state를 찾으려면 필요)
	@for s in $$(aws secretsmanager list-secrets --profile $(PROFILE) --region $(REGION) \
	  --query "SecretList[?starts_with(Name,'sb/')].Name" --output text); do \
	  aws secretsmanager delete-secret --secret-id "$$s" --force-delete-without-recovery \
	    --profile $(PROFILE) --region $(REGION) --query Name --output text; \
	done
	@echo "--- production / staging 병렬 destroy (로그: /tmp/down-*.log) ---"
	@( cd $(PROD) && $(TF_INIT) > /dev/null 2>&1 && terraform destroy -input=false -auto-approve > /tmp/down-prod.log 2>&1 && echo "[prod] destroy 완료" || { echo "[prod] 실패 — /tmp/down-prod.log 확인"; exit 1; } ) & \
	( cd $(STAGE) && $(TF_INIT) > /dev/null 2>&1 && terraform destroy -input=false -auto-approve > /tmp/down-stage.log 2>&1 && echo "[stage] destroy 완료" || { echo "[stage] 실패 — /tmp/down-stage.log 확인"; exit 1; } ) & \
	wait
	cd application && $(TF_INIT) > /dev/null && terraform destroy -input=false -auto-approve
	@echo "--- SSM 파라미터(/sb/*) 정리 ---"
	-@for p in $$(aws ssm get-parameters-by-path --path /sb --recursive --profile $(PROFILE) --region $(REGION) \
	  --query "Parameters[].Name" --output text); do \
	  aws ssm delete-parameter --name "$$p" --profile $(PROFILE) --region $(REGION) && echo "deleted: $$p"; \
	done
	@echo "✔ 전체 삭제 완료 (계정 제로 상태) — 재생성: make up-all"

# ---------- 재배포 보조 ----------
clean-secrets: ## CLI 생성 비밀 (sb/*) 전부 강제 삭제 — 전체 재배포 전 1단계 (확인 입력 필요)
	@printf "⚠️  sb/* 비밀을 전부 강제 삭제합니다. 계속하려면 'delete' 입력: " && read ans && [ "$$ans" = "delete" ]
	@for s in $$(aws secretsmanager list-secrets --profile $(PROFILE) --region $(REGION) \
	  --query "SecretList[?starts_with(Name,'sb/')].Name" --output text); do \
	  aws secretsmanager delete-secret --secret-id "$$s" --force-delete-without-recovery \
	    --profile $(PROFILE) --region $(REGION) --query Name --output text; \
	done
