# =============================================================================
# PROJECT 02-DATABASE - variables.tf
# =============================================================================

# --- Where to find project 01's state ---

variable "state_bucket" {
  description = "S3 bucket holding all three state files. Must match project 01's backend."
  type        = string
  default     = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"
}

variable "network_state_key" {
  description = "Path to project 01's state file inside the bucket"
  type        = string
  default     = "keycloak/dev/01-network/terraform.tfstate"
}

variable "aws_region" {
  description = "AWS region. Must match project 01."
  type        = string
  default     = "us-east-1"
}

# --- Engine and sizing ---

variable "engine_version" {
  description = "PostgreSQL major version. Pin the major only so AWS can patch minors."
  type        = string
  default     = "16"
}

variable "parameter_group_family" {
  description = "Must line up with engine_version, e.g. postgres16"
  type        = string
  default     = "postgres16"
}

variable "instance_class" {
  description = "db.t4g.micro (~$12/mo) for dev, db.t4g.small (~$25/mo) or larger for production"
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Starting disk size in GB. Minimum 20."
  type        = number
  default     = 20
}

variable "max_allocated_storage" {
  description = "Autoscaling ceiling in GB. Storage can grow but never shrink. 0 disables."
  type        = number
  default     = 100
}

# --- Credentials ---

variable "db_name" {
  description = "Database name Keycloak connects to"
  type        = string
  default     = "keycloak"
}

variable "db_username" {
  description = "Master username. Not 'postgres' or 'admin'."
  type        = string
  default     = "kcdbadmin"
}

variable "db_port" {
  description = "PostgreSQL port"
  type        = number
  default     = 5432
}

# --- Availability and backups ---

variable "multi_az" {
  description = "Synchronous standby in a second AZ. DOUBLES THE COST. False for dev."
  type        = bool
  default     = false
}

variable "backup_retention_days" {
  description = "Days of automated backups. 0 disables backups AND point-in-time recovery."
  type        = number
  default     = 7
}

variable "backup_window" {
  description = "Daily backup window, UTC, HH:MM-HH:MM"
  type        = string
  default     = "03:00-04:00"
}

variable "maintenance_window" {
  description = "Weekly patch window, UTC. Must not overlap backup_window."
  type        = string
  default     = "sun:04:30-sun:05:30"
}

# --- Deletion safety ---

variable "deletion_protection" {
  description = "Block terraform destroy. TRUE for production."
  type        = bool
  default     = false
}

variable "skip_final_snapshot" {
  description = "Skip the safety snapshot on delete. True for dev, FALSE for production."
  type        = bool
  default     = true
}

variable "apply_immediately" {
  description = "Apply changes now rather than in the maintenance window. May force a restart."
  type        = bool
  default     = false
}

# --- Monitoring ---

variable "enable_log_exports" {
  description = "Ship PostgreSQL logs to CloudWatch"
  type        = bool
  default     = true
}

variable "enable_performance_insights" {
  description = "Query-level performance data. 7-day retention is free."
  type        = bool
  default     = false
}

variable "monitoring_interval" {
  description = "Enhanced Monitoring seconds. 0 disables. Valid: 0,1,5,10,15,30,60."
  type        = number
  default     = 0
}

variable "force_ssl" {
  description = "Require TLS on all database connections"
  type        = bool
  default     = true
}

variable "admin_access_cidrs" {
  description = "CIDRs allowed direct DB access. Leave empty; use SSM port forwarding instead."
  type        = list(string)
  default     = []
}
