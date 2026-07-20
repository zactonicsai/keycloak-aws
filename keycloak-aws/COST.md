I'll build a detailed cost breakdown from the actual configuration values in the files.Important detail: interface endpoints use `subnet_ids = aws_subnet.private[*].id` — that's 2 subnets, so each endpoint bills **2 ENIs**, not 1. Let me confirm.Confirmed — 10 ENIs, not 5. My earlier README estimate of ~$35 was half the real cost. Let me verify current pricing.Confirmed: **$0.01/hour per endpoint per AZ**. With 5 endpoints × 2 AZs, that's 10 ENIs. Let me verify the remaining prices.I have solid pricing. Let me also confirm the public IPv4 charge, which applies to both the ALB and the NAT Gateway's EIP.Now let me compute the precise totals from the configured values.My README said **~$118/month**. The real figure is **~$165** — I'd undercounted VPC endpoints by half. Here's the corrected breakdown.

## Dev environment — as configured today

`t3.medium` · 30 GB · NAT on · endpoints on · us-east-1

| Item | Rate | Quantity | Monthly |
|---|---|---|---|
| **VPC interface endpoints** | $0.01/hr per AZ | 5 endpoints × 2 AZ = **10 ENIs** | **$73.00** |
| **NAT Gateway** | $0.045/hr | 1 × 730 hr | **$32.85** |
| **EC2 t3.medium** | $0.0416/hr | 1 × 730 hr | **$30.37** |
| Application Load Balancer | $0.0225/hr | 1 × 730 hr | $16.43 |
| ALB LCU | $0.008/LCU-hr | ~1 LCU | $5.84 |
| EBS gp3 root volume | $0.08/GB | 30 GB | $2.40 |
| KMS customer keys | $1.00/key | 2 keys | $2.00 |
| Data transfer out | $0.09/GB | ~5 GB | $0.45 |
| Secrets Manager | $0.40/secret | 1 | $0.40 |
| CloudWatch Logs ingest | $0.50/GB | ~1 GB | $0.50 |
| NAT data processing | $0.045/GB | ~5 GB | $0.23 |
| CloudWatch Logs storage | $0.03/GB | ~1 GB | $0.03 |
| S3 state storage | $0.023/GB | <1 GB | $0.02 |
| S3 gateway endpoint | — | 1 | **$0.00** |
| VPC, subnets, IGW, route tables | — | — | **$0.00** |
| Security groups, IAM roles | — | — | **$0.00** |
| ACM certificate | — | public certs | **$0.00** |
| Auto Scaling Group | — | — | **$0.00** |
| | | **TOTAL** | **≈ $164.51** |

## Prod environment — as configured

`m6i.large` · 50 GB · plus the RDS you'll need

| Item | Rate | Quantity | Monthly |
|---|---|---|---|
| **EC2 m6i.large** | $0.096/hr | 1 × 730 hr | **$70.08** |
| **VPC interface endpoints** | $0.01/hr per AZ | 10 ENIs | **$73.00** |
| **NAT Gateway** | $0.045/hr | 1 × 730 hr | **$32.85** |
| **RDS db.t3.small** ⚠️ | $0.034/hr | not yet in code | **$24.82** |
| ALB LCU | $0.008/LCU-hr | ~3 LCU | $17.52 |
| Application Load Balancer | $0.0225/hr | 1 | $16.43 |
| Data transfer out | $0.09/GB | ~50 GB | $4.50 |
| EBS gp3 root volume | $0.08/GB | 50 GB | $4.00 |
| CloudWatch Logs ingest | $0.50/GB | ~10 GB | $5.00 |
| CloudWatch Logs storage | $0.03/GB | 10 GB × 90d | $0.90 |
| RDS storage gp3 | $0.115/GB | 20 GB | $2.30 |
| KMS keys | $1.00 | 2 | $2.00 |
| NAT data processing | $0.045/GB | ~20 GB | $0.90 |
| Secrets Manager | $0.40 | 1 | $0.40 |
| | | **TOTAL** | **≈ $254.69** |

## Cutting the dev bill

| Configuration | Monthly | Saves |
|---|---|---|
| As shipped | $164.51 | — |
| `create_vpc_endpoints = false` | $91.51 | $73 |
| ...plus `t3.small` | $76.32 | $88 |
| ...plus `create_nat_gateway = false` ¹ | $43.25 | $121 |
| **`terraform destroy` when idle** ² | **~$43** | **$122** |

¹ Requires moving the EC2 to a public subnet — it must reach GitHub to install Keycloak. Not just a flag flip.
² 8 hrs/day × 22 days. With `db_vendor = "dev-file"` the data dies on rebuild anyway, so there's nothing to protect.

---

**The correction that matters:** I wrote "~$35" for VPC endpoints in the README. Wrong — billing is **per endpoint per AZ**, and the module sets `subnet_ids = aws_subnet.private[*].id`, which is both private subnets. So 5 endpoints × 2 AZs = 10 billable ENIs at $73/month. That single line is now the **largest** item in dev, bigger than the NAT Gateway.

Setting `create_vpc_endpoints = false` costs you nothing functionally in dev — SSM and KMS still work over the NAT Gateway. You lose the private network path, not the capability.

**Prod is understated in the code.** `db_vendor = "dev-file"` means H2 on local disk. When the ASG replaces that instance — and it will, on any health check failure — every user and realm is gone. RDS isn't in the Terraform yet, so that $24.82 line is a cost you'll add, not one you're paying.

