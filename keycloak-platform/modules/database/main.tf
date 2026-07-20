# =============================================================================
# DATABASE MODULE - main.tf
# =============================================================================
# RDS = Relational Database Service. Amazon runs the PostgreSQL server for
# you: backups, patching, failover, monitoring.
#
# WHY KEYCLOAK NEEDS A REAL DATABASE:
#
# Keycloak can run on an embedded H2 database written to local disk. It works
# and it is free. But the data lives on the instance's hard drive, so:
#
#   - Replace the instance and EVERY user, realm, and session is GONE
#   - You can never run two Keycloak nodes, because they cannot share H2
#   - There are no backups
#
# The Auto Scaling Group WILL replace the instance eventually - on any health
# check failure, or any launch template change. So with H2, data loss is not
# a risk, it is a scheduled event.
#
# This module creates PostgreSQL, which fixes all three problems.
# =============================================================================

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}


# =============================================================================
# PART 1: THE DATABASE PASSWORD
# =============================================================================
# Same pattern as the Keycloak admin password: generate it randomly, store it
# encrypted, never write it in a file.
resource "random_password" "db" {
  length = 32

  # Symbols make it stronger, but RDS REJECTS certain characters in the
  # master password: / (slash), @ (at), " (quote), and space. Passing one
  # produces an unhelpful API error, so we restrict the set explicitly.
  special          = true
  override_special = "!#%&*()-_=+[]{}<>:?"

  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

resource "aws_secretsmanager_secret" "db" {
  # name_prefix, not name: a deleted secret's name stays reserved during its
  # recovery window, so reusing an exact name fails.
  name_prefix = "${var.name_prefix}-db-credentials-"
  description = "PostgreSQL credentials for Keycloak (${var.name_prefix})"

  # Encrypt with the KMS key from project 01.
  kms_key_id = var.secrets_kms_key_arn

  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-secret"
  })
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id

  # Store as JSON with every field Keycloak needs, so project 03 can read
  # one secret and get the whole connection.
  secret_string = jsonencode({
    username = var.db_username
    password = random_password.db.result
    engine   = "postgres"
    host     = aws_db_instance.keycloak.address
    port     = aws_db_instance.keycloak.port
    dbname   = var.db_name

    # A ready-to-use JDBC URL, so the boot script does not have to assemble
    # one from parts and get the syntax subtly wrong.
    jdbc_url = "jdbc:postgresql://${aws_db_instance.keycloak.endpoint}/${var.db_name}"
  })
}


# =============================================================================
# PART 2: NETWORK PLACEMENT
# =============================================================================
# A DB subnet group tells RDS which subnets it may use. It requires at least
# two, in different availability zones, even for a single-AZ database - AWS
# needs somewhere to fail over TO if you later enable Multi-AZ.
resource "aws_db_subnet_group" "keycloak" {
  name_prefix = "${var.name_prefix}-db-"
  description = "Private subnets for the Keycloak database"

  # PRIVATE subnets. A database should never be publicly reachable.
  subnet_ids = var.private_subnet_ids

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-subnet-group"
  })
}


# =============================================================================
# PART 3: THE DATABASE FIREWALL
# =============================================================================
resource "aws_security_group" "db" {
  name_prefix = "${var.name_prefix}-db-"
  description = "Keycloak database - accepts PostgreSQL from the app tier only"
  vpc_id      = var.vpc_id

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-sg"
  })
}

# --- The only inbound rule: Postgres from the Keycloak instances ---
#
# THE IMPORTANT DETAIL: the source is a SECURITY GROUP, not an IP range.
#
# This works even though project 03 has not been applied yet, because the
# security group itself was created back in project 01. The rule says
# "anything wearing that badge," and it stays correct forever as instances
# are replaced and get new private IPs.
#
# Had we written a CIDR range instead, we would be granting access to every
# machine in those subnets, present and future - much broader than intended.
resource "aws_vpc_security_group_ingress_rule" "db_from_keycloak" {
  security_group_id = aws_security_group.db.id

  referenced_security_group_id = var.keycloak_security_group_id

  from_port   = var.db_port
  to_port     = var.db_port
  ip_protocol = "tcp"
  description = "PostgreSQL from the Keycloak application tier"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-ingress-app"
  })
}

# --- Optional: direct admin access for troubleshooting ---
# Off by default. When you need it, prefer connecting through SSM port
# forwarding from the Keycloak instance rather than opening the database
# to the internet.
resource "aws_vpc_security_group_ingress_rule" "db_from_admin" {
  for_each = toset(var.admin_access_cidrs)

  security_group_id = aws_security_group.db.id
  cidr_ipv4         = each.value
  from_port         = var.db_port
  to_port           = var.db_port
  ip_protocol       = "tcp"
  description       = "Direct admin PostgreSQL access from ${each.value}"

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-ingress-admin"
  })
}


# =============================================================================
# PART 4: PARAMETER GROUP
# =============================================================================
# A parameter group is the database's configuration file. We create our own
# rather than using the AWS default, because the default cannot be modified.
resource "aws_db_parameter_group" "keycloak" {
  name_prefix = "${var.name_prefix}-pg-"

  # The family string must match the engine major version exactly.
  # "postgres16" pairs with engine_version "16.x".
  family      = var.parameter_group_family
  description = "PostgreSQL tuning for Keycloak (${var.name_prefix})"

  # --- Log slow queries ---
  parameter {
    name = "log_min_duration_statement"
    # Milliseconds. Any query slower than this gets logged. 1000 = 1 second.
    value = tostring(var.slow_query_threshold_ms)
  }

  # --- Log every connection and disconnection ---
  # Useful for spotting connection leaks, which Keycloak is prone to when
  # its pool is misconfigured.
  parameter {
    name  = "log_connections"
    value = "1"
  }

  parameter {
    name  = "log_disconnections"
    value = "1"
  }

  # --- Require encrypted connections ---
  # Forces TLS between Keycloak and the database. Traffic stays inside the
  # VPC either way, but defense in depth costs nothing here.
  parameter {
    name  = "rds.force_ssl"
    value = var.force_ssl ? "1" : "0"

    # "pending-reboot" means the change waits for a restart rather than
    # applying live. Static parameters like this one cannot change on a
    # running server. Setting "immediate" here would fail.
    apply_method = "pending-reboot"
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db-params"
  })
}


# =============================================================================
# PART 5: THE DATABASE ITSELF
# =============================================================================
resource "aws_db_instance" "keycloak" {
  identifier_prefix = "${var.name_prefix}-db-"

  # --- Engine ---
  engine = "postgres"

  # Pin the MAJOR version (e.g. "16") rather than a full version like
  # "16.3". With just the major version, AWS applies minor patches during
  # your maintenance window and Terraform will not fight it.
  engine_version = var.engine_version

  # --- Size ---
  # db.t4g.micro is the cheapest option that works. Graviton (ARM) instances
  # are roughly 20% cheaper than equivalent Intel ones and Keycloak's
  # workload does not care about the architecture.
  instance_class = var.instance_class

  # --- Storage ---
  allocated_storage = var.allocated_storage

  # Storage autoscaling: RDS grows the disk automatically when it fills up.
  # Set to 0 to disable. Growing is automatic; SHRINKING is impossible,
  # so do not set the maximum wildly high.
  max_allocated_storage = var.max_allocated_storage

  # gp3 is the current-generation SSD. Cheaper than gp2 and lets you set
  # IOPS independently of disk size.
  storage_type = "gp3"

  # Encrypt at rest with the KMS key from project 01.
  storage_encrypted = true
  kms_key_id        = var.ebs_kms_key_arn

  # --- Credentials ---
  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  # --- Networking ---
  db_subnet_group_name   = aws_db_subnet_group.keycloak.name
  vpc_security_group_ids = [aws_security_group.db.id]
  port                   = var.db_port

  # NEVER true. This would give the database a public IP reachable from the
  # internet. Publicly accessible databases are one of the most common
  # serious cloud misconfigurations.
  publicly_accessible = false

  parameter_group_name = aws_db_parameter_group.keycloak.name

  # --- High availability ---
  # Multi-AZ keeps a synchronous standby copy in another data center and
  # fails over automatically in 60-120 seconds.
  #
  # It DOUBLES the cost. Off for dev, on for production.
  multi_az = var.multi_az

  # --- Backups ---
  # Days to keep automated backups. 0 DISABLES BACKUPS ENTIRELY and also
  # disables point-in-time recovery. Never use 0 for anything real.
  backup_retention_period = var.backup_retention_days

  # UTC window for the daily backup. Pick a quiet hour.
  backup_window = var.backup_window

  # UTC window for patching. Must not overlap the backup window.
  maintenance_window = var.maintenance_window

  # Apply minor version patches automatically during that window.
  auto_minor_version_upgrade = true

  # --- Deletion safety ---
  # When true, `terraform destroy` REFUSES to delete this database.
  # True for production. False in dev, or you cannot tear down your sandbox.
  deletion_protection = var.deletion_protection

  # A final snapshot before deletion is your last line of defense against
  # a mistaken destroy. Skipping it is fine in dev and reckless in prod.
  skip_final_snapshot = var.skip_final_snapshot

  # Only used when skip_final_snapshot is false.
  final_snapshot_identifier = var.skip_final_snapshot ? null : "${var.name_prefix}-db-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  # --- Monitoring ---
  # Ship PostgreSQL logs to CloudWatch. "postgresql" is the error log;
  # "upgrade" logs major version upgrades.
  enabled_cloudwatch_logs_exports = var.enable_log_exports ? ["postgresql", "upgrade"] : []

  # Performance Insights records query-level performance data. The 7-day
  # retention tier is FREE; longer retention is billed.
  performance_insights_enabled          = var.enable_performance_insights
  performance_insights_retention_period = var.enable_performance_insights ? 7 : null
  performance_insights_kms_key_id       = var.enable_performance_insights ? var.ebs_kms_key_arn : null

  # Enhanced Monitoring polls OS-level metrics from inside the DB host.
  # 0 disables it. Requires an IAM role when enabled.
  monitoring_interval = var.monitoring_interval
  monitoring_role_arn = var.monitoring_interval > 0 ? aws_iam_role.rds_monitoring[0].arn : null

  # --- Change control ---
  # false means changes wait for the maintenance window instead of applying
  # instantly. Instant changes can cause an unplanned restart mid-day.
  apply_immediately = var.apply_immediately

  lifecycle {
    ignore_changes = [
      # The final snapshot name embeds timestamp(), which changes on every
      # single plan. Without this, Terraform shows a permanent phantom diff.
      final_snapshot_identifier,

      # AWS applies minor version patches automatically. Ignoring this stops
      # Terraform from trying to roll them back.
      engine_version,
    ]
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-db"
  })
}


# =============================================================================
# PART 6: ENHANCED MONITORING ROLE
# =============================================================================
# Enhanced Monitoring needs permission to write OS metrics to CloudWatch.
# Only created when monitoring is actually turned on.
resource "aws_iam_role" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  name_prefix = "${var.name_prefix}-rds-mon-"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        # Note the ".monitoring." prefix - this is a DIFFERENT service
        # principal from plain rds.amazonaws.com.
        Service = "monitoring.rds.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-rds-monitoring-role"
  })
}

resource "aws_iam_role_policy_attachment" "rds_monitoring" {
  count = var.monitoring_interval > 0 ? 1 : 0

  role       = aws_iam_role.rds_monitoring[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonRDSEnhancedMonitoringRole"
}
