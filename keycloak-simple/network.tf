# =============================================================================
# network.tf - VPC, subnets, routing, firewalls
# =============================================================================
# Everything here except the NAT Gateway is FREE. AWS charges nothing for a
# VPC, subnets, an internet gateway, route tables, or security groups.
# =============================================================================


# -----------------------------------------------------------------------------
# THE VPC
# -----------------------------------------------------------------------------
# Your own private slice of AWS. Nobody else can reach into it.
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16" # 65,536 private addresses

  enable_dns_support   = true # let instances resolve names
  enable_dns_hostnames = true # required for the ALB to find instances

  tags = { Name = "${var.name}-vpc" }
}


# -----------------------------------------------------------------------------
# INTERNET GATEWAY - the front door
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${var.name}-igw" }
}


# -----------------------------------------------------------------------------
# SUBNETS
# -----------------------------------------------------------------------------
# Which physical data centers can this account use? Ask, rather than
# hardcoding "us-east-1a" and hoping it exists.
data "aws_availability_zones" "available" {
  state = "available"
}

# PUBLIC subnets: have a route to the internet gateway. The ALB lives here.
# We need TWO because an ALB legally requires two availability zones.
resource "aws_subnet" "public" {
  count = 2

  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.${count.index + 1}.0/24"
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name}-public-${count.index + 1}" }
}

# PRIVATE subnet: NO route to the internet gateway. Keycloak lives here, so
# nothing on the internet can reach it directly - only the ALB can.
#
# Just ONE. The ALB needs two subnets; a single instance does not.
resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.10.0/24"
  availability_zone = data.aws_availability_zones.available.names[0]

  tags = { Name = "${var.name}-private" }
}


# -----------------------------------------------------------------------------
# NAT GATEWAY - one-way door out
# -----------------------------------------------------------------------------
# The problem: Keycloak sits in a private subnet, so it cannot reach the
# internet. But it MUST, to download Java and Keycloak at boot.
#
# The solution: a NAT Gateway is a mail slot. Traffic goes OUT, nothing comes
# IN. The instance can download things; the internet cannot find it.
#
# COST: ~$32.85/month. This is the price of keeping the instance private,
# and it is the single most expensive item in this stack.
resource "aws_eip" "nat" {
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
  tags       = { Name = "${var.name}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id

  # The NAT gateway itself must sit in a PUBLIC subnet - it needs internet
  # access in order to provide it to others.
  subnet_id  = aws_subnet.public[0].id
  depends_on = [aws_internet_gateway.main]

  tags = { Name = "${var.name}-nat" }
}


# -----------------------------------------------------------------------------
# ROUTING
# -----------------------------------------------------------------------------
# A route table is a list of directions: "to reach X, go via Y."

# Public: send everything to the internet gateway.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0" # "everywhere"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Private: send everything to the NAT gateway instead. This one difference
# is what makes the subnet "private."
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}


# =============================================================================
# SECURITY GROUPS - the firewalls
# =============================================================================
# These are FREE and they are the entire security model. Two layers:
#
#   You (68.32.112.68)
#        |  only your IP
#        v
#   [ALB]  <- public, but locked to your IP
#        |  only the ALB
#        v
#   [Keycloak]  <- private subnet, no public IP at all
#
# Note the second arrow does not mention your IP. Keycloak does not know who
# you are; it only trusts the load balancer. So even if someone learned the
# instance's private address, they still could not reach it.
#
# Security groups are DENY BY DEFAULT - you only ever write "allow" rules.
# They are also STATEFUL: allow traffic in, and the reply is automatically
# allowed back out.

# --- Firewall 1: the load balancer ---
resource "aws_security_group" "alb" {
  name_prefix = "${var.name}-alb-"
  description = "Keycloak ALB - HTTPS from approved admin IPs only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from approved admin IPs"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"

    # THE IP LOCK. Each address becomes a /32, meaning exactly one machine.
    # Everything else on the internet is silently dropped here.
    cidr_blocks = [for ip in var.my_ips : "${ip}/32"]
  }

  ingress {
    description = "HTTP from approved admin IPs - redirected to HTTPS only"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [for ip in var.my_ips : "${ip}/32"]
  }

  egress {
    description = "Forward to Keycloak"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # any protocol
    cidr_blocks = [aws_vpc.main.cidr_block]
  }

  lifecycle { create_before_destroy = true }
  tags = { Name = "${var.name}-alb-sg" }
}

# --- Firewall 2: the Keycloak instance ---
resource "aws_security_group" "keycloak" {
  name_prefix = "${var.name}-app-"
  description = "Keycloak instance - traffic from the ALB only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "App traffic from the ALB"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"

    # THE IMPORTANT BIT: the source is the ALB's security group, not an IP
    # range. That means "any machine wearing that badge," which keeps
    # working forever as instances are replaced and get new IPs.
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Health checks from the ALB"
    from_port       = 9000
    to_port         = 9000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    description = "Outbound for package installs and AWS APIs"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
  tags = { Name = "${var.name}-app-sg" }
}

# =============================================================================
# NOTE: THERE IS NO PORT 22 RULE ANYWHERE. THAT IS DELIBERATE.
# =============================================================================
# No SSH means nothing to port-scan, no key file to lose, and no key to
# rotate when someone leaves. Instead, get a shell through SSM:
#
#     aws ssm start-session --target <instance-id>
#
# It works because the SSM agent reaches OUT to AWS over HTTPS (allowed by
# the egress rule above) rather than AWS reaching in. Access is controlled
# by IAM, and every session is logged to CloudTrail.
#
# Opening port 22 to 0.0.0.0/0 gets you found by automated scanners within
# minutes. That is not an exaggeration.
# =============================================================================
