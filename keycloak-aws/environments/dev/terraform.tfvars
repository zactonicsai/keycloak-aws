# =============================================================================
# DEV ENVIRONMENT - terraform.tfvars
# =============================================================================
# This file holds the ACTUAL VALUES. Terraform loads it automatically.
#
# SECURITY NOTE: this file is safe to commit as written, because it contains
# no secrets. If you ever put a password or key in here, add it to .gitignore
# immediately. Better still, never put secrets in tfvars at all — this stack
# generates the admin password and stores it in Secrets Manager for exactly
# that reason.
# =============================================================================

# --- Project identity ---
project_name = "keycloak"
environment  = "dev"
aws_region   = "us-east-1"

# =============================================================================
# ACCESS CONTROL - YOUR IP ADDRESS
# =============================================================================
# This is the whole security perimeter. Only these addresses can reach
# Keycloak; every other packet on the internet is dropped at the ALB.
#
# Write bare addresses. Do NOT add /32 — the module appends it.
#
# TO FIND YOUR CURRENT IP:  curl ifconfig.me
#
# IF KEYCLOAK STOPS LOADING ONE DAY, check this first. Home ISPs hand out
# dynamic addresses that change every few weeks. Update the list and re-apply.
allowed_admin_ips = [
  "68.32.112.68", # primary admin workstation
  # "203.0.113.45",  # add a second address here if you need one
]

# Also enforce the restriction at the HTTP layer, independently of the
# security group. Two locks, so one bad edit does not open the door.
restrict_admin_paths = true

# =============================================================================
# CERTIFICATE SETTINGS
# =============================================================================
# Currently set for NO DOMAIN, which is the quickest way to get running.
# You will get a browser warning about the certificate. That is expected;
# the connection is still encrypted, it just is not third-party verified.
use_acm_certificate = false
domain_name         = ""
hosted_zone_name    = ""
create_dns_records  = false

# --- WHEN YOU HAVE A REAL DOMAIN, swap to this instead: ---
# use_acm_certificate = true
# domain_name         = "keycloak.example.com"
# hosted_zone_name    = "example.com"
# create_dns_records  = true

# Redirect anyone who types http:// over to https://
enable_http_redirect = true

# Keep false in dev so `terraform destroy` actually works.
enable_deletion_protection = false

# =============================================================================
# NETWORK
# =============================================================================
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]

# REQUIRED as configured. The instance sits in a private subnet and needs
# outbound internet access to download Keycloak from GitHub.
# Cost: roughly $32/month.
create_nat_gateway = true

# Interface endpoints for SSM, KMS, and CloudWatch Logs. Roughly $7/month
# each. Set false to save money in dev; you lose private-path access to
# those services but everything still works over the NAT gateway.
create_vpc_endpoints = true

# =============================================================================
# COMPUTE SIZING
# =============================================================================
# t3.medium gives 2 vCPU and 4GB RAM, which is the realistic minimum for
# Keycloak. t3.small (2GB) technically boots but thrashes under any load.
instance_type = "t3.medium"

# Java heap at roughly half the instance memory, leaving room for the OS
# and the JVM's own non-heap overhead.
java_heap_size = "1536m"

root_volume_size = 30

# Exactly one instance. The ASG still replaces it automatically if it dies.
min_size         = 1
max_size         = 1
desired_capacity = 1

# =============================================================================
# KEYCLOAK APPLICATION
# =============================================================================
keycloak_version = "26.0.7"

# Not "admin". Attackers try that username first, every time.
admin_username = "kcadmin"

# dev-file stores data in an embedded H2 database on the instance disk.
# THE DATA IS LOST when the instance is replaced. That is acceptable for
# testing and unacceptable for production — switch to postgres with RDS.
db_vendor = "dev-file"

# =============================================================================
# REALM IMPORT
# =============================================================================
# The realm is your isolated tenant: its own users, login page, and apps.
realm_name = "myrealm"

# Leave EMPTY to use the automatic path: realms/myrealm-realm.json
#
# THE FALLBACK BEHAVIOR YOU ASKED FOR:
#   file present -> imported as-is
#   file missing -> a sensible default realm is generated instead
#
# Either way the apply succeeds. Check the `realm_source` output afterwards
# to see which path was taken.
realm_file_path = ""

# --- These apply ONLY when the default realm is used ---
registration_allowed = false # do not let strangers self-register
create_default_user  = true  # seed a test account to log in with

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

# Short window in dev so test keys can be cleaned up quickly.
# Production should use 30.
kms_deletion_window_days = 7
