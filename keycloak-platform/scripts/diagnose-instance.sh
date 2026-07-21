#!/usr/bin/env bash
# =============================================================================
# diagnose-instance.sh - find out why Keycloak is not answering
# =============================================================================
# Run this when the load balancer returns 503, or Keycloak will not load.
#
# There is no Auto Scaling Group in this stack, so a failed instance is NOT
# replaced automatically. This script tells you what state it is actually in.
#
# USAGE:  ./scripts/diagnose-asg.sh
# =============================================================================

set -uo pipefail   # NOT -e: we want to keep going even when a check fails

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT/03-keycloak"

info() { echo -e "\033[0;34m[INFO]\033[0m  $*"; }
ok()   { echo -e "\033[0;32m[OK]\033[0m    $*"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m  $*"; }
bad()  { echo -e "\033[0;31m[BAD]\033[0m   $*"; }

banner() { echo ""; echo "=== $* ==="; }

# -----------------------------------------------------------------------------
# STEP 1: Find the instance
# -----------------------------------------------------------------------------
banner "1. Locating the Keycloak instance"

INSTANCE=$(terraform output -raw instance_id 2>/dev/null || echo "")
if [[ -z "$INSTANCE" ]]; then
  warn "Could not read instance_id from Terraform. Searching by tag..."
  INSTANCE=$(aws ec2 describe-instances \
    --filters "Name=tag:Name,Values=*keycloak*" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null)
fi
[[ -z "$INSTANCE" || "$INSTANCE" == "None" ]] && { bad "No Keycloak instance found."; exit 1; }
ok "Instance: $INSTANCE"

# -----------------------------------------------------------------------------
# STEP 2: Is the instance actually running and passing its status checks?
# -----------------------------------------------------------------------------
banner "2. EC2 instance state and status checks"

aws ec2 describe-instance-status --instance-ids "$INSTANCE" --include-all-instances \
  --query 'InstanceStatuses[0].{State:InstanceState.Name,System:SystemStatus.Status,Instance:InstanceStatus.Status}' \
  --output table 2>/dev/null

echo ""
info "What these mean:"
echo "    State=running, both checks 'ok'  -> the VM is fine; problem is Keycloak"
echo "    System check failed              -> AWS hardware issue; auto-recovery should fire"
echo "    Instance check failed            -> the OS is unreachable or misconfigured"
echo "    State=stopped/terminated         -> nothing is running. NO ASG will replace it."

# -----------------------------------------------------------------------------
# STEP 3: Target group health - what the ALB thinks
# -----------------------------------------------------------------------------
banner "3. ALB target health"

TG=$(terraform output -raw target_group_arn 2>/dev/null || echo "")
if [[ -n "$TG" ]]; then
  aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
    --output table 2>/dev/null

  echo ""
  info "State meanings:"
  echo "    initial   - still booting. Normal for the first ~10 minutes."
  echo "    unhealthy - Keycloak is not answering /health/ready on port 9000."
  echo "    healthy   - working."
  echo "    unused    - the instance is not registered with the target group."
else
  warn "No target group ARN in state."
fi

# -----------------------------------------------------------------------------
# STEP 4: The boot log
# -----------------------------------------------------------------------------
banner "4. Boot log"

info "Console output (may be empty for the first few minutes):"
aws ec2 get-console-output --instance-id "$INSTANCE" --output text 2>/dev/null | tail -30 \
  || warn "Console output not available yet."

echo ""
info "Full log with per-step timings:"
echo ""
echo "    aws ssm start-session --target $INSTANCE"
echo "    sudo cat /var/log/user-data.log       # [+NNNs] markers per step"
echo "    sudo journalctl -u keycloak -n 100    # Keycloak itself"
echo ""

# -----------------------------------------------------------------------------
# STEP 5: Verdict
# -----------------------------------------------------------------------------
banner "5. What to do"

cat <<'GUIDANCE'
  Target health "healthy":
      Working. If the browser still fails, check your IP:
          curl ifconfig.me
      and compare against 01-network/terraform.tfvars.

  Target health "initial":
      Still booting. Keycloak takes 5-12 minutes on a fresh instance. Wait.

  Target health "unhealthy", instance running:
      Keycloak failed to start. Read the boot log above. Common causes:
        - cannot reach the database (check project 02 security group rules)
        - cannot read a secret (IAM needs BOTH secretsmanager:GetSecretValue
          AND kms:Decrypt on the key)
        - no outbound internet (NAT gateway missing or route broken)

  Instance stopped or terminated:
      There is NO Auto Scaling Group, so nothing rebuilds it. Do it yourself:
          terraform taint module.compute.aws_instance.keycloak
          terraform apply

  Want automatic replacement back?
      Add an Auto Scaling Group - but set health_check_grace_period to at
      least 900s, or it will terminate instances mid-boot in a loop.
GUIDANCE
