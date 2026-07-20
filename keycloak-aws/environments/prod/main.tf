# =============================================================================
# DEV ENVIRONMENT - main.tf
# =============================================================================
# This is the ROOT MODULE. It is the file you actually run terraform against.
#
# Notice it creates almost nothing directly. Its job is to wire the modules
# together: take the outputs of one and feed them into the inputs of the next.
#
# THE DEPENDENCY CHAIN:
#
#   network  ──> gives us a VPC and subnets
#      │
#      ├──> security ──> needs the VPC, produces firewall rules
#      │        │
#      │        ├──> alb ──> needs public subnets + the ALB security group
#      │        │      │
#      │        │      └──> produces the target group
#      │        │
#   kms ───────────────> produces encryption keys
#            │           │
#            └───────────┴──> compute ──> needs private subnets, the app
#                                          security group, the target group,
#                                          and both KMS keys
#
# Terraform works this order out automatically from the references. You never
# write the order down; it reads it from the data flow.
# =============================================================================


# -----------------------------------------------------------------------------
# LOCAL VALUES
# -----------------------------------------------------------------------------
locals {
  # One prefix used by every module, so all resources share a naming scheme.
  name_prefix = "${var.project_name}-${var.environment}"

  # Tags applied to literally everything. This is not busywork:
  #   - Environment lets you filter dev from prod in the console
  #   - ManagedBy warns humans not to hand-edit these resources
  #   - CostCenter makes the AWS bill breakdown actually useful
  common_tags = merge(var.additional_tags, {
    Project     = var.project_name
    Environment = var.environment
    ManagedBy   = "terraform"
    Repository  = var.repository_url
  })

  # If no domain was configured, users reach Keycloak at the ALB's own
  # AWS-generated DNS name. We can't know that name until the ALB exists,
  # so we read it back out of the alb module.
  keycloak_url = var.domain_name != "" ? "https://${var.domain_name}" : "https://${module.alb.alb_dns_name}"
}


# -----------------------------------------------------------------------------
# LOOK UP AVAILABILITY ZONES
# -----------------------------------------------------------------------------
# Rather than hardcoding "us-east-1a", ask AWS which zones this account can
# actually use. Not every account has access to every zone, and hardcoding
# one that you can't use produces a confusing failure.
data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name = "opt-in-status"
    # Skip Local Zones and Wavelength Zones, which need explicit opt-in
    # and don't support all services.
    values = ["opt-in-not-required"]
  }
}


# =============================================================================
# MODULE 1: NETWORK
# =============================================================================
module "network" {
  # source tells Terraform where the module code lives.
  # "../../modules/network" is a relative path: up two folders, then down.
  source = "../../modules/network"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region

  vpc_cidr             = var.vpc_cidr
  public_subnet_cidrs  = var.public_subnet_cidrs
  private_subnet_cidrs = var.private_subnet_cidrs

  # slice() takes a portion of a list: slice(list, from, to).
  # We take the first two zones. This guarantees the ALB gets its required
  # two AZs without hardcoding zone names.
  availability_zones = slice(data.aws_availability_zones.available.names, 0, 2)

  create_nat_gateway   = var.create_nat_gateway
  create_vpc_endpoints = var.create_vpc_endpoints

  tags = local.common_tags
}


# =============================================================================
# MODULE 2: KMS
# =============================================================================
module "kms" {
  source = "../../modules/kms"

  name_prefix = local.name_prefix

  # Short window in dev so you can clean up test keys quickly.
  # Production should use 30.
  deletion_window_in_days = var.kms_deletion_window_days

  tags = local.common_tags
}


# =============================================================================
# MODULE 3: SECURITY GROUPS
# =============================================================================
module "security" {
  source = "../../modules/security"

  name_prefix = local.name_prefix

  # These two values come from the network module's outputs. Writing
  # module.network.vpc_id here is what tells Terraform "build the network
  # first." That is the entire dependency mechanism.
  vpc_id   = module.network.vpc_id
  vpc_cidr = module.network.vpc_cidr

  # THIS IS THE IP RESTRICTION. Only addresses in this list can reach
  # the load balancer at all.
  allowed_admin_ips = var.allowed_admin_ips

  keycloak_http_port       = var.keycloak_http_port
  keycloak_management_port = var.keycloak_management_port
  enable_http_redirect     = var.enable_http_redirect

  tags = local.common_tags
}


# =============================================================================
# MODULE 4: LOAD BALANCER, CERTIFICATE, TARGET GROUP
# =============================================================================
module "alb" {
  source = "../../modules/alb"

  name_prefix = local.name_prefix

  vpc_id                = module.network.vpc_id
  public_subnet_ids     = module.network.public_subnet_ids
  alb_security_group_id = module.security.alb_security_group_id

  # Certificate settings.
  use_acm_certificate       = var.use_acm_certificate
  domain_name               = var.domain_name
  hosted_zone_name          = var.hosted_zone_name
  subject_alternative_names = var.subject_alternative_names
  create_dns_records        = var.create_dns_records

  keycloak_http_port       = var.keycloak_http_port
  keycloak_management_port = var.keycloak_management_port

  enable_http_redirect       = var.enable_http_redirect
  enable_deletion_protection = var.enable_deletion_protection

  # The listener rule blocking admin paths reuses the same CIDR list the
  # security group uses, so the two layers can never drift apart.
  restrict_admin_paths = var.restrict_admin_paths
  allowed_admin_cidrs  = module.security.admin_cidrs

  tags = local.common_tags
}


# =============================================================================
# MODULE 5: EC2 AND KEYCLOAK
# =============================================================================
module "compute" {
  source = "../../modules/compute"

  name_prefix = local.name_prefix

  private_subnet_ids         = module.network.private_subnet_ids
  keycloak_security_group_id = module.security.keycloak_security_group_id
  target_group_arn           = module.alb.target_group_arn

  ebs_kms_key_arn     = module.kms.ebs_key_arn
  secrets_kms_key_arn = module.kms.secrets_key_arn

  instance_type    = var.instance_type
  java_heap_size   = var.java_heap_size
  root_volume_size = var.root_volume_size

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  keycloak_version         = var.keycloak_version
  keycloak_http_port       = var.keycloak_http_port
  keycloak_management_port = var.keycloak_management_port

  # The public URL. Uses the domain if set, otherwise the ALB's DNS name.
  # This value ends up inside tokens, so it must match what users type.
  keycloak_hostname = local.keycloak_url

  admin_username = var.admin_username
  db_vendor      = var.db_vendor

  # --- Realm import ---
  # If realm_file_path is empty, the module looks for
  # realms/<realm_name>-realm.json. If that is missing too, it falls back
  # to the built-in default realm instead of erroring out.
  realm_name      = var.realm_name
  realm_file_path = var.realm_file_path

  # These only apply when the DEFAULT realm is used.
  registration_allowed         = var.registration_allowed
  create_default_user          = var.create_default_user
  default_client_redirect_uris = var.default_client_redirect_uris
  default_client_web_origins   = var.default_client_web_origins

  enable_cloudwatch_agent = var.enable_cloudwatch_agent
  log_retention_days      = var.log_retention_days

  tags = local.common_tags
}
