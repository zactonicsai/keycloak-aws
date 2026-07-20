# =============================================================================
# DATABASE MODULE - outputs.tf
# =============================================================================

output "db_instance_id" {
  description = "RDS instance identifier"
  value       = aws_db_instance.keycloak.id
}

output "db_endpoint" {
  description = "Endpoint with port, e.g. mydb.abc123.us-east-1.rds.amazonaws.com:5432"
  value       = aws_db_instance.keycloak.endpoint
}

output "db_address" {
  description = "Hostname only, without the port"
  value       = aws_db_instance.keycloak.address
}

output "db_port" {
  description = "Port the database listens on"
  value       = aws_db_instance.keycloak.port
}

output "db_name" {
  description = "Name of the database"
  value       = aws_db_instance.keycloak.db_name
}

output "db_username" {
  description = "Master username"
  value       = var.db_username
}

output "db_security_group_id" {
  description = "Security group protecting the database"
  value       = aws_security_group.db.id
}

output "db_secret_arn" {
  description = "Secrets Manager ARN holding the credentials. Project 03 reads this."
  value       = aws_secretsmanager_secret.db.arn
}

output "db_secret_name" {
  description = "Secret name, for use with the AWS CLI"
  value       = aws_secretsmanager_secret.db.name
}

output "jdbc_url" {
  description = "Ready-to-use JDBC connection string for Keycloak"
  value       = "jdbc:postgresql://${aws_db_instance.keycloak.endpoint}/${var.db_name}"
}

output "get_db_password_command" {
  description = "Command to retrieve the generated database password"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.db.name} --query SecretString --output text | jq -r '.password'"
}
