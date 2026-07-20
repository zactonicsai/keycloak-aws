# =============================================================================
# SECURITY MODULE - outputs.tf
# =============================================================================

output "alb_security_group_id" {
  description = "Security group for the load balancer. The ALB module attaches this."
  value       = aws_security_group.alb.id
}

output "keycloak_security_group_id" {
  description = "Security group for the EC2 instance. The compute module attaches this."
  value       = aws_security_group.keycloak.id
}

output "admin_cidrs" {
  description = "The admin IPs converted to /32 CIDR form, handy for verifying what got applied"
  value       = local.admin_cidrs
}
