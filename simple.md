## 1. Create a folder

```bash
mkdir terraform-s3
cd terraform-s3
```

## 2. Create `main.tf`

```hcl
# Tell Terraform which providers are required.
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

# Configure the AWS provider.
provider "aws" {
  region = "us-east-1"
}

# Generate a random value because every S3 bucket name
# must be unique across all AWS accounts.
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Create the S3 bucket.
resource "aws_s3_bucket" "example" {
  bucket = "zac-simple-bucket-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "Zac Simple S3 Bucket"
    Environment = "Development"
    ManagedBy   = "Terraform"
  }
}

# Keep the bucket private.
resource "aws_s3_bucket_public_access_block" "example" {
  bucket = aws_s3_bucket.example.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Turn on file versioning.
resource "aws_s3_bucket_versioning" "example" {
  bucket = aws_s3_bucket.example.id

  versioning_configuration {
    status = "Enabled"
  }
}

# Display the bucket name after creation.
output "bucket_name" {
  description = "Name of the new S3 bucket"
  value       = aws_s3_bucket.example.bucket
}

# Display the bucket ARN.
output "bucket_arn" {
  description = "ARN of the new S3 bucket"
  value       = aws_s3_bucket.example.arn
}
```

S3 bucket names must be unique, so the `random_id` resource adds characters such as `a93f612b` to the name. The public-access block keeps the bucket private, which follows AWS guidance for private storage. ([AWS Documentation][1])

## 3. Verify your AWS login

```bash
aws sts get-caller-identity
```

## 4. Run Terraform

```bash
# Download the AWS and random providers.
terraform init

# Check the Terraform formatting.
terraform fmt

# Check the configuration for errors.
terraform validate

# Preview what Terraform will create.
terraform plan

# Create the bucket.
terraform apply
```

Enter:

```text
yes
```

Terraform will display an output similar to:

```text
bucket_name = "zac-simple-bucket-a93f612b"
bucket_arn  = "arn:aws:s3:::zac-simple-bucket-a93f612b"
```

Terraform uses resource blocks such as `aws_s3_bucket` to declare infrastructure that it should create and manage. ([HashiCorp Developer][2])

## 5. Test the bucket

```bash
aws s3 ls
```

Upload a test file:

```bash
echo "Hello from Terraform" > hello.txt
aws s3 cp hello.txt "s3://$(terraform output -raw bucket_name)/hello.txt"
```

List the bucket contents:

```bash
aws s3 ls "s3://$(terraform output -raw bucket_name)/"
```

## 6. Delete everything

First empty the bucket:

```bash
aws s3 rm "s3://$(terraform output -raw bucket_name)/" --recursive
```

Then destroy the Terraform resources:

```bash
terraform destroy
```

Enter `yes` when Terraform asks for approval.

[1]: https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html?utm_source=chatgpt.com "Blocking public access to your Amazon S3 storage - Amazon Simple Storage Service"
[2]: https://developer.hashicorp.com/terraform/language/block/resource?utm_source=chatgpt.com "resource block reference | Terraform | HashiCorp Developer"
