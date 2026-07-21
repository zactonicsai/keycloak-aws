# =============================================================================
# outputs.tf - what you need after apply
# =============================================================================

output "url" {
  description = "Open this in your browser. Only reachable from your allowed IPs."
  value       = "https://${aws_lb.main.dns_name}"
}

output "admin_console" {
  description = "Direct link to the admin console"
  value       = "https://${aws_lb.main.dns_name}/admin"
}

output "admin_username" {
  description = "Username for the admin console"
  value       = var.admin_username
}

output "admin_password" {
  description = "Read it with: terraform output -raw admin_password"

  # sensitive = true hides the value from normal terraform output, so it does
  # not end up in CI logs or on a shared screen. It does NOT encrypt it in
  # the state file - the state itself needs protecting.
  value     = random_password.admin.result
  sensitive = true
}

output "instance_id" {
  description = "For getting a shell: aws ssm start-session --target <this>"
  value       = aws_instance.keycloak.id
}

output "realm_source" {
  description = "Whether YOUR realm file was used, or the built-in default"
  value       = local.realm_source
}

output "allowed_ips" {
  description = "The only addresses that can reach Keycloak"
  value       = [for ip in var.my_ips : "${ip}/32"]
}

output "check_health" {
  description = "Command to see whether the instance is passing health checks"
  value       = "aws elbv2 describe-target-health --target-group-arn ${aws_lb_target_group.keycloak.arn} --query 'TargetHealthDescriptions[].TargetHealth.State' --output text"
}

output "next_steps" {
  description = "What to do now"
  value       = <<-EOT

    ==========================================================
    DEPLOYED
    ==========================================================

    1. WAIT 5-10 MINUTES. Keycloak is still installing.
       Check:  aws elbv2 describe-target-health --target-group-arn ${aws_lb_target_group.keycloak.arn} --query 'TargetHealthDescriptions[].TargetHealth.State' --output text
       "initial" = still booting.  "healthy" = ready.

    2. GET THE PASSWORD:
         terraform output -raw admin_password

    3. OPEN:  https://${aws_lb.main.dns_name}/admin
       User:  ${var.admin_username}

       You WILL see a certificate warning. That is expected - the cert is
       self-signed. The connection is encrypted; it just is not vouched for
       by a third party. Click Advanced, then Proceed.

    4. REALM USED: ${local.realm_source}

    IF IT WILL NOT LOAD:
      curl ifconfig.me
      Must be one of: ${join(", ", [for ip in var.my_ips : "${ip}/32"])}
      If your IP changed, edit terraform.tfvars and re-apply.

    SHELL ON THE BOX (no SSH needed):
      aws ssm start-session --target ${aws_instance.keycloak.id}
      sudo cat /var/log/setup.log
    ==========================================================
  EOT
}
