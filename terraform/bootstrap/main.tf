# ============================================================
# BOOTSTRAP — run this ONCE, manually, from your laptop.
# It creates the S3 bucket + DynamoDB table that the main
# terraform/ config needs as its remote backend so that
# GitHub Actions (which is stateless between runs) can share
# state safely.
#
# Usage:
#   cd terraform/bootstrap
#   terraform init
#   terraform apply
#   terraform output   <- copy these values into terraform/backend.tf
# ============================================================

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
  # Intentionally local state here — this is the one config
  # that has to exist before remote state can exist.
}

variable "region" {
  default = "us-east-1"
}

variable "state_bucket_name" {
  description = "Must be globally unique"
  default     = "hello-cicd-tfstate-dasariram"
}

provider "aws" {
  region = var.region
}

resource "aws_s3_bucket" "tfstate" {
  bucket = var.state_bucket_name

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "hello-cicd-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}

output "state_bucket_name" {
  value = aws_s3_bucket.tfstate.bucket
}

output "lock_table_name" {
  value = aws_dynamodb_table.tflock.name
}

output "region" {
  value = var.region
}
