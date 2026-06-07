# ---------------------------------------------------------------------------
# global-bridge 인프라 운영 명령 모음 — `make help`로 타겟 확인
#
# ── `make up-all` 이 자동 수행하는 전 과정 (수동으로 할 땐 이 순서 그대로) ──
#   0. (선행) environments/*/terraform.tfvars 준비(example 참고)
#      + secrets/wg.{prod,stg}.env WG 키 파일 배치
#   1. cd application && terraform init && terraform apply
#        # myApplications 앱 — 환경이 remote state로 ARN을 읽으므로 반드시 먼저
#   2. cd environments/production && terraform init && terraform apply
#      cd environments/staging    && terraform init && terraform apply
#        # 두 환경은 state가 분리돼 있어 병렬 실행 가능 (~20분)
#   3. make bootstrap-prod bootstrap-stage
#        # Redis AUTH(ROTATE→SET) + 논리 DB/서비스 계정/비밀 — 점프호스트 SSM 원격 실행
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
PROFILE ?= woori-fisa-1k
REGION  ?= ap-northeast-2

PROD  := environments/production
STAGE := environments/staging

.DEFAULT_GOAL := help
.PHONY: help fmt validate init plan-app apply-app plan-prod apply-prod destroy-prod \
        plan-stage apply-stage destroy-stage bootstrap-prod bootstrap-stage clean-secrets \
        vpn-keys-prod vpn-keys-stage vpn-restart vpn-eip kubectl-tunnel-prod kubectl-tunnel-stage \
        up-all down-all

help: ## 타겟 목록 출력
	@awk 'BEGIN {FS = ":.*##"} /^[a-zA-Z0-9_-]+:.*##/ {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

# ---------- 공통 ----------
fmt: ## 전체 Terraform 코드 포맷
	terraform fmt -recursive

validate: ## 3개 스택(application/prod/stage) validate
	cd application && terraform validate
	cd $(PROD) && terraform validate
	cd $(STAGE) && terraform validate

init: ## 3개 스택 init
	cd application && terraform init -input=false
	cd $(PROD) && terraform init -input=false
	cd $(STAGE) && terraform init -input=false

# ---------- application (myApplications 앱 — 환경보다 먼저 1회) ----------
plan-app: ## application 스택 plan
	cd application && terraform plan

apply-app: ## application 스택 apply
	cd application && terraform apply

# ---------- production ----------
plan-prod: ## production plan
	cd $(PROD) && terraform plan

apply-prod: ## production apply
	cd $(PROD) && terraform apply

destroy-prod: ## production 전체 삭제 (확인 입력 필요)
	@printf "⚠️  production 전체를 삭제합니다. 계속하려면 'prod' 입력: " && read ans && [ "$$ans" = "prod" ]
	cd $(PROD) && terraform destroy

# ---------- staging ----------
plan-stage: ## staging plan
	cd $(STAGE) && terraform plan

apply-stage: ## staging apply
	cd $(STAGE) && terraform apply

destroy-stage: ## staging 전체 삭제 (확인 입력 필요)
	@printf "⚠️  staging 전체를 삭제합니다. 계속하려면 'stage' 입력: " && read ans && [ "$$ans" = "stage" ]
	cd $(STAGE) && terraform destroy

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

kubectl-tunnel-prod: ## prod EKS(private-only)로 kubectl 터널 (점프호스트 SSM 포트포워딩, Ctrl+C 종료)
	./scripts/kubectl-tunnel.sh prod

kubectl-tunnel-stage: ## stage EKS(private-only)로 kubectl 터널
	./scripts/kubectl-tunnel.sh stage

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
up-all: ## 전체 인프라 생성: app→환경 병렬 apply→부트스트랩→VPN 키/재기동 (~40분)
	@printf "전체 인프라를 생성합니다 (약 40분, NAT/EKS/Aurora 과금 시작). 계속하려면 CONFIRM 입력: " && read ans && [ "$$ans" = "CONFIRM" ]
	cd application && terraform init -input=false > /dev/null && terraform apply -input=false -auto-approve
	@echo "--- production / staging 병렬 apply (로그: /tmp/up-*.log) ---"
	@( cd $(PROD) && terraform init -input=false > /dev/null && terraform apply -input=false -auto-approve > /tmp/up-prod.log 2>&1 && echo "[prod] apply 완료" || { echo "[prod] 실패 — /tmp/up-prod.log 확인"; exit 1; } ) & \
	( cd $(STAGE) && terraform init -input=false > /dev/null && terraform apply -input=false -auto-approve > /tmp/up-stage.log 2>&1 && echo "[stage] apply 완료" || { echo "[stage] 실패 — /tmp/up-stage.log 확인"; exit 1; } ) & \
	wait
	$(MAKE) bootstrap-prod bootstrap-stage
	@echo "--- VPN 키 등록(새 CMK) + 라우터 재기동 ---"
	$(MAKE) vpn-keys-prod vpn-keys-stage
	$(MAKE) vpn-restart
	$(MAKE) vpn-eip
	@echo "✔ 전체 생성 완료 — 다음 절차: pfSense Peer Endpoint를 secrets/eip.env 의 EIP로 갱신"

down-all: ## 전체 인프라 삭제: 비밀 정리→환경 병렬 destroy→application (복구 불가)
	@printf "⚠️  전체 인프라를 삭제합니다 (복구 불가, CMK 삭제 대기 진입). 계속하려면 CONFIRM 입력: " && read ans && [ "$$ans" = "CONFIRM" ]
	@for s in $$(aws secretsmanager list-secrets --profile $(PROFILE) --region $(REGION) \
	  --query "SecretList[?starts_with(Name,'sb/')].Name" --output text); do \
	  aws secretsmanager delete-secret --secret-id "$$s" --force-delete-without-recovery \
	    --profile $(PROFILE) --region $(REGION) --query Name --output text; \
	done
	@echo "--- production / staging 병렬 destroy (로그: /tmp/down-*.log) ---"
	@( cd $(PROD) && terraform destroy -input=false -auto-approve > /tmp/down-prod.log 2>&1 && echo "[prod] destroy 완료" || { echo "[prod] 실패 — /tmp/down-prod.log 확인"; exit 1; } ) & \
	( cd $(STAGE) && terraform destroy -input=false -auto-approve > /tmp/down-stage.log 2>&1 && echo "[stage] destroy 완료" || { echo "[stage] 실패 — /tmp/down-stage.log 확인"; exit 1; } ) & \
	wait
	cd application && terraform destroy -input=false -auto-approve
	@echo "--- SSM 파라미터(/sb/*) 정리 ---"
	-@for p in $$(aws ssm get-parameters-by-path --path /sb --recursive --profile $(PROFILE) --region $(REGION) \
	  --query "Parameters[].Name" --output text); do \
	  aws ssm delete-parameter --name "$$p" --profile $(PROFILE) --region $(REGION) && echo "deleted: $$p"; \
	done
	@echo "✔ 전체 삭제 완료 (계정 제로 상태) — 재생성: make up-all"

# ---------- 재배포 보조 ----------
clean-secrets: ## CLI 생성 비밀(sb/*) 전부 강제 삭제 — 전체 재배포 전 1단계 (확인 입력 필요)
	@printf "⚠️  sb/* 비밀을 전부 강제 삭제합니다. 계속하려면 'delete' 입력: " && read ans && [ "$$ans" = "delete" ]
	@for s in $$(aws secretsmanager list-secrets --profile $(PROFILE) --region $(REGION) \
	  --query "SecretList[?starts_with(Name,'sb/')].Name" --output text); do \
	  aws secretsmanager delete-secret --secret-id "$$s" --force-delete-without-recovery \
	    --profile $(PROFILE) --region $(REGION) --query Name --output text; \
	done
