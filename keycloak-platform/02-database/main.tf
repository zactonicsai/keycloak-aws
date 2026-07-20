# =============================================================================
# PROJECT 02-DATABASE - main.tf
# =============================================================================
# THE DATA LAYER. Apply this second.
#
# WHY THE DATABASE GETS ITS OWN PROJECT:
#
#   1. DIFFERENT LIFECYCLE. Keycloak gets rebuilt constantly - new version,
#      new config, new AMI. The database should be rebuilt approximately
#      never. Separate state means `terraform destroy` in 03 physically
#      cannot delete your data, because the database is not in that state
#      file at all.
#
#   2. DIFFERENT RISK. A bad Keycloak plan is an inconvenience. A bad
#      database plan is a data loss incident. Separating them means you
#      read the database plan carefully because it is rare, instead of
#      skimming past it inside a 60-resource diff.
#
#   3. DIFFERENT SPEED. RDS takes 5-10 minutes to create and can take
#      20+ minutes to modify. Keeping it out of the Keycloak project means
#      Keycloak changes stay fast.
#
# THIS PROJECT IS OPTIONAL. If you set use_rds=false in project 03, Keycloak
# runs on an embedded H2 database and you can skip 02 entirely. That is fine
# for a throwaway test and wrong for anything you care about.
# =============================================================================

# -----------------------------------------------------------------------------
# READING PROJECT 01'S STATE
# -----------------------------------------------------------------------------
# THIS IS THE MECHANISM THAT CHAINS THE PROJECTS TOGETHER.
#
# A `terraform_remote_state` data source reads ANOTHER project's state file
# and exposes its outputs. It is read-only: this project can see project 01's
# VPC ID, but can never modify or delete anything project 01 owns.
#
# HOW IT DIFFERS FROM A MODULE:
#
#   module.network.vpc_id
#     -> both live in ONE state file, applied together
#
#   data.terraform_remote_state.network.outputs.vpc_id
#     -> SEPARATE state files, applied independently, read-only reference
#
# IMPORTANT: this reads only what project 01 EXPORTED as an output. If a
# value is not in project 01's outputs.tf, it is invisible here no matter
# what exists in its state.
data "terraform_remote_state" "network" {
  backend = "s3"

  # These MUST match project 01's backend.tf exactly, or you will read the
  # wrong state file - or, more confusingly, an empty one.
  config = {
    bucket = var.state_bucket
    key    = var.network_state_key
    region = var.aws_region
  }
}


locals {
  # Pull project 01's values into short local names so the rest of the file
  # stays readable. Without this, every reference is 60 characters long.
  net = data.terraform_remote_state.network.outputs

  name_prefix = local.net.name_prefix

  # Inherit project 01's tags, then override the Layer marker so resources
  # created here are identifiable as belonging to this project.
  common_tags = merge(local.net.common_tags, {
    Layer = "02-database"
  })
}


# =============================================================================
# THE DATABASE
# =============================================================================
module "database" {
  source = "../modules/database"

  name_prefix = local.name_prefix

  # --- Everything below comes from project 01's state ---
  vpc_id             = local.net.vpc_id
  private_subnet_ids = local.net.private_subnet_ids

  # The Keycloak security group. Note this exists even though project 03 has
  # not been applied yet - project 01 created it. That is exactly why the
  # security groups live in the network layer.
  keycloak_security_group_id = local.net.keycloak_security_group_id

  ebs_kms_key_arn     = local.net.ebs_kms_key_arn
  secrets_kms_key_arn = local.net.secrets_kms_key_arn

  # --- Sizing and engine ---
  engine_version         = var.engine_version
  parameter_group_family = var.parameter_group_family
  instance_class         = var.instance_class
  allocated_storage      = var.allocated_storage
  max_allocated_storage  = var.max_allocated_storage

  # --- Credentials ---
  db_name     = var.db_name
  db_username = var.db_username
  db_port     = var.db_port

  # --- Availability and backups ---
  multi_az              = var.multi_az
  backup_retention_days = var.backup_retention_days
  backup_window         = var.backup_window
  maintenance_window    = var.maintenance_window

  # --- Deletion safety ---
  deletion_protection = var.deletion_protection
  skip_final_snapshot = var.skip_final_snapshot
  apply_immediately   = var.apply_immediately

  # --- Monitoring ---
  enable_log_exports          = var.enable_log_exports
  enable_performance_insights = var.enable_performance_insights
  monitoring_interval         = var.monitoring_interval
  force_ssl                   = var.force_ssl

  admin_access_cidrs = var.admin_access_cidrs

  tags = local.common_tags
}
