# Let's Make Infra Great Again (KCP Proof of Concept)
This repository demonstrates KCP (Kubernetes Control Plane) and its Identity Provider (IDP) capabilities through a multi-cluster setup.
## Overview
KCP is an open-source Kubernetes Control Plane that separates the Kubernetes control plane from the data plane, allowing users to manage multiple clusters through a single API. This PoC showcases how KCP can be used to implement identity provider functionality across multiple Kubernetes clusters.
## Architecture
This demo uses four Kubernetes clusters:
- **Platform Cluster**: The KCP control plane
- **Providers Cluster**: Hosts shared services and providers
- **Tenant Clusters** (tenant1 and tenant2): Simulates multi-tenant environments

## Prerequisites
- [AWS CLI](https://docs.aws.amazon.com/cli) configured with credentials and region.
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [helm](https://helm.sh/)
- [krew](https://krew.sigs.k8s.io/)

## Installation & Setup
The repository includes a Makefile to automate setup:

```shell
# Bring up all infrastructure and apps (VPC, EKS, Argo CD, External DNS, KCP)
# DOMAIN=<your-domain> make up (e.g., DOMAIN=example.com)
DOMAIN=example.com make up

# Tear down infrastructure (EKS, VPC)
make down

# Clean local artifacts and Argo CD Applications
make clean
```

## Stack Components
Provision or tear down components individually:

```shell
# Create VPC
make vpc-create

# Create EKS cluster
make eks-create

# Install/upgrade Argo CD
make argocd-install

# Deploy applications (External DNS, Cert Manager, ACK, KCP)
make kcp-install

# Install kubectl plugins for KCP
make kcp-setup-kubectl

# Generate KCP kubeconfig
make kcp-create-kubeconfig
```

## Components
The setup includes several key components:
1. **KCP**: The central control plane (installed as part of the setup)
2. **Cert Manager**: For certificate management
3. **ArgoCD**: For GitOps-style deployments
4. **External DNS**: For domain name management
5. **ACK**: For AWS service integration
6. **API SyncAgent**: For synchronizing resources between clusters

## Sample KCP Commands
Once you have KCP up and running, here are some useful commands to interact with it:

```shell
# Create a workspace
export KUBECONFIG=kcp.kubeconfig
kubectl create workspace my-workspace

# Use a workspace
kubectl ws my-workspace

# List workspaces
kubectl get workspace

# Tree of workspaces
kubectl ws tree

# View API resources available in the workspace
kubectl api-resources

# Create a workspace type from a file
kubectl apply -f manifests/platform/workspace-types/dev.yaml

# Create a workspace of "dev" type from a file
kubectl apply -f manifests/platform/workspaces/tenant1.yaml
