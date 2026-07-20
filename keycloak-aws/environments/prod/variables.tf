# =============================================================================
# DEV ENVIRONMENT - variables.tf
# =============================================================================
# Actual VALUES go in terraform.tfvars. This file only declares what exists,
# what type it is, and what the default is.
# =============================================================================

# --- Project identity ---

variable "project_name" {
  description = "Short project name used in every resource name. Keep it under 12 characters."
  type        = string
  default     = "keycloak"

  validation {
    condition     = length(var.project_name) <= 12
    error_message = "project_name must be 12 characters or fewer; AWS caps ALB names at 32."
  }
}

variable "environment" {
  description = "Environment name: dev, staging, or prod"
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "repository_url" {
  description = "Where this code lives, tagged onto resources so people can find the source"
  type        = string
  default     = "https://github.com/your-org/keycloak-aws"
}

variable "additional_tags" {
  description = "Extra tags merged into the standard set"
  type        = map(string)
  default     = {}
}

# --- Network ---

variable "vpc_cidr" {
  description = "IP range for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet ranges (for the load balancer)"
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet ranges (for the Keycloak instance)"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "create_nat_gateway" {
  description = <<-EOT
    Build a NAT Gateway so the private instance can download Keycloak.

    COST: about $32/month plus data transfer. This is the single most
    expensive item in this stack.

    You need it as written, because the instance is in a private subnet
    and must reach GitHub to download Keycloak. Setting this to false
    without other changes gives you an instance that cannot install
    anything and will fail health checks forever.
  EOT
  type        = bool
  default     = true
}

variable "create_vpc_endpoints" {
  description = "Build interface endpoints for SSM/KMS/Logs. ~$7/mo each, but keeps traffic off the internet."
  type        = bool
  default     = true
}

# --- ACCESS CONTROL ---

variable "allowed_admin_ips" {
  description = <<-EOT
    THE MOST IMPORTANT VARIABLE IN THIS FILE.

    Only these IP addresses can reach Keycloak at all. Everyone else is
    dropped at the load balancer.

    Give bare addresses with no /32 suffix; the module adds it.

    Find your current IP with:  curl ifconfig.me

    HEADS UP: most home internet connections get a new IP every few weeks.
    If Keycloak suddenly stops loading, this is almost always why.
  EOT
  type        = list(string)
}

variable "restrict_admin_paths" {
  description = "Also block /admin at the ALB listener level, as a second independent layer"
  type        = bool
  default     = true
}

# --- Certificate and DNS ---

variable "use_acm_certificate" {
  description = <<-EOT
    true  = real ACM certificate. Requires a domain in Route 53. No browser
            warnings. Free and auto-renewing.
    false = self-signed certificate. Works with no domain. Browsers show a
            "Not Secure" warning you must click past. Fine for testing.
  EOT
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Domain for Keycloak, e.g. keycloak.example.com. Leave empty to use the ALB's own hostname."
  type        = string
  default     = ""
}

variable "hosted_zone_name" {
  description = "The Route 53 zone that owns domain_name, e.g. example.com"
  type        = string
  default     = ""
}

variable "subject_alternative_names" {
  description = "Additional hostnames on the certificate"
  type        = list(string)
  default     = []
}

variable "create_dns_records" {
  description = "Let Terraform manage Route 53 records. Requires use_acm_certificate and a hosted zone."
  type        = bool
  default     = false
}

variable "enable_http_redirect" {
  description = "Listen on port 80 to redirect visitors to HTTPS"
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "Stop terraform destroy from deleting the ALB. Keep false in dev."
  type        = bool
  default     = false
}

# --- Compute sizing ---

variable "instance_type" {
  description = "EC2 instance size. t3.medium (4GB) is the practical minimum for Keycloak."
  type        = string
  default     = "t3.medium"
}

variable "java_heap_size" {
  description = "Java heap. Roughly half the instance memory."
  type        = string
  default     = "1536m"
}

variable "root_volume_size" {
  description = "Root disk in GB"
  type        = number
  default     = 30
}

variable "min_size" {
  description = "Minimum instances in the ASG"
  type        = number
  default     = 1
}

variable "max_size" {
  description = "Maximum instances in the ASG"
  type        = number
  default     = 1
}

variable "desired_capacity" {
  description = "Instances to run right now"
  type        = number
  default     = 1
}

# --- Keycloak application ---

variable "keycloak_version" {
  description = "Keycloak version to install"
  type        = string
  default     = "26.0.7"
}

variable "keycloak_http_port" {
  description = "Application port"
  type        = number
  default     = 8080
}

variable "keycloak_management_port" {
  description = "Health and metrics port"
  type        = number
  default     = 9000
}

variable "admin_username" {
  description = "Admin console username. Avoid 'admin'; it is the first guess attackers make."
  type        = string
  default     = "kcadmin"
}

variable "db_vendor" {
  description = "dev-file for testing (data dies with the instance) or postgres for production"
  type        = string
  default     = "dev-file"
}

# --- REALM IMPORT ---

variable "realm_name" {
  description = "Name of the realm to create"
  type        = string
  default     = "myrealm"
}

variable "realm_file_path" {
  description = <<-EOT
    Path to your realm export JSON.

    Leave EMPTY and the module looks for realms/<realm_name>-realm.json
    automatically.

    IF NO FILE IS FOUND, a working default realm is generated instead of
    failing. Check the realm_source output afterwards to confirm which
    one you got.
  EOT
  type        = string
  default     = ""
}

variable "registration_allowed" {
  description = "DEFAULT REALM ONLY: allow public self-registration"
  type        = bool
  default     = false
}

variable "create_default_user" {
  description = "DEFAULT REALM ONLY: seed a test user"
  type        = bool
  default     = true
}

variable "default_client_redirect_uris" {
  description = "DEFAULT REALM ONLY: allowed post-login redirect URLs"
  type        = list(string)
  default     = ["http://localhost:3000/*", "http://localhost:8080/*"]
}

variable "default_client_web_origins" {
  description = "DEFAULT REALM ONLY: allowed CORS origins"
  type        = list(string)
  default     = ["http://localhost:3000", "http://localhost:8080"]
}

# --- Monitoring and encryption ---

variable "enable_cloudwatch_agent" {
  description = "Ship logs to CloudWatch"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Days to keep logs before automatic deletion"
  type        = number
  default     = 30
}

variable "kms_deletion_window_days" {
  description = "Grace period before a deleted KMS key is destroyed (7-30)"
  type        = number
  default     = 7
}
