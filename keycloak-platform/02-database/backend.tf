# =============================================================================
# PROJECT 02-DATABASE - backend.tf
# =============================================================================
# STATE FILE #2 OF 3.
#
# Same bucket as the other two projects, different key. The key is the only
# thing that separates them.
#
#   keycloak/dev/01-network/terraform.tfstate
#   keycloak/dev/02-database/terraform.tfstate   <- THIS PROJECT
#   keycloak/dev/03-keycloak/terraform.tfstate
#
# Because the database lives in its own state file, `terraform destroy` run
# in project 03 cannot touch it. Terraform has no record of the database
# there, so there is nothing for it to delete.
# =============================================================================

terraform {
  backend "s3" {
    bucket       = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"
    key          = "keycloak/dev/02-database/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
