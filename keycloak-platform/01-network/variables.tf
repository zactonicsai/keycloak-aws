# =============================================================================
# PROJECT 01-NETWORK - variables.tf
# =============================================================================

variable "project_name" {
  description = "Short project name. MUST MATCH across all three projects or names will not line up."
  type        = string
  default     = "keycloak"

  validation {
    condition     = length(var.project_name) <= 12
    error_message = "project_name must be 12 characters or fewer; AWS caps ALB names at 32."
  }
}

variable "environment" {
  description = "Environment name. MUST MATCH across all three projects."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region. MUST MATCH across all three projects."
  type        = string
  default     = "us-east-1"
}

variable "additional_tags" {
  description = "Extra tags merged into the standard set"
  type        = map(string)
  default     = {}
}

# --- Network layout ---

variable "vpc_cidr" {
  description = "IP range for the whole VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "Public subnet ranges. The ALB lives here. Need 2+ for a load balancer."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]
}

variable "private_subnet_cidrs" {
  description = "Private subnet ranges. RDS and the EC2 instance live here."
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "create_nat_gateway" {
  description = <<-EOT
    Build a NAT Gateway so private instances can reach the internet.

    REQUIRED as configured: the Keycloak instance sits in a private subnet
    and must download Java and Keycloak from the internet at boot.

    COST: ~$32.85/month plus $0.045/GB processed.
  EOT
  type        = bool
  default     = true
}

variable "create_vpc_endpoints" {
  description = <<-EOT
    Build interface VPC endpoints for SSM, KMS, and CloudWatch Logs.

    COST WARNING: billed PER ENDPOINT PER AVAILABILITY ZONE. With 5 endpoints
    across 2 AZs that is 10 billable network interfaces at $0.01/hour each,
    about $73/month. This is the single most expensive line in a dev setup.

    Setting this to false loses nothing functionally - SSM and KMS still work
    over the NAT Gateway. You lose the private network path, not the ability.
  EOT
  type        = bool
  default     = true
}

variable "kms_deletion_window_days" {
  description = "Grace period before a deleted KMS key is destroyed forever (7-30 days)"
  type        = number
  default     = 7
}

# --- Access control ---

variable "allowed_admin_ips" {
  description = <<-EOT
    THE MOST IMPORTANT VARIABLE IN THIS PROJECT.

    Only these IPs can reach the load balancer. Everyone else is dropped.

    Bare addresses, no /32 suffix - the module adds it.

    Find yours with:  curl ifconfig.me

    Home ISPs rotate addresses every few weeks. If Keycloak stops loading,
    check this first, update it, and re-apply THIS project (01). The change
    lands immediately; you do not need to touch 02 or 03.
  EOT
  type        = list(string)
}

# --- Ports (must match project 03) ---

variable "keycloak_http_port" {
  description = "Application port. MUST MATCH project 03."
  type        = number
  default     = 8080
}

variable "keycloak_management_port" {
  description = "Health and metrics port. MUST MATCH project 03."
  type        = number
  default     = 9000
}

variable "enable_http_redirect" {
  description = "Open port 80 on the ALB purely to redirect to HTTPS. MUST MATCH project 03."
  type        = bool
  default     = true
}
