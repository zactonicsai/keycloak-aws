# =============================================================================
# ALB MODULE - versions.tf
# =============================================================================
# Declares which providers this module needs. Modules must declare their own
# required_providers so Terraform knows to install them.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 5.0 means "any 5.x version, but not 6.0". This is a pessimistic
      # constraint: pick up bug fixes automatically, never a breaking change.
      version = "~> 5.0"
    }

    # The tls provider generates the self-signed certificate locally.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
