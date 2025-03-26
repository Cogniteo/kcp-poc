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
- [kind](https://kind.sigs.k8s.io/) - For creating local Kubernetes clusters
- [kubectl](https://kubernetes.io/docs/tasks/tools/) - For interacting with Kubernetes clusters
- [krew](https://krew.sigs.k8s.io/) - Kubernetes plugin manager

## Installation & Setup
The repository includes a comprehensive Makefile to automate the setup process:
``` shell
# Set up all components (clusters, CLI tools, KCP, and tenant resources)
make all

# Create only the Kubernetes clusters
make clusters

# Clean up resources
make clean
```
### Cluster Setup
Individual clusters can be provisioned separately with:
``` shell
# Create the platform cluster for KCP
make kcp

# Create the providers cluster
make providers 

# Create the tenant clusters
make tenant
```

## Components
The setup includes several key components:
1. **KCP**: The central control plane (installed as part of the setup)
2. **Cert Manager**: For certificate management
3. **ArgoCD**: For GitOps-style deployments
4. **NGINX Controller**: For ingress management
5. **API SyncAgent**: For synchronizing resources between clusters

## Sample KCP Commands
Once you have KCP up and running, here are some useful commands to interact with it:

```shell
# Create a workspace
kubectl kcp workspace create my-workspace --kubeconfig=kcp.kubeconfig

# Use a workspace
kubectl kcp workspace use my-workspace --kubeconfig=kcp.kubeconfig

# List workspaces
kubectl kcp workspace list --kubeconfig=kcp.kubeconfig

# Create a logical cluster within a workspace
kubectl kcp workspace create my-cluster --type=LogicalCluster --kubeconfig=kcp.kubeconfig

# Bind a service account to a workspace
kubectl create serviceaccount my-sa --kubeconfig=kcp.kubeconfig
kubectl kcp bind my-sa --workspace my-workspace --role admin --kubeconfig=kcp.kubeconfig

# Sync resources between KCP and a physical cluster
kubectl kcp workload sync my-workspace --syncer-image kcp-syncer:latest --kubeconfig=kcp.kubeconfig

# View API resources available in the workspace
kubectl api-resources --kubeconfig=kcp.kubeconfig

# Export a kubeconfig for a workspace
kubectl kcp workspace get-kubeconfig my-workspace --kubeconfig=kcp.kubeconfig > my-workspace-kubeconfig.yaml

# Switch between different workspaces
kubectl kcp workspace use another-workspace --kubeconfig=kcp.kubeconfig

# Create a workspace type from a file
kubectl --kubeconfig=kcp.kubeconfig apply -f manifests/platform/workspace-types/dev.yaml

# Create a workspace of "dev" type from a file
kubectl --kubeconfig=kcp.kubeconfig apply -f manifests/platform/workspaces/tenant1.yaml
```


