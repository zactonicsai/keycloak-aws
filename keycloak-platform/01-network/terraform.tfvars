# =============================================================================
# PROJECT 01-NETWORK - terraform.tfvars
# =============================================================================
# Safe to commit: contains no secrets, only your IP address.
# =============================================================================

# --- Identity. THESE THREE MUST MATCH in all three projects. ---
project_name = "keycloak"
environment  = "dev"
aws_region   = "us-east-1"

# =============================================================================
# YOUR IP ADDRESS - the security perimeter
# =============================================================================
# Only these addresses can reach Keycloak. Check yours with: curl ifconfig.me
allowed_admin_ips = [
  "68.32.112.68", # primary admin workstation
]

# --- Network layout ---
vpc_cidr             = "10.0.0.0/16"
public_subnet_cidrs  = ["10.0.1.0/24", "10.0.2.0/24"]
private_subnet_cidrs = ["10.0.11.0/24", "10.0.12.0/24"]

# Required: the private instance needs outbound internet to install Keycloak.
# ~$32.85/month.
create_nat_gateway = true

# ~$73/month (5 endpoints x 2 AZs x $0.01/hr). Set false to save that in dev;
# SSM and KMS still work over the NAT gateway.
create_vpc_endpoints = true

# --- Ports. Must match project 03. ---
keycloak_http_port       = 8080
keycloak_management_port = 9000
enable_http_redirect     = true

# Short window in dev so test keys clean up fast. Use 30 in production.
kms_deletion_window_days = 7
