# =============================================================================
# COMPUTE MODULE - variables.tf
# =============================================================================

variable "name_prefix" {
  description = "Prefix for all compute resource names"
  type        = string
}

# --- Networking inputs (from the network and security modules) ---

variable "private_subnet_ids" {
  description = "Private subnets the instances launch into"
  type        = list(string)
}

variable "keycloak_security_group_id" {
  description = "Security group attached to the instances"
  type        = string
}

variable "target_group_arn" {
  description = "ALB target group the ASG registers instances into"
  type        = string
}

# --- Encryption inputs (from the KMS module) ---

variable "ebs_kms_key_arn" {
  description = "KMS key encrypting the root volume"
  type        = string
}

variable "secrets_kms_key_arn" {
  description = "KMS key encrypting the admin credentials secret"
  type        = string
}

# --- Instance sizing ---

variable "instance_type" {
  description = <<-EOT
    EC2 size. Keycloak is a Java app and is memory-hungry.

    t3.small  (2GB) - bare minimum, will be sluggish
    t3.medium (4GB) - good for dev and light use
    t3.large  (8GB) - comfortable for small production
    m6i.large (8GB) - production, no CPU burst credits to run out of

    A note on t3: burstable instances earn CPU credits while idle and spend
    them under load. Run out and you are throttled hard. Fine for dev,
    risky for production traffic.
  EOT
  type        = string
  default     = "t3.medium"
}

variable "java_heap_size" {
  description = "Java heap. Use roughly half the instance RAM, leaving the rest for the OS."
  type        = string
  default     = "1536m"
}

variable "root_volume_size" {
  description = "Root disk size in GB. Keycloak plus Java needs about 8GB; 30 gives headroom."
  type        = number
  default     = 30

  validation {
    condition     = var.root_volume_size >= 20
    error_message = "root_volume_size must be at least 20 GB for the OS, Java, and Keycloak."
  }
}

# --- Auto Scaling Group sizing ---

# --- Keycloak application settings ---

variable "keycloak_version" {
  description = "Keycloak release to install, e.g. 26.0.7. Check github.com/keycloak/keycloak/releases."
  type        = string
  default     = "26.0.7"
}

variable "keycloak_http_port" {
  description = "Port Keycloak serves the app on"
  type        = number
  default     = 8080
}

variable "keycloak_management_port" {
  description = "Port Keycloak serves health and metrics on"
  type        = number
  default     = 9000
}

variable "keycloak_hostname" {
  description = <<-EOT
    The PUBLIC URL users will type, e.g. https://keycloak.example.com

    This must match how users actually reach Keycloak, because it gets baked
    into tokens and redirect URLs. A mismatch here is the number one cause of
    "invalid redirect_uri" errors and login loops.

    With no domain, use the ALB's DNS name.
  EOT
  type        = string
}

variable "admin_username" {
  description = "Bootstrap admin username. Avoid 'admin' if you can; it is the first thing attackers try."
  type        = string
  default     = "kcadmin"
}

variable "admin_password" {
  description = "Admin password. LEAVE EMPTY to auto-generate a strong one (recommended)."
  type        = string
  default     = ""

  # sensitive = true hides the value from all Terraform console output.
  # It does NOT encrypt it in the state file, so the state still needs
  # protecting. It only stops shoulder-surfing and CI log leaks.
  sensitive = true
}

variable "db_vendor" {
  description = <<-EOT
    Database backend.

    dev-file - embedded H2 on local disk. Data dies with the instance.
               Fine for testing, never for production.
    postgres - external PostgreSQL, normally RDS. Required for production
               and for running more than one node.
  EOT
  type        = string
  default     = "dev-file"

  validation {
    condition     = contains(["dev-file", "dev-mem", "postgres", "mysql", "mariadb"], var.db_vendor)
    error_message = "db_vendor must be one of: dev-file, dev-mem, postgres, mysql, mariadb."
  }
}

variable "secret_recovery_window_days" {
  description = "Days a deleted secret stays recoverable. 0 deletes immediately (no undo)."
  type        = number
  default     = 7
}

# --- REALM IMPORT SETTINGS ---

variable "realm_name" {
  description = "Name of the realm to create or import"
  type        = string
  default     = "myrealm"

  validation {
    # Realm names appear in URLs, so restrict them to URL-safe characters.
    condition     = can(regex("^[a-zA-Z0-9_-]+$", var.realm_name))
    error_message = "realm_name may contain only letters, numbers, hyphens, and underscores."
  }
}

variable "realm_file_path" {
  description = <<-EOT
    Path to your realm JSON export.

    LEAVE EMPTY to use the conventional location:
      realms/<realm_name>-realm.json

    IF THE FILE IS MISSING, the module builds a sensible default realm
    instead of failing. This is handled by fileexists() at plan time.
    Check the realm_source output to see which one was actually used.
  EOT
  type        = string
  default     = ""
}

variable "registration_allowed" {
  description = "DEFAULT REALM ONLY: let visitors create their own accounts. Keep false for internal apps."
  type        = bool
  default     = false
}

variable "verify_email" {
  description = "DEFAULT REALM ONLY: require email verification. Needs working SMTP settings."
  type        = bool
  default     = false
}

variable "create_default_user" {
  description = "DEFAULT REALM ONLY: seed a starter user account"
  type        = bool
  default     = true
}

variable "default_user_name" {
  description = "DEFAULT REALM ONLY: username of the seeded account"
  type        = string
  default     = "testuser"
}

variable "default_user_email" {
  description = "DEFAULT REALM ONLY: email of the seeded account"
  type        = string
  default     = "testuser@example.com"
}

variable "default_client_redirect_uris" {
  description = <<-EOT
    DEFAULT REALM ONLY: URLs Keycloak may redirect to after login.

    SECURITY: never use a bare "*" in production. An open redirect lets an
    attacker capture authorization codes. List exact URLs.
  EOT
  type        = list(string)
  default     = ["http://localhost:3000/*", "http://localhost:8080/*"]
}

variable "default_client_web_origins" {
  description = "DEFAULT REALM ONLY: origins allowed to make cross-site browser requests (CORS)"
  type        = list(string)
  default     = ["http://localhost:3000", "http://localhost:8080"]
}

# --- Monitoring ---

variable "enable_cloudwatch_agent" {
  description = "Ship Keycloak logs and metrics to CloudWatch"
  type        = bool
  default     = true
}

variable "enable_detailed_monitoring" {
  description = "1-minute EC2 metrics instead of 5-minute. Costs slightly more."
  type        = bool
  default     = false
}

variable "log_retention_days" {
  description = "Days to keep CloudWatch logs. Without a limit they are kept forever and billed forever."
  type        = number
  default     = 30
}

variable "tags" {
  description = "Labels applied to compute resources"
  type        = map(string)
  default     = {}
}

# =============================================================================
# DATABASE CONNECTION (from project 02)
# =============================================================================
# All optional. Leave every one empty to run on the embedded H2 database,
# which is fine for a throwaway test and loses all data on instance
# replacement.

variable "db_secret_arn" {
  description = <<-EOT
    Secrets Manager ARN holding the database credentials, from project 02.

    The instance role is granted read access to this ARN and the boot script
    fetches the password from it. The password is never passed through
    Terraform state or user_data.

    Empty = use the embedded H2 database instead.
  EOT
  type    = string
  default = ""
}

variable "db_host" {
  description = "Database hostname from project 02. Empty when using H2."
  type        = string
  default     = ""
}

variable "db_port" {
  description = "Database port from project 02"
  type        = number
  default     = 5432
}

variable "db_name" {
  description = "Database name from project 02"
  type        = string
  default     = "keycloak"
}

# =============================================================================
# FAILURE DETECTION (replaces ASG self-healing)
# =============================================================================
# With no Auto Scaling Group, nothing repairs a failed instance automatically.
# These settings make failures visible, and recover from hardware faults.

variable "enable_status_alarm" {
  description = <<-EOT
    Create a CloudWatch alarm that fires when the instance fails its status
    check.

    This does NOT fix anything - it tells you. Without an ASG, a crashed
    instance stays crashed until someone acts, so being told promptly is the
    whole point.
  EOT
  type    = bool
  default = true
}

variable "enable_auto_recovery" {
  description = <<-EOT
    Automatically restart the instance on new hardware when the underlying
    AWS host fails. Keeps the same instance ID, private IP, and EBS volumes.

    This is the closest thing to ASG self-healing without an ASG.

    IMPORTANT LIMITATION: it reacts only to HARDWARE failure (lost power,
    network, or host). It will NOT help if Keycloak itself crashes or hangs
    while the instance stays up. For that you need an ASG or a person.
  EOT
  type    = bool
  default = true
}

variable "alarm_sns_topic_arns" {
  description = <<-EOT
    SNS topics to notify when the status alarm fires, e.g. an email or
    PagerDuty subscription.

    Empty means the alarm still turns red in the CloudWatch console but
    sends nothing. Create a topic and subscribe to it to actually be told.
  EOT
  type    = list(string)
  default = []
}
