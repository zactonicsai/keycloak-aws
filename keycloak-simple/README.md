# Keycloak on AWS — Minimal

One directory. One `terraform apply`. **22 AWS resources**, down from 69.

Only your IP (`68.32.112.68`) can reach it. The instance itself has no public address.

---

## What this is

```
        YOU (68.32.112.68)
              │  HTTPS — and only from your IP
              ▼
      ┌───────────────┐
      │ Load Balancer │   public, but locked to your IP
      └───────────────┘
              │  private network only
              ▼
      ┌───────────────┐
      │   Keycloak    │   no public IP at all
      └───────────────┘
```

**Keycloak** is a login server. Instead of every app managing its own passwords, they all ask Keycloak. It hands out a token — like a wristband — and apps just check the wristband.

---

## Quick start

**1. Check your tools**

```bash
terraform version                # need 1.10+
aws sts get-caller-identity      # should show 406207085797
```

**2. Check your IP**

```bash
curl ifconfig.me
```

If it isn't `68.32.112.68`, edit `my_ips` in `terraform.tfvars`.

**3. Deploy**

```bash
terraform init
terraform apply
```

Takes about 4 minutes to build, then **5–10 more** while Keycloak installs itself on the instance.

**4. Log in**

```bash
terraform output -raw admin_password
terraform output admin_console
```

> ⚠️ **You'll get a certificate warning.** Expected — the cert is self-signed. The connection *is* encrypted; it just isn't vouched for by a third party. Click **Advanced → Proceed**.

**5. Tear down when done**

```bash
terraform destroy
```

At ~$0.24/hour, destroying overnight is the biggest cost saver available.

---

## The files

| File | What's in it |
|---|---|
| `main.tf` | Providers, state storage |
| `network.tf` | VPC, subnets, routing, NAT, **firewalls** |
| `alb.tf` | Load balancer, TLS cert, target group |
| `keycloak.tf` | The instance, its IAM role, the realm |
| `setup.sh` | Boot script that installs Keycloak |
| `variables.tf` | Every setting |
| `terraform.tfvars` | **Your IP goes here** |

No modules. No layers. No separate state files. Read them top to bottom.

---

## What got cut, and why

Started at 69 resources. Now 22.

| Removed | Saved/mo | Why it wasn't needed |
|---|---|---|
| **10 VPC endpoints** | **$73.00** | Pure optimization. The NAT gateway does the same job. Billed *per endpoint per AZ* — that's 10 network interfaces. |
| **RDS PostgreSQL** | **$14.71** | You said data is disposable. Keycloak uses embedded H2 on local disk. |
| 2 KMS keys | $2.00 | AWS-managed keys are **free** and encrypt identically. |
| 2 Secrets Manager secrets | $0.80 | The password is a Terraform output instead. |
| CloudWatch logs + alarms | $0.73 | `journalctl` on the box works. |
| S3 realm bucket | $0.00 | The realm fits in `user_data` now that the script is smaller. |
| 2 ALB listener rules | $0.00 | **Redundant.** The security group already drops non-approved IPs before they reach the listener. |
| Auto Scaling Group | $0.00 | Brought a kill/respawn failure mode for a single instance. |
| Launch template | $0.00 | Only existed to feed the ASG. |
| 3-project split | $0.00 | Made sense with a database to protect. Without one, it's ceremony. |

**Total saved: ~$91/month (51%).**

### What stayed, and why

| Kept | $/mo | Why |
|---|---|---|
| VPC, subnets, IGW, routes | $0.00 | Free. The instance has to live somewhere. |
| **Security groups** | $0.00 | Free, and they *are* the security model. |
| **NAT Gateway** | $32.85 | Required. A private instance can't download Keycloak without it. |
| **ALB + target group** | $22.27 | You chose to keep the instance private. This is what makes that possible. |
| EC2 + disk | $32.77 | This is Keycloak. |
| IAM role | $0.00 | Free. Gives you a shell without SSH. |
| ACM certificate | $0.00 | Free. |

**~$88/month, or $0.24/hour.**

> **Why the NAT gateway survived a "least services" pass:** keeping the ALB means the instance stays in a private subnet, and a private instance still needs outbound internet to install Java and Keycloak. The alternative — VPC endpoints — costs *more* ($73) and doesn't even cover GitHub, where Keycloak is downloaded from. NAT is the cheap option here.

---

## Security

What actually protects this:

- ✅ Only `68.32.112.68` reaches the load balancer — everything else is dropped
- ✅ Keycloak has **no public IP** and sits in a private subnet
- ✅ Only the ALB can talk to Keycloak — the rule references the ALB's *security group*, not an IP, so it survives instance replacement
- ✅ **No port 22 open.** Shell access is via SSM, controlled by IAM and logged to CloudTrail
- ✅ IMDSv2 required — blocks SSRF attacks that steal IAM credentials
- ✅ Disk encrypted (AWS-managed key, free)
- ✅ Password randomly generated, never written in a file
- ✅ Runs as a non-root user with no login shell
- ✅ TLS 1.2 minimum

**Honest caveats:**

- ⚠️ The admin password **is** in your Terraform state, in plaintext. That's the tradeoff for dropping Secrets Manager. State lives in S3 encrypted with public access blocked — treat it as a secret.
- ⚠️ Self-signed cert means a browser warning.
- ⚠️ **H2 database: all data is lost if the instance is replaced.**
- ⚠️ No auto-healing. A crashed instance stays down until you rebuild it.

---

## The realm

A realm is an isolated tenant — its own users, login page, and apps.

**The fallback:** if `realms/myrealm-realm.json` exists, it's imported. If not, a working default is generated. Either way `apply` succeeds.

```bash
terraform output realm_source    # tells you which one you got
```

To use your own:

```bash
cp realms/example-realm.json.example realms/myrealm-realm.json
# edit it
terraform apply
```

The default realm isn't a stub — it includes brute-force protection, a 12-character password policy, 5-minute access tokens, and a PKCE-required client.

> ⚠️ Keycloak only imports realms that **don't already exist**. On restart it leaves an existing realm alone — your users are safe, but edits to the file won't apply either.

> ⚠️ The realm is embedded in `user_data`, which AWS caps at 16 KB after encoding. Currently at **32%**. A realm with several hundred users would exceed it — put it in S3 at that point.

---

## Troubleshooting

### Page won't load at all

**Your IP changed.** By far the most common cause.

```bash
curl ifconfig.me
terraform output allowed_ips
```

Don't match? Update `terraform.tfvars` and `terraform apply`.

### 503 from the load balancer

Still booting, or Keycloak failed to start.

```bash
terraform output -raw check_health   # copy and run it
```

- `initial` → still booting, wait
- `unhealthy` → check the logs below
- `healthy` → it's something else

```bash
aws ssm start-session --target $(terraform output -raw instance_id)
sudo cat /var/log/setup.log        # timing markers per step
sudo journalctl -u keycloak -n 100
```

The setup log prints elapsed seconds per step, so you can see exactly what's slow:

```
[+0s]   === 1. Installing Java ===
[+58s]  === 3. Downloading Keycloak 26.0.7 ===
[+142s] === 6. Building Keycloak ===
```

### Login redirect loop

Almost always a proxy header problem. Verify:

```bash
sudo grep proxy /opt/keycloak/conf/keycloak.conf
# should show: proxy-headers=xforwarded
```

Without it, Keycloak builds redirect URLs from its own private IP over `http://`.

### The instance died

There's no Auto Scaling Group, so nothing replaces it:

```bash
terraform taint aws_instance.keycloak
terraform apply
```

### "Unsupported argument: use_lockfile"

Terraform older than 1.10. Upgrade — this project uses S3-native state locking rather than a DynamoDB table.

---

## Cost

| Item | $/hour | $/month |
|---|---|---|
| NAT Gateway | $0.045 | $32.85 |
| EC2 t3.medium | $0.042 | $30.37 |
| ALB | $0.023 | $16.43 |
| ALB LCU | $0.008 | $5.84 |
| EBS 20 GB | $0.002 | $1.60 |
| Everything else | $0.000 | $0.00 |
| **Total** | **$0.24** | **$88** |

**Cheapest lever:** `terraform destroy` when you're not using it. Rebuild takes ~10 minutes. With H2 the data is disposable anyway, so there's nothing to protect.

Second cheapest: `instance_type = "t3.small"` saves ~$15/mo, but 2 GB RAM makes Keycloak sluggish.

---

## Using a real domain

To lose the certificate warning, you need a domain in Route 53. Replace the self-signed cert in `alb.tf`:

```hcl
resource "aws_acm_certificate" "cert" {
  domain_name       = "keycloak.example.com"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}
```

ACM certs are free and auto-renew. You'll also need a Route 53 alias record pointing at `aws_lb.main.dns_name`.

---

## If you outgrow this

| Need | Change |
|---|---|
| Data must survive | Add RDS PostgreSQL, set `db=postgres` |
| More than one node | RDS first — H2 can't be shared |
| Auto-healing | Add an ASG, with `health_check_grace_period ≥ 900` |
| No browser warning | Real domain + ACM cert |
| Audit logging | CloudWatch log group + agent |

Each of those adds services back. Add them when you need them, not before.
