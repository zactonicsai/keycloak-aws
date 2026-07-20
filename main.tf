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