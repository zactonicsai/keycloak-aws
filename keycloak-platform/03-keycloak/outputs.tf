# =============================================================================
# PROJECT 03-KEYCLOAK - outputs.tf
# =============================================================================

output "keycloak_url" {
  description = "Open this in your browser. Only reachable from your allowed IPs."
  value       = local.keycloak_url
}

output "keycloak_admin_console_url" {
  description = "Direct link to the admin console"
  value       = "${local.keycloak_url}/admin"
}

output "alb_dns_name" {
  description = "The load balancer's AWS hostname"
  value       = module.alb.alb_dns_name
}

output "target_group_arn" {
  description = "Target group ARN, for checking instance health"
  value       = module.alb.target_group_arn
}

output "admin_username" {
  description = "Keycloak admin console username"
  value       = module.compute.admin_username
}

output "get_admin_password" {
  description = "Command to retrieve the auto-generated admin password"
  value       = module.compute.get_admin_password_command
}

output "realm_name" {
  description = "The realm that was created"
  value       = module.compute.realm_name
}

output "realm_source" {
  description = "Whether your realm FILE was used, or the built-in default"
  value       = module.compute.realm_source
}

output "autoscaling_group_name" {
  description = "ASG name, for forcing an instance refresh"
  value       = module.compute.autoscaling_group_name
}

output "database_mode" {
  description = "Which database Keycloak is actually using"
  value       = var.use_rds ? "PostgreSQL (RDS) at ${local.db_host}:${local.db_port}/${local.db_name}" : "Embedded H2 - DATA IS LOST ON INSTANCE REPLACEMENT"
}

output "connect_via_ssm" {
  description = "Get a shell on the instance without SSH"
  value       = "aws ssm start-session --target $(aws ec2 describe-instances --filters 'Name=tag:Name,Values=${local.name_prefix}-keycloak' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text)"
}

output "next_steps" {
  description = "What to do now"
  value       = <<-EOT

    ===================================================================
    ALL 3 LAYERS COMPLETE
    ===================================================================

    1. WAIT 5-8 MINUTES. The instance is still installing Keycloak.
       Watch progress:
         aws elbv2 describe-target-health --target-group-arn ${module.alb.target_group_arn}
       You want "healthy". "initial" means still booting.

    2. GET YOUR PASSWORD:
         ${module.compute.get_admin_password_command}

    3. OPEN THE CONSOLE:
         ${local.keycloak_url}/admin
       Username: ${module.compute.admin_username}

    4. WHICH REALM DID YOU GET?
         ${module.compute.realm_source}

    5. DATABASE:
         ${var.use_rds ? "PostgreSQL (durable)" : "Embedded H2 (NOT durable)"}

    IF THE PAGE WILL NOT LOAD:
      - Check your IP has not changed:  curl ifconfig.me
        Allowed: ${join(", ", local.net.admin_cidrs)}
        If it changed, edit 01-network/terraform.tfvars and re-apply
        PROJECT 01 ONLY. You do not need to touch 02 or 03.
      - A self-signed certificate warning is expected. Click through it.

    TO TEAR DOWN JUST THIS LAYER (keeps VPC and database):
      terraform destroy
    ===================================================================
  EOT
}
