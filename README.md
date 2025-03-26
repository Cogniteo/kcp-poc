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


## License
This project is available under the [MIT License](LICENSE).
## Contributing

