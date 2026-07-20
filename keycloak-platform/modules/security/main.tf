# =============================================================================
# SECURITY MODULE - main.tf
# =============================================================================
# A SECURITY GROUP is a firewall that wraps around a single resource.
#
# ANALOGY: think of it as a bouncer standing at the door of one specific
# building. The bouncer has a guest list. Anyone not on the list gets turned
# away. Each building (EC2 instance, load balancer) gets its own bouncer.
#
# TWO IMPORTANT RULES ABOUT SECURITY GROUPS:
#
#   1. They are DENY BY DEFAULT. If you don't write a rule allowing something,
#      it is blocked. You never write "deny" rules — you only write "allow."
#
#   2. They are STATEFUL. If you allow traffic IN, the reply is automatically
#      allowed back OUT, even with no matching egress rule. You don't have to
#      think about return traffic. (A Network ACL, the other AWS firewall type,
#      is stateless and does make you think about it. Security groups are
#      friendlier, which is why we use them.)
#
# THE LAYERED DESIGN HERE:
#
#   Your laptop (68.32.112.68)
#          |  only your IP allowed
#          v
#   [ALB Security Group]  <- lives in public subnets, faces the internet
#          |  only the ALB allowed
#          v
#   [EC2 Security Group]  <- lives in private subnets, no public IP at all
#
# Notice the second arrow does NOT mention your IP. The EC2 box doesn't know
# or care who you are. It only trusts the load balancer. This is called
# "defense in depth" — even if someone found the EC2 instance's private IP,
# they still could not reach it.
# =============================================================================


# -----------------------------------------------------------------------------
# LOCAL VALUES
# -----------------------------------------------------------------------------
# `locals` are named values computed once and reused. They keep us from
# repeating the same expression in five places and getting it wrong in one.
locals {
  # Convert the plain IP address into CIDR notation.
  #
  # WHAT IS CIDR? It's a way to describe a RANGE of IP addresses.
  # The number after the slash says how many bits are locked down.
  #   68.32.112.68/32  -> /32 locks all 32 bits -> EXACTLY ONE address
  #   68.32.112.0/24   -> locks 24 bits -> 256 addresses (68.32.112.0-255)
  #   0.0.0.0/0        -> locks nothing -> every address on earth
  #
  # We want /32 because we want exactly your machine and nothing else.
  admin_cidrs = [for ip in var.allowed_admin_ips : "${ip}/32"]

  # Merge the base tags with a marker showing these came from this module.
  common_tags = merge(var.tags, {
    Module = "security"
  })
}


# =============================================================================
# SECURITY GROUP 1: THE APPLICATION LOAD BALANCER
# =============================================================================
# This is the ONLY thing in the whole design that the public internet can
# touch, and even then only from your one IP address.
resource "aws_security_group" "alb" {
  # name_prefix (instead of name) lets Terraform generate a unique suffix.
  # This matters because of create_before_destroy below: to replace a security
  # group safely, Terraform must build the new one before deleting the old,
  # and two security groups cannot share a name.
  name_prefix = "${var.name_prefix}-alb-"

  # The description is REQUIRED by AWS and cannot be changed after creation.
  # Write something useful for the person reading this in six months.
  description = "Keycloak ALB - accepts HTTPS from approved admin IPs only"

  vpc_id = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-alb-sg"
    Tier = "public"
  })

  lifecycle {
    # Build the replacement before destroying the original. Without this,
    # changing a rule causes an error because AWS refuses to delete a
    # security group that is still attached to a load balancer.
    create_before_destroy = true
  }
}


# --- ALB INBOUND: HTTPS from your IP only ---
#
# NOTE ON STYLE: we use separate aws_vpc_security_group_ingress_rule resources
# instead of inline `ingress {}` blocks inside the security group.
#
# WHY? With inline blocks, Terraform treats the rule list as one big value.
# Adding one rule can cause it to delete and recreate ALL rules, briefly
# dropping traffic. Separate rule resources are managed individually, so
# adding a rule only adds a rule. This is the current recommended practice.
resource "aws_vpc_security_group_ingress_rule" "alb_https_from_admin" {
  # for_each over the admin CIDR list, so adding a second admin IP later
  # creates a second rule automatically without touching the first.
  #
  # toset() converts the list to a set. for_each requires a set or a map
  # because it needs stable, unique keys — not positions.
  for_each = toset(local.admin_cidrs)

  security_group_id = aws_security_group.alb.id

  # cidr_ipv4 is the SOURCE — who is allowed to connect.
  # each.value is the current item in the loop, e.g. "68.32.112.68/32".
  cidr_ipv4 = each.value

  # Port 443 is standard HTTPS. from_port and to_port define a RANGE;
  # setting both to 443 means exactly one port.
  from_port = 443
  ip_protocol = "tcp"
  to_port     = 443

  description = "HTTPS from approved admin IP ${each.value}"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-alb-https-${replace(each.value, "/", "-")}"
  })
}


# --- ALB INBOUND: HTTP from your IP (redirect only) ---
#
# Port 80 is plain, unencrypted HTTP. We allow it ONLY so that if you type
# "http://keycloak.example.com" by habit, the load balancer can catch it and
# bounce you to the https:// version instead of showing a dead page.
#
# No actual application traffic ever flows over port 80 — the listener's only
# job is to issue a redirect. See the ALB module.
#
# You can set enable_http_redirect = false to close port 80 entirely. That is
# marginally more secure and marginally more annoying.
resource "aws_vpc_security_group_ingress_rule" "alb_http_from_admin" {
  # This produces an empty set (creating nothing) when the flag is false.
  for_each = var.enable_http_redirect ? toset(local.admin_cidrs) : toset([])

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = each.value
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
  description       = "HTTP from ${each.value} - redirected to HTTPS, no app traffic"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-alb-http-${replace(each.value, "/", "-")}"
  })
}


# --- ALB OUTBOUND: to the Keycloak instance only ---
#
# By default a new security group has NO egress rules when you manage egress
# with separate resources, so we must explicitly allow the ALB to talk to
# the app. We deliberately do NOT allow the ALB to reach the open internet.
# A load balancer has no business making outbound calls anywhere else.
resource "aws_vpc_security_group_egress_rule" "alb_to_keycloak" {
  security_group_id = aws_security_group.alb.id

  # THIS IS THE IMPORTANT PART: instead of an IP range, the destination is
  # ANOTHER SECURITY GROUP. This is called a "security group reference."
  #
  # Why it's better than an IP: EC2 instances get new private IPs when they
  # are replaced. A hardcoded IP rule breaks the moment the instance is
  # recycled. A security group reference keeps working forever, because it
  # means "whatever machines are wearing that badge."
  referenced_security_group_id = aws_security_group.keycloak.id

  from_port   = var.keycloak_http_port
  ip_protocol = "tcp"
  to_port     = var.keycloak_http_port
  description = "Forward requests to Keycloak instances on the app port"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-alb-egress-app"
  })
}


# =============================================================================
# SECURITY GROUP 2: THE KEYCLOAK EC2 INSTANCE
# =============================================================================
# This instance sits in a private subnet with no public IP. Nothing on the
# internet can route to it. This security group is the second lock.
resource "aws_security_group" "keycloak" {
  name_prefix = "${var.name_prefix}-keycloak-"
  description = "Keycloak app server - accepts traffic from the ALB only"
  vpc_id      = var.vpc_id

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-keycloak-sg"
    Tier = "private"
  })

  lifecycle {
    create_before_destroy = true
  }
}


# --- KEYCLOAK INBOUND: from the ALB only ---
#
# Read this rule carefully, because it is the heart of the security model:
# the source is the ALB's security group, NOT your IP, NOT the VPC range.
#
# That means a request reaching Keycloak must have physically passed through
# the load balancer. There is no side door.
resource "aws_vpc_security_group_ingress_rule" "keycloak_from_alb" {
  security_group_id = aws_security_group.keycloak.id

  referenced_security_group_id = aws_security_group.alb.id

  from_port   = var.keycloak_http_port
  ip_protocol = "tcp"
  to_port     = var.keycloak_http_port
  description = "Application traffic from the ALB only"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-keycloak-ingress-alb"
  })
}


# --- KEYCLOAK INBOUND: health check port ---
#
# Keycloak exposes health endpoints (/health/ready, /health/live) on a
# separate management port, 9000, in recent versions. The ALB polls this
# to decide whether the instance is alive.
#
# If the health port and the app port are the same number, this rule would
# duplicate the one above and AWS would reject it, so we skip it in that case.
resource "aws_vpc_security_group_ingress_rule" "keycloak_health_from_alb" {
  count = var.keycloak_management_port != var.keycloak_http_port ? 1 : 0

  security_group_id            = aws_security_group.keycloak.id
  referenced_security_group_id = aws_security_group.alb.id

  from_port   = var.keycloak_management_port
  ip_protocol = "tcp"
  to_port     = var.keycloak_management_port
  description = "Health check probes from the ALB"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-keycloak-ingress-health"
  })
}


# --- KEYCLOAK OUTBOUND: HTTPS to anywhere ---
#
# The instance needs to reach out to:
#   - Amazon Linux package repos (to install Java and updates)
#   - the Keycloak download server on GitHub
#   - AWS APIs for Secrets Manager, KMS, SSM, and CloudWatch
#
# All of those are HTTPS on port 443. Traffic leaves through the NAT Gateway
# or, better, through the VPC endpoints we created in the network module.
#
# WHY NOT ALLOW ALL OUTBOUND (protocol "-1")? Because unrestricted egress is
# how compromised machines phone home to an attacker. Restricting outbound
# traffic limits the damage if something does get in. This is the single most
# commonly skipped security control in AWS setups.
resource "aws_vpc_security_group_egress_rule" "keycloak_https_out" {
  security_group_id = aws_security_group.keycloak.id

  cidr_ipv4   = "0.0.0.0/0"
  from_port   = 443
  ip_protocol = "tcp"
  to_port     = 443
  description = "HTTPS out for package installs and AWS API calls"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-keycloak-egress-https"
  })
}


# --- KEYCLOAK OUTBOUND: HTTP to anywhere ---
#
# Some Linux package mirrors still serve metadata over plain HTTP. Package
# contents are verified by GPG signature regardless, so this is acceptable.
# Set allow_http_egress = false if your package mirrors are all HTTPS.
resource "aws_vpc_security_group_egress_rule" "keycloak_http_out" {
  count = var.allow_http_egress ? 1 : 0

  security_group_id = aws_security_group.keycloak.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  ip_protocol       = "tcp"
  to_port           = 80
  description       = "HTTP out for OS package repository metadata"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-keycloak-egress-http"
  })
}


# --- KEYCLOAK OUTBOUND: DNS ---
#
# Before the instance can download anything, it has to turn a name like
# "github.com" into an IP address. That's DNS, and it runs on port 53.
#
# AWS provides a DNS server at the VPC's base address plus two. For a VPC of
# 10.0.0.0/16, that is 10.0.0.2.
#
# cidrhost() does that math for us instead of us hardcoding it wrong.
# DNS traditionally uses UDP, with TCP as a fallback for large responses,
# so we open both.
resource "aws_vpc_security_group_egress_rule" "keycloak_dns_udp" {
  security_group_id = aws_security_group.keycloak.id

  # "${...}/32" builds a single-address CIDR for the DNS resolver.
  cidr_ipv4   = "${cidrhost(var.vpc_cidr, 2)}/32"
  from_port   = 53
  ip_protocol = "udp"
  to_port     = 53
  description = "DNS lookups to the Amazon-provided VPC resolver"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-keycloak-egress-dns-udp"
  })
}

resource "aws_vpc_security_group_egress_rule" "keycloak_dns_tcp" {
  security_group_id = aws_security_group.keycloak.id
  cidr_ipv4         = "${cidrhost(var.vpc_cidr, 2)}/32"
  from_port         = 53
  ip_protocol       = "tcp"
  to_port           = 53
  description       = "DNS over TCP for oversized responses"

  tags = merge(local.common_tags, {
    Name = "${var.name_prefix}-keycloak-egress-dns-tcp"
  })
}


# =============================================================================
# A NOTE ON WHAT IS DELIBERATELY MISSING: PORT 22 (SSH)
# =============================================================================
# There is no SSH rule anywhere in this file. That is intentional.
#
# The old way: open port 22, manage a .pem key file, hope nobody loses it,
# hope nobody commits it to git, rotate it when someone leaves the team.
#
# The modern way: AWS Systems Manager Session Manager. You get a shell in the
# browser or through the CLI with:
#
#     aws ssm start-session --target i-0abc123...
#
# Advantages over SSH:
#   - No open inbound port at all. Nothing to port-scan.
#   - No key files to lose, leak, or rotate.
#   - Access is controlled by normal IAM permissions.
#   - Every session is logged to CloudTrail, and can be recorded to S3.
#
# The connection works because the SSM agent on the instance reaches OUT to
# AWS over HTTPS (allowed above), rather than AWS reaching in. That is why
# no inbound rule is needed.
#
# If you genuinely need SSH — a legacy tool, a debugging emergency — add it
# scoped to your IP only, and treat it as temporary:
#
#   resource "aws_vpc_security_group_ingress_rule" "ssh_break_glass" {
#     security_group_id = aws_security_group.keycloak.id
#     cidr_ipv4         = "68.32.112.68/32"   # never 0.0.0.0/0
#     from_port         = 22
#     ip_protocol       = "tcp"
#     to_port           = 22
#     description       = "TEMPORARY break-glass SSH - remove after debugging"
#   }
#
# Opening port 22 to 0.0.0.0/0 gets you found by automated scanners within
# minutes. This is not an exaggeration; the internet is scanned constantly.
# =============================================================================
