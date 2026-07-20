# =============================================================================
# ALB MODULE - outputs.tf
# =============================================================================

output "alb_arn" {
  description = "ARN of the load balancer"
  value       = aws_lb.main.arn
}

output "alb_dns_name" {
  description = "The AWS-generated hostname for the ALB. Use this if you have no domain."
  value       = aws_lb.main.dns_name
}

output "alb_zone_id" {
  description = "Route 53 zone ID of the ALB, needed for alias records elsewhere"
  value       = aws_lb.main.zone_id
}

output "target_group_arn" {
  description = "Target group ARN. The compute module registers instances into this."
  value       = aws_lb_target_group.keycloak.arn
}

output "certificate_arn" {
  description = "ARN of whichever certificate ended up in use"
  value       = local.certificate_arn
}

output "https_listener_arn" {
  description = "ARN of the HTTPS listener, useful for attaching more rules"
  value       = aws_lb_listener.https.arn
}

output "keycloak_url" {
  description = "The URL to open in your browser"

  # If a domain was configured use it; otherwise fall back to the ALB's
  # own AWS-generated DNS name.
  value = var.domain_name != "" ? "https://${var.domain_name}" : "https://${aws_lb.main.dns_name}"
}
