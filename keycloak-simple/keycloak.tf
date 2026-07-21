# =============================================================================
# keycloak.tf - the EC2 instance, its permissions, and the realm
# =============================================================================


# -----------------------------------------------------------------------------
# FIND THE OPERATING SYSTEM IMAGE
# -----------------------------------------------------------------------------
# An AMI is a snapshot of a disk used as the starting point for a server.
#
# AMI IDs are DIFFERENT IN EVERY REGION and change every time Amazon
# publishes a patch, so hardcoding one is a mistake that quietly rots.
data "aws_ami" "al2023" {
  most_recent = true

  # Only trust images published by Amazon. Anyone can publish a public AMI,
  # including people who put backdoors in them.
  owners = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}


# -----------------------------------------------------------------------------
# THE ADMIN PASSWORD
# -----------------------------------------------------------------------------
# Generated randomly rather than written in a file. Terraform files go into
# git, and once a secret is in git history it is effectively public forever.
#
# WE ARE NOT USING SECRETS MANAGER. That would cost $0.40/month and add a
# service. Instead the password is a Terraform output you read once:
#
#     terraform output -raw admin_password
#
# TRADEOFF, stated honestly: the password IS stored in your Terraform state
# file, in plaintext. That is why the state file lives in an S3 bucket with
# encryption and public access blocked. Treat the state file as a secret.
resource "random_password" "admin" {
  length  = 24
  special = true

  # Restrict the symbol set. Quotes, backslashes, and dollar signs break
  # shell scripts and config files in surprising ways.
  override_special = "!#%&*()-_=+"

  # Guarantee a mix, so we never randomly produce an all-lowercase password.
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}


# -----------------------------------------------------------------------------
# IAM ROLE - the instance's badge
# -----------------------------------------------------------------------------
# A role is a set of permissions a machine wears.
#
# WHY A ROLE AND NOT ACCESS KEYS? Keys are long-lived strings that must be
# stored on the instance, which means they can be stolen. A role hands out
# temporary credentials that rotate automatically. Nothing permanent to steal.
#
# This role does exactly ONE thing: allow SSM Session Manager, so you can get
# a shell without opening port 22. That is the entire permission set.
resource "aws_iam_role" "keycloak" {
  name_prefix = "${var.name}-"

  # The trust policy answers "WHO may wear this badge" - here, only the EC2
  # service. A human or another account cannot assume it.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.name}-role" }
}

# AWS maintains this policy. It grants exactly what Session Manager needs.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# An EC2 instance cannot attach to a role directly; it needs this thin
# wrapper. It exists for historical reasons - just create it and move on.
resource "aws_iam_instance_profile" "keycloak" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.keycloak.name
}


# -----------------------------------------------------------------------------
# THE REALM
# -----------------------------------------------------------------------------
# A realm is an isolated tenant inside Keycloak: its own users, own login
# page, own applications. Realms cannot see each other.
#
# THE FALLBACK: if realms/<name>-realm.json exists it is imported. If not, the
# default below is used. Either way `terraform apply` succeeds.
#
# fileexists() checks at PLAN time and returns true/false. We use it rather
# than file() because file() throws a hard error on a missing file and stops
# the whole run.
locals {
  realm_path   = "${path.module}/realms/${var.realm_name}-realm.json"
  realm_exists = fileexists(local.realm_path)

  # A minimal but genuinely usable realm.
  default_realm = {
    realm   = var.realm_name
    enabled = true

    # "external" requires HTTPS for outside clients but not localhost.
    # Correct when sitting behind a load balancer.
    sslRequired = "external"

    registrationAllowed   = false # do not let strangers sign themselves up
    resetPasswordAllowed  = true
    loginWithEmailAllowed = true

    # Token lifetimes, in seconds. A short access token limits the damage
    # if one is stolen. Five minutes is standard.
    accessTokenLifespan   = 300
    ssoSessionIdleTimeout = 1800  # 30 min idle
    ssoSessionMaxLifespan = 36000 # 10 hour hard cap

    # Lock an account after repeated failed logins. This is genuinely
    # important and OFF by default in Keycloak, which surprises people.
    bruteForceProtected = true
    failureFactor       = 5

    passwordPolicy = "length(12) and upperCase(1) and lowerCase(1) and digits(1) and specialChars(1) and notUsername"

    roles = {
      realm = [
        { name = "user", description = "Standard user" },
        { name = "admin", description = "Administrator" },
      ]
    }

    clients = [{
      clientId = "${var.realm_name}-web"
      enabled  = true

      # publicClient = true for browser and mobile apps, which cannot keep
      # a secret. They use PKCE instead.
      publicClient              = true
      standardFlowEnabled       = true
      directAccessGrantsEnabled = false # deprecated: sends the raw password

      # SECURITY: never use a bare "*" here in production. An open redirect
      # lets an attacker capture authorization codes.
      redirectUris = var.redirect_uris
      webOrigins   = var.web_origins

      attributes = {
        # Require PKCE, which stops an intercepted authorization code from
        # being redeemed by anyone else.
        "pkce.code.challenge.method" = "S256"
      }
    }]
  }

  # THE FALLBACK DECISION: your file, or the default.
  realm_json = local.realm_exists ? file(local.realm_path) : jsonencode(local.default_realm)

  # Recorded so the output can tell you which one was used.
  realm_source = local.realm_exists ? "file: realms/${var.realm_name}-realm.json" : "built-in default (no file found)"
}


# -----------------------------------------------------------------------------
# THE INSTANCE
# -----------------------------------------------------------------------------
# A plain EC2 instance. No launch template, no Auto Scaling Group.
#
# WHAT THAT MEANS: if this instance dies, it STAYS DEAD until you rebuild it:
#
#     terraform taint aws_instance.keycloak && terraform apply
#
# An ASG would replace it automatically, but it also brought a failure mode
# where it would terminate a still-installing instance and loop forever.
# For a single test instance, simple and predictable wins.
resource "aws_instance" "keycloak" {
  ami           = data.aws_ami.al2023.id
  instance_type = var.instance_type

  # PRIVATE subnet. No public IP. Unreachable from the internet.
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.keycloak.id]

  iam_instance_profile = aws_iam_instance_profile.keycloak.name

  root_block_device {
    volume_size = var.disk_size
    volume_type = "gp3" # current-gen SSD, cheaper than gp2

    # Encrypt the disk. With no kms_key_id specified, AWS uses its own
    # managed key, which is FREE. A customer-managed key would cost $1/month
    # and encrypt exactly as well for this use case.
    encrypted = true

    delete_on_termination = true
  }

  # IMDS is the special address instances query to learn about themselves
  # and fetch IAM credentials.
  #
  # THIS IS A REAL SECURITY CONTROL. Requiring IMDSv2 blocks SSRF attacks,
  # where an attacker tricks your app into fetching that URL and leaking its
  # credentials. IMDSv2 requires a PUT to get a token first, which a simple
  # tricked GET cannot do.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2 only
    http_put_response_hop_limit = 1
  }

  # The boot script.
  #
  # base64gzip compresses before encoding. cloud-init detects the gzip header
  # and decompresses automatically.
  #
  # WHY BOTHER? user_data is hard-capped at 16,384 bytes AFTER base64
  # encoding, which inflates by ~33%. Compression keeps us well under.
  user_data = base64gzip(templatefile("${path.module}/setup.sh", {
    keycloak_version = var.keycloak_version
    admin_username   = var.admin_username
    admin_password   = random_password.admin.result
    realm_json       = local.realm_json
    realm_name       = var.realm_name
  }))

  # Rebuild the instance whenever the boot script or realm changes.
  # Without this, editing the realm would do nothing until you manually
  # replaced the instance.
  user_data_replace_on_change = true

  lifecycle {
    ignore_changes = [
      # AWS publishes new AMIs constantly. Without this, every plan would
      # want to replace the instance just because a newer image exists.
      ami,
    ]
  }

  tags        = { Name = "${var.name}-keycloak" }
  volume_tags = { Name = "${var.name}-keycloak-disk" }
}
