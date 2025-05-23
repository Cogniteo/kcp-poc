SHELL := /bin/bash

# Default cluster names (adjust to suit your environment)
PLATFORM_CLUSTER   ?= platform
PROVIDERS_CLUSTER  ?= providers
TENANT1_CLUSTER    ?= tenant1
TENANT2_CLUSTER    ?= tenant2
DOMAIN             ?= kcp.piotrjanik.dev
HOSTNAME           ?= api.$(DOMAIN)
EKS_CLUSTER_NAME   ?= kcp-cluster
AWS_REGION         ?= eu-central-1
EKS_NODE_TYPE      ?= t3.small
# Location of your merged kubeconfig file
KUBECONFIG_FILE    ?= kube.config
KCPCONFIG_FILE     ?= kcp.kubeconfig
KREW_ROOT          ?= $(HOME)/.krew
ARGOCD_DOMAIN      ?= argocd.$(DOMAIN)


.PHONY: all kcp providers cli vpc-create eks \
        kcp kcp-create-cluster install-argocd-platform kcp-provision-cluster \
        provider providers-create-cluster install-argocd-providers providers-provision-cluster providers-expose-db-api \
        cli kcp-setup-kubectl clean eks-create eks-delete

all: kcp providers cli

eks: eks-create
kcp: kcp-create-cluster install-argocd-platform kcp-provision-cluster
providers: providers-create-cluster install-argocd-providers providers-provision-cluster providers-expose-db-api
cli: kcp-setup-kubectl

kcp-create-cluster:
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


kcp-install:
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/eks/applications/cert-manager.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/eks/applications/ack.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/eks/applications/kcp.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s application ack
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" wait --for=create --timeout=480s customresourcedefinitions.apiextensions.k8s.io certificates.cert-manager.io
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" wait --for=create --timeout=120s -n cert-manager deployment cert-manager-app-webhook
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" wait --for=condition=Available --timeout=120s -n cert-manager deployment/cert-manager-app-webhook
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/eks/clusterissuer.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" wait --for=create --timeout=480s customresourcedefinitions.apiextensions.k8s.io certificates.cert-manager.io
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/eks/certificate-argocd.yaml

kcp-create-kubeconfig:
	@echo "Creating tmp directory if necessary..."
	@mkdir -p tmp
	@echo "Applying client certificate manifest to the platform cluster..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp apply -f manifests/kcp/cert.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp wait certificate.cert-manager.io --for=condition=ready cluster-admin-client-cert
	echo "Extracting the KCP front proxy certificate to tmp/ca.crt..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp get secret kcp-front-proxy-cert -o=jsonpath='{.data.tls\.crt}' | base64 -d > tmp/ca.crt
	@echo "Extracting client certificate and key from secret..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp get secret cluster-admin-client-cert -o=jsonpath='{.data.tls\.crt}' | base64 -d > tmp/client.crt
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n kcp get secret cluster-admin-client-cert -o=jsonpath='{.data.tls\.key}' | base64 -d > tmp/client.key
	@chmod 600 tmp/client.crt tmp/client.key

	echo "Configuring 'base' cluster in kcp.kubeconfig..."
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-cluster base --server https://$(HOSTNAME):8443 --certificate-authority=tmp/ca.crt
	echo "Configuring 'root' cluster in kcp.kubeconfig..."
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-cluster root --server https://$(HOSTNAME):8443/clusters/root --certificate-authority=tmp/ca.crt
	@echo "Setting kcp-admin credentials in kcp.kubeconfig..."
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-credentials kcp-admin --client-certificate=tmp/client.crt --client-key=tmp/client.key
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-context base --cluster=base --user=kcp-admin
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-context root --cluster=root --user=kcp-admin
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config use-context root


kcp-setup-kubectl:
	@if command -v kubectl-krew > /dev/null 2>&1; then \
	  echo "Krew is already installed. Skipping..."; \
	else \
	  echo "Installing Krew using Homebrew..."; \
	  brew install krew; \
	  echo "Krew installation complete. If needed, add $$HOME/.krew/bin to your PATH."; \
	fi
	@echo "Installing kcp plugins (kcp, ws, create-workspace) using Krew..."
	@kubectl krew index add kcp-dev https://github.com/kcp-dev/krew-index.git || true
	@kubectl krew install kcp-dev/kcp
	@kubectl krew install kcp-dev/ws
	@kubectl krew install kcp-dev/create-workspace
	@cp ${KREW_ROOT}/bin/kubectl-create_workspace ${KREW_ROOT}/bin/kubectl-create-workspace

argocd-install:
	@helm repo add argo https://argoproj.github.io/argo-helm || true
	@helm repo update
	@echo "Installing Argo CD"
	@helm upgrade --install argocd argo/argo-cd --version 8.0.3 \
	  --namespace argocd \
	  --create-namespace \
	  --kubeconfig "$(KUBECONFIG_FILE)" \
	  --values manifests/eks/applications/argocd-values.yaml

vpc-create:
	@echo "Creating or updating VPC resources via CloudFormation using template manifests/eks/cf/vpc.yaml"
	@aws cloudformation deploy \
	  --template-file manifests/eks/cf/vpc.yaml \
	  --stack-name $(EKS_CLUSTER_NAME)-vpc \
	  --region $(AWS_REGION) \
	  --capabilities CAPABILITY_IAM \
	  --parameter-overrides ClusterName=$(EKS_CLUSTER_NAME)

vpc-delete:
	@echo "Deleting VPC resources via CloudFormation stack $(EKS_CLUSTER_NAME)-vpc"
	@aws cloudformation delete-stack \
	  --stack-name $(EKS_CLUSTER_NAME)-vpc \
	  --region $(AWS_REGION)

eks-create:		
	@echo "Creating or updating EKS cluster via CloudFormation"
	@aws cloudformation deploy \
	    --template-file manifests/eks/cf/eks.yaml \
	    --stack-name $(EKS_CLUSTER_NAME) \
	    --region $(AWS_REGION) \
	    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
	    --parameter-overrides ClusterName=$(EKS_CLUSTER_NAME)
	@echo "Updating kubeconfig for cluster $(EKS_CLUSTER_NAME)"
	@aws eks update-kubeconfig --name $(EKS_CLUSTER_NAME) --region $(AWS_REGION) --kubeconfig $(KUBECONFIG_FILE)
	@echo "Applying Karpenter NodePool manifest..."
	@kubectl apply -f manifests/eks/nodepool.yaml --kubeconfig $(KUBECONFIG_FILE)
	@kubectl apply -f manifests/eks/ingressclass.yaml --kubeconfig $(KUBECONFIG_FILE)
	@kubectl apply -f manifests/eks/storageclass.yaml --kubeconfig $(KUBECONFIG_FILE)

eks-delete:
	@echo "Deleting EKS cluster via CloudFormation stack $(EKS_CLUSTER_NAME)"
	@aws cloudformation delete-stack \
	  --stack-name $(EKS_CLUSTER_NAME) \
	  --region $(AWS_REGION)
	@echo "Waiting for EKS CF stack deletion to complete..."
	@aws cloudformation wait stack-delete-complete \
	  --stack-name $(EKS_CLUSTER_NAME) \
	  --region $(AWS_REGION)

clean:
	@echo "Deleting Argo CD applications..."
	@kubectl --kubeconfig=$(KUBECONFIG_FILE) -n argocd delete applications --all || true
	@echo "Deleting EKS CF stack..."
	@$(MAKE) eks-delete
	@echo "Deleting VPC CF stack..."
	@$(MAKE) vpc-delete
	@echo "Cleaning up temporary files..."
	@rm -rf tmp
	@rm -f $(KUBECONFIG_FILE)
	@rm -f $(KCPCONFIG_FILE)
	@echo "Clean up complete."