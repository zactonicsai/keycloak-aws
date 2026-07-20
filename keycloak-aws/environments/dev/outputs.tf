# =============================================================================
# DEV ENVIRONMENT - outputs.tf
# =============================================================================
# These print after `terraform apply` and are the first thing you read.
# Re-display them any time with: terraform output
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

output "admin_username" {
  description = "Username for the Keycloak admin console"
  value       = module.compute.admin_username
}

output "get_admin_password" {
  description = "Run this command to retrieve the auto-generated admin password"
  value       = module.compute.get_admin_password_command
}

output "realm_name" {
  description = "The realm that was created"
  value       = module.compute.realm_name
}

output "realm_source" {
  description = "IMPORTANT: shows whether your realm file was used, or the built-in default"
  value       = module.compute.realm_source
}

output "allowed_admin_ips" {
  description = "The only IP addresses that can reach Keycloak"
  value       = module.security.admin_cidrs
}

output "vpc_id" {
  description = "The VPC that was created"
  value       = module.network.vpc_id
}

output "autoscaling_group_name" {
  description = "ASG name, useful for forcing an instance refresh"
  value       = module.compute.autoscaling_group_name
}

output "kms_key_arns" {
  description = "The two KMS keys protecting disks and secrets"
  value = {
    ebs     = module.kms.ebs_key_arn
    secrets = module.kms.secrets_key_arn
  }
}

output "connect_via_ssm" {
  description = "How to get a shell on the instance without SSH"
  value       = "aws ssm start-session --target $(aws ec2 describe-instances --filters 'Name=tag:Name,Values=${local.name_prefix}-keycloak' 'Name=instance-state-name,Values=running' --query 'Reservations[0].Instances[0].InstanceId' --output text)"
}

output "next_steps" {
  description = "What to do after apply finishes"
  value = <<-EOT

    ===================================================================
    DEPLOYMENT COMPLETE
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

    IF THE PAGE WILL NOT LOAD:
      - Check your IP has not changed:  curl ifconfig.me
        It must be in: ${join(", ", module.security.admin_cidrs)}
      - A self-signed certificate warning is expected. Click through it.
      - Still stuck? See the Troubleshooting section of the README.
    ===================================================================
  EOT
}

output "target_group_arn" {
  description = "Target group ARN, used for checking instance health"
  value       = module.alb.target_group_arn
}
