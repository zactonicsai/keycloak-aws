# Keycloak on AWS — Three Independent Terraform Projects

Split into three layers, each with its own state file, each deployable and destroyable on its own.

```
01-network  →  02-database  →  03-keycloak
   VPC           PostgreSQL      ALB + EC2 + Keycloak
```

---

## Table of Contents

1. [Why Three Projects Instead of One?](#1-why-three-projects-instead-of-one)
2. [Quick Start](#2-quick-start)
3. [How the Projects Talk to Each Other](#3-how-the-projects-talk-to-each-other)
4. [What Lives Where, and Why](#4-what-lives-where-and-why)
5. [Everyday Operations](#5-everyday-operations)
6. [Tearing Down Safely](#6-tearing-down-safely)
7. [Options and Tradeoffs](#7-options-and-tradeoffs)
8. [Troubleshooting](#8-troubleshooting)
9. [Costs](#9-costs)
10. [Command Reference](#10-command-reference)

---

## 1. Why Three Projects Instead of One?

### The problem with one big project

Imagine your whole house wired to a single circuit breaker. Change a light bulb, and you have to shut off the refrigerator.

That's a single Terraform state file. Every `terraform plan` reads and refreshes **everything**. Tweak a Keycloak setting and Terraform re-checks your VPC, your NAT gateway, your database. Three problems follow:

**It's slow.** A 60-resource refresh on every plan, when you changed one line.

**It's risky.** A typo in Keycloak config can produce a plan that wants to delete a subnet. You're one distracted `yes` away from a bad afternoon.

**It's all-or-nothing.** `terraform destroy` destroys *everything*. There's no way to say "just rebuild Keycloak, leave my database alone."

### The fix: separate state files

Each project gets its own state file. That gives you a **blast radius**.

> Running `terraform destroy` in `03-keycloak` **physically cannot** delete your VPC or your database. Not "shouldn't" — *cannot*. Those resources aren't in that state file, so Terraform has no record of them there and nothing to delete.

This isn't a convention you have to remember. It's structural.

### The cost of splitting

Two things get slightly harder:

1. **Order matters on first deploy.** 01, then 02, then 03.
2. **Wiring is more verbose.** Instead of `module.network.vpc_id`, you write `data.terraform_remote_state.network.outputs.vpc_id`.

That's the trade. For anything you care about, it's worth it.

### Different layers change at different speeds

| Layer | How often it changes | What a mistake costs |
|---|---|---|
| **01-network** | Almost never | High — everything depends on it |
| **02-database** | Rarely | **Very high** — data loss |
| **03-keycloak** | Constantly | Low — rebuild in 10 minutes |

Splitting by change rate means the risky layers sit still while you iterate on the safe one.

---

## 2. Quick Start

### Step 1 — Tools

```bash
terraform version    # need 1.10.0 or higher
aws sts get-caller-identity    # must show account 406207085797
```

> **Why 1.10?** These projects use `use_lockfile` for S3-native state locking. Older Terraform needs a separate DynamoDB table; we deliberately avoid that. On an older version `terraform init` fails outright.

### Step 2 — State bucket

```bash
cd keycloak-platform
./scripts/bootstrap-state-bucket.sh
```

Your bucket already exists, so this just verifies versioning, encryption, public-access blocking, and TLS-only. Safe to run repeatedly.

### Step 3 — Set your IP

```bash
curl ifconfig.me
```

Check `01-network/terraform.tfvars`:

```hcl
allowed_admin_ips = [
  "68.32.112.68",   # ← must be YOUR ip
]
```

### Step 4 — Deploy, in order

```bash
# Layer 1: VPC, subnets, KMS keys, security groups  (~3 min)
cd 01-network
terraform init
terraform apply

# Layer 2: PostgreSQL  (~10 min — RDS is slow)
cd ../02-database
terraform init
terraform apply

# Layer 3: ALB, EC2, Keycloak  (~8 min)
cd ../03-keycloak
terraform init
terraform apply
```

Or use the helper:

```bash
./scripts/deploy-all.sh
```

### Step 5 — Log in

```bash
cd 03-keycloak
terraform output -raw get_admin_password    # copy and run the printed command
terraform output keycloak_admin_console_url
```

> ⚠️ Certificate warning is expected with the self-signed default. Click **Advanced → Proceed**.

---

## 3. How the Projects Talk to Each Other

### The mechanism: `terraform_remote_state`

A downstream project reads an upstream project's state **read-only**:

```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "cloud-team-playbook-dev-tfstate-406207085797-us-east-1"
    key    = "keycloak/dev/01-network/terraform.tfstate"
    region = "us-east-1"
  }
}

# Then use it:
vpc_id = data.terraform_remote_state.network.outputs.vpc_id
```

**Module vs remote state — the key difference:**

| | `module.network.vpc_id` | `data.terraform_remote_state.network.outputs.vpc_id` |
|---|---|---|
| State files | One, shared | **Two, separate** |
| Applied | Together | **Independently** |
| Can modify upstream? | Yes | **No — read-only** |

### Outputs are a published API

> **Critical:** a downstream project can only see what the upstream project **exports as an output**. A resource can exist in project 01's state and be completely invisible to project 03 unless `outputs.tf` exposes it.
>
> Deleting an output breaks downstream projects on their next plan. Treat `outputs.tf` like a public interface, not scratch notes.

### What flows where

```
01-network exports:              02-database exports:
  vpc_id                           db_address
  private_subnet_ids               db_port
  public_subnet_ids                db_name
  ebs_kms_key_arn                  db_secret_arn   ← ARN only, never the password
  secrets_kms_key_arn
  alb_security_group_id
  keycloak_security_group_id
  admin_cidrs
  name_prefix, common_tags
        │                                 │
        ├─────────────┬───────────────────┘
        ▼             ▼
   02-database    03-keycloak
```

### The password never travels through state

Project 02 exports the **secret ARN**, not the password. Project 03 grants its EC2 role permission to read that ARN, and the instance fetches the actual value at boot.

**Why this matters:** Terraform stores outputs in state files in **plaintext**. Passing the password as an output would write it into project 02's state *and* project 03's state. Passing only the ARN keeps it in exactly one place — Secrets Manager.

---

## 4. What Lives Where, and Why

### The rule

> A resource belongs in the **lowest layer that any other layer needs it from.**

### 01-network — the foundation

| Resource | Why here |
|---|---|
| VPC, subnets, IGW, NAT, routes | Obviously the network layer |
| VPC endpoints | Same |
| **KMS keys** | *Both* 02 and 03 need them |
| **Security groups (ALB + Keycloak)** | 02 needs the Keycloak group to write its DB rule |

The last two surprise people. Here's the reasoning:

Project 02 writes a database rule saying *"allow PostgreSQL from the Keycloak security group."* That reference must resolve **before project 03 has ever been applied**. So the security group has to already exist — which means it belongs in 01.

If the groups lived in 03, then 02 would depend on 03, and the whole ordering inverts.

### 02-database — the durable layer

RDS PostgreSQL, subnet group, DB security group, credentials secret.

Separate because the database should be rebuilt approximately **never**, while Keycloak gets rebuilt constantly.

### 03-keycloak — the disposable layer

ALB, certificate, target group, listeners, launch template, ASG, IAM role, admin secret, realm S3 bucket.

Destroy and rebuild this freely. Nothing here holds state you can't recreate in 10 minutes.

---

## 5. Everyday Operations

### Your IP changed

Home ISPs rotate addresses every few weeks. When Keycloak stops loading:

```bash
curl ifconfig.me
# edit 01-network/terraform.tfvars
cd 01-network && terraform apply
```

**Only project 01.** The change takes effect immediately — you don't touch 02 or 03.

### Upgrade Keycloak

```bash
# edit keycloak_version in 03-keycloak/terraform.tfvars
cd 03-keycloak && terraform apply
```

The ASG does a rolling instance refresh. Your data is safe in RDS.

### Resize the database

```bash
# edit instance_class in 02-database/terraform.tfvars
cd 02-database && terraform apply
```

With `apply_immediately = false` (the default), this waits for the maintenance window rather than restarting mid-day.

### Change the realm

```bash
cp realms/example-realm.json.example realms/myrealm-realm.json
# edit it
cd 03-keycloak && terraform apply
terraform output realm_source    # confirm your file was picked up
```

> ⚠️ Keycloak only imports realms that **don't already exist**. On restart, an existing realm is left alone — your users are safe, but edits to the file won't apply to a live realm either. Delete the realm first, or use the admin API.

---

## 6. Tearing Down Safely

This is where the split pays off.

| Command | What dies | What survives |
|---|---|---|
| `cd 03-keycloak && terraform destroy` | ALB, EC2, Keycloak | **VPC + database** |
| `cd 02-database && terraform destroy` | PostgreSQL | **VPC** |
| `cd 01-network && terraform destroy` | VPC | nothing |

**Destroy in reverse order: 03 → 02 → 01.** Going the other way fails, because AWS refuses to delete a VPC that still has things in it.

### Save money overnight

```bash
cd 03-keycloak && terraform destroy    # kills the expensive compute
# next morning:
terraform apply                         # ~8 minutes, data intact
```

Your users and realms are in RDS, untouched. This is the single biggest cost lever you have.

---

## 7. Options and Tradeoffs

### Skip the database entirely

Set `use_rds = false` in `03-keycloak/terraform.tfvars` and project 02 becomes optional.

| | `use_rds = true` | `use_rds = false` |
|---|---|---|
| Data survives instance replacement | ✅ | ❌ **everything lost** |
| Can run 2+ nodes | ✅ | ❌ H2 can't be shared |
| Backups | ✅ | ❌ |
| Cost | +$12–25/mo | free |

> The ASG **will** replace the instance — on any health check failure or template change. With H2, data loss isn't a risk, it's a scheduled event. Use `false` only for throwaway testing.

### VPC endpoints

`create_vpc_endpoints = true` costs **~$73/month** — billed per endpoint *per AZ*, so 5 endpoints × 2 AZs = 10 billable interfaces.

Setting it `false` loses nothing functionally. SSM and KMS still work over the NAT gateway; you lose the private network path, not the capability.

### Certificate

| | ACM | Self-signed |
|---|---|---|
| ✅ | No warnings, auto-renews, free | Works with no domain |
| ❌ | Needs a domain in Route 53 | Scary browser warning |

---

## 8. Troubleshooting

### "Unsupported argument: use_lockfile"

Terraform older than 1.10. **Upgrade** — this project is S3-only by design and doesn't use a DynamoDB lock table.

### "Error: Unable to find remote state"

Project 03 can't read project 01's state. Either:
- Project 01 hasn't been applied yet → apply it
- The `key` in 03's tfvars doesn't match 01's `backend.tf` → compare them

### "This object does not have an attribute named X"

Project 01 doesn't export what a downstream project wants. Add the output to `01-network/outputs.tf` and re-apply project 01.

### 503 from the load balancer

Instance still booting, or failing health checks:

```bash
cd 03-keycloak
aws elbv2 describe-target-health --target-group-arn $(terraform output -raw target_group_arn)
```

`initial` = wait. `unhealthy` = check logs:

```bash
aws ssm start-session --target <instance-id>
sudo tail -100 /var/log/user-data.log
sudo journalctl -u keycloak -n 100
```

### Keycloak can't reach the database

```bash
# On the instance:
sudo grep -A5 '^db' /opt/keycloak/conf/keycloak.conf
timeout 3 bash -c "cat < /dev/null > /dev/tcp/<db-host>/5432" && echo reachable
```

If unreachable, check that project 02's security group rule references project 01's Keycloak security group.

### Page won't load at all

**Your IP changed.** See [Everyday Operations](#5-everyday-operations).

---

## 9. Costs

Monthly, us-east-1, running 24/7:

| Layer | Item | Monthly |
|---|---|---|
| **01** | VPC interface endpoints (5 × 2 AZ) | **$73.00** |
| **01** | NAT Gateway | **$32.85** |
| 01 | KMS keys (2) | $2.00 |
| 01 | VPC, subnets, IGW, routes, SGs | $0.00 |
| **02** | RDS db.t4g.micro | **$12.41** |
| 02 | RDS storage 20 GB gp3 | $2.30 |
| 02 | Secrets Manager | $0.40 |
| **03** | EC2 t3.medium | **$30.37** |
| 03 | Application Load Balancer | $16.43 |
| 03 | ALB LCU (light) | $5.84 |
| 03 | EBS gp3 30 GB | $2.40 |
| 03 | Secrets Manager, S3, logs | $0.95 |
| | **TOTAL** | **≈ $179** |

### Cutting it down

| Change | Saves | New total |
|---|---|---|
| `create_vpc_endpoints = false` | $73 | $106 |
| ...plus `t3.small` | $15 | $91 |
| **Destroy 03 overnight** (16h/day) | ~$37 | **~$54** |

Destroying layer 03 nightly is the biggest lever, and it's safe — the database keeps your data.

---

## 10. Command Reference

```bash
# Deploy everything in order
./scripts/deploy-all.sh

# Or one layer at a time
cd 01-network  && terraform init && terraform apply
cd 02-database && terraform init && terraform apply
cd 03-keycloak && terraform init && terraform apply

# Destroy — REVERSE order
cd 03-keycloak && terraform destroy
cd 02-database && terraform destroy
cd 01-network  && terraform destroy

# Inspect
terraform output                    # all outputs for current layer
terraform output realm_source       # which realm was used
terraform output database_mode      # RDS or H2?

# Credentials
cd 03-keycloak && terraform output -raw get_admin_password
cd 02-database && terraform output -raw get_db_password

# Shell on the instance (no SSH)
aws ssm start-session --target <instance-id>

# Tunnel to the database (no inbound rule needed)
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["<db-address>"],"portNumber":["5432"],"localPortNumber":["5432"]}'

# Health
aws elbv2 describe-target-health --target-group-arn $(terraform output -raw target_group_arn)

# Formatting and validation
terraform fmt -recursive
terraform validate
```

---

## Directory Layout

```
keycloak-platform/
│
├── 01-network/              STATE FILE 1 — VPC, KMS, security groups
├── 02-database/             STATE FILE 2 — PostgreSQL
├── 03-keycloak/             STATE FILE 3 — ALB, EC2, Keycloak
│
├── modules/                 shared, used by all three
│   ├── network/  kms/  security/  database/  alb/  compute/
│
├── realms/                  realm JSON exports
└── scripts/
    ├── bootstrap-state-bucket.sh
    └── deploy-all.sh
```

Each numbered folder has the same six files: `backend.tf` (its state key), `main.tf`, `variables.tf`, `terraform.tfvars`, `outputs.tf`, `providers.tf`.
