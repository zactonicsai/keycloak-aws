# =============================================================================
# COMPUTE MODULE - outputs.tf
# =============================================================================

output "autoscaling_group_name" {
  description = "Name of the ASG managing the Keycloak instances"
  value       = aws_autoscaling_group.keycloak.name
}

output "launch_template_id" {
  description = "ID of the launch template"
  value       = aws_launch_template.keycloak.id
}

output "iam_role_arn" {
  description = "ARN of the instance role"
  value       = aws_iam_role.keycloak.arn
}

output "admin_secret_arn" {
  description = "Secrets Manager ARN holding the admin credentials"
  value       = aws_secretsmanager_secret.keycloak_admin.arn
}

output "admin_secret_name" {
  description = "Secret name, for use with the AWS CLI"
  value       = aws_secretsmanager_secret.keycloak_admin.name
}

output "admin_username" {
  description = "The bootstrap admin username"
  value       = var.admin_username
}

output "ami_id" {
  description = "AMI the instances were built from"
  value       = data.aws_ami.amazon_linux.id
}

output "realm_source" {
  description = <<-EOT
    Tells you WHICH realm definition was used: your file, or the built-in
    default. Check this after apply if you are unsure whether your realm
    file was picked up.
  EOT
  value = local.realm_source
}

output "realm_file_exists" {
  description = "true if a realm file was found on disk, false if the default was used"
  value       = local.realm_file_exists
}

output "realm_name" {
  description = "Name of the imported realm"
  value       = var.realm_name
}

output "get_admin_password_command" {
  description = "Copy-paste command to read the generated admin password"
  value       = "aws secretsmanager get-secret-value --secret-id ${aws_secretsmanager_secret.keycloak_admin.name} --query SecretString --output text | jq -r '.password'"
}

output "realm_bucket_name" {
  description = "S3 bucket holding the realm import file"
  value       = aws_s3_bucket.realm.id
}

output "realm_object_key" {
  description = "Object key of the realm file inside the bucket"
  value       = aws_s3_object.realm.key
}
