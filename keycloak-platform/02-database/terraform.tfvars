# =============================================================================
# PROJECT 02-DATABASE - terraform.tfvars
# =============================================================================
# DEV SETTINGS. See the comments for what to change in production.
# =============================================================================

# --- Where project 01's state lives. Must match its backend.tf. ---
state_bucket      = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"
network_state_key = "keycloak/dev/01-network/terraform.tfstate"
aws_region        = "us-east-1"

# --- Engine ---
engine_version         = "16"
parameter_group_family = "postgres16"

# --- Sizing ---
# db.t4g.micro: 2 vCPU, 1 GB RAM, ~$12/month. Fine for dev and light testing.
# PROD: db.t4g.small (~$25/mo) or db.t4g.medium (~$50/mo).
instance_class        = "db.t4g.micro"
allocated_storage     = 20
max_allocated_storage = 100

# --- Credentials ---
db_name     = "keycloak"
db_username = "kcdbadmin"
db_port     = 5432

# --- Availability ---
# PROD: set true. Doubles the cost but gives automatic failover in ~60-120s.
multi_az = false

# --- Backups ---
# 7 days of automated backups plus point-in-time recovery.
# PROD: 30 is a common choice.
backup_retention_days = 7
backup_window         = "03:00-04:00"
maintenance_window    = "sun:04:30-sun:05:30"

# --- Deletion safety ---
# DEV: both settings favor easy teardown.
# PROD: deletion_protection = true AND skip_final_snapshot = false.
deletion_protection = false
skip_final_snapshot = true
apply_immediately   = false

# --- Monitoring ---
enable_log_exports          = true
enable_performance_insights = false
monitoring_interval         = 0
force_ssl                   = true

# Leave empty. Use SSM port forwarding for admin access instead of opening
# the database to an IP range.
admin_access_cidrs = []
