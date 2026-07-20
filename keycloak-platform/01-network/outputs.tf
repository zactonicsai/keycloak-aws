# =============================================================================
# PROJECT 01-NETWORK - outputs.tf
# =============================================================================
# THESE OUTPUTS ARE THE PUBLIC API OF THIS PROJECT.
#
# Projects 02 and 03 read them through a `terraform_remote_state` data
# source. That means:
#
#   1. If you DELETE an output here, the downstream project breaks on its
#      next plan. Treat these like a published interface, not scratch notes.
#
#   2. Anything NOT listed here is invisible to the other projects. A
#      resource can exist in this state file and still be unreachable
#      downstream unless you expose it.
#
# Rule: output everything another layer could plausibly need, even if
# nothing uses it yet. Adding an output is free; discovering you need one
# mid-deploy is not.
# =============================================================================

# --- VPC ---

output "vpc_id" {
  description = "VPC ID - needed by the DB subnet group and the ALB target group"
  value       = module.network.vpc_id
}

output "vpc_cidr" {
  description = "VPC IP range - used for security group rules in downstream layers"
  value       = module.network.vpc_cidr
}

# --- Subnets ---

output "public_subnet_ids" {
  description = "Public subnets - project 03 puts the ALB here"
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnets - project 02 puts RDS here, project 03 puts EC2 here"
  value       = module.network.private_subnet_ids
}

# --- Encryption keys ---

output "ebs_kms_key_arn" {
  description = "KMS key for disk encryption - used by project 03 (EC2 root volume)"
  value       = module.kms.ebs_key_arn
}

output "secrets_kms_key_arn" {
  description = "KMS key for secrets - used by projects 02 (DB password) and 03 (admin password)"
  value       = module.kms.secrets_key_arn
}

output "ebs_kms_key_id" {
  description = "Short ID of the EBS key"
  value       = module.kms.ebs_key_id
}

output "secrets_kms_key_id" {
  description = "Short ID of the secrets key"
  value       = module.kms.secrets_key_id
}

# --- Security groups ---

output "alb_security_group_id" {
  description = "ALB firewall - project 03 attaches this to the load balancer"
  value       = module.security.alb_security_group_id
}

output "keycloak_security_group_id" {
  description = <<-EOT
    Keycloak instance firewall.

    Used by BOTH downstream projects:
      - project 02 writes a database rule allowing Postgres FROM this group
      - project 03 attaches it to the EC2 instances
  EOT
  value       = module.security.keycloak_security_group_id
}

output "admin_cidrs" {
  description = "Admin IPs in /32 form - project 03 reuses these for the ALB listener rules"
  value       = module.security.admin_cidrs
}

# --- Naming and identity ---

output "name_prefix" {
  description = "Shared naming prefix, so all three projects name things consistently"
  value       = local.name_prefix
}

output "common_tags" {
  description = "Base tags. Downstream projects merge these and override the Layer tag."
  value       = local.common_tags
}

output "availability_zones" {
  description = "The AZs actually used, so RDS and the ALB land in the same ones"
  value       = slice(data.aws_availability_zones.available.names, 0, 2)
}

# --- Convenience ---

output "next_step" {
  description = "What to run next"
  value       = <<-EOT

    ===================================================================
    LAYER 1 OF 3 COMPLETE - Network foundation is up.
    ===================================================================

    VPC:              ${module.network.vpc_id}
    Private subnets:  ${join(", ", module.network.private_subnet_ids)}
    Public subnets:   ${join(", ", module.network.public_subnet_ids)}
    Admin IPs:        ${join(", ", module.security.admin_cidrs)}

    NEXT:  cd ../02-database && terraform init && terraform apply

    (You can skip 02 entirely if you set use_rds=false in 03. See the README.)
    ===================================================================
  EOT
}
