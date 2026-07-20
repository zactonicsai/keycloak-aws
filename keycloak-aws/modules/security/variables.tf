# =============================================================================
# SECURITY MODULE - variables.tf
# =============================================================================

variable "name_prefix" {
  description = "Prefix for security group names and tags"
  type        = string
}

variable "vpc_id" {
  description = "VPC the security groups belong to (from the network module)"
  type        = string
}

variable "vpc_cidr" {
  description = "VPC IP range, used to compute the AWS DNS resolver address"
  type        = string
}

variable "allowed_admin_ips" {
  description = <<-EOT
    Plain IP addresses allowed to reach the load balancer. Do NOT include /32;
    the module appends it. Example: ["68.32.112.68"]

    Every address here gets full access to the Keycloak admin console, so keep
    the list short. Home internet IPs usually change every few weeks, so if
    access suddenly breaks, check whether your IP moved: curl ifconfig.me
  EOT
  type        = list(string)

  validation {
    # Refuse to build anything if the list is empty. An empty list would
    # create a load balancer that nobody on earth can reach.
    condition     = length(var.allowed_admin_ips) > 0
    error_message = "You must list at least one admin IP or nothing can reach Keycloak."
  }

  validation {
    # alltrue() returns true only if EVERY item in the list passes.
    # The regex checks for four groups of 1-3 digits separated by dots.
    condition = alltrue([
      for ip in var.allowed_admin_ips :
      can(regex("^([0-9]{1,3}\\.){3}[0-9]{1,3}$", ip))
    ])
    error_message = "Each entry must be a bare IPv4 address like 68.32.112.68, with no /32 suffix."
  }

  validation {
    # Explicitly block the "allow the entire internet" value. People paste
    # this in while debugging and then forget to take it out.
    condition = alltrue([
      for ip in var.allowed_admin_ips : ip != "0.0.0.0"
    ])
    error_message = "0.0.0.0 would expose the Keycloak admin console to the entire internet. Refusing."
  }
}

variable "keycloak_http_port" {
  description = "Port Keycloak serves the application on inside the private subnet"
  type        = number
  default     = 8080
}

variable "keycloak_management_port" {
  description = "Port Keycloak serves /health and /metrics on (9000 in Keycloak 25+)"
  type        = number
  default     = 9000
}

variable "enable_http_redirect" {
  description = "Open port 80 on the ALB purely to redirect visitors to HTTPS"
  type        = bool
  default     = true
}

variable "allow_http_egress" {
  description = "Let the instance make outbound port 80 calls for OS package metadata"
  type        = bool
  default     = true
}

variable "tags" {
  description = "Labels applied to every security group and rule"
  type        = map(string)
  default     = {}
}
