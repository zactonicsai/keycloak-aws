# =============================================================================
# DATABASE MODULE - variables.tf
# =============================================================================

variable "name_prefix" {
  description = "Prefix for all database resource names"
  type        = string
}

# --- Inputs from project 01 (via terraform_remote_state) ---

variable "vpc_id" {
  description = "VPC ID from project 01"
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets from project 01. Need 2+ in different AZs."
  type        = list(string)

  validation {
    condition     = length(var.private_subnet_ids) >= 2
    error_message = "RDS requires at least 2 subnets in different availability zones, even for single-AZ."
  }
}

variable "keycloak_security_group_id" {
  description = <<-EOT
    The Keycloak instance security group, from project 01.

    We allow PostgreSQL FROM this group. Referencing a security group rather
    than an IP range means the rule keeps working as instances are replaced.
  EOT
  type = string
}

variable "ebs_kms_key_arn" {
  description = "KMS key from project 01, used to encrypt database storage"
  type        = string
}

variable "secrets_kms_key_arn" {
  description = "KMS key from project 01, used to encrypt the credentials secret"
  type        = string
}

# --- Engine and sizing ---

variable "engine_version" {
  description = <<-EOT
    PostgreSQL major version. Pin the MAJOR only (e.g. "16", not "16.3") so
    AWS can apply minor patches without Terraform trying to revert them.

    Keycloak 26 supports PostgreSQL 13 through 17.
  EOT
  type    = string
  default = "16"
}

variable "parameter_group_family" {
  description = "Must match the engine version, e.g. postgres16 for engine_version 16"
  type        = string
  default     = "postgres16"
}

variable "instance_class" {
  description = <<-EOT
    Database instance size.

    db.t4g.micro   (2 vCPU, 1 GB)  ~$12/mo  - dev, light testing
    db.t4g.small   (2 vCPU, 2 GB)  ~$25/mo  - small production
    db.t4g.medium  (2 vCPU, 4 GB)  ~$50/mo  - real production
    db.m6g.large   (2 vCPU, 8 GB)  ~$125/mo - heavy use

    t4g/m6g are Graviton (ARM) and cost ~20% less than Intel equivalents.
    Keycloak does not care about CPU architecture.
  EOT
  type    = string
  default = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Starting disk size in GB. Minimum 20 for PostgreSQL."
  type        = number
  default     = 20

  validation {
    condition     = var.allocated_storage >= 20
    error_message = "RDS PostgreSQL requires at least 20 GB."
  }
}

variable "max_allocated_storage" {
  description = <<-EOT
    Ceiling for storage autoscaling. RDS grows the disk automatically when
    it fills. Set 0 to disable autoscaling.

    NOTE: storage can grow but can NEVER shrink. Do not set this very high.
  EOT
  type    = number
  default = 100
}

# --- Credentials ---

variable "db_name" {
  description = "Name of the database Keycloak will use"
  type        = string
  default     = "keycloak"

  validation {
    # Postgres identifiers must start with a letter and contain only
    # letters, digits, and underscores.
    condition     = can(regex("^[a-zA-Z][a-zA-Z0-9_]*$", var.db_name))
    error_message = "db_name must start with a letter and contain only letters, numbers, and underscores."
  }
}

variable "db_username" {
  description = "Master username. Avoid 'postgres' and 'admin'; both are guessed first."
  type        = string
  default     = "kcdbadmin"

  validation {
    condition     = !contains(["postgres", "admin", "root", "rdsadmin"], lower(var.db_username))
    error_message = "Do not use postgres, admin, root, or rdsadmin. rdsadmin is reserved by AWS."
  }
}

variable "db_port" {
  description = "PostgreSQL port. 5432 is standard."
  type        = number
  default     = 5432
}

variable "secret_recovery_window_days" {
  description = "Days a deleted secret stays recoverable. 0 deletes immediately with no undo."
  type        = number
  default     = 7
}

# --- Availability and backups ---

variable "multi_az" {
  description = <<-EOT
    Keep a synchronous standby in a second availability zone with automatic
    failover in 60-120 seconds.

    THIS DOUBLES THE COST. Off for dev, on for production.
  EOT
  type    = bool
  default = false
}

variable "backup_retention_days" {
  description = <<-EOT
    Days to keep automated backups (0-35).

    0 DISABLES BACKUPS AND POINT-IN-TIME RECOVERY ENTIRELY. Never use 0
    for anything you would be upset to lose.
  EOT
  type    = number
  default = 7

  validation {
    condition     = var.backup_retention_days >= 0 && var.backup_retention_days <= 35
    error_message = "backup_retention_days must be between 0 and 35."
  }
}

variable "backup_window" {
  description = "Daily backup window in UTC, format HH:MM-HH:MM. Pick a quiet hour."
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  description = "Weekly patch window in UTC, format ddd:HH:MM-ddd:HH:MM. Must not overlap backup_window."
  type        = string
  default     = "sun:04:30-sun:05:30"
}

# --- Deletion safety ---

variable "deletion_protection" {
  description = "Block terraform destroy from deleting the database. TRUE for production."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = <<-EOT
    Skip the safety snapshot taken before deletion.

    true  = faster teardown, no snapshot, data gone forever (dev)
    false = a final snapshot is kept (production)
  EOT
  type    = bool
  default = true
}

variable "apply_immediately" {
  description = "Apply changes now instead of waiting for the maintenance window. May cause a restart."
  type        = bool
  default     = false
}

# --- Monitoring ---

variable "enable_log_exports" {
  description = "Ship PostgreSQL logs to CloudWatch Logs"
  type        = bool
  default     = true
}

variable "enable_performance_insights" {
  description = "Query-level performance data. The 7-day retention tier is free."
  type        = bool
  default     = false
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring interval in seconds. 0 disables. Valid: 0, 1, 5, 10, 15, 30, 60."
  type        = number
  default     = 0

  validation {
    condition     = contains([0, 1, 5, 10, 15, 30, 60], var.monitoring_interval)
    error_message = "monitoring_interval must be one of: 0, 1, 5, 10, 15, 30, 60."
  }
}

variable "slow_query_threshold_ms" {
  description = "Log queries slower than this many milliseconds. 1000 = 1 second."
  type        = number
  default     = 1000
}

variable "force_ssl" {
  description = "Require TLS for all database connections"
  type        = bool
  default     = true
}

variable "admin_access_cidrs" {
  description = <<-EOT
    CIDRs allowed to connect DIRECTLY to the database, bypassing the app.

    Leave EMPTY. Prefer SSM port forwarding through the Keycloak instance:

      aws ssm start-session --target <instance-id> \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters '{"host":["<db-endpoint>"],"portNumber":["5432"],"localPortNumber":["5432"]}'

    That gives you a local port 5432 with no inbound rule opened at all.
  EOT
  type    = list(string)
  default = []
}

variable "tags" {
  description = "Tags applied to all database resources"
  type        = map(string)
  default     = {}
}
