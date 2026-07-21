# =============================================================================
# terraform.tfvars - your settings
# =============================================================================
# Safe to commit: no secrets here, just your IP.
# =============================================================================

name   = "keycloak"
region = "us-east-1"

# =============================================================================
# YOUR IP - the entire security perimeter
# =============================================================================
# Only these addresses can reach Keycloak. Check yours: curl ifconfig.me
my_ips = [
  "68.32.112.68",
]

# --- Instance ---
instance_type = "t3.medium" # 4 GB RAM; t3.small will struggle
disk_size     = 20

# --- Keycloak ---
keycloak_version = "26.0.7"
admin_username   = "kcadmin" # not "admin"
realm_name       = "myrealm"

# --- Default realm client (ignored if you supply your own realm file) ---
redirect_uris = ["http://localhost:3000/*", "http://localhost:8080/*"]
web_origins   = ["http://localhost:3000", "http://localhost:8080"]
