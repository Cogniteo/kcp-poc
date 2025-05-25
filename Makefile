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
        cli kcp-setup-kubectl clean eks-create eks-delete up down

all: kcp providers cli

eks: eks-create
kcp: kcp-create-cluster install-argocd-platform kcp-provision-cluster
providers: providers-create-cluster install-argocd-providers providers-provision-cluster providers-expose-db-api
cli: kcp-setup-kubectl

vpc-create:
	@echo -e "\033[1;32m[VPC] Creating/updating via CloudFormation\033[0m"
	@aws cloudformation deploy \
	  --template-file manifests/core/eks/vpc.yaml \
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
	@echo -e "\033[1;32m[EKS] Creating/updating cluster via CloudFormation\033[0m"
	@aws cloudformation deploy \
	    --template-file manifests/core/eks/eks.yaml \
	    --stack-name $(EKS_CLUSTER_NAME) \
	    --region $(AWS_REGION) \
	    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
	    --parameter-overrides ClusterName=$(EKS_CLUSTER_NAME)
	@echo "Updating kubeconfig for cluster $(EKS_CLUSTER_NAME)"
	@aws eks update-kubeconfig --name $(EKS_CLUSTER_NAME) --region $(AWS_REGION) --kubeconfig $(KUBECONFIG_FILE)
	@echo "Applying Karpenter NodePool manifest..."
	@kubectl apply -f manifests/core/eks/nodepool.yaml --kubeconfig $(KUBECONFIG_FILE)
	@kubectl apply -f manifests/core/eks/ingressclass.yaml --kubeconfig $(KUBECONFIG_FILE)
	@kubectl apply -f manifests/core/eks/storageclass.yaml --kubeconfig $(KUBECONFIG_FILE)

eks-delete:
	@echo "Deleting EKS cluster via CloudFormation stack $(EKS_CLUSTER_NAME)"
	@aws cloudformation delete-stack \
	  --stack-name $(EKS_CLUSTER_NAME) \
	  --region $(AWS_REGION)
	@echo "Waiting for EKS CF stack deletion to complete..."
	@aws cloudformation wait stack-delete-complete \
	  --stack-name $(EKS_CLUSTER_NAME) \
	  --region $(AWS_REGION)

argocd-install:
	@echo -e "\033[1;32m[Argo CD] Installing/upgrading release\033[0m"
	@helm repo add argo https://argoproj.github.io/argo-helm || true
	@helm repo update
	@helm upgrade --install argocd argo/argo-cd --version 8.0.3 \
	  --namespace argocd \
	  --create-namespace \
	  --kubeconfig "$(KUBECONFIG_FILE)" \
	  --set global.domain="argocd.$(DOMAIN)" \
	  --values manifests/core/applications/argocd-values.yaml

kcp-install:
	@echo -e "\033[1;32m[External-Dns] Deploying application\033[0m"
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/core/applications/external-dns.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s application external-dns
	@echo -e "\033[1;32m[Cert-Manager] Deploying application\033[0m"
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/core/applications/cert-manager.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s application cert-manager
	@echo -e "\033[1;32m[ACK] Deploying application\033[0m"
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/core/applications/ack.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s application ack
	@echo -e "\033[1;32m[KCP] Deploying application\033[0m"
	@DOMAIN=$(DOMAIN) envsubst < manifests/core/applications/kcp.yaml | kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f -
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy --timeout=300s application kcp
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" wait --for=create --timeout=480s customresourcedefinitions.apiextensions.k8s.io certificates.cert-manager.io
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" wait --for=create --timeout=120s -n cert-manager deployment cert-manager-webhook
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" wait --for=condition=Available --timeout=120s -n cert-manager deployment/cert-manager-webhook
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f manifests/core/certificates/clusterissuer.yaml
	@DOMAIN=$(DOMAIN) envsubst < manifests/core/certificates/certificate-argocd.yaml | kubectl --kubeconfig="$(KUBECONFIG_FILE)" apply -f -

kcp-setup-kubectl:
	@echo -e "\033[1;32m[Kubectl plugin setup] Krew and KCP plugins\033[0m"
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

kcp-create-kubeconfig:
	@echo -e "\033[1;32m[KCP] Generating KCP kubeconfig\033[0m"
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

clean:
	@echo -e "\033[1;32m[Clean] Deleting Argo CD applications...\033[0m"
	@kubectl --kubeconfig=$(KUBECONFIG_FILE) -n argocd delete applications --all || true
	@echo -e "\033[1;32m[Clean] Deleting EKS CF stack...\033[0m"
	@$(MAKE) eks-delete
	@echo -e "\033[1;32m[Clean] Deleting VPC CF stack...\033[0m"
	@$(MAKE) vpc-delete
	@echo -e "\033[1;32m[Clean] Cleaning up temporary files...\033[0m"
	@rm -rf tmp
	@rm -f $(KUBECONFIG_FILE)
	@rm -f $(KCPCONFIG_FILE)
	@echo -e "\033[1;32m[Clean] Complete\033[0m"

.PHONY: up down

up:
	@$(MAKE) vpc-create
	@$(MAKE) eks-create
	@$(MAKE) argocd-install
	@$(MAKE) kcp-install
	@$(MAKE) kcp-setup-kubectl
	@$(MAKE) kcp-create-kubeconfig
	@$(MAKE) kcp-create-kubeconfig

down:
	@echo -e "\033[1;31m[DOWN] Deleting EKS cluster\033[0m"
	@$(MAKE) eks-delete
	@echo -e "\033[1;31m[DOWN] Deleting VPC resources\033[0m"
	@$(MAKE) vpc-delete
