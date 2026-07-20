# Keycloak on AWS with Terraform

A complete, locked-down Keycloak login server on AWS. Only **your** IP address can reach it.

---

## Table of Contents

1. [What Is This? (Background)](#1-what-is-this-background)
2. [Quick Start: One Example, Step by Step](#2-quick-start-one-example-step-by-step)
3. [What Just Got Built](#3-what-just-got-built)
4. [The Directory Structure Explained](#4-the-directory-structure-explained)
5. [Every Piece in Detail](#5-every-piece-in-detail)
6. [The Realm File and the Fallback](#6-the-realm-file-and-the-fallback)
7. [Options, Pros and Cons](#7-options-pros-and-cons)
8. [Troubleshooting](#8-troubleshooting)
9. [Costs](#9-costs)
10. [Going to Production](#10-going-to-production)
11. [Command Reference](#11-command-reference)

---

## 1. What Is This? (Background)

### What is Keycloak?

Imagine every app at your school needed its own username and password. The lunch app, the grades app, the library app. You'd have twelve passwords and you'd forget all of them.

Now imagine instead there's **one** front desk. You show your ID once, and the front desk gives you a wristband. Every app just checks the wristband.

That front desk is **Keycloak**. It's free, open-source software that handles logging people in so your apps don't have to. The wristband is called a **token**.

Keycloak speaks standard languages that apps already understand — OpenID Connect, OAuth 2.0, and SAML. So most apps can use it without custom code.

### What is Terraform?

Normally you build cloud servers by clicking buttons on a website. That works once. But then:

- You can't remember what you clicked
- Your teammate can't copy it
- Rebuilding it after a mistake takes hours

**Terraform** lets you write down what you want in text files. Then it builds it. The text files are the instructions *and* the documentation *and* the backup, all at once.

This idea has a name: **Infrastructure as Code**. Your servers are described by files you can put in git, review, and roll back.

### What is AWS?

Amazon Web Services rents computers by the hour. Instead of buying a server, you borrow one. The pieces we use:

| Piece | Plain English |
|---|---|
| **EC2** | A rented computer |
| **VPC** | Your own private network, walled off from everyone else |
| **ALB** | A receptionist that greets visitors and passes them along |
| **KMS** | A vault that holds encryption keys |
| **Secrets Manager** | A safe for passwords |
| **ACM** | Free certificates so browsers show a padlock |
| **S3** | A giant hard drive in the cloud |

### What are we actually building?

```
        YOU (68.32.112.68)
              │
              │  HTTPS — and ONLY from your IP
              ▼
    ┌─────────────────────┐
    │   Load Balancer     │  ← public, but locked to your IP
    │   (holds the cert)  │
    └─────────────────────┘
              │
              │  private network only
              ▼
    ┌─────────────────────┐
    │  Keycloak Server    │  ← no public IP at all
    │  (private subnet)   │     encrypted disk
    └─────────────────────┘
```

The important part: the Keycloak server has **no public address**. It cannot be reached from the internet directly, even if someone knew where it was. The only way in is through the load balancer, and the load balancer only talks to you.

---

## 2. Quick Start: One Example, Step by Step

Follow these seven steps exactly and you'll have a working Keycloak in about 20 minutes.

### Step 1 — Install the tools

You need two programs.

**Terraform** (version 1.10 or newer):

```bash
# Mac
brew install terraform

# Windows
choco install terraform

# Linux
wget -O- https://apt.releases.hashicorp.com/gpg | sudo gpg --dearmor -o /usr/share/keyrings/hashicorp.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform
```

**AWS CLI**:

```bash
# Mac
brew install awscli

# Windows
choco install awscli

# Linux
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscli.zip
unzip awscli.zip && sudo ./aws/install
```

Check both worked:

```bash
terraform version   # must say 1.10.0 or higher
aws --version
```

> **Why 1.10 specifically?** This project stores state in S3 and locks it using S3 itself (`use_lockfile`), a feature added in 1.10. Older Terraform needs a separate DynamoDB table for locking; we deliberately avoid that, so **1.10 is a hard requirement here, not a suggestion.** On an older version `terraform init` will fail — see [Troubleshooting](#8-troubleshooting).

### Step 2 — Log in to AWS

```bash
aws configure
```

It asks four questions:

```
AWS Access Key ID:     (paste from AWS console)
AWS Secret Access Key: (paste from AWS console)
Default region name:   us-east-1
Default output format: json
```

Prove it worked:

```bash
aws sts get-caller-identity
```

You should see account `406207085797`. **If you see a different number, stop.** You're pointed at the wrong AWS account and would build things in the wrong place.

### Step 3 — Verify the state bucket

Terraform needs a place to store its memory. That place is an S3 bucket:

```
cloud-team-playbook-dev-tfstate-406207085797-us-east-1
```

**This bucket already exists** (created 2026-07-13), so there's nothing to create. But run this anyway to confirm the safety settings are right:

```bash
cd keycloak-aws
chmod +x scripts/bootstrap-state-bucket.sh
./scripts/bootstrap-state-bucket.sh
```

It checks — and fixes if needed — four things:

| Setting | Why it matters |
|---|---|
| **Versioning** | Your undo button if state gets corrupted |
| **Encryption** | State files contain plaintext passwords |
| **Public access blocked** | All four switches, no exceptions |
| **HTTPS required** | No plaintext transfer over the network |

The script skips creation when the bucket is already there, so it's safe to run as many times as you like.

> **This project uses S3 only.** There's no DynamoDB table. Locking happens natively in S3 via `use_lockfile = true`, which needs **Terraform 1.10+**. That's one less resource to create, pay for, and forget about. The script checks your Terraform version at the end and warns you if it's too old.

> **Chicken and egg:** why can't Terraform make this bucket? Because Terraform stores its memory *in* the bucket. It can't remember creating the thing it uses to remember. So it's made outside Terraform, once.

### Step 4 — Set your IP address

Find your current public IP:

```bash
curl ifconfig.me
```

Open `environments/dev/terraform.tfvars` and check the `allowed_admin_ips` line:

```hcl
allowed_admin_ips = [
  "68.32.112.68",   # ← this should be YOUR ip
]
```

It's already set to `68.32.112.68`. If `curl ifconfig.me` printed something different, change it.

> **This is the single most important line in the whole project.** Everything else is plumbing. This line is the lock on the door.

### Step 5 — Initialize Terraform

```bash
cd environments/dev
terraform init
```

This downloads the AWS plugin and connects to your state bucket. You should see:

```
Successfully configured the backend "s3"!
Terraform has been successfully initialized!
```

### Step 6 — Preview, then build

**Always preview first.** `plan` shows what *would* happen without doing it:

```bash
terraform plan
```

Read the summary at the bottom. It should say roughly:

```
Plan: 47 to add, 0 to change, 0 to destroy.
```

Green `+` means create. Red `-` means destroy. On a first run you should see **zero** destroys.

Now build it:

```bash
terraform apply
```

Type `yes` when asked. This takes **5–10 minutes**, and most of that is the load balancer and the instance booting up.

### Step 7 — Log in

When apply finishes, it prints your info. Get the password:

```bash
terraform output -raw get_admin_password
```

Copy that command, run it, and it prints the password.

Get the URL:

```bash
terraform output keycloak_admin_console_url
```

Open it in your browser.

> ⚠️ **You will see a certificate warning.** That's expected — we used a self-signed certificate because you don't have a domain yet. The connection *is* encrypted; it's just not vouched for by a third party. Click **Advanced → Proceed**.

Log in with username `kcadmin` and the password you just fetched.

**🎉 Done.**

---

## 3. What Just Got Built

47-ish resources. Here's the honest list.

| # | Resource | What it does |
|---|---|---|
| 1 | VPC | Your private network |
| 2 | 2 public subnets | Where the load balancer sits |
| 3 | 2 private subnets | Where Keycloak sits |
| 4 | Internet Gateway | The front door |
| 5 | NAT Gateway | One-way door out, for downloads |
| 6 | Route tables | Directions for network traffic |
| 7 | VPC endpoints | Private tunnels to AWS services |
| 8 | 2 KMS keys | One for the disk, one for the password |
| 9 | 2 security groups | The firewalls |
| 10 | ALB | The receptionist |
| 11 | Certificate | The padlock |
| 12 | Target group | The health-check list |
| 13 | 2 listeners | Port 443 (real) and port 80 (redirect) |
| 14 | Listener rule | Second lock on `/admin` |
| 15 | Launch template | Blueprint for the server |
| 16 | Auto Scaling Group | Keeps exactly 1 server alive |
| 17 | IAM role + policies | The server's permissions |
| 18 | Secrets Manager secret | The admin password |
| 19 | CloudWatch log group | Where logs go |
| 20 | S3 bucket + object | Holds the realm import file |

---

## 4. The Directory Structure Explained

```
keycloak-aws/
│
├── modules/                    ← reusable building blocks
│   ├── network/                    VPC, subnets, routes, endpoints
│   ├── security/                   security groups (YOUR IP LOCK)
│   ├── kms/                        encryption keys
│   ├── alb/                        load balancer, cert, target group
│   └── compute/                    EC2, IAM, secrets, realm import
│       └── user_data.sh                the boot script
│
├── environments/               ← one folder per environment
│   ├── dev/
│   │   ├── backend.tf              ← where state is stored (S3)
│   │   ├── main.tf                 ← wires the modules together
│   │   ├── variables.tf            ← what settings exist
│   │   ├── terraform.tfvars        ← the actual values (YOUR IP)
│   │   ├── outputs.tf              ← what to print when done
│   │   └── providers.tf            ← AWS plugin config
│   └── prod/
│
├── realms/                     ← your Keycloak realm exports
│   └── example-realm.json.example
│
└── scripts/
    └── bootstrap-state-bucket.sh
```

### Why modules?

A **module** is a folder of Terraform files you can reuse, like a function in programming.

Without modules, one giant `main.tf` with 2,000 lines. With modules, five focused folders you can read one at a time.

Each module has the same three files:

| File | Purpose |
|---|---|
| `variables.tf` | The **inputs** — what you must supply |
| `main.tf` | The **work** — what gets built |
| `outputs.tf` | The **results** — what other modules can read |

### Why separate environments?

`dev` and `prod` are separate folders with separate state files. This means **you cannot accidentally destroy production while testing.** They don't know about each other.

### Where state is stored

Both environments use the **same S3 bucket**, separated by the key (the path inside the bucket):

```
s3://cloud-team-playbook-dev-tfstate-406207085797-us-east-1/
├── keycloak/dev/terraform.tfstate     ← environments/dev
└── keycloak/prod/terraform.tfstate    ← environments/prod
```

Different keys means they can never overwrite each other. Applying dev cannot touch prod's state.

**What is "state"?** When Terraform builds something, it writes down what it built. That record maps `aws_instance.keycloak` in your code to `i-0abc123...` in real AWS. Without it, Terraform has amnesia — run `apply` twice and it builds everything twice.

**Why not keep it on your laptop?** Three reasons:

1. Your laptop dies → Terraform forgets it owns \$100/month of AWS resources that nobody can now cleanly delete
2. Two people apply at once → corrupted state
3. **State files contain plaintext secrets** — passwords, keys, tokens

The S3 backend fixes all three: encrypted, versioned, and locked while someone is working.

**Locking, S3-only.** While one person runs `apply`, Terraform writes a small `.tflock` file next to the state. Anyone else who tries gets blocked instead of stomping on it. The lock is deleted when the run finishes.

Older setups used a DynamoDB table for this. Terraform 1.10 moved it into S3 itself, so **this project needs no DynamoDB table at all.**

> **The tradeoff of sharing one bucket:** the bucket is the access boundary. Anyone who can read this bucket can read *both* state files — and therefore both environments' secrets. That's fine when the same people manage dev and prod. Split into two buckets the moment that stops being true.

---

## 5. Every Piece in Detail

### 5.1 The VPC and subnets

A **VPC** is your own private slice of AWS. Ours uses IP range `10.0.0.0/16`, which gives 65,536 addresses.

**CIDR notation** — the number after the slash says how many bits are locked:

| Notation | Addresses | Meaning |
|---|---|---|
| `10.0.0.0/16` | 65,536 | The whole VPC |
| `10.0.1.0/24` | 256 | One subnet |
| `68.32.112.68/32` | **1** | Exactly your computer |
| `0.0.0.0/0` | all | The entire internet |

We use `/32` for your IP because we want exactly one address, and nothing else.

**Public vs private subnets:**

- **Public** = has a route to the Internet Gateway. The load balancer lives here.
- **Private** = no such route. Keycloak lives here.

Two of each, in two different data centers, because a load balancer legally requires two.

### 5.2 Security groups — the IP lock

This is the heart of it. Two layers:

**Layer 1 — the load balancer's firewall:**
```
ALLOW port 443 FROM 68.32.112.68/32
ALLOW port 80  FROM 68.32.112.68/32   (redirect only)
```
Everything else is dropped. Security groups are **deny by default** — you never write "deny" rules, only "allow."

**Layer 2 — Keycloak's firewall:**
```
ALLOW port 8080 FROM <the load balancer's security group>
```

Read that carefully. The source is **not your IP**. It's the load balancer itself. Keycloak doesn't know who you are — it only trusts the receptionist.

That's **defense in depth**: even if someone found the server's private IP, they still couldn't reach it.

**No SSH.** There's no port 22 rule anywhere. Instead we use **SSM Session Manager**:

```bash
aws ssm start-session --target i-0abc123...
```

Better than SSH because: no open port to scan, no key file to lose, IAM controls access, and every session is logged.

### 5.3 KMS — the key vault

**KMS** holds encryption keys and never lets you see them. You hand it data and say "encrypt this."

Because you can never touch the key, you can never lose it or email it to the wrong person.

We make **two** keys:
- One for the **disk** (EBS)
- One for the **password** (Secrets Manager)

Two keys, not one, so a mistake in one policy doesn't expose both.

Both have **automatic rotation** on — new key material every year, free, no downside.

> ⚠️ **Every KMS key policy must let the account root manage it.** Leave that out and the key becomes permanently unmanageable. AWS support cannot rescue you.

### 5.4 The load balancer, certificate, and target group

**The certificate** makes the padlock appear. Two options:

| | ACM certificate | Self-signed |
|---|---|---|
| Needs a domain | Yes | No |
| Browser warning | None | Yes, scary |
| Cost | Free | Free |
| Auto-renews | Yes | No |
| Good for | Real use | Testing |

We default to self-signed so you can start with no domain.

**The target group** is the list of servers plus the health check:

```
Check http://<server>:9000/health/ready every 30 seconds
2 passes  → healthy, send traffic
5 failures → unhealthy, stop sending
```

> **If you ever see a 503 error, it's almost always this.** A 503 means every target failed its health check.

**The listeners:**
- Port 443 → forward to Keycloak
- Port 80 → redirect to 443 (never serves real traffic)

**The listener rules** are the second lock — and there are **two** of them, for a reason worth understanding.

An ALB listener rule cannot say "NOT". The only condition types available are `host_header`, `http_header`, `http_request_method`, `path_pattern`, `query_string`, and `source_ip` — all positive matches, all ANDed together. There is no `not_source_ip` and no deny action.

So "block /admin from everyone except me" is expressed as two rules that rely on the ALB stopping at the first match:

| Priority | Condition | Action |
|---|---|---|
| 100 | path is `/admin` **AND** source IP is yours | forward |
| 110 | path is `/admin` (any remaining IP) | **403** |

Your request matches rule 100 and never reaches 110. Anyone else fails rule 100's IP condition, falls through, matches 110 on path alone, and gets a 403.

**The order is what creates the "NOT."** Rule 110 must have the *higher* number, or the deny would fire first and lock you out too.

> `source_ip` matches the real client IP as the ALB sees it, and deliberately ignores `X-Forwarded-For` — which a client can trivially forge. That's what makes this check trustworthy.

### 5.5 The EC2 instance

**Auto Scaling Group set to exactly 1.** Why an ASG for one server? **Self-healing.** A plain instance that crashes stays crashed until a human notices. An ASG rebuilds it in minutes. The ASG itself is free.

**The launch template** is the blueprint:
- Newest Amazon Linux 2023 (looked up, never hardcoded — AMI IDs differ per region and change constantly)
- Encrypted 30 GB gp3 disk
- **IMDSv2 required** — blocks SSRF attacks that steal IAM credentials
- The boot script

**The IAM role** is a badge the server wears. Better than access keys because there's nothing permanent to steal — credentials rotate automatically.

Permissions are scoped tight (**least privilege**):
- Read **one specific secret**, not all secrets
- Use **our two KMS keys**, not all keys
- Write to **our log group**, not all logs

> **Common gotcha:** reading an encrypted secret needs *both* `secretsmanager:GetSecretValue` **and** `kms:Decrypt`. Missing the second gives an "access denied" that doesn't say why.

### 5.6 The boot script

Runs once as root, first boot. Ten steps:

1. Install Java 21 and tools
2. Create a `keycloak` user with **no login shell** (never run web apps as root)
3. Download and unpack Keycloak
4. Fetch the password from Secrets Manager
5. **Write the realm file** ← the fallback happens here
6. Write `keycloak.conf`
7. Run the build step
8. Install the systemd service
9. Wait for health check to pass
10. Verify the realm imported

Watch it live:

```bash
aws ssm start-session --target <instance-id>
sudo tail -f /var/log/user-data.log
```

> **The most important config line** is `proxy-headers=xforwarded`. Without it, Keycloak builds redirect URLs from its own private IP and login breaks with a redirect loop. This is the #1 Keycloak-behind-a-load-balancer failure.

---

## 6. The Realm File and the Fallback

### What's a realm?

A **realm** is a completely separate tenant inside Keycloak — its own users, own login page, own apps. Realms can't see each other.

Think of Keycloak as an apartment building and each realm as an apartment.

### The fallback you asked for

**If your realm file exists → it gets imported.**
**If it doesn't → a sensible default is built instead.**

Either way, `terraform apply` succeeds.

**Where the realm actually lives:** Terraform resolves which JSON to use, then uploads it to a dedicated **S3 bucket**. The instance downloads it at boot using its IAM role.

Why not just embed it in the boot script? EC2 `user_data` is hard-capped at **16,384 bytes after base64 encoding** — and base64 inflates by ~33%. A realm with a few hundred users blows past that, and AWS rejects it at launch with `InvalidUserData.Malformed`. Moving the realm to S3 removes the ceiling entirely, and editing the realm no longer forces the launch template to be replaced.

Here's the actual logic, in `modules/compute/main.tf`:

```hcl
locals {
  # 1. Where should the file be?
  realm_file_path = var.realm_file_path != "" ? var.realm_file_path : "${path.module}/../../realms/${var.realm_name}-realm.json"

  # 2. Is it actually there?
  realm_file_exists = fileexists(local.realm_file_path)

  # 3. Pick one.
  realm_json = local.realm_file_exists ? file(local.realm_file_path) : jsonencode(local.default_realm)
}
```

**Why `fileexists()` and not just `file()`?** Because `file()` **crashes** on a missing file and kills the whole run. `fileexists()` returns true/false so we can handle it gracefully.

### Which one did I get?

```bash
terraform output realm_source
```

Prints either:
```
file: ../../realms/myrealm-realm.json
```
or:
```
built-in default (no file found at ../../realms/myrealm-realm.json)
```

**No guessing.**

### What's in the default realm?

Not a stub — a genuinely usable realm:

- Brute-force protection (lock after 5 failures)
- Strong password policy (12+ chars, mixed case, digit, symbol, no username, remembers last 3)
- 5-minute access tokens
- Roles: `user`, `admin`
- One public client with **PKCE required**
- Optional seed user with a forced password change

### Using your own realm

**Option A — export from a running Keycloak:**

Admin console → Realm settings → Action → Partial export → include groups, roles, and clients.

**Option B — start from the example:**

```bash
cp realms/example-realm.json.example realms/myrealm-realm.json
```

The filename must be `<realm_name>-realm.json`. With `realm_name = "myrealm"`, that's `myrealm-realm.json`.

Then:

```bash
terraform apply
terraform output realm_source   # confirm it was picked up
```

> ⚠️ **Import only runs for realms that don't already exist.** On restart, an existing realm is left alone. Your users are safe — but it also means editing the file won't update a live realm. Delete the realm first, or use the admin API.

> ⚠️ **Never put real passwords in a realm file you commit to git.**

---

## 7. Options, Pros and Cons

### Certificate

| | ACM | Self-signed |
|---|---|---|
| ✅ | No warnings, auto-renews, free | Works instantly, no domain |
| ❌ | Needs a domain in Route 53 | Scary browser warning |
| Use for | Anything real | Testing only |

### Database

| | `dev-file` (H2) | PostgreSQL on RDS |
|---|---|---|
| ✅ | Free, zero setup | Survives instance replacement, backups, multi-node |
| ❌ | **Data dies with the instance**, single node only | ~$15/mo, more setup |
| Use for | Testing | **Anything you care about** |

### NAT Gateway

| | With NAT (default) | Public subnet instead |
|---|---|---|
| ✅ | Server unreachable from internet | Saves ~$32/mo |
| ❌ | ~$32/mo | Server has a public IP |
| Use for | Any real deployment | Throwaway experiments |

### Instance size

| Size | RAM | Verdict |
|---|---|---|
| t3.small | 2 GB | Boots, then thrashes |
| **t3.medium** | 4 GB | **Good default** |
| t3.large | 8 GB | Small production |
| m6i.large | 8 GB | Production — no burst credits to run out of |

> **About `t3`:** burstable instances earn CPU credits while idle and spend them under load. Run out and you're throttled hard. Fine for dev, risky for steady production traffic.

### Single instance vs multiple

Currently `min = max = 1`. Going to 2+ requires:

1. **PostgreSQL** — H2 can't be shared
2. **Stickiness** — already configured
3. **Clustering config** — Keycloak nodes need to find each other

Don't just raise `max_size` and hope.

---

## 8. Troubleshooting

### "503 Service Temporarily Unavailable"

Almost always: the instance is still booting, or failing health checks.

```bash
terraform output -raw target_group_arn
aws elbv2 describe-target-health --target-group-arn <that-arn>
```

- `initial` → still booting, wait
- `unhealthy` → check the logs
- `healthy` → it's something else

```bash
aws ssm start-session --target <instance-id>
sudo tail -100 /var/log/user-data.log
sudo journalctl -u keycloak -n 100
```

### The page won't load at all (timeout)

**Your IP changed.** This is the most common cause by far.

```bash
curl ifconfig.me
terraform output allowed_admin_ips
```

Don't match? Update `terraform.tfvars` and `terraform apply`.

### Certificate warning

Expected with self-signed. Click **Advanced → Proceed**. To remove it, get a domain and set `use_acm_certificate = true`.

### Login redirect loop

`keycloak_hostname` doesn't match what you're typing. It must be exactly the URL in your address bar.

### "Error acquiring the state lock"

Someone else is applying, or a previous run crashed.

```bash
# Only if you're CERTAIN nobody else is running
terraform force-unlock <lock-id>
```

### "Backend initialization required"

```bash
terraform init -reconfigure
```

### Terraform older than 1.10

`terraform init` fails with **"Unsupported argument: use_lockfile"**.

This project uses S3-native state locking, added in Terraform 1.10. **Upgrade Terraform:**

```bash
brew upgrade terraform          # Mac
choco upgrade terraform         # Windows
sudo apt update && sudo apt install --only-upgrade terraform   # Linux

terraform version               # confirm 1.10.0+
```

> **Why not just add a DynamoDB table instead?** That's the older approach and it works, but it means creating, paying for, and remembering another resource. Upgrading is simpler and it's where Terraform is going. This project is S3-only by design.

### "User data is limited to 16384 bytes"

`terraform apply` fails creating the launch template.

EC2 caps `user_data` at 16,384 bytes **after base64 encoding**, which adds ~33% overhead. This project handles it two ways:

1. **`base64gzip()`** compresses the boot script before encoding. cloud-init spots the gzip header and decompresses automatically. Our ~16 KB script becomes ~8 KB, about half the limit.
2. **The realm file lives in S3**, not in the script, so realm size can't push you over.

If you hit this after adding your own steps to `user_data.sh`, the script itself has grown too large. Move the bulk into a file in S3 and download it at boot, exactly as the realm does.

### Realm didn't import

```bash
terraform output realm_source
```

If it says "built-in default" but you made a file, check the filename is exactly `<realm_name>-realm.json` in `realms/`.

Validate your JSON:
```bash
jq empty realms/myrealm-realm.json
```

---

## 9. Costs

Rough monthly, us-east-1, running 24/7:

| Item | Cost |
|---|---|
| NAT Gateway | **~$32** ← biggest item |
| Load Balancer | ~$16 |
| VPC endpoints (5 × $7) | ~$35 |
| t3.medium | ~$30 |
| 30 GB gp3 disk | ~$2.40 |
| KMS keys (2 × $1) | ~$2 |
| Secrets Manager | ~$0.40 |
| **Total** | **~$118/month** |

**Cutting it down for dev:**

```hcl
create_vpc_endpoints = false   # saves ~$35
instance_type = "t3.small"     # saves ~$15
```

→ about **$68/month**.

**Biggest saving of all:** destroy it when you're not using it.

```bash
terraform destroy
```

Rebuilding takes 10 minutes. With `db_vendor = "dev-file"` you lose the data anyway, so there's nothing to protect.

---

## 10. Going to Production

The dev defaults are **not** production-ready. Change these:

**1. Real database** — H2 loses everything on instance replacement.
```hcl
db_vendor = "postgres"   # plus an RDS instance
```

**2. Real certificate**
```hcl
use_acm_certificate = true
domain_name         = "keycloak.example.com"
hosted_zone_name    = "example.com"
create_dns_records  = true
```

**3. Deletion protection**
```hcl
enable_deletion_protection = true
```

**4. Longer KMS window**
```hcl
kms_deletion_window_days = 30
```

**5. Consider splitting the state bucket** — dev and prod currently share `cloud-team-playbook-dev-tfstate-406207085797-us-east-1`, separated only by key path. That is safe from an *overwrite* standpoint (different keys can't collide), but the bucket is the **access** boundary: anyone who can read it can read both environments' secrets. Split them when dev and prod need different access lists.

**6. Multiple instances** — needs PostgreSQL and clustering config first.

**7. Turn on ALB access logs, and add CloudWatch alarms.**

**8. Restrict who can `terraform apply`** with IAM.

---

## 11. Command Reference

```bash
# Setup
./scripts/bootstrap-state-bucket.sh
cd environments/dev
terraform init

# Daily
terraform plan                  # preview — always do this first
terraform apply                 # build
terraform output                # show all results
terraform output realm_source   # which realm was used?
terraform destroy               # tear it all down

# Get the password
terraform output -raw get_admin_password

# Shell on the box (no SSH needed)
aws ssm start-session --target <instance-id>

# Logs
sudo tail -f /var/log/user-data.log
sudo journalctl -u keycloak -f

# Health
aws elbv2 describe-target-health --target-group-arn <arn>

# Force a rebuild of the instance
aws autoscaling start-instance-refresh --auto-scaling-group-name <name>

# Formatting and validation
terraform fmt -recursive
terraform validate
```

---

## Security Summary

What protects this deployment:

- ✅ Only `68.32.112.68` can reach the load balancer
- ✅ Second, independent IP check on `/admin` paths
- ✅ Keycloak has **no public IP**
- ✅ Only the load balancer can talk to Keycloak
- ✅ Disk encrypted with your own KMS key
- ✅ Password auto-generated, stored in Secrets Manager, never in a file
- ✅ **No SSH port open** — SSM instead
- ✅ IMDSv2 required (blocks credential theft via SSRF)
- ✅ Least-privilege IAM, scoped to specific resources
- ✅ Runs as a non-root user with no login shell
- ✅ TLS 1.2 minimum
- ✅ Restricted outbound traffic
- ✅ State in S3: encrypted, versioned, public access blocked, TLS-only, natively locked

**What still needs your attention:**

- ⚠️ Self-signed cert → get a domain
- ⚠️ H2 database → move to RDS
- ⚠️ Your IP will change → update `terraform.tfvars`
- ⚠️ Dev and prod share one state bucket → split when access needs differ
