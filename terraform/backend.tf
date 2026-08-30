terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.13"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  # Remote state — fill these in with the outputs from
  # terraform/bootstrap after running it once.
  backend "s3" {
    bucket         = "hello-cicd-tfstate-dasariram"
    key            = "hello-cicd/terraform.tfstate"
    region         = "us-east-1"
    dynamodb_table = "hello-cicd-tflock"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

# Lets Terraform talk to the EKS cluster it just created,
# e.g. for the aws-auth configmap / access entries.
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args = [
      "eks", "get-token",
      "--cluster-name", module.eks.cluster_name,
      "--region", var.aws_region
    ]
  }
}
