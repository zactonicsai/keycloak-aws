# =============================================================================
# NETWORK MODULE - variables.tf
# =============================================================================
# Variables are the "inputs" to a module, like the ingredients list on a recipe.
# The module doesn't decide these values; whoever CALLS the module decides them.
# =============================================================================

variable "name_prefix" {
  # description shows up in `terraform plan` output and docs. Always write one.
  description = "String glued to the front of every resource name so you can tell projects apart"

  # type enforces what kind of value is allowed. Terraform will error out
  # if someone passes a number where a string belongs.
  type = string
}

variable "aws_region" {
  description = "AWS region code, like us-east-1. Needed to build VPC endpoint service names."
  type        = string
}

variable "vpc_cidr" {
  description = "The private IP range for the whole VPC"
  type        = string

  # default means this variable is OPTIONAL. If not provided, this is used.
  default = "10.0.0.0/16"

  # A validation block is a guardrail. It runs before anything is created.
  validation {
    # can() returns true if the expression works, false if it errors.
    # cidrhost() only works on a valid CIDR, so this checks the format.
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "vpc_cidr must be a valid CIDR block, for example 10.0.0.0/16."
  }
}

variable "public_subnet_cidrs" {
  description = "IP ranges for public subnets. Must be inside vpc_cidr. Need 2+ for the ALB."
  type        = list(string)
  default     = ["10.0.1.0/24", "10.0.2.0/24"]

  validation {
    # An ALB requires subnets in at least 2 different availability zones.
    condition     = length(var.public_subnet_cidrs) >= 2
    error_message = "You need at least 2 public subnets because an ALB requires 2 availability zones."
  }
}

variable "private_subnet_cidrs" {
  description = "IP ranges for private subnets, where the Keycloak EC2 instance lives"
  type        = list(string)
  default     = ["10.0.11.0/24", "10.0.12.0/24"]
}

variable "availability_zones" {
  description = "Physical data centers to spread across, like [us-east-1a, us-east-1b]"
  type        = list(string)
}

variable "create_nat_gateway" {
  description = "Build a NAT Gateway so private instances can reach the internet. Costs ~$32/mo."
  type        = bool
  default     = true
}

variable "create_vpc_endpoints" {
  description = "Build interface VPC endpoints for SSM/KMS/Logs. ~$7/mo each but more secure."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Key/value labels applied to every resource in this module"

  # map(string) means a dictionary where both keys and values are strings.
  type    = map(string)
  default = {}
}
