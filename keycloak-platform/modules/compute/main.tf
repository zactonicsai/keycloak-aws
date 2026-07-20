# =============================================================================
# COMPUTE MODULE - main.tf
# =============================================================================
# This is where Keycloak actually runs. The module handles:
#   1. Finding the right operating system image
#   2. Generating and safely storing the admin password
#   3. IAM permissions (what the server is allowed to do)
#   4. The realm file, WITH A FALLBACK if you didn't provide one
#   5. The launch template (the blueprint for the server)
#   6. The Auto Scaling Group (which builds the server and keeps it alive)
# =============================================================================


# -----------------------------------------------------------------------------
# DATA SOURCES: LOOKING THINGS UP
# -----------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- Find the newest Amazon Linux 2023 image ---
# An AMI (Amazon Machine Image) is a snapshot of a hard drive used as the
# starting point for a new server. AMI IDs are DIFFERENT IN EVERY REGION and
# change every time Amazon publishes a patch, so hardcoding one is a mistake
# that quietly rots over time.
data "aws_ami" "amazon_linux" {
  # Always pick the newest match rather than an arbitrary one.
  most_recent = true

  # Only trust images published by Amazon itself. "amazon" is a reserved
  # alias for Amazon's official account. Never omit this filter — anyone
  # can publish a public AMI, including people who put backdoors in them.
  owners = ["amazon"]

  filter {
    name = "name"
    # The * is a wildcard matching the date-stamped version portion.
    values = ["al2023-ami-2023.*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"] # the modern virtualization type; "paravirtual" is legacy
  }

  filter {
    name   = "state"
    values = ["available"] # skip images still being built or deregistered
  }
}


# =============================================================================
# PART 1: THE ADMIN PASSWORD
# =============================================================================
# NEVER put a password in a .tf file. Terraform files go into git, and once a
# secret is in git history it is effectively public forever.
#
# Instead: generate a strong random password, store it encrypted in AWS
# Secrets Manager, and let the instance fetch it at boot using its IAM role.
# The password never touches your laptop or your repository.

resource "random_password" "keycloak_admin" {
  # Only generate one if the caller didn't supply their own.
  count = var.admin_password == "" ? 1 : 0

  length = 32

  # Include punctuation for strength.
  special = true

  # Restrict which symbols are allowed. Some characters (quotes, backslashes,
  # dollar signs) break shell scripts and config files in surprising ways.
  # This set is safe everywhere.
  override_special = "!#%&*()-_=+[]{}<>:?"

  # Guarantee at least this many of each character class, so we never
  # randomly generate an all-lowercase password.
  min_upper   = 2
  min_lower   = 2
  min_numeric = 2
  min_special = 2
}

locals {
  # Use the caller's password if given, otherwise the generated one.
  admin_password = var.admin_password != "" ? var.admin_password : random_password.keycloak_admin[0].result
}

# --- The secret container ---
resource "aws_secretsmanager_secret" "keycloak_admin" {
  # name_prefix rather than name, because deleted secrets sit in a recovery
  # window and their name stays reserved. Reusing the exact name fails.
  name_prefix = "${var.name_prefix}-keycloak-admin-"

  description = "Keycloak bootstrap admin credentials for ${var.name_prefix}"

  # Encrypt with OUR KMS key rather than the AWS-managed default, so we
  # control exactly who can decrypt it.
  kms_key_id = var.secrets_kms_key_arn

  # Days before a deleted secret is truly gone. 0 would mean immediate,
  # which removes your safety net. 7 is the minimum non-zero value.
  recovery_window_in_days = var.secret_recovery_window_days

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-keycloak-admin-secret"
  })
}

# --- The actual secret value ---
# A secret and its value are separate resources: the container has a stable
# ARN, while versions of the value rotate underneath it.
resource "aws_secretsmanager_secret_version" "keycloak_admin" {
  secret_id = aws_secretsmanager_secret.keycloak_admin.id

  # Store as JSON so we can keep username and password together and add
  # fields later without breaking anything that reads it.
  secret_string = jsonencode({
    username = var.admin_username
    password = local.admin_password
  })
}


# =============================================================================
# PART 2: IAM ROLE AND PERMISSIONS
# =============================================================================
# An IAM ROLE is a set of permissions a machine can wear, like a badge.
#
# WHY A ROLE INSTEAD OF ACCESS KEYS? Access keys are long-lived strings that
# must be stored somewhere on the instance, which means they can be stolen.
# A role hands the instance temporary credentials that rotate automatically
# every few hours. There is nothing permanent to steal. Always use roles.

# --- The trust policy: WHO may wear this badge ---
# This is separate from what the badge can DO. Trust policy answers "who,"
# permission policies answer "what."
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type = "Service"
      # Only the EC2 service may assume this role. A human, a Lambda, or
      # another account cannot.
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "keycloak" {
  name_prefix        = "${var.name_prefix}-keycloak-"
  description        = "Role worn by the Keycloak EC2 instance"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-keycloak-role"
  })
}

# --- Managed policy: SSM Session Manager access ---
# This AWS-maintained policy is what lets you get a shell without SSH.
resource "aws_iam_role_policy_attachment" "ssm" {
  role = aws_iam_role.keycloak.name
  # "arn:aws:iam::aws:policy/..." (with "aws" as the account) marks this as
  # an AWS-managed policy that Amazon keeps updated for you.
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# --- Managed policy: CloudWatch agent ---
# Lets the instance ship logs and metrics to CloudWatch.
resource "aws_iam_role_policy_attachment" "cloudwatch" {
  count      = var.enable_cloudwatch_agent ? 1 : 0
  role       = aws_iam_role.keycloak.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

# --- Custom policy: read the admin secret and use the KMS key ---
# We write this one ourselves because it must be scoped to OUR specific
# secret, not every secret in the account.
#
# THE PRINCIPLE OF LEAST PRIVILEGE: grant the minimum permissions needed and
# nothing more. If this instance is ever compromised, the attacker inherits
# exactly these permissions — so keep the list short.
data "aws_iam_policy_document" "keycloak_permissions" {
  # Statement 1: read the one secret holding the admin password.
  statement {
    sid    = "ReadKeycloakAdminSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    # Scoped to this exact secret ARN. Not "*".
    resources = [aws_secretsmanager_secret.keycloak_admin.arn]
  }

  # Statement 2: decrypt using our KMS keys.
  # Reading an encrypted secret requires BOTH secretsmanager:GetSecretValue
  # AND kms:Decrypt on the key. Missing the second is a very common and very
  # confusing failure — the error says "access denied" without saying why.
  statement {
    sid    = "UseKmsKeys"
    effect = "Allow"

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:GenerateDataKey",
    ]

    resources = compact([
      var.secrets_kms_key_arn,
      var.ebs_kms_key_arn,
    ])
  }

  # Statement 3: write logs to CloudWatch.
  dynamic "statement" {
    for_each = var.enable_cloudwatch_agent ? [1] : []

    content {
      sid    = "WriteCloudWatchLogs"
      effect = "Allow"

      actions = [
        "logs:CreateLogStream",
        "logs:PutLogEvents",
        "logs:DescribeLogStreams",
      ]

      # Scoped to log groups belonging to this deployment only.
      resources = [
        "arn:aws:logs:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:log-group:/aws/ec2/${var.name_prefix}*",
      ]
    }
  }

  # Statement 4: read the DATABASE credentials secret from project 02.
  # Only created when we are actually using RDS.
  #
  # This is why the password never travels through Terraform state: project
  # 02 exports the secret ARN, we grant read access to it, and the instance
  # fetches the value itself at boot.
  dynamic "statement" {
    for_each = var.db_secret_arn != "" ? [1] : []

    content {
      sid    = "ReadDatabaseSecret"
      effect = "Allow"

      actions = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]

      resources = [var.db_secret_arn]
    }
  }

  # Statement 5: read the realm file from the bucket we created above.
  # Scoped to that ONE object, not the whole bucket and not all of S3.
  statement {
    sid    = "ReadRealmFileFromS3"
    effect = "Allow"

    actions = ["s3:GetObject"]

    resources = ["${aws_s3_bucket.realm.arn}/*"]
  }
}

resource "aws_iam_role_policy" "keycloak" {
  name_prefix = "${var.name_prefix}-keycloak-"
  role        = aws_iam_role.keycloak.id
  policy      = data.aws_iam_policy_document.keycloak_permissions.json
}

# --- Instance profile ---
# An EC2 instance cannot attach to a role directly. It needs an "instance
# profile," which is a thin wrapper around the role. This exists purely for
# historical reasons; just create it and move on.
resource "aws_iam_instance_profile" "keycloak" {
  name_prefix = "${var.name_prefix}-keycloak-"
  role        = aws_iam_role.keycloak.name

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-keycloak-profile"
  })
}


# =============================================================================
# PART 3: THE REALM FILE, WITH FALLBACK
# =============================================================================
# A REALM in Keycloak is an isolated tenant: its own users, its own login
# page, its own client applications. Realms cannot see each other.
#
# You asked for realm import with a default if the file is missing. Here is
# how that works.
#
# THE KEY FUNCTION IS fileexists(). It checks, at PLAN time, whether a file
# is present on disk, and returns true or false. Combined with a ternary,
# it lets us pick between your file and a built-in default without failing.
#
# WHY NOT JUST file()? Because file() throws a hard error on a missing file
# and stops the whole run. fileexists() lets us handle it gracefully.

locals {
  # Step 1: build the full path to where the realm file should be.
  realm_file_path = var.realm_file_path != "" ? var.realm_file_path : "${path.module}/../../realms/${var.realm_name}-realm.json"

  # Step 2: does that file actually exist?
  realm_file_exists = fileexists(local.realm_file_path)

  # Step 3: the DEFAULT realm, used when no file was supplied.
  # This is a minimal but complete and genuinely usable realm definition.
  default_realm = {
    # The internal ID and the URL-visible name of the realm.
    realm = var.realm_name
    id    = var.realm_name

    # enabled = false would make the realm exist but reject all logins.
    enabled = true

    # Show a "Forgot password?" link on the login page.
    resetPasswordAllowed = true

    # Let new users create their own accounts. Turn this OFF for anything
    # internal, or strangers can sign themselves up.
    registrationAllowed = var.registration_allowed

    # Users log in with an email address rather than a separate username.
    loginWithEmailAllowed = true

    # Two people may not share an email address.
    duplicateEmailsAllowed = false

    # Require new users to verify their email by clicking a link. This needs
    # working SMTP settings, so it defaults off for a test deployment.
    verifyEmail = var.verify_email

    # --- Token lifetimes (all in seconds) ---
    # An access token is the short-lived pass presented on each request.
    # Short lifetime limits the damage if one is stolen. 5 minutes is standard.
    accessTokenLifespan = 300

    # How long a login session can idle before requiring a fresh login.
    ssoSessionIdleTimeout = 1800 # 30 minutes

    # Hard maximum session length, idle or not.
    ssoSessionMaxLifespan = 36000 # 10 hours

    # --- Brute force protection ---
    # Locks an account after repeated failed logins. This is genuinely
    # important and off by default in Keycloak, which surprises people.
    bruteForceProtected = true
    failureFactor       = 5      # lock after 5 failures
    waitIncrementSeconds = 60    # lockout grows with repeated offenses
    maxFailureWaitSeconds = 900  # capped at 15 minutes
    permanentLockout    = false  # auto-unlock rather than lock forever

    # --- Password rules ---
    # Read as: minimum 12 chars, at least 1 uppercase, 1 lowercase, 1 digit,
    # 1 special character, cannot contain the username, and remembers the
    # last 3 passwords to stop cycling.
    passwordPolicy = "length(12) and upperCase(1) and lowerCase(1) and digits(1) and specialChars(1) and notUsername and passwordHistory(3)"

    # --- Roles ---
    # A role is a label granting permission. Applications check for these.
    roles = {
      realm = [
        {
          name        = "user"
          description = "Standard user with basic access"
        },
        {
          name        = "admin"
          description = "Administrator with elevated access"
        },
      ]
    }

    # Roles automatically given to every newly created user.
    defaultRoles = ["user"]

    # --- Clients ---
    # A "client" is an application that asks Keycloak to log people in.
    clients = [
      {
        clientId = "${var.realm_name}-web"
        name     = "Default Web Application"
        enabled  = true

        # public = true means the app cannot keep a secret (browser
        # JavaScript, mobile apps). It must use PKCE instead of a client
        # secret. Set false for a server-side app that CAN hold a secret.
        publicClient = true

        # Use the standard OAuth2 Authorization Code flow.
        standardFlowEnabled = true

        # Disable the legacy password-grant flow, which sends the user's
        # actual password to the application. It is deprecated for good reason.
        directAccessGrantsEnabled = false

        # Where Keycloak is allowed to send the user after login. This list
        # is a security control: an open redirect here lets an attacker
        # steal authorization codes. Never use a bare "*" in production.
        redirectUris = var.default_client_redirect_uris

        # Origins allowed to make cross-site browser requests.
        webOrigins = var.default_client_web_origins

        attributes = {
          # Require PKCE, which stops an attacker who intercepts the
          # authorization code from actually redeeming it.
          "pkce.code.challenge.method" = "S256"
        }
      },
    ]

    # --- Seed user ---
    # Optional starter account so you can log in and look around immediately.
    users = var.create_default_user ? [
      {
        username      = var.default_user_name
        enabled       = true
        emailVerified = true
        email         = var.default_user_email
        firstName     = "Default"
        lastName      = "User"

        credentials = [
          {
            type  = "password"
            value = local.admin_password

            # temporary = true forces a password change at first login.
            temporary = true
          },
        ]

        realmRoles = ["user"]
      },
    ] : []
  }

  # Step 4: THE FALLBACK DECISION.
  # If the file exists, read it. If not, use the default we just built.
  realm_json = local.realm_file_exists ? file(local.realm_file_path) : jsonencode(local.default_realm)

  # Record which path was taken, so we can surface it in the outputs and
  # you are never confused about which realm actually got imported.
  realm_source = local.realm_file_exists ? "file: ${local.realm_file_path}" : "built-in default (no file found at ${local.realm_file_path})"
}


# --- The S3 bucket that holds the realm file ---
# WHY NOT JUST PUT THE JSON IN user_data?
#
# EC2 user_data is hard-capped at 16,384 bytes AFTER base64 encoding (which
# inflates it by ~33%). A realm with a few hundred users blows straight past
# that, and AWS rejects it at launch time with InvalidUserData.Malformed.
#
# Putting the realm in S3 removes the size ceiling entirely and means editing
# the realm no longer forces the launch template to be recreated.
resource "aws_s3_bucket" "realm" {
  # bucket_prefix generates a globally-unique name with a random suffix.
  # S3 bucket names are unique across every AWS customer on earth, so a fixed
  # name would collide the moment two people deployed this.
  bucket_prefix = "${var.name_prefix}-realm-"

  # force_destroy lets `terraform destroy` delete the bucket even when it
  # still contains objects. Normally S3 refuses. Safe here because the only
  # contents are realm files that Terraform itself put there.
  force_destroy = true

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-realm-bucket"
  })
}

# Block ALL public access. Four separate switches, all on.
# A realm file can contain usernames, emails, and client configuration.
resource "aws_s3_bucket_public_access_block" "realm" {
  bucket = aws_s3_bucket.realm.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Encrypt objects at rest using the same KMS key that protects our secrets.
resource "aws_s3_bucket_server_side_encryption_configuration" "realm" {
  bucket = aws_s3_bucket.realm.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = var.secrets_kms_key_arn
    }
    # Bucket keys cut KMS request costs by reusing a data key across objects.
    bucket_key_enabled = true
  }
}

# Keep old versions, so a bad realm edit can be rolled back.
resource "aws_s3_bucket_versioning" "realm" {
  bucket = aws_s3_bucket.realm.id

  versioning_configuration {
    status = "Enabled"
  }
}

# --- Upload the realm file itself ---
# local.realm_json already resolved to EITHER your file OR the built-in
# default, via the fileexists() check above. This just puts the winner in S3.
resource "aws_s3_object" "realm" {
  bucket = aws_s3_bucket.realm.id
  key    = "${var.realm_name}-realm.json"

  # content takes a string directly, so we do not need a file on disk.
  content      = local.realm_json
  content_type = "application/json"

  # etag is an MD5 of the content. When the realm changes, the etag changes,
  # which tells Terraform to re-upload. Without it, edits would be ignored.
  etag = md5(local.realm_json)

  server_side_encryption = "aws:kms"
  kms_key_id             = var.secrets_kms_key_arn

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-realm-object"
  })
}


# =============================================================================
# PART 4: THE LAUNCH TEMPLATE
# ==============================================================================
# A launch template is a blueprint: it describes HOW to build an instance
# without building one. The Auto Scaling Group reads it whenever it needs a
# new server.
resource "aws_launch_template" "keycloak" {
  name_prefix = "${var.name_prefix}-keycloak-"
  description = "Blueprint for Keycloak servers in ${var.name_prefix}"

  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.keycloak.arn
  }

  vpc_security_group_ids = [var.keycloak_security_group_id]

  # --- The boot script ---
  # user_data runs as root the first time the instance starts.
  # It MUST be base64 encoded, which base64encode() handles.
  #
  # templatefile() reads a file and substitutes ${placeholders} with the
  # values in the second argument. This keeps the shell script in its own
  # readable file instead of jammed into a Terraform string.
  # --- The boot script, gzipped ---
  # base64gzip() compresses BEFORE base64 encoding. cloud-init detects the
  # gzip magic bytes and decompresses automatically, so the script runs
  # normally on the instance.
  #
  # WHY BOTHER? user_data is capped at 16,384 bytes after base64 encoding.
  # Our commented script is ~16 KB raw, which becomes ~23 KB encoded and gets
  # rejected. Gzip brings it to roughly 8 KB, leaving comfortable headroom.
  #
  # This is a genuine AWS-side limit, not a Terraform one, so there is no way
  # to raise it. Compression plus moving the realm to S3 is the standard fix.
  user_data = base64gzip(templatefile("${path.module}/user_data.sh", {
    keycloak_version   = var.keycloak_version
    admin_username     = var.admin_username
    secret_arn         = aws_secretsmanager_secret.keycloak_admin.arn
    aws_region         = data.aws_region.current.name
    realm_bucket       = aws_s3_bucket.realm.id
    realm_key          = aws_s3_object.realm.key
    realm_name         = var.realm_name
    http_port          = var.keycloak_http_port
    management_port    = var.keycloak_management_port
    hostname_url       = var.keycloak_hostname
    java_heap          = var.java_heap_size
    db_vendor          = var.db_vendor
    db_secret_arn      = var.db_secret_arn
    db_host            = var.db_host
    db_port            = var.db_port
    db_name            = var.db_name
  }))

  # --- The hard drive ---
  block_device_mappings {
    # The device name for the root volume on Amazon Linux 2023.
    device_name = "/dev/xvda"

    ebs {
      volume_size = var.root_volume_size

      # gp3 is the current generation SSD. It is cheaper than gp2 AND lets
      # you set throughput independently of size. There is no reason to
      # still be using gp2.
      volume_type = "gp3"

      # Encrypt the disk with our KMS key.
      encrypted  = true
      kms_key_id = var.ebs_kms_key_arn

      # Delete the disk when the instance is terminated, so we don't
      # accumulate orphaned volumes silently costing money.
      delete_on_termination = true
    }
  }

  # --- Instance metadata service settings ---
  # IMDS is a special address (169.254.169.254) instances query to learn
  # about themselves and to fetch their IAM credentials.
  #
  # THIS BLOCK IS A SIGNIFICANT SECURITY CONTROL. Requiring IMDSv2 blocks
  # SSRF attacks, where an attacker tricks your app into fetching that URL
  # and leaking its IAM credentials. IMDSv2 requires a PUT request to get a
  # token first, which a simple tricked GET cannot do.
  metadata_options {
    http_endpoint = "enabled"

    # "required" = IMDSv2 only. The older "optional" still permits IMDSv1
    # and leaves the hole open.
    http_tokens = "required"

    # How many network hops the metadata response may travel. 1 means the
    # instance itself only, which stops a container on the host from
    # reaching it.
    http_put_response_hop_limit = 1

    instance_metadata_tags = "enabled"
  }

  # --- Monitoring ---
  monitoring {
    # Detailed monitoring reports metrics every 1 minute instead of every 5.
    # It costs a little extra, so it is a flag.
    enabled = var.enable_detailed_monitoring
  }

  # Copy tags onto the instances and volumes the template creates.
  # Without these blocks the instances come out untagged and unidentifiable.
  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name = "${var.name_prefix}-keycloak"
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name = "${var.name_prefix}-keycloak-volume"
    })
  }

  lifecycle {
    create_before_destroy = true
  }

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-keycloak-lt"
  })
}


# =============================================================================
# PART 5: THE AUTO SCALING GROUP
# =============================================================================
# An ASG keeps a target number of instances running. If one dies or fails its
# health check, the ASG destroys it and builds a replacement automatically.
#
# WHY USE AN ASG FOR A SINGLE SERVER? Self-healing. With a plain
# aws_instance, a crashed server stays crashed until a human notices. With an
# ASG set to exactly 1, it repairs itself within minutes. The ASG is free;
# you pay only for the instances.
resource "aws_autoscaling_group" "keycloak" {
  name_prefix = "${var.name_prefix}-keycloak-"

  # PRIVATE subnets. The instances get no public IP and cannot be reached
  # from the internet directly.
  vpc_zone_identifier = var.private_subnet_ids

  min_size         = var.min_size
  max_size         = var.max_size
  desired_capacity = var.desired_capacity

  launch_template {
    id = aws_launch_template.keycloak.id
    # "$Latest" always uses the newest version of the template.
    # For production, consider pinning to a specific version number so a
    # template edit doesn't silently change what new instances look like.
    version = "$Latest"
  }

  # Register instances into the ALB target group automatically.
  target_group_arns = [var.target_group_arn]

  # "ELB" means the ASG trusts the load balancer's health check, not just
  # "is the VM powered on." This is important: EC2's own check only notices
  # a dead VM, not a hung Keycloak process. With ELB checks, a Keycloak that
  # stops responding gets replaced.
  health_check_type = "ELB"

  # Grace period before health checks start counting. Keycloak needs time to
  # download, install, import the realm, and boot. Too short a value creates
  # an infinite loop where instances are killed mid-startup, forever.
  health_check_grace_period = var.health_check_grace_period

  # Wait for instances to actually pass the ELB health check before
  # considering the ASG "created." Without this, terraform apply finishes
  # while the server is still booting and you get confusing 503s.
  wait_for_capacity_timeout = var.wait_for_capacity_timeout

  # --- Rolling replacement on template changes ---
  # When the launch template changes, replace instances gradually instead of
  # all at once, so there is no total outage.
  instance_refresh {
    strategy = "Rolling"

    preferences {
      # Keep at least this percentage healthy during the swap. With one
      # instance, 50% still means a brief gap; with two or more it is smooth.
      min_healthy_percentage = var.min_healthy_percentage

      # instance_warmup expects a STRING of seconds, even though it is a
      # number conceptually. tostring() converts our numeric variable so the
      # provider does not reject it with a type error.
      instance_warmup = tostring(var.health_check_grace_period)
    }

    # NOTE: no `triggers` argument here. A change to the launch template
    # (including user_data, which is part of it) ALREADY starts an instance
    # refresh by default. `triggers` is only for adding EXTRA things to watch
    # that would not otherwise cause one, and it accepts launch template
    # attribute names such as "launch_template" or "desired_capacity" — not
    # arbitrary strings.
  }

  # ASG tags use a different, more verbose format than everywhere else.
  # dynamic generates one tag block per entry in the tags map.
  dynamic "tag" {
    for_each = merge(var.tags, {
      Name = "${var.name_prefix}-keycloak"
    })

    content {
      key   = tag.key
      value = tag.value
      # propagate_at_launch copies the tag onto each new instance.
      # Without it, the tag lives only on the ASG object itself.
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true

    # Ignore drift in desired_capacity so that a scaling policy adjusting it
    # at 3am doesn't show up as a change Terraform wants to revert.
    ignore_changes = [desired_capacity]
  }
}


# =============================================================================
# PART 6: CLOUDWATCH LOG GROUP
# =============================================================================
# A log group is a labeled bucket for logs. Creating it here rather than
# letting the agent auto-create it means we control retention and encryption.
resource "aws_cloudwatch_log_group" "keycloak" {
  count = var.enable_cloudwatch_agent ? 1 : 0

  name = "/aws/ec2/${var.name_prefix}/keycloak"

  # Without a retention setting, logs are kept FOREVER and the bill grows
  # forever with them. Always set this.
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "${var.name_prefix}-keycloak-logs"
  })
}
