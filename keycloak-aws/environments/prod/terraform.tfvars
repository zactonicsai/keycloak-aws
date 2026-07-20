# =============================================================================
# PRODUCTION - terraform.tfvars
# =============================================================================
# Differences from dev are marked "PROD:" and explained.
# Read the "Going to Production" section of the README before using this.
# =============================================================================

project_name = "keycloak"
environment  = "prod"
aws_region   = "us-east-1"

# --- Access control ---
# PROD: usually a corporate VPN or office egress IP, not a home connection.
allowed_admin_ips = [
  "68.32.112.68",
]
restrict_admin_paths = true

# --- Certificate ---
# PROD: a real certificate. Self-signed is not acceptable in production —
# users are trained to click through warnings, which is exactly the habit
# that makes phishing work.
#
# REQUIRES: a domain whose name servers point at your Route 53 hosted zone.
use_acm_certificate = true
domain_name         = "keycloak.example.com" # <-- CHANGE THIS
hosted_zone_name    = "example.com"          # <-- CHANGE THIS
create_dns_records  = true

enable_http_redirect = true

# PROD: refuse to let terraform destroy delete the load balancer.
enable_deletion_protection = true

# --- Network ---
# PROD: a different CIDR from dev, so the two can be VPC-peered later
# without overlapping address ranges.
vpc_cidr             = "10.10.0.0/16"
public_subnet_cidrs  = ["10.10.1.0/24", "10.10.2.0/24"]
private_subnet_cidrs = ["10.10.11.0/24", "10.10.12.0/24"]

create_nat_gateway   = true
create_vpc_endpoints = true

# --- Compute ---
# PROD: m6i.large instead of t3. Burstable t3 instances earn CPU credits
# while idle and spend them under load; run out and you are throttled hard.
# m6i gives consistent performance with no credit system.
instance_type    = "m6i.large"
java_heap_size   = "4g"
root_volume_size = 50

min_size         = 1
max_size         = 1
desired_capacity = 1

# --- Keycloak ---
keycloak_version = "26.0.7"
admin_username   = "kcadmin"

# PROD: THIS MUST CHANGE TO postgres BEFORE REAL USE.
#
# dev-file stores everything in an embedded H2 database on the instance disk.
# When the ASG replaces the instance — which it will, on any health check
# failure or template change — EVERY USER, REALM, AND SESSION IS LOST.
#
# Set up an RDS PostgreSQL instance and switch this. Left as dev-file here
# only so the file is runnable as a starting point.
db_vendor = "dev-file" # <-- CHANGE TO "postgres"

# --- Realm ---
realm_name      = "production"
realm_file_path = ""

registration_allowed = false
create_default_user  = false # PROD: no seeded test accounts

default_client_redirect_uris = [
  "https://app.example.com/*", # <-- CHANGE THIS
]
default_client_web_origins = [
  "https://app.example.com", # <-- CHANGE THIS
]

# --- Monitoring ---
enable_cloudwatch_agent = true

# PROD: longer retention. Many compliance frameworks require 90 days or more.
log_retention_days = 90

# PROD: maximum recovery window on KMS keys. Deleting a key destroys every
# piece of data it protects, permanently.
kms_deletion_window_days = 30
