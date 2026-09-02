# =============================================================================
# Network module -- the minimum VPC the Fargate producer needs (roadmap.md, Phase 5)
#
# Until Phase 5 this project was VPC-less: Lambda, Glue, Step Functions and
# Athena all run outside one. The Binance producer is the first thing that has to
# live on an ENI, so a network appears here and nowhere earlier.
#
# WHY THIS IS SO SMALL, AND WHY THERE IS NO NAT GATEWAY.
# The producer only ever makes OUTBOUND connections -- one WebSocket to Binance
# and PutRecords to Kinesis. Nothing on the internet ever needs to reach it. The
# textbook "private subnet + NAT Gateway" layout would therefore buy zero
# security here (the security group already blocks every inbound packet) and
# cost ~$33/month -- more than triple the compute it exists to serve, and more
# than the entire rest of this phase. So: public subnets, public IP on the task,
# and a security group with no ingress rules at all.
#
# Two subnets in two AZs, not one. They cost nothing, and a single-AZ task dies
# with its AZ.
#
# Everything in this module is free: a VPC, subnets, an internet gateway, route
# tables and security groups carry no charge. It is applied even while the
# project is dormant -- see "Current state: DORMANT" in roadmap.md.
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "crypto-vpc-${var.environment}"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "crypto-igw-${var.environment}"
  }
}

# One /24 per AZ, carved from the /16. cidrsubnet() derives them so the CIDRs
# cannot drift out of the VPC range by hand-editing.
resource "aws_subnet" "public" {
  count = var.public_subnet_count

  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = {
    Name = "crypto-public-${data.aws_availability_zones.available.names[count.index]}-${var.environment}"
    Tier = "public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "crypto-public-rt-${var.environment}"
  }
}

resource "aws_route_table_association" "public" {
  count = var.public_subnet_count

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security group -- egress only, on purpose
#
# No ingress block at all. An aws_security_group with no ingress rules denies
# every inbound packet, which is the correct posture for a process that dials
# out and is never dialled. Egress is left open to 0.0.0.0/0 because the
# producer talks to two moving targets -- Binance's WebSocket endpoints and the
# Kinesis API -- neither of which publishes a stable IP range worth pinning.
# -----------------------------------------------------------------------------
resource "aws_security_group" "producer" {
  name        = "crypto-producer-sg-${var.environment}"
  description = "Binance producer: outbound only, no inbound"
  vpc_id      = aws_vpc.main.id

  egress {
    description = "All outbound (Binance WebSocket + Kinesis API)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "crypto-producer-sg-${var.environment}"
  }
}
