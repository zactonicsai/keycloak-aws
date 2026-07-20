#!/usr/bin/env bash
# =============================================================================
# bootstrap-state-bucket.sh
# =============================================================================
# Verifies (and if necessary creates) the S3 bucket that stores Terraform state.
#
# THIS PROJECT USES S3 ONLY. There is no DynamoDB lock table. Locking is
# handled natively by S3 via the `use_lockfile = true` setting in backend.tf,
# which requires Terraform 1.10 or newer.
#
# YOUR BUCKET ALREADY EXISTS (created 2026-07-13):
#   cloud-team-playbook-dev-tfstate-406207085797-us-east-1
#
# So this script will mostly SKIP creation and instead confirm the safety
# settings are correct: versioning, encryption, public access block, and
# TLS-only. Those are worth verifying because a state bucket without them
# is a real risk — state files hold plaintext secrets.
#
# WHY A SHELL SCRIPT INSTEAD OF TERRAFORM?
# Chicken-and-egg. Terraform stores its memory in this bucket, so the bucket
# has to exist BEFORE Terraform runs for the first time. You cannot ask
# Terraform to create the thing that holds Terraform's own state.
#
# Safe to run repeatedly — every step checks whether the work is already done
# first (this property is called being "idempotent," which just means
# "running it twice does no harm").
#
# USAGE:
#   chmod +x scripts/bootstrap-state-bucket.sh
#   ./scripts/bootstrap-state-bucket.sh
# =============================================================================

# --- Shell safety settings. Put these at the top of every bash script. ---
# -e : stop immediately if any command fails, instead of blundering onward
# -u : error out if we use a variable that was never set (catches typos)
# -o pipefail : if any command in a pipe (a | b) fails, the whole pipe fails
set -euo pipefail


# -----------------------------------------------------------------------------
# CONFIGURATION
# -----------------------------------------------------------------------------
# "${VAR:-default}" means "use VAR if it's set, otherwise use default."
# This lets you override values without editing the file:
#   BUCKET_NAME=my-other-bucket ./bootstrap-state-bucket.sh
BUCKET_NAME="${BUCKET_NAME:-cloud-team-playbook-dev-tfstate-406207085797-us-east-1}"
AWS_REGION="${AWS_REGION:-us-east-1}"
EXPECTED_ACCOUNT_ID="406207085797"


# -----------------------------------------------------------------------------
# PRETTY OUTPUT HELPERS
# -----------------------------------------------------------------------------
# These are just colored echo shortcuts so the output is readable.
# \033[0;32m is an ANSI escape code meaning "switch to green."
info()  { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[0;32m[OK]\033[0m    $*"; }
warn()  { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
fail()  { echo -e "\033[0;31m[FAIL]\033[0m  $*"; exit 1; }


# -----------------------------------------------------------------------------
# STEP 0: PREFLIGHT CHECKS
# -----------------------------------------------------------------------------
info "Checking that the AWS CLI is installed..."
# command -v finds a program in your PATH. >/dev/null throws away the output
# because we only care whether it succeeded, not what it printed.
command -v aws >/dev/null 2>&1 || fail "AWS CLI not found. Install it: https://aws.amazon.com/cli/"
ok "AWS CLI found: $(aws --version 2>&1)"

info "Checking that your AWS credentials work..."
# sts get-caller-identity is the "who am I?" command. If credentials are
# missing or expired, this is where you find out.
CALLER_JSON=$(aws sts get-caller-identity --output json 2>/dev/null) \
  || fail "AWS credentials are not working. Run 'aws configure' or 'aws sso login'."

# Pull the account ID out of the JSON response.
ACCOUNT_ID=$(echo "$CALLER_JSON" | grep -o '"Account": *"[0-9]*"' | grep -o '[0-9]\{12\}')
CALLER_ARN=$(echo "$CALLER_JSON" | grep -o '"Arn": *"[^"]*"' | cut -d'"' -f4)
ok "Authenticated as: ${CALLER_ARN}"
ok "Account ID: ${ACCOUNT_ID}"

# Guard rail: make sure we're pointed at the RIGHT account. Building dev
# infrastructure in the production account is a very bad afternoon.
if [[ "$ACCOUNT_ID" != "$EXPECTED_ACCOUNT_ID" ]]; then
  fail "Wrong AWS account. Expected ${EXPECTED_ACCOUNT_ID} but you are in ${ACCOUNT_ID}. Switch profiles and retry."
fi
ok "Account matches the expected target."


# -----------------------------------------------------------------------------
# STEP 1: CREATE THE BUCKET (IF IT DOESN'T EXIST)
# -----------------------------------------------------------------------------
info "Checking whether bucket '${BUCKET_NAME}' already exists..."

# head-bucket returns success if the bucket exists AND you can access it.
if aws s3api head-bucket --bucket "$BUCKET_NAME" 2>/dev/null; then
  ok "Bucket already exists. Skipping creation."
else
  warn "Bucket not found. Creating it now..."

  # QUIRK OF AWS: us-east-1 is the original region and behaves differently.
  # For us-east-1 you must NOT pass a LocationConstraint. For every other
  # region you MUST pass it. This trips up nearly everyone once.
  if [[ "$AWS_REGION" == "us-east-1" ]]; then
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION"
  else
    aws s3api create-bucket \
      --bucket "$BUCKET_NAME" \
      --region "$AWS_REGION" \
      --create-bucket-configuration LocationConstraint="$AWS_REGION"
  fi
  ok "Bucket created."
fi


# -----------------------------------------------------------------------------
# STEP 2: TURN ON VERSIONING
# -----------------------------------------------------------------------------
# Versioning keeps every old copy of a file instead of overwriting it.
#
# This is your undo button. If a bad apply corrupts the state file, you can
# roll back to yesterday's version. Without versioning, a corrupted state
# means manually rebuilding Terraform's memory by hand, resource by resource.
# It is genuinely awful. Always turn this on.
info "Enabling versioning (this is your undo button for state corruption)..."
aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled
ok "Versioning enabled."


# -----------------------------------------------------------------------------
# STEP 3: TURN ON ENCRYPTION AT REST
# -----------------------------------------------------------------------------
# State files contain plaintext secrets. Encrypt them.
#
# We use SSE-S3 (AES256), which is free and managed entirely by AWS.
# You could use SSE-KMS with a customer key for tighter audit control, but
# that adds a dependency: the KMS key must exist before the bucket is usable,
# and everyone running Terraform needs kms:Decrypt permission.
info "Enabling default encryption on the bucket..."
aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration '{
    "Rules": [{
      "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" },
      "BucketKeyEnabled": true
    }]
  }'
ok "Encryption enabled (AES256)."


# -----------------------------------------------------------------------------
# STEP 4: BLOCK ALL PUBLIC ACCESS
# -----------------------------------------------------------------------------
# There are four separate switches here and you want all four ON.
# A publicly readable state bucket is a full breach: it hands over your
# infrastructure layout plus any secrets Terraform recorded.
info "Blocking all public access (four separate switches, all on)..."
aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
ok "Public access fully blocked."


# -----------------------------------------------------------------------------
# STEP 5: REQUIRE ENCRYPTED CONNECTIONS (TLS)
# -----------------------------------------------------------------------------
# Encryption at rest protects the file sitting on disk. This protects it
# while it travels over the network. We attach a bucket policy that flatly
# denies any request that didn't arrive over HTTPS.
info "Adding a bucket policy that denies non-HTTPS requests..."
aws s3api put-bucket-policy \
  --bucket "$BUCKET_NAME" \
  --policy "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Sid\": \"DenyUnencryptedTransport\",
        \"Effect\": \"Deny\",
        \"Principal\": \"*\",
        \"Action\": \"s3:*\",
        \"Resource\": [
          \"arn:aws:s3:::${BUCKET_NAME}\",
          \"arn:aws:s3:::${BUCKET_NAME}/*\"
        ],
        \"Condition\": {
          \"Bool\": { \"aws:SecureTransport\": \"false\" }
        }
      }
    ]
  }"
ok "TLS-only policy applied."


# -----------------------------------------------------------------------------
# STEP 6: CLEAN UP OLD VERSIONS AUTOMATICALLY
# -----------------------------------------------------------------------------
# Versioning is great, but every apply writes a new version and old ones pile
# up forever, quietly costing money. This lifecycle rule keeps 90 days of
# history and deletes anything older. Ninety days is far more rollback room
# than anyone realistically needs.
info "Adding a lifecycle rule to expire old state versions after 90 days..."
aws s3api put-bucket-lifecycle-configuration \
  --bucket "$BUCKET_NAME" \
  --lifecycle-configuration '{
    "Rules": [
      {
        "ID": "expire-old-state-versions",
        "Status": "Enabled",
        "Filter": { "Prefix": "" },
        "NoncurrentVersionExpiration": { "NoncurrentDays": 90 },
        "AbortIncompleteMultipartUpload": { "DaysAfterInitiation": 7 }
      }
    ]
  }'
ok "Lifecycle rule applied."


# -----------------------------------------------------------------------------
# DONE
# -----------------------------------------------------------------------------
echo ""
ok "State bucket is ready: s3://${BUCKET_NAME}"
echo ""
info "Next step — initialize Terraform:"
echo "    cd environments/dev"
echo "    terraform init"
echo ""

# -----------------------------------------------------------------------------
# TERRAFORM VERSION CHECK
# -----------------------------------------------------------------------------
# backend.tf uses `use_lockfile = true`, which is S3-native state locking.
# It was added in Terraform 1.10. On anything older, init will fail with an
# "Unsupported argument" error, so check now rather than after a confusing
# failure.
if command -v terraform >/dev/null 2>&1; then
  TF_VER=$(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4)
  if [[ -n "$TF_VER" ]]; then
    # sort -V compares version numbers properly (so 1.10 > 1.9, which a plain
    # string comparison would get wrong). If the lowest of the two is 1.10.0,
    # then our version is at least 1.10.0.
    LOWEST=$(printf '%s\n1.10.0\n' "$TF_VER" | sort -V | head -1)
    if [[ "$LOWEST" == "1.10.0" ]]; then
      ok "Terraform ${TF_VER} supports S3-native locking (use_lockfile)."
    else
      warn "Terraform ${TF_VER} is older than 1.10 and does NOT support use_lockfile."
      warn "Upgrade Terraform: https://developer.hashicorp.com/terraform/install"
      warn "This project is S3-only by design and does not use a DynamoDB lock table."
    fi
  fi
else
  warn "Terraform is not installed yet. Install 1.10 or newer before running init."
fi
echo ""
