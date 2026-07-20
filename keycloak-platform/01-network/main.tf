# =============================================================================
# PROJECT 01-NETWORK - main.tf
# =============================================================================
# THE FOUNDATION LAYER. Apply this first; it depends on nothing.
#
# WHAT LIVES HERE AND WHY:
#
#   VPC, subnets, routes, NAT, endpoints
#     Obvious - this is the network project.
#
#   KMS KEYS
#     Both the database (02) and Keycloak (03) need encryption keys. If the
#     keys lived in 03, then 02 would have to depend on 03, which inverts
#     the whole order. Shared things belong in the layer everything else
#     depends on.
#
#   SECURITY GROUPS for the ALB and the Keycloak instance
#     Same reasoning. The database project needs to reference the Keycloak
#     security group to write a rule saying "allow Postgres from these
#     instances." That reference must resolve before 03 has even been
#     applied, so the group has to exist here.
#
# THE RULE OF THUMB: a resource belongs in the LOWEST layer that any other
# layer needs it from. Things change less often the lower they sit.
# =============================================================================

locals {
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = merge(var.additional_tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"

    # Records WHICH of the three projects created this resource. When you
    # are staring at a resource in the AWS console six months from now,
    # this tag tells you which folder to edit.
    Layer = "01-network"
  })
}

# Ask AWS which availability zones this account can actually use, rather
# than hardcoding "us-east-1a" and hoping.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name = "opt-in-status"
    # Skip Local Zones and Wavelength Zones, which need explicit opt-in.
    values = ["opt-in-not-required"]
  }
}


# =============================================================================
# THE VPC AND EVERYTHING IN IT
# =============================================================================
module "network" {
  source = "../modules/network"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region

  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  # Take the first two zones. Two is the minimum an ALB requires, and it is
  # also what RDS needs for a subnet group.
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)

  create_nat_gateway   = var.create_nat_gateway
  create_vpc_endpoints = var.create_vpc_endpoints

  tags = local.common_tags
}


# =============================================================================
# ENCRYPTION KEYS (shared with projects 02 and 03)
# =============================================================================
module "kms" {
  source = "../modules/kms"

  name_prefix             = local.name_prefix
  deletion_window_in_days = var.kms_deletion_window_days

  tags = local.common_tags
}


# =============================================================================
# SECURITY GROUPS (shared with projects 02 and 03)
# =============================================================================
# Creates two groups:
#   - the ALB group, locked to your admin IPs
#   - the Keycloak instance group, which only accepts traffic from the ALB
#
# Project 02 references the Keycloak group when it writes the database rule.
# Project 03 attaches both groups to the resources it creates.
module "security" {
  source = "../modules/security"

  name_prefix = local.name_prefix

  vpc_id   = module.network.vpc_id
  vpc_cidr = module.network.vpc_cidr

  # THE IP RESTRICTION. Only these addresses reach the load balancer.
  allowed_admin_ips = var.allowed_admin_ips

  keycloak_http_port       = var.keycloak_http_port
  keycloak_management_port = var.keycloak_management_port
  enable_http_redirect     = var.enable_http_redirect

  tags = local.common_tags
}
