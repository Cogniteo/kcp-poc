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
KCPCONFIG_FILE     ?= $(KUBECONFIG_FILE)
KREW_ROOT          ?= $(HOME)/.krew
ARGOCD_DOMAIN      ?= argocd.$(DOMAIN)
ACME_EMAIL         ?= admin@$(DOMAIN)

# Variables for TLS Secret
K8S_NAMESPACE_FOR_SECRET ?= controllers
TLS_SECRET_NAME ?= kcp-controller-certs
CLIENT_CERT_FILE ?= tmp/client.crt
CLIENT_KEY_FILE ?= tmp/client.key
CA_CERT_FILE ?= tmp/ca.crt


.PHONY: all kcp providers cli vpc-create cognito-create cognito-delete eks \
        kcp kcp-create-cluster install-argocd-platform kcp-provision-cluster \
        provider providers-create-cluster install-argocd-providers providers-provision-cluster providers-expose-db-api \
        cli kcp-setup-kubectl kcp-delete clean eks-create eks-delete up down deploy-controllers \
        create-tls-secret delete-tls-secret ecr-clean

all: up

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
	@echo -e "\033[1;31m[VPC] Deleting VPC resources via CloudFormation stack $(EKS_CLUSTER_NAME)-vpc\033[0m"
	@aws cloudformation delete-stack \
	  --stack-name $(EKS_CLUSTER_NAME)-vpc \
	  --region $(AWS_REGION)
	@echo "Waiting for VPC CF stack deletion to complete..."
	@aws cloudformation wait stack-delete-complete \
	  --stack-name $(EKS_CLUSTER_NAME)-vpc \
	  --region $(AWS_REGION)

eks-create:		
	@echo -e "\033[1;32m[EKS] Creating/updating cluster via CloudFormation\033[0m"
	@echo "Checking if SpotServiceLinkedRole exists..."; \
	if aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1; then \
	    echo "SpotServiceLinkedRole already exists. Skipping creation."; \
	    CREATE_SPOT_ROLE=false; \
	else \
	    echo "SpotServiceLinkedRole not found. It will be created by CloudFormation."; \
	    CREATE_SPOT_ROLE=true; \
	fi; \
	echo "Creating CloudFormation stack $(EKS_CLUSTER_NAME) with CreateSpotRole=$$CREATE_SPOT_ROLE"; \
	aws cloudformation deploy \
	    --template-file manifests/core/eks/eks.yaml \
	    --stack-name $(EKS_CLUSTER_NAME) \
	    --region $(AWS_REGION) \
	    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
	    --parameter-overrides ClusterName=$(EKS_CLUSTER_NAME) CreateSpotRole=$$CREATE_SPOT_ROLE
	@echo "Updating kubeconfig for cluster $(EKS_CLUSTER_NAME)"
	@aws eks update-kubeconfig --name $(EKS_CLUSTER_NAME) --region $(AWS_REGION) --kubeconfig $(KUBECONFIG_FILE) --alias eks
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" config delete-context $(EKS_CLUSTER_NAME) || true
	@echo "Applying Karpenter NodePool manifest..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks apply -f manifests/core/eks/nodepool.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks apply -f manifests/core/eks/ingressclass.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks apply -f manifests/core/eks/storageclass.yaml

eks-delete: ecr-clean
	@echo -e "\033[1;31m[EKS] Deleting EKS cluster via CloudFormation stack $(EKS_CLUSTER_NAME)\033[0m"
	@aws cloudformation delete-stack \
	  --stack-name $(EKS_CLUSTER_NAME) \
	  --region $(AWS_REGION)
	@echo "Waiting for EKS CF stack deletion to complete..."
	@aws cloudformation wait stack-delete-complete \
	  --stack-name $(EKS_CLUSTER_NAME) \
	  --region $(AWS_REGION)

argocd-install:
	@echo -e "\033[1;32m[Argo CD] Installing/upgrading release\033[0m"; \
	helm repo add argo https://argoproj.github.io/argo-helm || true; \
	helm repo update; \
	helm upgrade --install argocd argo/argo-cd --version 8.0.3 \
	  --namespace argocd \
	  --create-namespace \
	  --kubeconfig "$(KUBECONFIG_FILE)" \
	  --set global.domain="argocd.$(DOMAIN)" \
	  --values manifests/core/argocd-values.yaml

kcp-install:
	@echo -e "\033[1;32m[ArgoCD] Deploying ApplicationSet\033[0m"
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks apply -f manifests/core/applicationset.yaml
	ACME_EMAIL=$(ACME_EMAIL) envsubst < manifests/core/certificates/clusterissuer.yaml | kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks apply -f -

kcp-delete:
	@echo -e "\033[1;31m[KCP] Deleting custom resources...\033[0m"
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks delete clusterissuer selfsigned-cluster-issuer --ignore-not-found || true
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks delete userpool kcp-userpool --ignore-not-found || true

kcp-setup-kubectl:
	@echo -e "\033[1;32m[Kubectl plugin setup] Krew and KCP plugins\033[0m"
	@if command -v kubectl-krew > /dev/null 2>&1; then \
	  echo -e "\033[1;32m[Krew] Krew is already installed. Skipping...\033[0m"; \
	else \
	  echo -e "\033[1;32m[Krew] Installing Krew using Homebrew...\033[0m"; \
	  brew install krew; \
	  echo -e "\033[1;32m[Krew] Krew installation complete. If needed, add $$HOME/.krew/bin to your PATH.\033[0m"; \
	fi
	@echo -e "\033[1;32m[Krew] Installing kcp plugins (kcp, ws, create-workspace) using Krew...\033[0m"
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
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks -n kcp apply -f manifests/kcp/cert.yaml
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks -n kcp wait certificate.cert-manager.io --for=condition=ready cluster-admin-client-cert
	echo "Extracting the KCP front proxy certificate to tmp/ca.crt..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks -n kcp get secret kcp-front-proxy-cert -o=jsonpath='{.data.tls\.crt}' | base64 -d > tmp/ca.crt
	@echo "Extracting client certificate and key from secret..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks -n kcp get secret cluster-admin-client-cert -o=jsonpath='{.data.tls\.crt}' | base64 -d > tmp/client.crt
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks -n kcp get secret cluster-admin-client-cert -o=jsonpath='{.data.tls\.key}' | base64 -d > tmp/client.key
	@chmod 600 tmp/client.crt tmp/client.key

	echo "Configuring 'base' cluster in kcp.kubeconfig..."
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-cluster base --server https://$(HOSTNAME):443 --certificate-authority=tmp/ca.crt
	echo "Configuring 'root' cluster in kcp.kubeconfig..."
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-cluster root --server https://$(HOSTNAME):443/clusters/root --certificate-authority=tmp/ca.crt
	@echo "Setting kcp-admin credentials in kcp.kubeconfig..."
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-credentials kcp-admin --client-certificate=tmp/client.crt --client-key=tmp/client.key
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-context kcp-base --cluster=base --user=kcp-admin
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-context kcp-root --cluster=root --user=kcp-admin
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config use-context kcp-root

controllers-create-tls-secret:
	@echo -e "\033[1;32m[TLS Secret] Creating/updating TLS secret $(TLS_SECRET_NAME) in namespace $(K8S_NAMESPACE_FOR_SECRET) using context eks\033[0m"
	@if [ ! -f "$(CLIENT_CERT_FILE)" ]; then \
		echo -e "\033[1;31m[TLS Secret] Error: Client certificate file $(CLIENT_CERT_FILE) not found. Ensure 'make kcp-create-kubeconfig' succeeded.\033[0m"; \
		exit 1; \
	fi
	@if [ ! -f "$(CLIENT_KEY_FILE)" ]; then \
		echo -e "\033[1;31m[TLS Secret] Error: Client key file $(CLIENT_KEY_FILE) not found. Ensure 'make kcp-create-kubeconfig' succeeded.\033[0m"; \
		exit 1; \
	fi
	@if [ ! -f "$(CA_CERT_FILE)" ]; then \
		echo -e "\033[1;31m[TLS Secret] Error: CA certificate file $(CA_CERT_FILE) not found. Ensure 'make kcp-create-kubeconfig' succeeded.\033[0m"; \
		exit 1; \
	fi
	@echo "Creating/Updating secret $(TLS_SECRET_NAME)..."
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks create secret generic $(TLS_SECRET_NAME) \
		--from-file=tls.crt=$(CLIENT_CERT_FILE) \
		--from-file=tls.key=$(CLIENT_KEY_FILE) \
		--from-file=ca.crt=$(CA_CERT_FILE) \
		--namespace=$(K8S_NAMESPACE_FOR_SECRET) \
		--dry-run=client -o yaml | kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks apply -f -

controllers-delete-tls-secret:
	@echo -e "\033[1;31m[TLS Secret] Deleting TLS secret $(TLS_SECRET_NAME) from namespace $(K8S_NAMESPACE_FOR_SECRET) using context eks\033[0m"
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks delete secret $(TLS_SECRET_NAME) \
		--namespace=$(K8S_NAMESPACE_FOR_SECRET) --ignore-not-found=true

controllers-deploy:
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" config use-context eks
	@kubectl --kubeconfig="$(KUBECONFIG_FILE)" create namespace controllers || true
	@$(MAKE) controllers-create-tls-secret
	@IMG=ghcr.io/piotrjanik/kcp-users-controller:latest && \
	@echo "Deploying kcp-users-controller using GHCR image $${IMG}" && \
	@$(MAKE) -C ../kcp-users-controller deploy IMG=$${IMG} KUBECTL="kubectl --kubeconfig=$(CURDIR)/$(KUBECONFIG_FILE)"

kcp-deploy-sample:
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" --context kcp-root apply -f manifests/kcp/users/v1alpha1.users.yaml
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" --context kcp-root apply -f manifests/kcp/users/workspace.yaml
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-cluster users --server https://$(HOSTNAME):443/clusters/root:users --certificate-authority=tmp/ca.crt
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" config set-context users --cluster=users --user=kcp-admin
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" --context users create namespace default || true
	@kubectl --kubeconfig="$(KCPCONFIG_FILE)" --context users apply -n default -f manifests/kcp/users/sample-user.yml
	
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

down:
	@echo -e "\033[1;31m[DOWN] Deleting EKS cluster\033[0m"
	@$(MAKE) eks-delete
	@echo -e "\033[1;31m[DOWN] Deleting VPC resources\033[0m"
	@$(MAKE) vpc-delete

ecr-clean:
	@echo -e "\033[1;33m[ECR] Cleaning Controllers ECR repository\033[0m"
	@ECR_URI=$$(aws cloudformation describe-stacks --stack-name $(EKS_CLUSTER_NAME) --region $(AWS_REGION) --query "Stacks[0].Outputs[?OutputKey=='ControllersRepositoryUri'].OutputValue" --output text) && \
	if [ -z "$$ECR_URI" ]; then \
	  echo -e "\033[1;33m[ECR] No ControllersRepositoryUri found. Skipping ECR cleanup.\033[0m"; \
	else \
	  REPO=$$(echo $$ECR_URI | cut -d/ -f2-); \
	  COUNT=$$(aws ecr list-images --repository-name $$REPO --region $(AWS_REGION) --query 'length(imageIds)' --output text); \
	  if [ "$$COUNT" -gt 0 ]; then \
	    IDS=$$(aws ecr list-images --repository-name $$REPO --region $(AWS_REGION) --query 'imageIds[*]' --output json); \
	    aws ecr batch-delete-image --repository-name $$REPO --region $(AWS_REGION) --image-ids "$$IDS"; \
	    echo -e "\033[1;33m[ECR] Deleted $$COUNT images from $$REPO.\033[0m"; \
	  else \
	    echo -e "\033[1;33m[ECR] ECR repo $$REPO is already empty.\033[0m"; \
	  fi; \
	fi
