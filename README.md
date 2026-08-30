# Hello CI/CD — Terraform-Provisioned EKS Pipeline

Full pipeline, infra as code, everything auto-triggered by git push:

```
                    ┌─ push to terraform/**  → terraform.yml → plan/apply infra (VPC, EKS, ECR, IAM)
Developer → GitHub ─┤
                    └─ push (any code)       → deploy.yml    → build image → push ECR → deploy to EKS
```

## Repo structure
```
hello-cicd-eks/
├── index.html, style.css, Dockerfile        # the app
├── k8s/                                      # Kubernetes manifests (app deploy target)
│   ├── namespace.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   └── hpa.yaml
├── terraform/                                 # infra as code
│   ├── bootstrap/main.tf                      # run ONCE manually — creates remote state backend
│   ├── backend.tf                             # providers + S3 backend config
│   ├── variables.tf
│   ├── vpc.tf                                 # VPC via terraform-aws-modules
│   ├── eks.tf                                 # EKS cluster + node group + LB controller
│   ├── helm.tf                                # metrics-server (for autoscaling)
│   ├── ecr.tf                                 # ECR repo for the app image
│   ├── iam-github-oidc.tf                     # GitHub OIDC provider + 2 IAM roles + EKS access
│   ├── outputs.tf
│   └── terraform.tfvars.example
└── .github/workflows/
    ├── terraform.yml                          # auto plan/apply on terraform/** changes
    └── deploy.yml                             # auto build+deploy on any push
```

## Why two IAM roles
| Role | Used by | Permissions |
|---|---|---|
| `hello-cicd-github-terraform` | `terraform.yml` | Broad (AdministratorAccess) — needs to create/modify VPC, EKS, IAM, ECR |
| `hello-cicd-github-app-deploy` | `deploy.yml` | Narrow — only ECR push + EKS deploy to the `hello-cicd` namespace |

Terraform itself creates both roles (`iam-github-oidc.tf`), so once the first `terraform apply` runs, the app pipeline's permissions are fully managed as code too.

## Implementation steps

### 1. One-time: create the remote state backend
Terraform needs somewhere durable to store state since GitHub Actions runners are thrown away after every run.
```bash
cd terraform/bootstrap
terraform init
terraform apply
terraform output   # note the bucket + table names
```
If you changed `state_bucket_name` in `bootstrap/main.tf`, update the matching values in `terraform/backend.tf`.

### 2. One-time: bootstrap Terraform's own AWS access
Terraform's GitHub workflow needs an IAM role to assume *before* it can create IAM roles for itself (classic chicken-and-egg). Create this one manually, once:
```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
# (skip if you already created this earlier)

aws iam create-role \
  --role-name hello-cicd-github-terraform-bootstrap \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"},
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {"token.actions.githubusercontent.com:aud": "sts.amazonaws.com"},
        "StringLike": {"token.actions.githubusercontent.com:sub": "repo:<YOUR_GH_USERNAME>/<YOUR_REPO>:*"}
      }
    }]
  }'

aws iam attach-role-policy \
  --role-name hello-cicd-github-terraform-bootstrap \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess
```

### 3. Add the bootstrap role as a GitHub secret
**Settings → Secrets and variables → Actions → New repository secret**
- Name: `TF_AWS_ROLE_ARN`
- Value: ARN of `hello-cicd-github-terraform-bootstrap`

### 4. Configure your values
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit github_org, github_repo, create_oidc_provider
```
Since you already created infra manually in the console before, set:
```hcl
create_oidc_provider = false
```
so Terraform looks up the existing OIDC provider instead of trying to recreate it. **If you plan to let Terraform fully manage the EKS cluster going forward, either import your existing manual cluster into state (`terraform import`) or delete it manually first so there's no naming conflict with `module.eks`.**

### 5. Push — this auto-triggers Terraform
```bash
git add terraform/
git commit -m "Add terraform infra"
git push origin main
```
`terraform.yml` fires automatically (it only triggers on changes under `terraform/`), runs `plan` then `apply`, and provisions everything: VPC, EKS cluster, node group, ECR repo, Load Balancer Controller, metrics-server, and both IAM roles.

### 6. Switch the app secret over to the Terraform-managed role
Once step 5 finishes, grab the new role ARN:
```bash
cd terraform && terraform output github_app_deploy_role_arn
```
Update the GitHub secret used by `deploy.yml`:
- Name: `AWS_ROLE_ARN`
- Value: the `github_app_deploy_role_arn` output

### 7. Push app changes — auto-triggers the deploy pipeline
```bash
git add index.html style.css
git commit -m "Update portfolio content"
git push origin main
```
`deploy.yml` fires (any push), builds the Docker image, pushes to the Terraform-created ECR repo, and deploys to the Terraform-created EKS cluster.

### 8. Get the live URL
```bash
$(terraform -chdir=terraform output -raw kubeconfig_command)
kubectl get service portfolio-app-service -n hello-cicd
```

## Making infra changes going forward
Just edit files under `terraform/` (e.g. bump `node_max_size` in `variables.tf`) and push:
```bash
git add terraform/variables.tf
git commit -m "Scale up node group"
git push origin main
```
`terraform.yml` auto-runs `plan` + `apply` — no manual `terraform apply` needed after the initial bootstrap. Opening a PR instead of pushing directly will run `plan` only and post the diff as a PR comment, so you can review before merging.

## Cleanup (avoid ongoing charges)
```bash
cd terraform
terraform destroy
cd bootstrap
terraform destroy   # only after confirming no other state depends on this bucket
```
