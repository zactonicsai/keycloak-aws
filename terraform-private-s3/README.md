# Private AWS S3 Bucket with Terraform

This project creates:

- One private Amazon S3 bucket
- A private bucket ACL
- S3 Block Public Access settings
- S3 versioning
- AES-256 server-side encryption
- A bucket policy that requires HTTPS
- A VPC security group for an EC2 instance or application that accesses S3
- An outbound security-group rule that allows HTTPS only to the AWS-managed S3 prefix list

## Important

Amazon S3 buckets do not support security groups directly.

The security group in this project must be attached to an EC2 instance or another supported VPC resource that needs to access S3.

IAM permissions and an optional S3 VPC endpoint policy are still needed to control which AWS identities and VPC resources can read or write objects.

## Requirements

- Terraform 1.5 or newer
- AWS CLI configured
- An existing AWS VPC
- AWS permissions to create S3 buckets, policies, security groups, and security-group rules

## 1. Confirm your AWS login

```bash
aws sts get-caller-identity
```

## 2. Find a VPC ID

```bash
aws ec2 describe-vpcs \
  --query "Vpcs[*].[VpcId,IsDefault,CidrBlock]" \
  --output table
```

## 3. Create your variable file

Copy the example file:

### Linux or macOS

```bash
cp terraform.tfvars.example terraform.tfvars
```

### Windows PowerShell

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars` and replace the example VPC ID.

## 4. Create the resources

```bash
terraform init
terraform fmt
terraform validate
terraform plan
terraform apply
```

Type `yes` when Terraform asks for approval.

## 5. Test the bucket

```bash
echo "Private S3 test" > private-test.txt

aws s3 cp private-test.txt \
  "s3://$(terraform output -raw bucket_name)/private-test.txt"

aws s3 ls \
  "s3://$(terraform output -raw bucket_name)/"
```

PowerShell upload example:

```powershell
"Private S3 test" | Set-Content private-test.txt

$BucketName = terraform output -raw bucket_name
aws s3 cp private-test.txt "s3://$BucketName/private-test.txt"
aws s3 ls "s3://$BucketName/"
```

## 6. Destroy the resources

Because versioning is enabled, delete all object versions and delete markers before destroying the bucket.

For a new test bucket with only the current object version, this may be enough:

```bash
aws s3 rm "s3://$(terraform output -raw bucket_name)/" --recursive
terraform destroy
```

Type `yes` when Terraform asks for approval.
