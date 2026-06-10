# 온프렘 ArgoCD → EKS 연동 (CD 담당자용)

온프렘 ArgoCD가 이 repo로 배포한 **private-only EKS**를 배포 대상 클러스터로 등록하기 위한 템플릿이다.
AWS 측 배선 ( 네트워크 경로·DNS·전용 IAM User·access entry ) 은 Terraform이 이미 끝냈고, 여기서는
그 산출물로 ArgoCD에 cluster Secret 하나만 등록하면 된다.

## 인증·권한 모델

- **principal**: 환경별 전용 IAM User ( `sb-<env>-argocd` ) — `argocd-iam` 모듈이 생성. 상시 AWS 권한 0.
- **인증**: cluster Secret의 `execProviderConfig`가 ArgoCD 내장 `argocd-k8s-auth aws`로 EKS 토큰을 발급
  ( IAM User 액세스 키를 클러스터별 env에 내장 — 전역 자격증명 불필요, stage/prod 공존 안전 ).
- **권한**: EKS access entry가 **네임스페이스 한정 Edit** ( `argocd_namespaces` ) 만 부여. 그 외 네임스페이스·클러스터 리소스는 접근 불가.

## 사전 조건 ( AWS·온프렘 측, 이미 되어 있어야 함 )

1. 해당 환경이 `onprem_integration.enabled = true`로 apply 됨.
2. `make onprem-handoff-<env>` 실행 → `secrets/.argocd-cluster`에 자격증명·접속 정보 기록됨.
3. 배포 대상 네임스페이스 ( 예 `sb-stage-app-ns` ) 가 클러스터에 존재 — `install-k8s-stack.sh`의 `all`/`ns`
   phase가 자동 생성 ( 한정 Edit은 네임스페이스를 직접 못 만들기 때문 ).
4. 온프렘 pfSense에 EKS 엔드포인트 도메인 → resolver inbound IP 조건부 포워더 설정
   ( `secrets/.eks-control-plane-dns-ip` 참고 ) — ArgoCD가 API 호스트명을 private ENI IP로 해석해야 한다.

## 등록 절차

```bash
# 1. 값 채운 사본 생성 (시크릿 포함 — 커밋 금지)
cp cluster-secret.yaml.example cluster-secret.yaml

# 2. secrets/.argocd-cluster 의 <ENV>_* 값으로 <플레이스홀더> 치환
#    <EKS_CLUSTER_NAME>      ← <ENV>_EKS_CLUSTER_NAME
#    <EKS_ENDPOINT_HOST>     ← <ENV>_EKS_ENDPOINT_HOST
#    <EKS_CA_DATA>           ← <ENV>_EKS_CA_DATA
#    <EKS_REGION>            ← <ENV>_EKS_REGION
#    <ARGOCD_ACCESS_KEY_ID>  ← <ENV>_ARGOCD_ACCESS_KEY_ID
#    <ARGOCD_SECRET_ACCESS_KEY> ← <ENV>_ARGOCD_SECRET_ACCESS_KEY

# 3. ArgoCD가 도는 클러스터에 적용
kubectl apply -f cluster-secret.yaml

# 4. 등록 확인
argocd cluster list            # 방금 등록한 server가 Successful 인지
```

검증용 Application ( 한정 네임스페이스로만 sync 되는지 ):

```bash
argocd app create probe --repo <git> --path <chart> \
  --dest-server https://<EKS_ENDPOINT_HOST> --dest-namespace sb-<env>-app-ns
argocd app sync probe        # 대상 네임스페이스 내 리소스는 OK
# 다른 네임스페이스 (예 kube-system) 대상 sync는 RBAC로 거부되어야 정상 (한정 스코프 확인)
```

## 키 회전

전용 IAM User의 액세스 키를 갈아끼울 때:

```bash
terraform -chdir=environments/<env> taint module.argocd_iam[0].aws_iam_access_key.this
terraform -chdir=environments/<env> apply
make onprem-handoff-<env>      # secrets/.argocd-cluster 재생성
# cluster-secret 의 키 값을 새 값으로 갱신 후 kubectl apply
```
