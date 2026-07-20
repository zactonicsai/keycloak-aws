# =============================================================================
# KMS MODULE - outputs.tf
# =============================================================================

output "ebs_key_arn" {
  description = "Full ARN of the EBS key. The launch template needs this exact string."
  value       = aws_kms_key.ebs.arn
}

output "ebs_key_id" {
  description = "Short ID of the EBS key"
  value       = aws_kms_key.ebs.key_id
}

output "secrets_key_arn" {
  description = "Full ARN of the Secrets Manager key"
  value       = aws_kms_key.secrets.arn
}

output "secrets_key_id" {
  description = "Short ID of the Secrets Manager key"
  value       = aws_kms_key.secrets.key_id
}

output "ebs_key_alias" {
  description = "Friendly alias name for the EBS key"
  value       = aws_kms_alias.ebs.name
}

output "secrets_key_alias" {
  description = "Friendly alias name for the Secrets key"
  value       = aws_kms_alias.secrets.name
}
