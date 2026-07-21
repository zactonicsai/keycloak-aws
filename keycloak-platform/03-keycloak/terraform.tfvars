# =============================================================================
# PROJECT 03-KEYCLOAK - terraform.tfvars
# =============================================================================

# --- Where the upstream state files live ---
state_bucket       = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"
network_state_key  = "keycloak/dev/01-network/terraform.tfstate"
database_state_key = "keycloak/dev/02-database/terraform.tfstate"
aws_region         = "us-east-1"

# =============================================================================
# DATABASE MODE
# =============================================================================
# true  = use PostgreSQL from project 02 (apply 02 first). Data survives
#         instance replacement. This is the correct setting.
#
# false = embedded H2 on local disk. Skips project 02 entirely.
#         Every user and realm is DESTROYED when the ASG replaces the
#         instance, which it does on any health check failure.
use_rds = true

# =============================================================================
# CERTIFICATE
# =============================================================================
# No domain configured, so we use a self-signed certificate. Expect a browser
# warning; the connection is still encrypted, just not third-party verified.
use_acm_certificate = false
domain_name         = ""
hosted_zone_name    = ""
create_dns_records  = false

# --- With a real domain, use this instead: ---
# use_acm_certificate = true
# domain_name         = "keycloak.example.com"
# hosted_zone_name    = "example.com"
# create_dns_records  = true

enable_http_redirect       = true
enable_deletion_protection = false
restrict_admin_paths       = true

# =============================================================================
# COMPUTE
# =============================================================================
instance_type    = "t3.medium"
java_heap_size   = "1536m"
root_volume_size = 30


# =============================================================================
# KEYCLOAK
# =============================================================================
keycloak_version = "26.0.7"
admin_username   = "kcadmin"

# Ports must match project 01's security group rules.
keycloak_http_port       = 8080
keycloak_management_port = 9000

# =============================================================================
# REALM IMPORT
# =============================================================================
realm_name = "myrealm"

# Empty = look for ../realms/myrealm-realm.json
# Missing file = built-in default realm is generated, apply still succeeds.
# Check `terraform output realm_source` to see which was used.
realm_file_path = ""

registration_allowed = false
create_default_user  = true

default_client_redirect_uris = [
  "http://localhost:3000/*",
  "http://localhost:8080/*",
]
default_client_web_origins = [
  "http://localhost:3000",
  "http://localhost:8080",
]

# =============================================================================
# MONITORING
# =============================================================================
enable_cloudwatch_agent = true
log_retention_days      = 30


# =============================================================================
# FAILURE DETECTION
# =============================================================================
# There is no Auto Scaling Group, so a crashed instance stays crashed until
# someone acts. These make that visible.

# Alarm when the instance fails its EC2 status check.
enable_status_alarm = true

# Restart on new hardware if the underlying AWS host fails. Keeps the same
# instance ID, private IP, and volumes. Does NOT help if Keycloak itself
# crashes while the instance stays up.
enable_auto_recovery = true

# SNS topics to notify. Empty means the alarm turns red in the console but
# tells nobody. Add a topic ARN to actually get emailed.
alarm_sns_topic_arns = []
