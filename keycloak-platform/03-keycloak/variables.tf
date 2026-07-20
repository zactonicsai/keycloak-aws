# =============================================================================
# PROJECT 03-KEYCLOAK - variables.tf
# =============================================================================

# --- Where to find the upstream state files ---

variable "state_bucket" {
  description = "S3 bucket holding all three state files"
  type        = string
  default     = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"
}

variable "network_state_key" {
  description = "Path to project 01's state file"
  type        = string
  default     = "keycloak/dev/01-network/terraform.tfstate"
}

variable "database_state_key" {
  description = "Path to project 02's state file. Only read when use_rds is true."
  type        = string
  default     = "keycloak/dev/02-database/terraform.tfstate"
}

variable "aws_region" {
  description = "AWS region. Must match projects 01 and 02."
  type        = string
  default     = "us-east-1"
}

variable "use_rds" {
  description = <<-EOT
    true  = connect to the PostgreSQL database from project 02.
            Project 02 MUST be applied first.

    false = use the embedded H2 database on local disk. Project 02 can be
            skipped entirely.

            WARNING: with H2, every user, realm, and session is DESTROYED
            when the instance is replaced - and the Auto Scaling Group will
            replace it on any health check failure or template change.
            Use this only for throwaway testing.
  EOT
  type        = bool
  default     = true
}

# --- Certificate and DNS ---

variable "use_acm_certificate" {
  description = "true = real ACM cert (needs a domain). false = self-signed (browser warning)."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Domain for Keycloak. Empty uses the ALB's own hostname."
  type        = string
  default     = ""
}

variable "hosted_zone_name" {
  description = "Route 53 zone owning domain_name, e.g. example.com"
  type        = string
  default     = ""
}

variable "subject_alternative_names" {
  description = "Extra hostnames on the certificate"
  type        = list(string)
  default     = []
}

variable "create_dns_records" {
  description = "Let Terraform manage Route 53 records"
  type        = bool
  default     = false
}

variable "enable_http_redirect" {
  description = "Listen on port 80 to redirect to HTTPS. Must match project 01."
  type        = bool
  default     = true
}

variable "enable_deletion_protection" {
  description = "Block terraform destroy from deleting the ALB. Keep false in dev."
  type        = bool
  default     = false
}

variable "restrict_admin_paths" {
  description = "Add ALB listener rules restricting /admin by source IP"
  type        = bool
  default     = true
}

# --- Instance sizing ---

variable "instance_type" {
  description = "EC2 size. t3.medium (4 GB) is the practical minimum for Keycloak."
  type        = string
  default     = "t3.medium"
}

variable "java_heap_size" {
  description = "Java heap, roughly half the instance memory"
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
  description = "Maximum instances. Going above 1 requires RDS - H2 cannot be shared."
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
  description = "Application port. Must match project 01."
  type        = number
  default     = 8080
}

variable "keycloak_management_port" {
  description = "Health and metrics port. Must match project 01."
  type        = number
  default     = 9000
}

variable "admin_username" {
  description = "Admin console username. Avoid 'admin'."
  type        = string
  default     = "kcadmin"
}

# --- Realm import ---

variable "realm_name" {
  description = "Name of the realm to create"
  type        = string
  default     = "myrealm"
}

variable "realm_file_path" {
  description = <<-EOT
    Path to your realm export JSON.

    Leave EMPTY and the module looks for ../realms/<realm_name>-realm.json

    IF NO FILE IS FOUND, a working default realm is generated instead of
    failing. Check the realm_source output to confirm which was used.
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

# --- Monitoring ---

variable "enable_cloudwatch_agent" {
  description = "Ship logs to CloudWatch"
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "Days to keep logs"
  type        = number
  default     = 30
}

# =============================================================================
# BOOT TIMING
# =============================================================================
# These exist because the Auto Scaling Group can time out waiting for an
# instance that is simply still installing. See the README troubleshooting
# section "Error: waiting for Auto Scaling Group capacity satisfied".

variable "wait_for_capacity_timeout" {
  description = <<-EOT
    How long `terraform apply` blocks waiting for the instance to pass its
    ELB health check.

    IS THE WAIT NEEDED? NO. It is purely a convenience.

      "25m" - apply finishes only when Keycloak actually answers. A green
              apply means it genuinely works.

      "0"   - apply returns in seconds, as soon as the ASG object exists.
              The instance still boots exactly the same way; Terraform just
              stops watching. Check health yourself afterwards with:
                aws elbv2 describe-target-health --target-group-arn <arn>

    Setting "0" does NOT make anything less reliable. It only changes
    whether Terraform waits around to confirm.
  EOT
  type        = string
  default     = "25m"
}

variable "health_check_grace_period" {
  description = <<-EOT
    Seconds the ASG ignores health checks after launching an instance.

    THIS ONE MATTERS. If it is shorter than the boot sequence, the ASG
    decides a still-installing instance is broken, terminates it, and
    launches a replacement that starts from zero - forever. That loop is
    what produces "have 0 healthy instances" until Terraform gives up.

    900s covers a slow boot with margin. Raise it, never lower it.
  EOT
  type        = number
  default     = 900
}
