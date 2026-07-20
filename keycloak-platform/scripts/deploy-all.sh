#!/usr/bin/env bash
# =============================================================================
# deploy-all.sh - apply all three projects in the correct order
# =============================================================================
# Layer 3 depends on layer 2 depends on layer 1, so order is not optional
# on a first deploy. This script enforces it.
#
# USAGE:
#   ./scripts/deploy-all.sh              # apply everything
#   ./scripts/deploy-all.sh plan         # preview only, changes nothing
#   ./scripts/deploy-all.sh destroy      # tear down in REVERSE order
#   SKIP_DB=true ./scripts/deploy-all.sh # skip layer 2 (H2 database)
# =============================================================================

set -euo pipefail

ACTION="${1:-apply}"
SKIP_DB="${SKIP_DB:-false}"

# Find the project root regardless of where the script is called from.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[0;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
fail() { echo -e "\033[0;31m[FAIL]\033[0m  $*"; exit 1; }

banner() {
  echo ""
  echo "==================================================================="
  echo "  $*"
  echo "==================================================================="
}

# --- Preflight ---
command -v terraform >/dev/null 2>&1 || fail "Terraform not installed."

TF_VER=$(terraform version -json 2>/dev/null | grep -o '"terraform_version":"[^"]*"' | cut -d'"' -f4)
# sort -V compares version numbers correctly (1.10 > 1.9, which string
# comparison gets wrong). If the lower of the two is 1.10.0, we are >= 1.10.0.
LOWEST=$(printf '%s\n1.10.0\n' "$TF_VER" | sort -V | head -1)
[[ "$LOWEST" == "1.10.0" ]] || fail "Terraform $TF_VER is too old. Need 1.10+ for use_lockfile."
ok "Terraform $TF_VER"

aws sts get-caller-identity >/dev/null 2>&1 || fail "AWS credentials not working."
ok "AWS credentials valid"

# --- Build the layer list ---
if [[ "$SKIP_DB" == "true" ]]; then
  warn "SKIP_DB=true - skipping 02-database."
  warn "Remember to set use_rds=false in 03-keycloak/terraform.tfvars,"
  warn "or layer 3 will fail trying to read a state file that does not exist."
  LAYERS=(01-network 03-keycloak)
else
  LAYERS=(01-network 02-database 03-keycloak)
fi

# Destroy must run in REVERSE order: you cannot delete a VPC that still
# has a database and a load balancer inside it.
if [[ "$ACTION" == "destroy" ]]; then
  # Reverse the array.
  REVERSED=()
  for (( i=${#LAYERS[@]}-1 ; i>=0 ; i-- )); do REVERSED+=("${LAYERS[i]}"); done
  LAYERS=("${REVERSED[@]}")

  banner "DESTROY - reverse order: ${LAYERS[*]}"
  warn "This deletes infrastructure. Layer 02 holds your Keycloak data."
  read -rp "Type 'destroy' to confirm: " CONFIRM
  [[ "$CONFIRM" == "destroy" ]] || fail "Cancelled."
fi

# --- Run each layer ---
for layer in "${LAYERS[@]}"; do
  banner "LAYER: $layer  ($ACTION)"
  cd "$ROOT/$layer"

  # -input=false stops Terraform from prompting for a missing variable and
  # hanging forever in a script.
  info "terraform init"
  terraform init -input=false

  case "$ACTION" in
    plan)
      terraform plan -input=false
      ;;
    apply)
      terraform apply -input=false -auto-approve
      ok "$layer applied"
      ;;
    destroy)
      terraform destroy -input=false -auto-approve
      ok "$layer destroyed"
      ;;
    *)
      fail "Unknown action '$ACTION'. Use plan, apply, or destroy."
      ;;
  esac
done

# --- Summary ---
if [[ "$ACTION" == "apply" ]]; then
  banner "ALL LAYERS APPLIED"
  cd "$ROOT/03-keycloak"
  terraform output next_steps 2>/dev/null || true
elif [[ "$ACTION" == "destroy" ]]; then
  banner "ALL LAYERS DESTROYED"
fi
