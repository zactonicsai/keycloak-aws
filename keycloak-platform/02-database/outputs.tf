# =============================================================================
# PROJECT 02-DATABASE - outputs.tf
# =============================================================================
# Project 03 reads these to build its database connection.
#
# NOTE WHAT IS NOT HERE: the password. Project 03 does not receive it through
# Terraform state at all. Instead it gets the SECRET ARN, and the EC2 instance
# fetches the actual password from Secrets Manager at boot using its IAM role.
#
# Why that matters: state files store outputs in PLAINTEXT. Passing the
# password as an output would write it into project 02's state AND project
# 03's state. Passing only the ARN keeps it in exactly one place.
# =============================================================================

output "db_endpoint" {
  description = "Hostname and port, e.g. mydb.abc.us-east-1.rds.amazonaws.com:5432"
  value       = module.database.db_endpoint
}

output "db_address" {
  description = "Hostname only, no port"
  value       = module.database.db_address
}

output "db_port" {
  description = "Database port"
  value       = module.database.db_port
}

output "db_name" {
  description = "Database name"
  value       = module.database.db_name
}

output "db_username" {
  description = "Master username"
  value       = module.database.db_username
}

output "db_secret_arn" {
  description = <<-EOT
    Secrets Manager ARN holding the credentials.

    Project 03 grants its instance role permission to read THIS ARN, and the
    boot script fetches the password from it. The password itself never
    travels through Terraform state.
  EOT
  value       = module.database.db_secret_arn
}

output "db_secret_name" {
  description = "Secret name, for AWS CLI use"
  value       = module.database.db_secret_name
}

output "db_security_group_id" {
  description = "Security group protecting the database"
  value       = module.database.db_security_group_id
}

output "jdbc_url" {
  description = "Ready-to-use JDBC connection string"
  value       = module.database.jdbc_url
}

output "get_db_password" {
  description = "Command to retrieve the generated database password"
  value       = module.database.get_db_password_command
}

output "next_step" {
  description = "What to run next"
  value       = <<-EOT

    ===================================================================
    LAYER 2 OF 3 COMPLETE - PostgreSQL is running.
    ===================================================================

    Endpoint:  ${module.database.db_endpoint}
    Database:  ${module.database.db_name}
    Username:  ${module.database.db_username}

    Get the password:
      ${module.database.get_db_password_command}

    Connect through SSM port forwarding (no inbound rule needed):
      aws ssm start-session --target <keycloak-instance-id> \
        --document-name AWS-StartPortForwardingSessionToRemoteHost \
        --parameters '{"host":["${module.database.db_address}"],"portNumber":["${module.database.db_port}"],"localPortNumber":["5432"]}'

    NEXT:  cd ../03-keycloak && terraform init && terraform apply
    ===================================================================
  EOT
}
