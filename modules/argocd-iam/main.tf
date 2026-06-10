# ---------------------------------------------------------------------------
# 온프렘 ArgoCD 전용 IAM User — EKS access entry에 매핑될 principal.
# 온프렘 ArgoCD는 클러스터 밖이라 IRSA를 못 쓰므로 정적 액세스 키로 인증한다.
#
# 인라인 정책 없음 (상시 AWS 권한 0): ArgoCD의 `aws eks get-token`은 STS 서명
# 요청이라 IAM 권한이 필요 없고, K8s RBAC는 전적으로 EKS access entry가 부여한다.
# 따라서 이 키가 유출돼도 blast radius는 매핑된 access entry (네임스페이스 한정
# Edit) 하나뿐이다. 클러스터 ARN도 참조하지 않아 eks 모듈에 의존하지 않는다 (순환 없음).
# ---------------------------------------------------------------------------

resource "aws_iam_user" "this" {
  name = var.name

  # down-* 시 access key가 남아 User 삭제가 막히지 않게 (destroy 멱등)
  force_destroy = true

  tags = {
    Name = var.name
  }
}

resource "aws_iam_access_key" "this" {
  user = aws_iam_user.this.name
}
