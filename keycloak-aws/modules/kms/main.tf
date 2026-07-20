# =============================================================================
# KMS MODULE - main.tf
# =============================================================================
# KMS = Key Management Service. It's AWS's vault for encryption keys.
#
# ANALOGY: Imagine a diary with a lock. KMS holds the key to that lock and
# never lets anyone actually SEE the key. Instead you hand KMS your diary and
# say "lock this" or "unlock this," and KMS does it for you. Because you can
# never touch the key, you can never lose it or accidentally email it to
# someone.
#
# We create TWO keys here so that a leak of one doesn't compromise the other:
#   1. An EBS key   - encrypts the hard drive of the EC2 instance
#   2. A Secrets key - encrypts the Keycloak admin password in Secrets Manager
# =============================================================================


# -----------------------------------------------------------------------------
# DATA SOURCES
# -----------------------------------------------------------------------------
# A "data" block does not CREATE anything. It LOOKS UP something that already
# exists and lets you read its values. Think of it as a question, not a command.

# Who am I? Returns the AWS account ID of whoever is running Terraform.
data "aws_caller_identity" "current" {}

# What region am I in? Returns the region from the provider config.
data "aws_region" "current" {}


# -----------------------------------------------------------------------------
# KMS KEY FOR EBS VOLUME ENCRYPTION
# -----------------------------------------------------------------------------
# This key scrambles everything written to the EC2 instance's hard drive.
# If someone stole the physical disk out of the Amazon data center, the data
# would be unreadable gibberish without this key.
resource "aws_kms_key" "ebs" {
  description = "${var.name_prefix} - encrypts the EBS root volume of the Keycloak server"

  # How many days AWS waits before permanently destroying the key after you
  # ask to delete it. This is a safety net: if you delete by accident, you have
  # this many days to change your mind. Minimum 7, maximum 30.
  deletion_window_in_days = var.deletion_window_in_days

  # Key rotation automatically generates fresh key material once a year.
  # Old data stays readable (AWS keeps the old material around).
  # This is free and there is no reason to turn it off.
  enable_key_rotation = true

  # SYMMETRIC_DEFAULT means one key both locks and unlocks (AES-256).
  # The alternative, asymmetric, uses a public/private pair and is for
  # signing or for sharing with outsiders. We don't need that here.
  key_usage = "ENCRYPT_DECRYPT"
  customer_master_key_spec = "SYMMETRIC_DEFAULT"

  # The key policy is a rulebook saying WHO may use this key and HOW.
  # jsonencode() turns Terraform objects into JSON so we don't have to write
  # raw JSON strings with escaped quotes everywhere.
  policy = jsonencode({
    Version = "2012-10-17" # This date is a fixed IAM version string, not today's date.
    Statement = [
      {
        # Statement 1: the account root can manage the key.
        # WITHOUT THIS, THE KEY BECOMES UNMANAGEABLE FOREVER. AWS support
        # cannot rescue you. Always include it.
        Sid    = "EnableRootAccountManagement"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*" # every KMS action
        Resource = "*"     # in a key policy, "*" means "this key"
      },
      {
        # Statement 2: let the EC2/Auto Scaling service use the key so it can
        # actually attach an encrypted volume at boot time.
        Sid    = "AllowServiceUseOfTheKey"
        Effect = "Allow"
        Principal = {
          # A "service principal" is an AWS service acting on your behalf.
          Service = ["ec2.amazonaws.com"]
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*", # makes the per-volume data key
          "kms:DescribeKey",
          "kms:CreateGrant", # lets EC2 delegate use of the key to the volume
        ]
        Resource = "*"

        # A Condition narrows WHEN the statement applies. Without this,
        # any EC2 in any account could theoretically ask to use the key.
        Condition = {
          StringEquals = {
            # Only requests originating from OUR account.
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
            # Only when the request comes via the EC2 service in our region.
            "kms:ViaService" = "ec2.${data.aws_region.current.name}.amazonaws.com"
          }
        }
      },
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-ebs-key"
    Purpose = "ebs-encryption"
  })
}

# An ALIAS is a friendly nickname for a key. Key IDs look like
# "1234abcd-12ab-34cd-56ef-1234567890ab" which nobody can remember.
# An alias lets you write "alias/keycloak-ebs" instead.
resource "aws_kms_alias" "ebs" {
  # Aliases MUST start with "alias/". AWS enforces this.
  name          = "alias/${var.name_prefix}-ebs"
  target_key_id = aws_kms_key.ebs.key_id
}


# -----------------------------------------------------------------------------
# KMS KEY FOR SECRETS MANAGER
# -----------------------------------------------------------------------------
# A separate key for the Keycloak admin password. Separate keys = separate
# blast radius. If the EBS key policy is misconfigured, the password is
# still safe.
resource "aws_kms_key" "secrets" {
  description             = "${var.name_prefix} - encrypts the Keycloak admin credentials in Secrets Manager"
  deletion_window_in_days = var.deletion_window_in_days
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EnableRootAccountManagement"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      {
        # Let Secrets Manager encrypt and decrypt the secret value.
        Sid    = "AllowSecretsManagerUse"
        Effect = "Allow"
        Principal = {
          Service = "secretsmanager.amazonaws.com"
        }
        Action = [
          "kms:Encrypt",
          "kms:Decrypt",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:CreateGrant",
          "kms:DescribeKey",
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "kms:CallerAccount" = data.aws_caller_identity.current.account_id
          }
        }
      },
    ]
  })

  tags = merge(var.tags, {
    Name    = "${var.name_prefix}-secrets-key"
    Purpose = "secrets-encryption"
  })
}

resource "aws_kms_alias" "secrets" {
  name          = "alias/${var.name_prefix}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}
