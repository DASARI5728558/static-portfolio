data "tls_certificate" "github" {
  url = "https://token.actions.githubusercontent.com/.well-known/openid-configuration"
}

# If you already created the GitHub OIDC provider manually (e.g. from the
# earlier console walkthrough), set create_oidc_provider = false in
# terraform.tfvars and Terraform will just look it up instead of
# re-creating it (re-creating it would fail with "already exists").
resource "aws_iam_openid_connect_provider" "github" {
  count           = var.create_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.github.certificates[0].sha1_fingerprint]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 0 : 1
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# ---------------------------------------------------------------
# Role #1 — used by the APP workflow (.github/workflows/deploy.yml)
# Narrow permissions: push to ECR + read the EKS cluster to deploy.
# ---------------------------------------------------------------
data "aws_iam_policy_document" "github_app_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_app_deploy" {
  name               = "${var.project_name}-github-app-deploy"
  assume_role_policy = data.aws_iam_policy_document.github_app_trust.json
}

resource "aws_iam_role_policy_attachment" "app_ecr" {
  role       = aws_iam_role.github_app_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser"
}

data "aws_iam_policy_document" "app_eks_describe" {
  statement {
    effect    = "Allow"
    actions   = ["eks:DescribeCluster", "eks:ListClusters"]
    resources = [module.eks.cluster_arn]
  }
}

resource "aws_iam_role_policy" "app_eks_describe" {
  name   = "eks-describe"
  role   = aws_iam_role.github_app_deploy.id
  policy = data.aws_iam_policy_document.app_eks_describe.json
}

# Give that role access INSIDE the cluster (K8s RBAC, separate from IAM)
resource "aws_eks_access_entry" "github_app_deploy" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_app_deploy.arn
}

resource "aws_eks_access_policy_association" "github_app_deploy" {
  cluster_name  = module.eks.cluster_name
  principal_arn = aws_iam_role.github_app_deploy.arn
  policy_arn    = "arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy"

  access_scope {
    type       = "namespace"
    namespaces = ["hello-cicd"]
  }
}

# ---------------------------------------------------------------
# Role #2 — used by the TERRAFORM workflow (.github/workflows/terraform.yml)
# Broader permissions: needs to create/update/destroy VPC, EKS,
# ECR, IAM resources etc. AdministratorAccess is simplest for a
# learning project; scope this down for production use.
# ---------------------------------------------------------------
data "aws_iam_policy_document" "github_terraform_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_org}/${var.github_repo}:ref:refs/heads/main",
        "repo:${var.github_org}/${var.github_repo}:pull_request"
      ]
    }
  }
}

resource "aws_iam_role" "github_terraform" {
  name               = "${var.project_name}-github-terraform"
  assume_role_policy = data.aws_iam_policy_document.github_terraform_trust.json
}

resource "aws_iam_role_policy_attachment" "terraform_admin" {
  role       = aws_iam_role.github_terraform.name
  policy_arn = "arn:aws:iam::aws:policy/AdministratorAccess"
}

output "github_app_deploy_role_arn" {
  value = aws_iam_role.github_app_deploy.arn
}

output "github_terraform_role_arn" {
  value = aws_iam_role.github_terraform.arn
}
