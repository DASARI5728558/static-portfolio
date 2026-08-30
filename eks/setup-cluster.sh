#!/bin/bash
# ============================================================
# One-time infra setup for the Hello CI/CD project on EKS
# Requires: aws cli, eksctl, kubectl, helm — all installed & configured
# ============================================================
set -e

REGION="us-east-1"
CLUSTER_NAME="hello-cicd-cluster"
REPO_NAME="hello-cicd-portfolio"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

echo "Account: $ACCOUNT_ID | Region: $REGION"

# 1. Create ECR repository
echo "Creating ECR repo..."
aws ecr create-repository \
  --repository-name $REPO_NAME \
  --region $REGION || echo "Repo may already exist, continuing..."

# 2. Create the EKS cluster (takes ~15-20 minutes)
echo "Creating EKS cluster (this takes a while)..."
eksctl create cluster -f cluster-config.yaml

# 3. Point kubectl at the new cluster
aws eks update-kubeconfig --name $CLUSTER_NAME --region $REGION

# 4. Install the AWS Load Balancer Controller (so the Service of type
#    LoadBalancer provisions a real ALB/NLB in front of the pods)
echo "Installing AWS Load Balancer Controller..."

# 4a. Create IAM policy for the controller (one-time per account)
curl -o iam_policy.json https://raw.githubusercontent.com/kubernetes-sigs/aws-load-balancer-controller/v2.9.0/docs/install/iam_policy.json
aws iam create-policy \
  --policy-name AWSLoadBalancerControllerIAMPolicy \
  --policy-document file://iam_policy.json || echo "Policy may already exist, continuing..."

# 4b. Create IAM service account bound to that policy
eksctl create iamserviceaccount \
  --cluster=$CLUSTER_NAME \
  --namespace=kube-system \
  --name=aws-load-balancer-controller \
  --attach-policy-arn=arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy \
  --override-existing-serviceaccounts \
  --approve \
  --region $REGION

# 4c. Install the controller via Helm
helm repo add eks https://aws.github.io/eks-charts
helm repo update
helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=$CLUSTER_NAME \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller

# 5. Install metrics-server (required for HPA / CPU autoscaling to work)
echo "Installing metrics-server..."
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

# 6. Create the app namespace
kubectl apply -f ../k8s/namespace.yaml

echo "Cluster setup complete. Next: set up GitHub OIDC role, then push code."
