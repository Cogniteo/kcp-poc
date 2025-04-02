SHELL := /bin/bash

# Default cluster names (adjust to suit your environment)
PLATFORM_CLUSTER   ?= platform
PROVIDERS_CLUSTER  ?= providers
TENANT1_CLUSTER    ?= tenant1
TENANT2_CLUSTER    ?= tenant2
HOSTNAME           ?= kcp.local.gd
# Location of your merged kubeconfig file
KUBECONFIG_FILE    ?= kube.config
KUBECONFIG_FILE    ?= kcp.kubeconfig
KREW_ROOT          ?= $(HOME)/.krew


.PHONY: all clusters kcp-cluster providers-cluster tenant-clusters \
        install-cert-manager install-kcp install-kcp-plugin install-krew \
        install-argocd install-nginx-controller install-api-syncagent \
        create-kcp-config create-kcp-kubeconfig clean

# ------------------------------------------------------------------------------
# all: Execute all actions (excluding clean)
# ------------------------------------------------------------------------------
all: clusters cli kcp tenants

# ------------------------------------------------------------------------------
# clusters: Execute cluster creation for all clusters.
# ------------------------------------------------------------------------------
clusters: kcp-cluster providers-cluster tenant-clusters

# ------------------------------------------------------------------------------
# kcp-cluster: Ensure the kcp (platform) cluster exists, export and merge its kubeconfig.
# ------------------------------------------------------------------------------
kcp-cluster:
	@echo "Ensuring kcp cluster exists: $(PLATFORM_CLUSTER)"
	@rm -f $(KUBECONFIG_FILE)
	@touch $(KUBECONFIG_FILE)
	@mkdir -p tmp
	@if kind get clusters | grep -qw $(PLATFORM_CLUSTER); then \
	  echo "Cluster '$(PLATFORM_CLUSTER)' already exists. Skipping creation..."; \
	else \
	  echo "Cluster '$(PLATFORM_CLUSTER)' does not exist. Creating using kind-kcp.yaml configuration..."; \
	  kind create cluster --name $(PLATFORM_CLUSTER) --config kind-kcp.yaml; \
	fi
	@echo "Exporting kubeconfig for cluster '$(PLATFORM_CLUSTER)'..."
	@kind get kubeconfig --name $(PLATFORM_CLUSTER) > tmp/kube-$(PLATFORM_CLUSTER).config
	@echo "Merging kubeconfig for cluster '$(PLATFORM_CLUSTER)' into $(KUBECONFIG_FILE)..."
	@KUBECONFIG=$(KUBECONFIG_FILE):tmp/kube-$(PLATFORM_CLUSTER).config kubectl config view --merge --flatten > tmp/merged.config
	@mv tmp/merged.config $(KUBECONFIG_FILE)

# ------------------------------------------------------------------------------
# providers-cluster: Ensure the providers cluster exists, export and merge its kubeconfig.
# ------------------------------------------------------------------------------
providers-cluster:
	@echo "Ensuring providers cluster exists: $(PROVIDERS_CLUSTER)"
	@if kind get clusters | grep -qw $(PROVIDERS_CLUSTER); then \
	  echo "Cluster '$(PROVIDERS_CLUSTER)' already exists. Skipping creation..."; \
	else \
	  echo "Cluster '$(PROVIDERS_CLUSTER)' does not exist. Creating..."; \
	  kind create cluster --name $(PROVIDERS_CLUSTER); \
	fi
	@echo "Exporting kubeconfig for cluster '$(PROVIDERS_CLUSTER)'..."
	@kind get kubeconfig --name $(PROVIDERS_CLUSTER) > tmp/kube-$(PROVIDERS_CLUSTER).config
	@echo "Merging kubeconfig for cluster '$(PROVIDERS_CLUSTER)' into $(KUBECONFIG_FILE)..."
	@KUBECONFIG=$(KUBECONFIG_FILE):tmp/kube-$(PROVIDERS_CLUSTER).config kubectl config view --merge --flatten > tmp/merged.config
	@mv tmp/merged.config $(KUBECONFIG_FILE)

# ------------------------------------------------------------------------------
# tenant-clusters: Ensure tenant clusters exist, export and merge their kubeconfigs.
# ------------------------------------------------------------------------------
tenant-clusters:
	@echo "Ensuring tenant clusters exist: $(TENANT1_CLUSTER) and $(TENANT2_CLUSTER)"
	@for cluster in $(TENANT1_CLUSTER) $(TENANT2_CLUSTER); do \
	  if kind get clusters | grep -qw $$cluster; then \
	    echo "Cluster '$$cluster' already exists. Skipping creation..."; \
	  else \
	    echo "Cluster '$$cluster' does not exist. Creating..."; \
	    kind create cluster --name $$cluster; \
	  fi; \
	  echo "Exporting kubeconfig for cluster '$$cluster'..."; \
	  kind get kubeconfig --name $$cluster > tmp/kube-$$cluster.config; \
	  echo "Merging kubeconfig for cluster '$$cluster' into $(KUBECONFIG_FILE)..."; \
	  KUBECONFIG=$(KUBECONFIG_FILE):tmp/kube-$$cluster.config kubectl config view --merge --flatten > tmp/merged.config; \
	  mv tmp/merged.config $(KUBECONFIG_FILE); \
	done

# ------------------------------------------------------------------------------
# cli: Install kcp plugins via Krew.
# ------------------------------------------------------------------------------
cli: install-kcp-plugin

# ------------------------------------------------------------------------------
# kcp: Install the kcp chart on the $(PLATFORM_CLUSTER) cluster.
# Depends on cert-manager and nginx-controller installation.
# ------------------------------------------------------------------------------
kcp: kcp-cluster install-kcp create-kcp-kubeconfig

# ------------------------------------------------------------------------------
# tenants: Install API sync agent and ArgoCD on the appropriate clusters.
# ------------------------------------------------------------------------------
tenants: install-api-syncagent install-argocd

# ------------------------------------------------------------------------------
# create-kcp-kubeconfig: Merge steps to create KCP kubeconfig entries.
# ------------------------------------------------------------------------------
create-kcp-kubeconfig:
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" config use-context kind-$(PLATFORM_CLUSTER)
	@echo "Creating tmp directory if necessary..."
	@mkdir -p tmp
	@echo "Applying client certificate manifest to the platform cluster..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp apply -f manifests/platform/cert.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp wait certificate --for=condition=ready -l app.kubernetes.io/instance=kcp
	echo "Extracting the KCP front proxy certificate to tmp/ca.crt..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp get secret kcp-front-proxy-cert -o=jsonpath='{.data.tls\.crt}' | base64 -d > tmp/ca.crt
	@echo "Extracting client certificate and key from secret..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp get secret cluster-admin-client-cert -o=jsonpath='{.data.tls\.crt}' | base64 -d > tmp/client.crt
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp get secret cluster-admin-client-cert -o=jsonpath='{.data.tls\.key}' | base64 -d > tmp/client.key
	@chmod 600 tmp/client.crt tmp/client.key

	echo "Configuring 'base' cluster in kcp.kubeconfig..."
	@kubectl --kubeconfig=kcp.kubeconfig config set-cluster base --server https://$(HOSTNAME):30443 --certificate-authority=tmp/ca.crt
	echo "Configuring 'root' cluster in kcp.kubeconfig..."
	@kubectl --kubeconfig=kcp.kubeconfig config set-cluster root --server https://$(HOSTNAME):30443/clusters/root --certificate-authority=tmp/ca.crt
	@echo "Setting kcp-admin credentials in kcp.kubeconfig..."
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-credentials kcp-admin --client-certificate=tmp/client.crt --client-key=tmp/client.key
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-context base --cluster=base --user=kcp-admin
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-context root --cluster=root --user=kcp-admin
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config use-context root
# ------------------------------------------------------------------------------
# install-cert-manager: Install cert-manager on the $(PLATFORM_CLUSTER) cluster using Helm.
# ------------------------------------------------------------------------------
install-cert-manager:
	@echo "Installing cert-manager (including CRDs) on the $(PLATFORM_CLUSTER) cluster..."
	@helm repo add jetstack https://charts.jetstack.io || true
	@helm repo update
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" config use-context kind-$(PLATFORM_CLUSTER)
	@helm upgrade --install cert-manager jetstack/cert-manager \
	  --namespace cert-manager \
	  --create-namespace \
	  --kube-context kind-$(PLATFORM_CLUSTER) \
	  --kubeconfig "$(KUBECONFIG_FILE)" \
	  --set crds.enabled=true
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/platform/clusterissuer.yaml
# ------------------------------------------------------------------------------
# install-kcp: Install the kcp chart on the $(PLATFORM_CLUSTER) cluster.
# Depends on cert-manager and nginx-controller installation.
# ------------------------------------------------------------------------------
install-kcp: install-cert-manager
	@echo "Installing 'kcp' chart on the $(PLATFORM_CLUSTER) cluster..."
	@helm repo add kcp-dev https://kcp-dev.github.io/helm-charts || true
	@helm repo update
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" config use-context kind-$(PLATFORM_CLUSTER)
	@helm upgrade --install kcp kcp-dev/kcp \
	  --namespace kcp \
	  --create-namespace \
	  --kube-context kind-$(PLATFORM_CLUSTER) \
	  --kubeconfig "$(KUBECONFIG_FILE)" \
	  --set letsEncrypt.production.email=$$EMAIL \
	  -f values-kcp.yaml

# ------------------------------------------------------------------------------
# install-nginx-controller: Install the nginx ingress controller on the $(PLATFORM_CLUSTER) cluster.
# ------------------------------------------------------------------------------
install-nginx-controller:
	@echo "Installing the nginx ingress controller on the $(PLATFORM_CLUSTER) cluster..."
	@helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx || true
	@helm repo update
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" config use-context kind-$(PLATFORM_CLUSTER)
	@helm upgrade --install nginx-ingress ingress-nginx/ingress-nginx \
	  --namespace ingress-nginx \
	  --create-namespace \
	  --kube-context kind-$(PLATFORM_CLUSTER) \
	  -f values-nginx.yaml \
	  --kubeconfig "$(KUBECONFIG_FILE)"

# ------------------------------------------------------------------------------
# install-kcp-plugin: Install kcp-related plugins via Krew.
# ------------------------------------------------------------------------------
install-kcp-plugin:
	@echo "Installing kcp plugins (kcp, ws, create-workspace) using Krew..."
	@kubectl krew index add kcp-dev https://github.com/kcp-dev/krew-index.git || true
	@kubectl krew install kcp-dev/kcp
	@kubectl krew install kcp-dev/ws
	@kubectl krew install kcp-dev/create-workspace
	@cp ${KREW_ROOT}/bin/kubectl-create_workspace ${KREW_ROOT}/bin/kubectl-create-workspace

# ------------------------------------------------------------------------------
# install-krew: Install Krew via Homebrew if not already installed.
# ------------------------------------------------------------------------------
install-krew:
	@if command -v kubectl-krew > /dev/null 2>&1; then \
	  echo "Krew is already installed. Skipping..."; \
	else \
	  echo "Installing Krew using Homebrew..."; \
	  brew install krew; \
	  echo "Krew installation complete. If needed, add $$HOME/.krew/bin to your PATH."; \
	fi

# ------------------------------------------------------------------------------
# install-argocd: Install Argo CD on the $(PLATFORM_CLUSTER) cluster.
# ------------------------------------------------------------------------------
install-argocd:
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" config use-context kind-$(PLATFORM_CLUSTER)
	@echo "Installing Argo CD on the $(PLATFORM_CLUSTER) cluster..."
	@helm repo add argo https://argoproj.github.io/argo-helm || true
	@helm repo update
	@helm upgrade --install argocd argo/argo-cd \
	  --namespace argocd \
	  --create-namespace \
	  --kube-context kind-$(PLATFORM_CLUSTER) \
	  --kubeconfig "$(KUBECONFIG_FILE)"

# ------------------------------------------------------------------------------
# install-api-syncagent: Install api-syncagent on the providers cluster and
# create a secret with the platform cluster's kubeconfig.
# ------------------------------------------------------------------------------
install-api-syncagent:
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" config use-context kind-$(PLATFORM_CLUSTER)
	@echo "Installing 'api-syncagent' chart on the $(PROVIDERS_CLUSTER) cluster..."
	@helm repo add kcp-dev https://kcp-dev.github.io/helm-charts || true
	@helm repo update
	@helm upgrade --install api-syncagent kcp-dev/api-syncagent \
	  --namespace api-syncagent \
	  --create-namespace \
	  --kube-context kind-$(PROVIDERS_CLUSTER) \
	  --kubeconfig "$(KUBECONFIG_FILE)" \
	  -f values-syncagent.yaml
	@echo "Creating secret 'platform-kubeconfig' in the 'api-syncagent' namespace on the $(PROVIDERS_CLUSTER) cluster..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" config use-context kind-$(PROVIDERS_CLUSTER)
	@kubectl create secret generic platform-kubeconfig \
	  --from-file=kubeconfig=tmp/kube-$(PLATFORM_CLUSTER).config \
	  --namespace api-syncagent --dry-run=client -o yaml | kubectl apply -f -

# ------------------------------------------------------------------------------
# clean: Clean up temporary files and delete clusters.
# Warning: This will remove clusters and cannot be undone.
# ------------------------------------------------------------------------------
clean:
	@echo "Cleaning up temporary files..."
	@rm -rf tmp
	@echo "Deleting clusters: $(PLATFORM_CLUSTER), $(PROVIDERS_CLUSTER), $(TENANT1_CLUSTER), $(TENANT2_CLUSTER)..."
	@for cluster in $(PLATFORM_CLUSTER) $(PROVIDERS_CLUSTER) $(TENANT1_CLUSTER) $(TENANT2_CLUSTER); do \
	  kind delete cluster --name $$cluster; \
	done
	@rm -f $(KUBECONFIG_FILE)
	@echo "Clean up complete."