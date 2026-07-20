variable "aws_region" {
  description = "AWS region where resources will be created"
  type        = string
  default     = "us-east-1"
}

variable "vpc_id" {
  description = "VPC where the S3 client security group will be created"
  type        = string
}

variable "bucket_name_prefix" {
  description = "Beginning of the globally unique S3 bucket name"
  type        = string
  default     = "zac-private-bucket"
}

variable "environment" {
  description = "Environment tag"
  type        = string
  default     = "Development"
}
