Hourly pricing is genuinely different from monthly/730, because some charges aren't hourly at all. Let me compute it precisely.Let me verify the two rates I'm least sure of at hourly granularity — KMS and Secrets Manager, which are monthly-billed, not hourly.Both prorate hourly. Now let me compute the actual hourly figures.## Cost for 1 hour: **≈ $0.31**

### A. Hourly-billed (the bulk of it)

| Layer | Item | Rate/hr | Qty | 1 hour |
|---|---|---|---|---|
| 01 | **VPC interface endpoints** | $0.0100 | **10** | **$0.1000** |
| 01 | **NAT Gateway** | $0.0450 | 1 | **$0.0450** |
| 03 | EC2 t3.medium | $0.0416 | 1 | $0.0416 |
| 03 | Application Load Balancer | $0.0225 | 1 | $0.0225 |
| 02 | RDS db.t4g.micro | $0.0160 | 1 | $0.0160 |
| 03 | ALB LCU (light traffic) | $0.0080 | ~1 | $0.0080 |
| | | | **Subtotal** | **$0.2331** |

### B. Monthly charges, prorated hourly

| Layer | Item | $/month | 1 hour |
|---|---|---|---|
| 01 | KMS keys (2 × $1) | $2.00 | $0.0027 |
| 02 | Secrets Manager (1) | $0.40 | $0.0005 |
| 03 | Secrets Manager (1) | $0.40 | $0.0005 |
| | | **Subtotal** | **$0.0038** |

### C. Storage (GB-month, prorated)

| Layer | Item | $/month | 1 hour |
|---|---|---|---|
| 03 | EBS gp3 30 GB | $2.40 | $0.0033 |
| 02 | RDS gp3 20 GB | $2.30 | $0.0032 |
| | | **Subtotal** | **$0.0064** |

### D. Usage — only what you actually consume

| Layer | Item | 1 hour | Note |
|---|---|---|---|
| 03 | CloudWatch Logs | $0.0250 | ~50 MB |
| 01 | NAT data processing | $0.0225 | ~0.5 GB during install |
| 03 | Data transfer out | $0.0180 | ~0.2 GB |
| 01 | KMS API requests | $0.0000 | under 20k free tier |
| 03 | S3 (realm + state) | $0.0000 | negligible |
| | | **Subtotal** | **$0.0655** |

### By layer

| Layer | 1 hour |
|---|---|
| **01-network** | **$0.1702** |
| 03-keycloak | $0.1189 |
| 02-database | $0.0197 |

### Scaling up

| Duration | Cost |
|---|---|
| 1 hour | **$0.31** |
| 8 hours (a workday) | $2.47 |
| 24 hours | $7.41 |
| 8h × 22 workdays | $54.36 |
| Full month | $225.48 |

---

**Two things the hourly view exposes that the monthly one hides.**

Layer 01 costs *more per hour than Keycloak itself* — $0.17 vs $0.12 — almost entirely because of the 10 VPC endpoint ENIs at $0.10/hr. Setting `create_vpc_endpoints = false` drops your hourly cost to **$0.21**, a 32% cut, and loses nothing functionally.

The database is the cheapest layer at **$0.02/hr**. That's the argument for the three-project split: destroying layer 03 nightly saves $0.12/hr while the layer holding all your actual data costs two cents to leave running.

**A billing detail worth knowing:** hourly resources bill *partial hours as full hours*. Running 10 minutes costs the same as 60. So "1 hour" is really the minimum charge, not a proportional one.

The $0.0655 usage line is my estimate for a light hour that includes the initial install — the Keycloak download pulls ~250 MB through the NAT gateway. A steady-state idle hour would be closer to $0.01, putting the total near **$0.25**.