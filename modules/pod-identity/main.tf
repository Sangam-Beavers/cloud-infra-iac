# EKS Pod Identity로 파드에 AWS 권한을 부여합니다.
# IRSA (OIDC 웹 아이덴티티)와 달리 앱에 software.amazon.awssdk:sts 의존성이 필요하지 않습니다.
# eks-pod-identity-agent 애드온이 컨테이너 자격증명을 제공하고 SDK의 ContainerCredentialsProvider가
# 이를 사용하므로, 'sts trap' (sts 미포함 시 노드 롤로 폴백되는 문제)이 발생하지 않습니다.
# 신뢰 관계도 OIDC 대신 pods.eks.amazonaws.com 서비스 프린시플 한 줄로 단순합니다.

data "aws_iam_policy_document" "trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = ["pods.eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = var.name
  assume_role_policy = data.aws_iam_policy_document.trust.json
  tags               = { Name = var.name }
}

# 권한 내용은 호출 측이 jsonencode로 주입합니다 (모듈은 메커니즘만 제공하고, 정책은 외부에서 정의해 재사용성을 확보).
resource "aws_iam_role_policy" "this" {
  name   = var.name
  role   = aws_iam_role.this.id
  policy = var.policy
}

# ServiceAccount와 역할을 연결합니다. SA는 차트가 생성하며 (roleArn 어노테이션 불필요), 이름 기반 바인딩이라 SA 생성 순서와 무관합니다.
resource "aws_eks_pod_identity_association" "this" {
  cluster_name    = var.cluster_name
  namespace       = var.namespace
  service_account = var.service_account
  role_arn        = aws_iam_role.this.arn
}
