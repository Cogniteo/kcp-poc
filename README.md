# KCP Proof of Concept (PoC)

This repository demonstrates KCP (Kubernetes Control Plane) and its multi-cluster management capabilities through a simplified infrastructure setup on AWS EKS.

## Overview

KCP is an open-source project that implements a Kubernetes-like control plane focusing on multi-tenancy, workload management, and extensibility. This PoC showcases:

- Multi-cluster management through a single control plane
- Workspace-based multi-tenancy
- GitOps deployment with ArgoCD
- Automated infrastructure provisioning on AWS

## Architecture

The setup consists of:

- **AWS VPC**: Network infrastructure with public/private subnets
- **AWS EKS Cluster**: Kubernetes cluster hosting KCP and other components
- **KCP**: The control plane managing multiple logical clusters (workspaces)
- **ArgoCD**: GitOps continuous deployment
- **Supporting Services**: External DNS, Cert Manager, AWS Controllers for Kubernetes (ACK)

## Project Structure

```
kcp-poc/
├── Makefile                    # Simplified infrastructure management
├── manifests/
│   ├── eks/
│   │   ├── vpc.yaml           # VPC CloudFormation stack
│   │   ├── eks.yaml           # EKS CloudFormation stack
│   │   ├── nodepool.yaml      # Karpenter node pool configuration
│   │   ├── ingressclass.yaml  # Ingress class definition
│   │   └── storageclass.yaml  # Storage class definition
│   ├── kcp/
│   │   ├── kcp-front-proxy-cert.yaml  # KCP certificate configuration
│   │   └── users/                     # Sample user resources
│   └── platform/
│       ├── applicationset.yaml        # ArgoCD ApplicationSet
│       ├── argocd-values.yaml        # ArgoCD Helm values
│       └── kcp-suite/                # KCP Helm chart
└── tmp/                              # Temporary files (gitignored)
```

## Prerequisites

- [AWS CLI](https://docs.aws.amazon.com/cli) configured with appropriate credentials
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/)
- [make](https://www.gnu.org/software/make/)
- [envsubst](https://www.gnu.org/software/gettext/manual/html_node/envsubst-Invocation.html) (usually pre-installed on Linux/macOS)
- A domain name with DNS management access

## Required Environment Variables

Before running any commands, you must set these environment variables:

```bash
export DOMAIN=your-domain.com           # Your domain for the deployment
export ACME_EMAIL=admin@your-domain.com # Email for Let's Encrypt certificates
```

## Quick Start

```bash
# Set required environment variables
export DOMAIN=example.com
export ACME_EMAIL=admin@example.com

# Create complete infrastructure (VPC, EKS, ArgoCD, KCP)
make up

# Access ArgoCD UI (after deployment)
open https://argocd.$DOMAIN

# Destroy all infrastructure
make down
```

**Note**: The initial deployment takes approximately 20-30 minutes.

## Makefile Targets

The Makefile provides organized targets for infrastructure management:

### Main Workflow

```bash
make up     # Create complete infrastructure (VPC, EKS, ArgoCD, KCP)
make down   # Destroy all infrastructure
```

### Infrastructure Management

```bash
make vpc-create   # Create VPC infrastructure
make vpc-delete   # Delete VPC infrastructure
make eks-create   # Create EKS cluster
make eks-delete   # Delete EKS cluster
```

### Application Deployment

```bash
make argocd-install   # Install ArgoCD
make kcp-install      # Install KCP
make kcp-delete       # Delete KCP
```

### KCP Setup

```bash
make kcp-setup-kubectl      # Install kubectl plugins for KCP
make kcp-create-kubeconfig  # Generate KCP kubeconfig
make kcp-deploy-sample      # Deploy sample KCP resources
```

### TLS Management

```bash
make controllers-create-tls-secret  # Create TLS secret for controllers
```

### Cleanup Operations

```bash
make ecr-clean  # Clean up ECR repository
```

## Configuration

The following variables can be customized:

- `EKS_CLUSTER_NAME`: Name of the EKS cluster (default: `kcp-cluster`)
- `AWS_REGION`: AWS region for deployment (default: `eu-central-1`)
- `KUBECONFIG_FILE`: Path to kubeconfig file (default: `kube.config`)

## Working with KCP

Once KCP is deployed, you can interact with it using kubectl:

```bash

# Create a workspace
kubectl ws create my-workspace --enter

# List workspaces
kubectl get workspaces

# View workspace tree
kubectl ws tree

# Switch between workspaces
kubectl ws use my-workspace

# Deploy sample user resources
make kcp-deploy-sample
```

### Sample Resources

The `kcp-deploy-sample` target creates:
- A custom resource definition for users
- A workspace named 'users'
- A sample user resource

## Components Deployed

The setup includes:

1. **KCP**: Multi-tenant Kubernetes control plane
2. **ArgoCD**: GitOps continuous deployment
3. **Cert Manager**: Automated certificate management
4. **External DNS**: Automatic DNS record management
5. **AWS Controllers for Kubernetes (ACK)**: AWS service integration

## Troubleshooting

### Check deployment status

```bash
# Check ArgoCD applications
kubectl get applications -n argocd

# View KCP pods
kubectl get pods -n kcp

# Check certificate status
kubectl get certificates -A
```

### View logs

```bash
# KCP logs
kubectl logs -n kcp -l app=kcp-front-proxy

# ArgoCD logs  
kubectl logs -n argocd -l app.kubernetes.io/name=argocd-server
```

## Complete Cleanup

To completely remove all resources:

```bash
# Remove all infrastructure (KCP, EKS, VPC)
make down

# The down target automatically cleans up:
# - Temporary files in tmp/
# - Generated kubeconfig files
# - KCP resources
# - EKS cluster and node groups
# - VPC and network resources
```

**Note**: The cleanup process may take 10-15 minutes as CloudFormation stacks are deleted in the correct order.

