# =============================================================================
# ALB MODULE - variables.tf
# =============================================================================

variable "name_prefix" {
  description = "Prefix for ALB, target group, and certificate names"
  type        = string

  validation {
    # AWS limits load balancer names to 32 characters. Our suffixes ("-alb")
    # eat a few, so we cap the prefix well below that.
    condition     = length(var.name_prefix) <= 24
    error_message = "name_prefix must be 24 characters or fewer; AWS caps ALB names at 32."
  }
}

variable "vpc_id" {
  description = "VPC the target group lives in"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the ALB. Must span at least 2 availability zones."
  type        = list(string)

  validation {
    condition     = length(var.public_subnet_ids) >= 2
    error_message = "An ALB requires at least 2 subnets in different availability zones."
  }
}

variable "alb_security_group_id" {
  description = "Security group restricting who can reach the ALB"
  type        = string
}

# --- Certificate settings ---

variable "use_acm_certificate" {
  description = "true = real ACM cert (needs a domain). false = self-signed (browser warnings)."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Domain for the certificate and DNS record, e.g. keycloak.example.com. Empty for self-signed testing."
  type        = string
  default     = ""
}

variable "hosted_zone_name" {
  description = "Route 53 zone that owns the domain, e.g. example.com (note the trailing dot is optional)"
  type        = string
  default     = ""
}

variable "subject_alternative_names" {
  description = "Extra hostnames the certificate should also cover"
  type        = list(string)
  default     = []
}

variable "create_dns_records" {
  description = "Let Terraform create Route 53 records for validation and the app"
  type        = bool
  default     = false
}

variable "self_signed_validity_hours" {
  description = "Lifetime of the self-signed certificate. 8760 hours = 1 year."
  type        = number
  default     = 8760
}

variable "ssl_policy" {
  description = "TLS versions and ciphers the ALB accepts. This default requires TLS 1.2 or 1.3."
  type        = string
  default     = "ELBSecurityPolicy-TLS13-1-2-2021-06"
}

# --- Target group and health checks ---

variable "keycloak_http_port" {
  description = "Port Keycloak serves the app on"
  type        = number
  default     = 8080
}

variable "keycloak_management_port" {
  description = "Port Keycloak serves /health on (9000 in Keycloak 25+)"
  type        = number
  default     = 9000
}

variable "health_check_path" {
  description = "URL the ALB polls to test if Keycloak is alive"
  type        = string
  default     = "/health/ready"
}

variable "health_check_interval" {
  description = "Seconds between health checks"
  type        = number
  default     = 30
}

variable "health_check_timeout" {
  description = "Seconds to wait for a health check reply. Must be less than the interval."
  type        = number
  default     = 5

  validation {
    condition     = var.health_check_timeout >= 2 && var.health_check_timeout <= 120
    error_message = "health_check_timeout must be between 2 and 120 seconds."
  }
}

variable "healthy_threshold" {
  description = "Consecutive passes before a target is marked healthy"
  type        = number
  default     = 2
}

variable "unhealthy_threshold" {
  description = "Consecutive failures before a target is pulled from rotation"
  type        = number
  default     = 5
}

variable "health_check_matcher" {
  description = "HTTP status codes that count as healthy"
  type        = string
  default     = "200"
}

variable "deregistration_delay" {
  description = "Seconds to let in-flight requests finish before removing a target"
  type        = number
  default     = 60
}

variable "enable_stickiness" {
  description = "Pin each browser to one instance via cookie. Needed once you run 2+ nodes."
  type        = bool
  default     = true
}

variable "stickiness_duration" {
  description = "How long the stickiness cookie lasts, in seconds"
  type        = number
  default     = 86400
}

# --- ALB behavior ---

variable "enable_http_redirect" {
  description = "Listen on port 80 solely to redirect to HTTPS"
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "Block terraform destroy from deleting the ALB. Use true in prod, false in dev."
  type        = bool
  default     = false
}

variable "idle_timeout" {
  description = "Seconds an idle connection stays open"
  type        = number
  default     = 60
}

variable "access_logs_bucket" {
  description = "S3 bucket for ALB access logs. Empty disables logging."
  type        = string
  default     = ""
}

# --- Admin path restriction ---

variable "restrict_admin_paths" {
  description = "Add a listener rule blocking admin URLs from non-approved IPs (second layer)"
  type        = bool
  default     = true
}

variable "admin_path_patterns" {
  description = "URL patterns treated as administrative"
  type        = list(string)
  default     = ["/admin", "/admin/*"]
}

variable "allowed_admin_cidrs" {
  description = "CIDRs permitted to reach admin paths, e.g. [\"68.32.112.68/32\"]"
  type        = list(string)
}

variable "tags" {
  description = "Labels applied to ALB resources"
  type        = map(string)
  default     = {}
}
