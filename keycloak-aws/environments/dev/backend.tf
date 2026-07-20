# =============================================================================
# BACKEND CONFIGURATION - environments/dev/backend.tf
# =============================================================================
# WHAT IS "STATE" AND WHY DOES IT NEED A HOME?
#
# When Terraform builds something, it writes down what it built in a file
# called terraform.tfstate. That file is Terraform's memory. It maps
# "aws_instance.keycloak" in your code to "i-0abc123..." in real AWS.
#
# Without state, Terraform has amnesia. Run `apply` twice and it builds
# everything twice, because it has no idea the first batch exists.
#
# By default that file sits on YOUR laptop. That's fine alone, but breaks
# the moment a second person joins:
#   - Your laptop dies, the state is gone, and Terraform forgets it owns
#     $200/month of AWS resources that now nobody can delete cleanly.
#   - Two people apply at the same time and corrupt each other's changes.
#   - The state file contains SECRETS in plain text (passwords, keys).
#
# A "remote backend" fixes all three: the state lives in an S3 bucket,
# encrypted, versioned, and locked while someone is working.
# =============================================================================

terraform {
  backend "s3" {
    # -------------------------------------------------------------------------
    # WHICH BUCKET
    # -------------------------------------------------------------------------
    # The S3 bucket that holds the state file. This bucket must ALREADY EXIST
    # before you run `terraform init` — Terraform cannot create the bucket that
    # stores its own state. That's a chicken-and-egg problem. See the README
    # section "Bootstrapping the state bucket" if it doesn't exist yet.
    #
    # Note this bucket name follows the standard convention:
    #   <project>-<env>-tfstate-<account-id>-<region>
    # Bucket names are GLOBALLY unique across every AWS customer on earth,
    # which is why people bolt the account ID onto the end.
    bucket = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"

    # -------------------------------------------------------------------------
    # WHERE INSIDE THE BUCKET
    # -------------------------------------------------------------------------
    # The "key" is just the file path inside the bucket. One bucket can hold
    # state for many projects as long as each uses a different key.
    #
    # Use a folder structure that reads clearly:
    #   keycloak/dev/terraform.tfstate
    #   keycloak/prod/terraform.tfstate
    #
    # CRITICAL: dev and prod must NEVER share a key. If they do, applying dev
    # will happily destroy prod, because Terraform will think prod's resources
    # are leftovers that need cleaning up.
    key = "keycloak/dev/terraform.tfstate"

    # -------------------------------------------------------------------------
    # REGION
    # -------------------------------------------------------------------------
    # The region the BUCKET lives in. This is separate from the region your
    # infrastructure gets built in, though here they happen to match.
    region = "us-east-1"

    # -------------------------------------------------------------------------
    # ENCRYPTION
    # -------------------------------------------------------------------------
    # Encrypt the state file at rest inside S3.
    #
    # This matters more than people expect. State files contain plaintext
    # copies of anything Terraform touched — database passwords, private keys,
    # the Keycloak admin credential. Treat the state file itself as a secret.
    encrypt = true

    # -------------------------------------------------------------------------
    # STATE LOCKING
    # -------------------------------------------------------------------------
    # A lock is a "do not disturb" sign. While one person is applying,
    # everyone else gets blocked instead of stomping on the state.
    #
    # Terraform 1.10+ supports native S3 locking via a small .tflock file
    # placed next to the state. This replaces the old DynamoDB table approach
    # and is the current recommended practice — one less resource to manage.
    use_lockfile = true

    # NOTE: this project uses S3 ONLY. There is no DynamoDB table and none is
    # needed. Native S3 locking (use_lockfile) writes a small .tflock object
    # next to the state file and deletes it when the run finishes.
    #
    # This REQUIRES Terraform 1.10 or newer. Check with: terraform version
    # If you are on an older version, upgrade rather than adding DynamoDB —
    # the S3-only approach is one less resource to create, pay for, and
    # forget about.
  }
}

# =============================================================================
# WHY IS THIS BLOCK ALMOST ENTIRELY HARDCODED?
# =============================================================================
# You cannot use variables inside a backend block. No var.bucket, no
# interpolation, nothing. Terraform reads the backend config before it has
# loaded any variables, so there's nothing to interpolate yet.
#
# Two ways around it if you need flexibility:
#
#   OPTION A - Partial configuration (common in CI/CD)
#     Leave values out of this file and pass them at init time:
#       terraform init \
#         -backend-config="bucket=cloud-team-playbook-dev-tfstate-406207085797-us-east-1" \
#         -backend-config="key=keycloak/dev/terraform.tfstate"
#     PRO: one codebase, many backends.  CON: easy to forget the flags and
#     silently init against the wrong place.
#
#   OPTION B - A separate backend.tf per environment folder (what we do here)
#     PRO: impossible to point dev at prod by accident; it's written down.
#     CON: a little copy-paste between folders.
#
# For a small team, Option B is safer and it's what this project uses.
# =============================================================================
