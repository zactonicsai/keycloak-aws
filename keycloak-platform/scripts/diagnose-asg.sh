#!/usr/bin/env bash
# =============================================================================
# diagnose-asg.sh - find out why the Auto Scaling Group has no healthy instance
# =============================================================================
# Run this when `terraform apply` fails with:
#   "waiting for Auto Scaling Group capacity satisfied: timeout while waiting
#    for state to become 'ok' (last state: want at least 1 healthy instance)"
#
# That message tells you the ASG never got a healthy instance. It does NOT
# tell you why. This script answers that.
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
# STEP 1: Find the ASG
# -----------------------------------------------------------------------------
banner "1. Locating the Auto Scaling Group"

ASG=$(terraform output -raw autoscaling_group_name 2>/dev/null || echo "")
if [[ -z "$ASG" ]]; then
  warn "Could not read the ASG name from Terraform output."
  warn "The apply failed, so state may be incomplete. Searching by tag instead..."
  ASG=$(aws autoscaling describe-auto-scaling-groups \
    --query "AutoScalingGroups[?contains(AutoScalingGroupName,'keycloak')].AutoScalingGroupName | [0]" \
    --output text 2>/dev/null)
fi
[[ -z "$ASG" || "$ASG" == "None" ]] && { bad "No Keycloak ASG found. Did the apply get that far?"; exit 1; }
ok "ASG: $ASG"

# -----------------------------------------------------------------------------
# STEP 2: Activity history - THE MOST USEFUL CHECK
# -----------------------------------------------------------------------------
# This is where the ASG records WHY it terminated an instance. If you see
# repeated "Terminating EC2 instance" entries, the instance is being killed
# and relaunched in a loop - almost always because health_check_grace_period
# is shorter than the boot takes.
banner "2. ASG activity history (why instances were terminated)"

aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "$ASG" \
  --max-records 10 \
  --query 'Activities[].{Time:StartTime,Status:StatusCode,Cause:Cause}' \
  --output text 2>/dev/null | head -30

echo ""
TERMINATIONS=$(aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "$ASG" --max-records 20 \
  --query "length(Activities[?contains(Description,'Terminating')])" \
  --output text 2>/dev/null || echo 0)

if [[ "$TERMINATIONS" -gt 1 ]]; then
  bad "$TERMINATIONS terminations recorded - this is a KILL/RESPAWN LOOP."
  bad "The ASG is terminating instances before Keycloak finishes installing."
  bad "FIX: raise health_check_grace_period in 03-keycloak/terraform.tfvars"
else
  ok "No termination loop detected."
fi

# -----------------------------------------------------------------------------
# STEP 3: Current instances
# -----------------------------------------------------------------------------
banner "3. Instances currently in the ASG"

aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[].{Id:InstanceId,Lifecycle:LifecycleState,Health:HealthStatus}' \
  --output table 2>/dev/null

INSTANCE=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text 2>/dev/null)

# -----------------------------------------------------------------------------
# STEP 4: Target group health - what the ALB actually thinks
# -----------------------------------------------------------------------------
banner "4. ALB target health"

TG=$(terraform output -raw target_group_arn 2>/dev/null || echo "")
if [[ -n "$TG" ]]; then
  aws elbv2 describe-target-health --target-group-arn "$TG" \
    --query 'TargetHealthDescriptions[].{Target:Target.Id,State:TargetHealth.State,Reason:TargetHealth.Reason,Desc:TargetHealth.Description}' \
    --output table 2>/dev/null

  echo ""
  info "What the states mean:"
  echo "    initial   - still booting. Normal for the first ~10 minutes."
  echo "    unhealthy - Keycloak is not answering /health/ready on port 9000."
  echo "    healthy   - working. If you see this, the timeout was just too short."
  echo "    draining  - being removed."
else
  warn "No target group ARN in state."
fi

# -----------------------------------------------------------------------------
# STEP 5: The boot log - where the real answer usually is
# -----------------------------------------------------------------------------
banner "5. Boot log from the instance"

if [[ -n "$INSTANCE" && "$INSTANCE" != "None" ]]; then
  info "Instance: $INSTANCE"
  info "Fetching console output (may be empty for the first ~4 minutes)..."

  aws ec2 get-console-output --instance-id "$INSTANCE" --output text 2>/dev/null \
    | tail -40 || warn "Console output not available yet."

  echo ""
  info "For the FULL boot log with per-step timings, connect and read it:"
  echo ""
  echo "    aws ssm start-session --target $INSTANCE"
  echo "    sudo cat /var/log/user-data.log        # our script, with [+NNNs] markers"
  echo "    sudo journalctl -u keycloak -n 100     # Keycloak itself"
  echo ""
  info "The [+NNNs] markers show elapsed seconds per step, so you can see"
  info "exactly which step is eating the time budget."
else
  warn "No instance currently running - it was likely terminated."
  warn "That is consistent with a kill/respawn loop. See step 2 above."
fi

# -----------------------------------------------------------------------------
# STEP 6: Verdict
# -----------------------------------------------------------------------------
banner "6. What to do"

cat <<'GUIDANCE'
  If step 4 shows "healthy":
      The instance worked; apply just stopped watching too early.
      Nothing is broken. Re-run `terraform apply` and it will converge.

  If step 2 shows repeated terminations:
      health_check_grace_period is too short. Raise it:
          health_check_grace_period = 1200   # in 03-keycloak/terraform.tfvars

  If step 4 shows "unhealthy" and the instance is alive:
      Keycloak failed to start. Read the boot log (step 5) - most common:
        - could not reach the database (check SG rules from project 02)
        - could not read a secret (check IAM: needs BOTH
          secretsmanager:GetSecretValue AND kms:Decrypt)
        - no internet egress (NAT gateway missing or route broken)

  If you just want apply to stop blocking entirely:
      wait_for_capacity_timeout = "0"     # in 03-keycloak/terraform.tfvars
      The instance still boots normally; Terraform just does not wait.
GUIDANCE
