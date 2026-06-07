data "aws_region" "current" {}

locals {
  # NAT를 배치할 AZ 목록 (public 서브넷이 있는 AZ 기준)
  public_azs = sort(keys(var.public_subnets))
  nat_azs = (
    var.nat_gateway_strategy == "per_az" ? local.public_azs :
    var.nat_gateway_strategy == "single" ? [coalesce(var.single_nat_az, local.public_azs[0])] :
    []
  )
}

# ---------------------------------------------------------------------------
# VPC / IGW
# ---------------------------------------------------------------------------

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.name}-vpc"
  }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-igw"
  }
}

# ---------------------------------------------------------------------------
# VPC Flow Logs → CloudWatch (CMK 암호화) — 네트워크 트래픽 감사/포렌식
# flow_log_kms_key_arn이 null이면 비활성
# ---------------------------------------------------------------------------

locals {
  flow_logs_enabled = var.flow_log_kms_key_arn != null
}

resource "aws_cloudwatch_log_group" "flow" {
  count = local.flow_logs_enabled ? 1 : 0

  name              = "/aws/vpc/${var.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = var.flow_log_kms_key_arn

  tags = {
    Name = "${var.name}-flow-logs"
  }
}

resource "aws_iam_role" "flow" {
  count = local.flow_logs_enabled ? 1 : 0

  name = "${var.name}-flow-logs-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "flow" {
  count = local.flow_logs_enabled ? 1 : 0

  name = "${var.name}-flow-logs"
  role = aws_iam_role.flow[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
      Resource = "${aws_cloudwatch_log_group.flow[0].arn}:*"
    }]
  })
}

resource "aws_flow_log" "this" {
  count = local.flow_logs_enabled ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow[0].arn
  iam_role_arn             = aws_iam_role.flow[0].arn
  max_aggregation_interval = 600

  tags = {
    Name = "${var.name}-flow-log"
  }
}

# ---------------------------------------------------------------------------
# 서브넷 (public / private / db / mgmt)
# ---------------------------------------------------------------------------

resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value
  availability_zone       = "${data.aws_region.current.region}${each.key}"
  map_public_ip_on_launch = true

  tags = merge(
    {
      Name = "${var.name}-public-${each.key}"
      Tier = "public"
    },
    var.public_subnet_extra_tags
  )
}

resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = "${data.aws_region.current.region}${each.key}"

  tags = merge(
    {
      Name = "${var.name}-private-${each.key}"
      Tier = "private"
    },
    var.private_subnet_extra_tags
  )
}

resource "aws_subnet" "db" {
  for_each = var.db_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = "${data.aws_region.current.region}${each.key}"

  tags = {
    Name = "${var.name}-db-${each.key}"
    Tier = "db"
  }
}

resource "aws_subnet" "mgmt" {
  for_each = var.mgmt_subnets

  vpc_id            = aws_vpc.this.id
  cidr_block        = each.value
  availability_zone = "${data.aws_region.current.region}${each.key}"

  tags = {
    Name = "${var.name}-mgmt-${each.key}"
    Tier = "mgmt"
  }
}

# ---------------------------------------------------------------------------
# NAT 게이트웨이 (nat_gateway_strategy에 따라 0 ~ AZ 수만큼 생성)
# ---------------------------------------------------------------------------

resource "aws_eip" "nat" {
  for_each = toset(local.nat_azs)

  domain = "vpc"

  tags = {
    Name = "${var.name}-nat-eip-${each.key}"
  }
}

resource "aws_nat_gateway" "this" {
  for_each = toset(local.nat_azs)

  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.key].id

  tags = {
    Name = "${var.name}-nat-${each.key}"
  }

  # NAT 게이트웨이는 IGW가 VPC에 연결된 뒤에만 생성 가능하나, 코드상
  # 참조(EIP/subnet)에는 IGW가 없어 TF가 순서를 추론 못 함 — 명시 필요
  depends_on = [aws_internet_gateway.this]
}

# ---------------------------------------------------------------------------
# S3 게이트웨이 엔드포인트 (무료) — private/db/mgmt 서브넷에서 S3 직접 접근
# AL2023 dnf 리포·ECR 이미지 레이어가 S3 기반: 격리 구역 패키지 설치 + NAT 비용 절감
# ---------------------------------------------------------------------------

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.s3"
  vpc_endpoint_type = "Gateway"

  route_table_ids = concat(
    [aws_route_table.db.id, aws_route_table.mgmt.id],
    [for rt in aws_route_table.private : rt.id]
  )

  tags = {
    Name = "${var.name}-vpce-s3"
  }
}

# ---------------------------------------------------------------------------
# 라우팅: public — IGW로 나가는 단일 라우트 테이블
# ---------------------------------------------------------------------------

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-public-rt"
  }
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

# ---------------------------------------------------------------------------
# 라우팅: private — AZ별 라우트 테이블 (NAT 활성화 시 0.0.0.0/0 → NAT)
# ---------------------------------------------------------------------------

resource "aws_route_table" "private" {
  for_each = var.private_subnets

  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-private-rt-${each.key}"
  }
}

resource "aws_route" "private_nat" {
  for_each = var.nat_gateway_strategy == "none" ? {} : var.private_subnets

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id = (
    contains(local.nat_azs, each.key)
    ? aws_nat_gateway.this[each.key].id
    : aws_nat_gateway.this[local.nat_azs[0]].id
  )

  lifecycle {
    # per_az에서 private AZ에 대응하는 public(NAT) AZ가 없으면 다른 AZ NAT로
    # 조용히 fallback되어 격리가 깨진다 — 명시적으로 실패시킴
    precondition {
      condition     = var.nat_gateway_strategy != "per_az" || contains(local.public_azs, each.key)
      error_message = "per_az 전략에서는 private 서브넷 AZ '${each.key}'에 대응하는 public 서브넷(NAT)이 필요합니다."
    }
  }
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}

# ---------------------------------------------------------------------------
# 라우팅: db — 인터넷 라우트 없는 격리 라우트 테이블 (VPC 내부 통신만)
# ---------------------------------------------------------------------------

resource "aws_route_table" "db" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-db-rt"
  }
}

resource "aws_route_table_association" "db" {
  for_each = aws_subnet.db

  subnet_id      = each.value.id
  route_table_id = aws_route_table.db.id
}

# ---------------------------------------------------------------------------
# 라우팅: mgmt — db와 동일한 격리 구역 (인터넷 라우트 없음)
# 점프 호스트는 SSM 인터페이스 엔드포인트로 접속 — 엔드포인트는 라우트가 필요 없음
# ---------------------------------------------------------------------------

resource "aws_route_table" "mgmt" {
  vpc_id = aws_vpc.this.id

  tags = {
    Name = "${var.name}-mgmt-rt"
  }
}

resource "aws_route_table_association" "mgmt" {
  for_each = aws_subnet.mgmt

  subnet_id      = each.value.id
  route_table_id = aws_route_table.mgmt.id
}
