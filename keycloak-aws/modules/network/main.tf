# =============================================================================
# NETWORK MODULE - main.tf
# =============================================================================
# This file builds the "neighborhood" that our Keycloak server lives in.
#
# Think of AWS like a giant apartment building. A VPC is YOUR apartment.
# Nobody else can walk into your apartment unless you open a door for them.
# Subnets are the rooms inside your apartment.
# =============================================================================


# -----------------------------------------------------------------------------
# THE VPC (Virtual Private Cloud)
# -----------------------------------------------------------------------------
# A VPC is your own private section of the AWS cloud. It has its own private
# IP address range that nobody outside can reach directly.
resource "aws_vpc" "main" {
  # cidr_block = the range of private IP addresses inside your VPC.
  # "10.0.0.0/16" means every address from 10.0.0.0 to 10.0.255.255.
  # The "/16" says "the first 16 bits (10.0) are locked, the rest can change."
  # That gives us 65,536 addresses to hand out. Way more than we need.
  cidr_block = var.vpc_cidr

  # enable_dns_support lets machines inside the VPC use Amazon's DNS server
  # to turn names like "google.com" into IP addresses.
  enable_dns_support = true

  # enable_dns_hostnames gives each EC2 instance a DNS name automatically.
  # We need this ON so the load balancer can find our server by name.
  enable_dns_hostnames = true

  # Tags are sticky notes. They do nothing technically, but they let you
  # find things later in the AWS console and track costs per project.
  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpc"
  })
}


# -----------------------------------------------------------------------------
# INTERNET GATEWAY
# -----------------------------------------------------------------------------
# An Internet Gateway (IGW) is the front door of your VPC. Without it,
# nothing inside your VPC can talk to the internet, and the internet
# can't talk to anything inside.
resource "aws_internet_gateway" "main" {
  # Attach the door to our VPC (an IGW must belong to exactly one VPC).
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-igw"
  })
}


# -----------------------------------------------------------------------------
# PUBLIC SUBNETS
# -----------------------------------------------------------------------------
# A subnet is a slice of the VPC's IP range that lives in ONE physical
# data center (called an Availability Zone, or AZ).
#
# "Public" means it has a route to the Internet Gateway.
# Our load balancer lives here because it needs to be reachable from your house.
#
# We create TWO because an Application Load Balancer legally requires at least
# two AZs. This is AWS's rule, not ours. It also means if one data center
# catches fire, the other keeps working.
resource "aws_subnet" "public" {
  # count = how many copies of this resource to make.
  # length() counts items in a list. If public_subnet_cidrs has 2 items,
  # Terraform makes 2 subnets: aws_subnet.public[0] and aws_subnet.public[1].
  count = length(var.public_subnet_cidrs)

  vpc_id = aws_vpc.main.id

  # count.index is 0 for the first copy, 1 for the second, etc.
  # So subnet 0 gets the first CIDR, subnet 1 gets the second.
  cidr_block = var.public_subnet_cidrs[count.index]

  # Spread subnets across different physical data centers.
  # The % (modulo) operator wraps around if we have more subnets than AZs.
  availability_zone = var.availability_zones[count.index % length(var.availability_zones)]

  # Automatically give any EC2 instance launched here a public IP address.
  # We turn this ON only for public subnets.
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-${count.index + 1}"
    Tier = "public"
  })
}


# -----------------------------------------------------------------------------
# PRIVATE SUBNETS
# -----------------------------------------------------------------------------
# "Private" means NO direct route to the internet. Nothing on the internet
# can reach a machine here, even if it wanted to.
#
# Our Keycloak EC2 server lives here. That's the whole security idea:
# the internet talks to the load balancer, the load balancer talks to Keycloak.
# Keycloak itself is never directly exposed.
resource "aws_subnet" "private" {
  count = length(var.private_subnet_cidrs)

  vpc_id            = aws_vpc.main.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = var.availability_zones[count.index % length(var.availability_zones)]

  # NO public IP. This is the key difference from the public subnet above.
  map_public_ip_on_launch = false

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-${count.index + 1}"
    Tier = "private"
  })
}


# -----------------------------------------------------------------------------
# ELASTIC IP FOR THE NAT GATEWAY
# -----------------------------------------------------------------------------
# An Elastic IP is a permanent public IP address that you own.
# The NAT Gateway needs one so outbound traffic has a consistent return address.
resource "aws_eip" "nat" {
  # domain = "vpc" tells AWS this IP is for use inside a VPC.
  # (The old value was `vpc = true`, which is now deprecated.)
  domain = "vpc"

  # Don't try to create the EIP until the Internet Gateway exists.
  # depends_on forces Terraform to wait, even though there's no direct link.
  depends_on = [aws_internet_gateway.main]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat-eip"
  })
}


# -----------------------------------------------------------------------------
# NAT GATEWAY
# -----------------------------------------------------------------------------
# NAT = Network Address Translation.
#
# Problem: our Keycloak server is in a private subnet, so it can't reach the
# internet. But it NEEDS to, in order to download Java, Keycloak, and updates.
#
# Solution: a NAT Gateway is a one-way door. Machines inside can reach OUT to
# the internet, but the internet cannot reach IN. Like a mail slot: you can
# push letters out, nobody can crawl in.
#
# COST WARNING: NAT Gateways cost about $32/month plus data charges.
# For a dev environment you can set create_nat_gateway = false and instead
# put the EC2 in a public subnet. See the README for that tradeoff.
resource "aws_nat_gateway" "main" {
  # Conditional creation: if create_nat_gateway is true, make 1. Otherwise 0.
  # The ? : syntax is a ternary — it's just a compact if/else.
  count = var.create_nat_gateway ? 1 : 0

  allocation_id = aws_eip.nat.id

  # The NAT Gateway itself must live in a PUBLIC subnet (it needs internet access
  # to do its job). It serves the private subnets from there.
  subnet_id = aws_subnet.public[0].id

  depends_on = [aws_internet_gateway.main]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-nat"
  })
}


# -----------------------------------------------------------------------------
# PUBLIC ROUTE TABLE
# -----------------------------------------------------------------------------
# A route table is a list of directions: "to reach X, go through Y."
# Every subnet uses exactly one route table.
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-public-rt"
  })
}

# The actual routing rule for public subnets.
resource "aws_route" "public_internet" {
  route_table_id = aws_route_table.public.id

  # "0.0.0.0/0" means "every possible IP address in the world."
  # This is the default route: anything not local goes here.
  destination_cidr_block = "0.0.0.0/0"

  # Send it to the Internet Gateway (the front door).
  gateway_id = aws_internet_gateway.main.id
}

# Connect each public subnet to the public route table.
# Without this association, the subnet uses the VPC's default table
# (which has no internet route) and nothing works.
resource "aws_route_table_association" "public" {
  count = length(aws_subnet.public)

  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}


# -----------------------------------------------------------------------------
# PRIVATE ROUTE TABLE
# -----------------------------------------------------------------------------
# Same idea, but the default route points at the NAT Gateway instead
# of the Internet Gateway. That's what makes the subnet "private."
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-private-rt"
  })
}

resource "aws_route" "private_nat" {
  # Only create this route if we actually built a NAT Gateway.
  count = var.create_nat_gateway ? 1 : 0

  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"

  # nat_gateway_id, NOT gateway_id. Different argument for a different device.
  # [0] because the NAT gateway was created with count, making it a list.
  nat_gateway_id = aws_nat_gateway.main[0].id
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}


# -----------------------------------------------------------------------------
# VPC ENDPOINTS
# -----------------------------------------------------------------------------
# A VPC Endpoint is a private tunnel from your VPC directly to an AWS service,
# without going over the public internet at all.
#
# Why bother? Three reasons:
#   1. Security  - traffic never leaves Amazon's network
#   2. Speed     - fewer hops
#   3. Money     - S3 gateway endpoints are FREE and skip NAT data charges
#
# There are two flavors:
#   - Gateway endpoints (S3, DynamoDB only): free, work via route tables
#   - Interface endpoints (everything else): ~$7/month each, work via a
#     private IP address (an ENI) placed in your subnet

# --- S3 Gateway Endpoint (FREE) ---
# EC2 uses S3 behind the scenes for package downloads and SSM.
resource "aws_vpc_endpoint" "s3" {
  vpc_id = aws_vpc.main.id

  # The service name format is: com.amazonaws.<region>.<service>
  service_name = "com.amazonaws.${var.aws_region}.s3"

  # Gateway type = free, but only available for S3 and DynamoDB.
  vpc_endpoint_type = "Gateway"

  # Gateway endpoints work by ADDING A ROUTE to your route tables.
  # We attach it to the private table so private instances use it.
  route_table_ids = [aws_route_table.private.id]

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-s3-endpoint"
  })
}

# --- Interface Endpoints for SSM ---
# SSM (Systems Manager) is how we log into the EC2 box WITHOUT SSH and
# WITHOUT opening port 22 to the world. It is strictly better than SSH keys.
#
# SSM needs three separate endpoints to work. This is an AWS requirement.
locals {
  # A local value is like a variable you define inline. Good for lists
  # you use more than once.
  interface_endpoints = var.create_vpc_endpoints ? [
    "ssm",          # the main Systems Manager API
    "ssmmessages",  # the channel Session Manager uses for the shell
    "ec2messages",  # legacy channel the SSM agent still needs
    "kms",          # so the instance can talk to KMS privately
    "logs",         # so CloudWatch logs ship without touching the internet
  ] : []
}

resource "aws_vpc_endpoint" "interface" {
  # for_each loops over a set. Unlike count, it keys resources by NAME
  # instead of by number, so removing "kms" from the list doesn't
  # accidentally destroy and recreate "logs".
  # toset() converts our list into a set, which is what for_each wants.
  for_each = toset(local.interface_endpoints)

  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.aws_region}.${each.value}"
  vpc_endpoint_type = "Interface"

  # Put the endpoint's network card in our private subnets.
  subnet_ids = aws_subnet.private[*].id

  # The endpoint needs its own security group controlling who may use it.
  security_group_ids = [aws_security_group.vpc_endpoints.id]

  # This makes AWS's normal service DNS name (ssm.us-east-1.amazonaws.com)
  # secretly resolve to the private endpoint IP inside your VPC.
  # Without it, you'd have to change every URL in your code. Leave it on.
  private_dns_enabled = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-${each.value}-endpoint"
  })
}

# Security group controlling access TO the VPC endpoints.
resource "aws_security_group" "vpc_endpoints" {
  name_prefix = "${var.name_prefix}-vpce-"
  description = "Allow HTTPS from inside the VPC to the interface VPC endpoints"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTPS from anywhere inside this VPC only"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    # Only the VPC's own IP range. Not the internet.
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1" # -1 means "any protocol"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # create_before_destroy avoids an error where Terraform tries to delete
  # a security group that's still attached to something.
  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-vpce-sg"
  })
}
