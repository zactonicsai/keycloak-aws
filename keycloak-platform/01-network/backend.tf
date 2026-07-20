# =============================================================================
# PROJECT 01-NETWORK - backend.tf
# =============================================================================
# STATE FILE #1 OF 3.
#
# Each project keeps its own separate state file in the same S3 bucket,
# distinguished by the `key` (the path inside the bucket):
#
#   keycloak/dev/01-network/terraform.tfstate    <- THIS PROJECT
#   keycloak/dev/02-database/terraform.tfstate
#   keycloak/dev/03-keycloak/terraform.tfstate
#
# WHY SPLIT THE STATE AT ALL?
#
# With one giant state file, every `terraform plan` reads and refreshes
# EVERYTHING. Changing a Keycloak setting makes Terraform re-check your VPC,
# your NAT gateway, your database. That is slow, and worse, it means a typo
# in the Keycloak config can produce a plan that wants to delete a subnet.
#
# Separate state files give you a blast radius. Running `terraform destroy`
# in 03-keycloak physically CANNOT touch the VPC, because the VPC is not in
# that state file. Terraform has no record of it there.
#
# The tradeoff: you must apply them in order the first time, and you wire
# them together with `terraform_remote_state` data sources instead of plain
# module outputs. That is the cost of the safety.
# =============================================================================

terraform {
  backend "s3" {
    bucket = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"

    # THE KEY IS WHAT MAKES THIS STATE FILE SEPARATE.
    # Change nothing else; change this and you have a different project.
    key = "keycloak/dev/01-network/terraform.tfstate"

    region  = "us-east-1"
    encrypt = true

    # S3-native locking. Requires Terraform 1.10+.
    # No DynamoDB table anywhere in this project.
    use_lockfile = true
  }
}
