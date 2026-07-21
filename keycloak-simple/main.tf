# =============================================================================
# main.tf - providers and state storage
# =============================================================================
# The actual resources live in three files, each readable on its own:
#
#   network.tf   VPC, subnets, routing, NAT gateway, security groups
#   alb.tf       load balancer, TLS certificate, target group, listeners
#   keycloak.tf  the EC2 instance, its IAM role, and the realm
#
# One state file. One `terraform apply`. Nothing to sequence.
# =============================================================================

terraform {
  # 1.10 minimum: `use_lockfile` (S3-native state locking) was added there.
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source = "hashicorp/aws"
      # ~> 5.0 means any 5.x but never 6.0. Major versions break things.
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

  # ---------------------------------------------------------------------------
  # STATE STORAGE
  # ---------------------------------------------------------------------------
  # Terraform records what it built in a state file. That file is its memory:
  # without it, running apply twice builds everything twice.
  #
  # The state lives in S3 rather than on your laptop because it contains
  # PLAINTEXT SECRETS - including the Keycloak admin password. Encrypted,
  # versioned, and locked while someone is applying.
  #
  # `use_lockfile` writes a small .tflock object next to the state so two
  # people cannot apply at once. No DynamoDB table needed.
  backend "s3" {
    bucket       = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"
    key          = "keycloak-simple/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  # Applied to every resource automatically, so you can find and cost-track
  # them later without tagging each one by hand.
  default_tags {
    tags = {
      Project   = var.name
      ManagedBy = "terraform"
    }
  }
}
