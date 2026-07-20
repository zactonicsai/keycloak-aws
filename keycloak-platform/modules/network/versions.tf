# =============================================================================
# versions.tf - provider requirements for this module
# =============================================================================
# Every module should declare what it needs. Terraform uses these constraints
# to pick a provider version that satisfies ALL modules at once.
# =============================================================================

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 5.0 allows 5.1, 5.99, etc. but never 6.0.
      # Major versions contain breaking changes, so we pin below the next one.
      version = "~> 5.0"
    }
  }
}
