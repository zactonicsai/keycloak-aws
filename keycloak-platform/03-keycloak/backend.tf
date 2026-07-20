# =============================================================================
# PROJECT 03-KEYCLOAK - backend.tf
# =============================================================================
# STATE FILE #3 OF 3.
#
#   keycloak/dev/01-network/terraform.tfstate
#   keycloak/dev/02-database/terraform.tfstate
#   keycloak/dev/03-keycloak/terraform.tfstate   <- THIS PROJECT
#
# THIS IS THE ONE YOU DESTROY FREELY.
#
# Because the VPC lives in state file 1 and the database in state file 2,
# `terraform destroy` here cannot reach either. Terraform only destroys what
# it has a record of, and this state file contains only the ALB, the EC2
# instance, and their supporting resources.
#
# That is not a convention or a promise - it is structural. There is no way
# for a plan in this directory to produce a "destroy aws_db_instance" line.
# =============================================================================

terraform {
  backend "s3" {
    bucket       = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"
    key          = "keycloak/dev/03-keycloak/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
