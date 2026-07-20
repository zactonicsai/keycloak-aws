# =============================================================================
# COMPUTE MODULE - versions.tf
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    # random generates the admin password locally.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }
}
