# =============================================================================
# PROJECT 03-KEYCLOAK - main.tf
# =============================================================================
# THE APPLICATION LAYER. Apply this last.
#
# This is the DISPOSABLE layer. Everything here can be destroyed and rebuilt
# in about 10 minutes without losing data, because the data lives in project
# 02 and the network lives in project 01.
#
# That is the whole point of the split: you can iterate on Keycloak freely
# without ever putting your VPC or your database at risk.
#
# WHAT THIS PROJECT READS:
#   from 01-network:  VPC, subnets, KMS keys, security groups
#   from 02-database: DB host, port, name, and the credentials SECRET ARN
#
# The database PASSWORD is deliberately not among them. We receive only the
# ARN; the instance fetches the actual value from Secrets Manager at boot.
# Terraform state stores outputs in plaintext, so keeping the password out
# of state means it exists in exactly one place instead of three.
# =============================================================================

# -----------------------------------------------------------------------------
# READ PROJECT 01'S STATE (required)
# -----------------------------------------------------------------------------
data "terraform_remote_state" "network" {
  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.network_state_key
    region = var.aws_region
  }
}

# -----------------------------------------------------------------------------
# READ PROJECT 02'S STATE (optional)
# -----------------------------------------------------------------------------
# count makes this conditional. With use_rds = false, the data source is
# never created and project 02 does not need to exist at all - Keycloak
# falls back to the embedded H2 database.
#
# This is what lets you deploy 01 -> 03 and skip 02 for a quick test.
data "terraform_remote_state" "database" {
  count = var.use_rds ? 1 : 0

  backend = "s3"

  config = {
    bucket = var.state_bucket
    key    = var.database_state_key
    region = var.aws_region
  }
}


locals {
  net = data.terraform_remote_state.network.outputs

  # try() returns the first expression that works. When use_rds is false the
  # list is empty and [0] would error, so we fall back to an empty object.
  db = var.use_rds ? data.terraform_remote_state.database[0].outputs : null

  name_prefix = local.net.name_prefix

  common_tags = merge(local.net.common_tags, {
    Layer = "03-keycloak"
  })

  # The public URL users type. Falls back to the ALB's own DNS name when no
  # custom domain is set. This value gets baked into tokens and redirect
  # URLs, so it must match what is actually in the browser address bar.
  keycloak_url = var.domain_name != "" ? "https://${var.domain_name}" : "https://${module.alb.alb_dns_name}"

  # Database wiring. All empty strings when running on H2, which is what
  # the compute module checks to decide which path to take.
  db_secret_arn = var.use_rds ? local.db.db_secret_arn : ""
  db_host       = var.use_rds ? local.db.db_address : ""
  db_port       = var.use_rds ? local.db.db_port : 5432
  db_name       = var.use_rds ? local.db.db_name : "keycloak"
}


# =============================================================================
# LOAD BALANCER, CERTIFICATE, TARGET GROUP
# =============================================================================
module "alb" {
  source = "../modules/alb"

  name_prefix = local.name_prefix

  # From project 01.
  vpc_id                = local.net.vpc_id
  public_subnet_ids     = local.net.public_subnet_ids
  alb_security_group_id = local.net.alb_security_group_id

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

  # Reuse project 01's admin CIDRs for the listener rules, so the two
  # layers of IP restriction can never drift apart.
  restrict_admin_paths = var.restrict_admin_paths
  allowed_admin_cidrs  = local.net.admin_cidrs

  tags = local.common_tags
}


# =============================================================================
# EC2, IAM, SECRETS, REALM IMPORT
# =============================================================================
module "compute" {
  source = "../modules/compute"

  name_prefix = local.name_prefix

  # From project 01.
  private_subnet_ids         = local.net.private_subnet_ids
  keycloak_security_group_id = local.net.keycloak_security_group_id
  ebs_kms_key_arn            = local.net.ebs_kms_key_arn
  secrets_kms_key_arn        = local.net.secrets_kms_key_arn

  # From this project's ALB.
  target_group_arn = module.alb.target_group_arn

  # --- Database, from project 02 (or empty for H2) ---
  db_secret_arn = local.db_secret_arn
  db_host       = local.db_host
  db_port       = local.db_port
  db_name       = local.db_name

  # db_vendor is only consulted when db_secret_arn is empty. When RDS is in
  # use the boot script writes db=postgres regardless of this value.
  db_vendor = var.use_rds ? "postgres" : "dev-file"

  # --- Instance sizing ---
  instance_type    = var.instance_type
  java_heap_size   = var.java_heap_size
  root_volume_size = var.root_volume_size

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  # --- Boot timing ---
  # health_check_grace_period must exceed the full install, or the ASG kills
  # instances mid-boot and loops. wait_for_capacity_timeout only controls how
  # long `terraform apply` watches; set it to "0" for fast applies.
  health_check_grace_period = var.health_check_grace_period
  wait_for_capacity_timeout = var.wait_for_capacity_timeout

  # --- Keycloak application ---
  keycloak_version         = var.keycloak_version
  keycloak_http_port       = var.keycloak_http_port
  keycloak_management_port = var.keycloak_management_port
  keycloak_hostname        = local.keycloak_url
  admin_username           = var.admin_username

  # --- Realm import ---
  # If realm_file_path is empty the module looks for
  # ../realms/<realm_name>-realm.json. Missing file = built-in default,
  # never a failure. Check the realm_source output to see which you got.
  realm_name      = var.realm_name
  realm_file_path = var.realm_file_path

  registration_allowed         = var.registration_allowed
  create_default_user          = var.create_default_user
  default_client_redirect_uris = var.default_client_redirect_uris
  default_client_web_origins   = var.default_client_web_origins

  enable_cloudwatch_agent = var.enable_cloudwatch_agent
  log_retention_days      = var.log_retention_days

  tags = local.common_tags
}
