# =============================================================================
# variables.tf - every setting, in one place
# =============================================================================

variable "name" {
  description = "Prefix for every resource name. Keep it short - AWS caps ALB names at 32 chars."
  type        = string
  default     = "keycloak"
}

variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "my_ips" {
  description = <<-EOT
    THE MOST IMPORTANT SETTING HERE.

    Only these IP addresses can reach Keycloak. Everything else on the
    internet is dropped at the load balancer.

    Bare addresses, no /32 - it is added automatically.

    Find yours:  curl ifconfig.me

    Home ISPs rotate addresses every few weeks. If Keycloak suddenly stops
    loading, this is almost always why. Update and re-apply.
  EOT
  type = list(string)

  validation {
    condition     = length(var.my_ips) > 0
    error_message = "You must list at least one IP, or nothing can reach Keycloak."
  }

  validation {
    condition     = alltrue([for ip in var.my_ips : ip != "0.0.0.0"])
    error_message = "0.0.0.0 would expose the admin console to the entire internet. Refusing."
  }
}

variable "instance_type" {
  description = <<-EOT
    EC2 size. Keycloak is a Java app and wants memory.

      t3.small  (2 GB)  - boots, then struggles
      t3.medium (4 GB)  - good default
      t3.large  (8 GB)  - comfortable
  EOT
  type    = string
  default = "t3.medium"
}

variable "disk_size" {
  description = "Root disk in GB. Keycloak plus Java needs about 8; 20 leaves room."
  type        = number
  default     = 20
}

variable "keycloak_version" {
  description = "Keycloak release to install. See github.com/keycloak/keycloak/releases"
  type        = string
  default     = "26.0.7"
}

variable "admin_username" {
  description = "Admin console username. Avoid 'admin' - it is the first thing attackers try."
  type        = string
  default     = "kcadmin"
}

variable "realm_name" {
  description = "Name of the realm to create"
  type        = string
  default     = "myrealm"
}

variable "redirect_uris" {
  description = <<-EOT
    DEFAULT REALM ONLY: URLs Keycloak may send users to after login.

    SECURITY: never use a bare "*" in production. An open redirect lets an
    attacker capture authorization codes.
  EOT
  type    = list(string)
  default = ["http://localhost:3000/*", "http://localhost:8080/*"]
}

variable "web_origins" {
  description = "DEFAULT REALM ONLY: origins allowed to make cross-site browser requests"
  type        = list(string)
  default     = ["http://localhost:3000", "http://localhost:8080"]
}
