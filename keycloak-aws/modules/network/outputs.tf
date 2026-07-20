# =============================================================================
# NETWORK MODULE - outputs.tf
# =============================================================================
# Outputs are the "return values" of a module. Other modules read these to
# find out what got built. Without outputs, a module is a black box.
# =============================================================================

output "vpc_id" {
  description = "ID of the VPC we created, needed by security groups and the ALB"
  value       = aws_vpc.main.id
}

output "vpc_cidr" {
  description = "The VPC's IP range, useful for writing security group rules"
  value       = aws_vpc.main.cidr_block
}

output "public_subnet_ids" {
  description = "List of public subnet IDs. The load balancer goes here."

  # The [*] is a "splat expression." It means "grab the .id from every item
  # in this list." Shorthand for [for s in aws_subnet.public : s.id]
  value = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs. The Keycloak EC2 instance goes here."
  value       = aws_subnet.private[*].id
}

output "nat_gateway_id" {
  description = "NAT Gateway ID, or null if we didn't build one"

  # try() attempts the first expression; if it errors, it falls back to the
  # second. Needed because aws_nat_gateway.main[0] blows up when count = 0.
  value = try(aws_nat_gateway.main[0].id, null)
}

output "vpc_endpoint_security_group_id" {
  description = "Security group protecting the VPC interface endpoints"
  value       = aws_security_group.vpc_endpoints.id
}
