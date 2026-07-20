# =============================================================================
# DEV ENVIRONMENT - providers.tf
# =============================================================================
# A PROVIDER is the plugin that knows how to talk to a specific API.
# The "aws" provider translates Terraform resources into AWS API calls.
# =============================================================================

terraform {
  # The minimum Terraform version. We need 1.5+ for `check` blocks and
  # 1.10+ for native S3 state locking (use_lockfile in backend.tf).
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  # default_tags applies these to EVERY resource this provider creates,
  # automatically, without you writing tags on each one.
  #
  # We still pass tags explicitly to modules as well. That is intentional
  # belt-and-braces: a few resource types silently ignore default_tags.
  default_tags {
    tags = {
      Project     = var.project_name
      Environment = var.environment
      ManagedBy   = "terraform"
    }
  }
}
