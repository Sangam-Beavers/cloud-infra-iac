# ---------------------------------------------------------------------------
# 하이브리드 DNS — on-prem (pfSense)과 AWS 사이의 양방향 이름 해석을 담당합니다.
#   inbound  : on-prem이 EKS private API 엔드포인트 (*.eks.amazonaws.com)를 해석합니다.
#   outbound : EKS 노드/파드가 on-prem 도메인 (harbor.corp.example 등)을 해석합니다.
# 엔드포인트는 on-prem 대면 tier를 일관되게 유지하기 위해 mgmt 서브넷에만 둡니다.
# ---------------------------------------------------------------------------

# inbound 엔드포인트 SG — on-prem에서 오는 DNS 질의 (53)만 허용합니다.
resource "aws_security_group" "inbound" {
  name        = "${var.name}-resolver-in-sg"
  description = "Route53 Resolver inbound endpoint: DNS 53 from on-prem"
  vpc_id      = var.vpc_id

  ingress {
    description = "DNS UDP from on-prem"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = var.inbound_allowed_cidrs
  }

  ingress {
    description = "DNS TCP from on-prem"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = var.inbound_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.name}-resolver-in-sg" }
}

# outbound 엔드포인트 SG — on-prem DNS 서버로 나가는 53만 허용합니다 (least-privilege).
resource "aws_security_group" "outbound" {
  name        = "${var.name}-resolver-out-sg"
  description = "Route53 Resolver outbound endpoint: DNS 53 to on-prem DNS"
  vpc_id      = var.vpc_id

  egress {
    description = "DNS UDP to on-prem DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "udp"
    cidr_blocks = [for ip in var.forward_target_ips : "${ip}/32"]
  }

  egress {
    description = "DNS TCP to on-prem DNS"
    from_port   = 53
    to_port     = 53
    protocol    = "tcp"
    cidr_blocks = [for ip in var.forward_target_ips : "${ip}/32"]
  }

  tags = { Name = "${var.name}-resolver-out-sg" }
}

resource "aws_route53_resolver_endpoint" "inbound" {
  name               = "${var.name}-inbound"
  direction          = "INBOUND"
  security_group_ids = [aws_security_group.inbound.id]

  dynamic "ip_address" {
    for_each = var.subnet_ids
    content {
      subnet_id = ip_address.value
    }
  }

  tags = { Name = "${var.name}-inbound" }
}

resource "aws_route53_resolver_endpoint" "outbound" {
  name               = "${var.name}-outbound"
  direction          = "OUTBOUND"
  security_group_ids = [aws_security_group.outbound.id]

  dynamic "ip_address" {
    for_each = var.subnet_ids
    content {
      subnet_id = ip_address.value
    }
  }

  tags = { Name = "${var.name}-outbound" }
}

# on-prem 도메인을 on-prem DNS로 보내는 포워딩 룰입니다 (VPC 연결 포함).
resource "aws_route53_resolver_rule" "forward" {
  for_each = toset(var.forward_domains)

  name                 = "${var.name}-${replace(each.value, ".", "-")}"
  domain_name          = each.value
  rule_type            = "FORWARD"
  resolver_endpoint_id = aws_route53_resolver_endpoint.outbound.id

  dynamic "target_ip" {
    for_each = var.forward_target_ips
    content {
      ip   = target_ip.value
      port = 53
    }
  }

  tags = { Name = "${var.name}-${replace(each.value, ".", "-")}" }
}

resource "aws_route53_resolver_rule_association" "forward" {
  for_each = aws_route53_resolver_rule.forward

  resolver_rule_id = each.value.id
  vpc_id           = var.vpc_id
}
