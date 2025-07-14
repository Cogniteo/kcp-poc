# KCP POC Infrastructure Makefile
# This Makefile manages the KCP infrastructure on AWS EKS
#
# Usage: make [target]
# Run 'make help' for a list of available targets

SHELL := /bin/bash

# Required external variables (must be provided)
ifndef DOMAIN
$(error DOMAIN is not set. Please provide DOMAIN variable, e.g., export DOMAIN=example.com)
endif
ifndef ACME_EMAIL
$(error ACME_EMAIL is not set. Please provide ACME_EMAIL variable, e.g., export ACME_EMAIL=admin@example.com)
endif

# Configuration
EKS_CLUSTER_NAME   ?= kcp-cluster
AWS_REGION         ?= eu-central-1

# Derived variables
KCP_HOSTNAME       := api.$(DOMAIN)
KUBECONFIG_FILE    ?= kube.config
KREW_ROOT          ?= $(HOME)/.krew
ARGOCD_DOMAIN      := argocd.$(DOMAIN)

# TLS Secret configuration
K8S_NAMESPACE_FOR_SECRET := controllers
TLS_SECRET_NAME := kcp-controller-certs
CLIENT_CERT_FILE := tmp/client.crt
CLIENT_KEY_FILE := tmp/client.key
CA_CERT_FILE := tmp/ca.crt

# Helper functions
define echo_up_header
	@echo -e "\033[1;34m=== $1 ===\033[0m"
endef

define echo_down_header
	@echo -e "\033[1;31m=== $1 ===\033[0m"
endef

define echo_up
	@echo -e "\033[1;32m[UP] $1\033[0m"
endef

define echo_down
	@echo -e "\033[1;31m[DOWN] $1\033[0m"
endef


# Kubectl command shortcuts
KUBECTL_EKS := kubectl --kubeconfig="$(KUBECONFIG_FILE)" --context eks
KUBECTL_KCP := kubectl --kubeconfig="$(KUBECONFIG_FILE)"


.PHONY: help all up down clean \
        vpc-create vpc-delete \
        eks-create eks-delete \
        cognito-create cognito-delete \
        kcp-setup-kubectl kcp-create-kubeconfig \
        controllers-create-tls-secret controllers-deploy \
        kcp-deploy-sample ecr-clean apply-admin-user

# Default target shows help
all: help

# Help target
help:
	@echo "KCP POC Infrastructure Management"
	@echo ""
	@echo "Required Environment Variables:"
	@echo "  DOMAIN                     - Your domain (current: $(DOMAIN))"
	@echo "  ACME_EMAIL                 - Email for ACME certificates (current: $(ACME_EMAIL))"
	@echo ""
	@echo "Main Workflow:"
	@echo "  make up                    - Create complete infrastructure (VPC, EKS, ArgoCD, KCP)"
	@echo "  make down                  - Destroy all infrastructure"
	@echo ""
	@echo "Infrastructure Management:"
	@echo "  make vpc-create            - Create VPC infrastructure"
	@echo "  make vpc-delete            - Delete VPC infrastructure"
	@echo "  make eks-create            - Create EKS cluster"
	@echo "  make eks-delete            - Delete EKS cluster"
	@echo "  make cognito-create        - Create Cognito resources"
	@echo "  make cognito-delete        - Delete Cognito resources"
	@echo ""
	@echo "Application Deployment:"
	@echo "  make argocd-install        - Install ArgoCD"
	@echo "  make kcp-install           - Install KCP"
	@echo "  make kcp-delete            - Delete KCP"
	@echo ""
	@echo "KCP Setup:"
	@echo "  make kcp-setup-kubectl     - Install kubectl plugins for KCP"
	@echo "  make kcp-create-kubeconfig - Generate KCP kubeconfig"
	@echo "  make kcp-deploy-sample     - Deploy sample KCP resources"
	@echo ""
	@echo "TLS Management:"
	@echo "  make controllers-create-tls-secret - Create TLS secret for controllers"
	@echo ""
	@echo "Cleanup:"
	@echo "  make ecr-clean             - Clean up ECR repository"
	@echo ""
	@echo "Configuration:"
	@echo "  EKS_CLUSTER_NAME=$(EKS_CLUSTER_NAME)"
	@echo "  AWS_REGION=$(AWS_REGION)"

# Main workflow targets
up:
	$(call echo_up_header,Infrastructure setup)
	@$(MAKE) vpc-create
	@$(MAKE) eks-create
	@$(MAKE) cognito-create
	@$(MAKE) argocd-install
	@$(MAKE) kcp-install
	@$(MAKE) kcp-create-kubeconfig
	$(call echo_up_header,Infrastructure setup complete)

# Teardown
down:	
	$(call echo_down_header,Cleaning up temporary files)
	@$(MAKE) kcp-delete eks-delete cognito-delete vpc-delete
	@rm -f $(KUBECONFIG_FILE)
	@rm -rf tmp
	$(call echo_down_header,Infrastructure teardown complete)

# VPC Management
vpc-create:
	$(call echo_up,Creating/updating VPC via CloudFormation)
	@aws cloudformation deploy \
	  --template-file manifests/eks/cf-vpc.yaml \
	  --stack-name $(EKS_CLUSTER_NAME)-vpc \
	  --region $(AWS_REGION) \
	  --capabilities CAPABILITY_IAM \
	  --parameter-overrides ClusterName=$(EKS_CLUSTER_NAME)

vpc-delete:
	$(call echo_down,Deleting VPC resources via CloudFormation)
	@aws cloudformation delete-stack \
	  --stack-name $(EKS_CLUSTER_NAME)-vpc \
	  --region $(AWS_REGION)
	@echo "Waiting for VPC CF stack deletion to complete..."
	@aws cloudformation wait stack-delete-complete \
	  --stack-name $(EKS_CLUSTER_NAME)-vpc \
	  --region $(AWS_REGION)

# Cognito Management
cognito-create:
	$(call echo_up,Creating/updating Cognito resources via CloudFormation)
	@aws cloudformation deploy \
	  --template-file manifests/cognito/cf-stack.yaml \
	  --stack-name $(EKS_CLUSTER_NAME)-cognito \
	  --region $(AWS_REGION) \
	  --capabilities CAPABILITY_IAM \
	  --parameter-overrides \
	    ClusterName=$(EKS_CLUSTER_NAME) \
	    CallbackUrl=https://api.$(DOMAIN)/auth/callback

cognito-delete:
	$(call echo_down,Deleting Cognito resources via CloudFormation)
	@aws cloudformation delete-stack \
	  --stack-name $(EKS_CLUSTER_NAME)-cognito \
	  --region $(AWS_REGION)
	@echo "Waiting for Cognito CF stack deletion to complete..."
	@aws cloudformation wait stack-delete-complete \
	  --stack-name $(EKS_CLUSTER_NAME)-cognito \
	  --region $(AWS_REGION)

# EKS Management
eks-create:
	$(call echo_up,Creating/updating EKS cluster via CloudFormation)
	@echo "Checking if SpotServiceLinkedRole exists..."
	@CREATE_SPOT_ROLE=$$(aws iam get-role --role-name AWSServiceRoleForEC2Spot >/dev/null 2>&1 && echo false || echo true); \
	echo "Creating CloudFormation stack $(EKS_CLUSTER_NAME) with CreateSpotRole=$$CREATE_SPOT_ROLE"; \
	aws cloudformation deploy \
	    --template-file manifests/eks/cf-eks.yaml \
	    --stack-name $(EKS_CLUSTER_NAME) \
	    --region $(AWS_REGION) \
	    --capabilities CAPABILITY_IAM CAPABILITY_NAMED_IAM \
	    --parameter-overrides ClusterName=$(EKS_CLUSTER_NAME) CreateSpotRole=$$CREATE_SPOT_ROLE
	@echo "Updating kubeconfig for cluster $(EKS_CLUSTER_NAME)"
	@aws eks update-kubeconfig --name $(EKS_CLUSTER_NAME) --region $(AWS_REGION) --kubeconfig $(KUBECONFIG_FILE) --alias eks
	@$(KUBECTL_EKS) config delete-context $(EKS_CLUSTER_NAME) || true
	@echo "Applying cluster manifests..."
	@$(KUBECTL_EKS) apply -f manifests/eks/nodepool.yaml
	@$(KUBECTL_EKS) apply -f manifests/eks/ingressclass.yaml
	@$(KUBECTL_EKS) apply -f manifests/eks/storageclass.yaml

eks-delete: ecr-clean
	$(call echo_down,Deleting EKS cluster via CloudFormation)
	@aws cloudformation delete-stack \
	  --stack-name $(EKS_CLUSTER_NAME) \
	  --region $(AWS_REGION)
	@echo "Waiting for EKS CF stack deletion to complete..."
	@aws cloudformation wait stack-delete-complete \
	  --stack-name $(EKS_CLUSTER_NAME) \
	  --region $(AWS_REGION)

argocd-install:
	$(call echo_up,Installing ArgoCD)
	helm repo add argo https://argoproj.github.io/argo-helm || true; \
	helm repo update; \
	helm upgrade --install argocd argo/argo-cd --version 8.0.3 \
	  --namespace argocd \
	  --create-namespace \
	  --kubeconfig "$(KUBECONFIG_FILE)" \
	  --set global.domain="argocd.$(DOMAIN)" \
	  --values manifests/platform/argocd-values.yaml

kcp-install:
	$(call echo_up,Installing KCP)
	ACME_EMAIL=$(ACME_EMAIL) \
	KCP_HOSTNAME=$(KCP_HOSTNAME) \
	envsubst < manifests/platform/applicationset.yaml | $(KUBECTL_EKS) apply -f -
	
	$(call echo_up,Creating OIDC secret for Cognito integration)
	@USER_POOL_ID=$$(aws cloudformation describe-stacks --stack-name $(EKS_CLUSTER_NAME)-cognito --region $(AWS_REGION) \
	  --query "Stacks[0].Outputs[?OutputKey=='UserPoolId'].OutputValue" --output text) && \
	CLIENT_ID=$$(aws cloudformation describe-stacks --stack-name $(EKS_CLUSTER_NAME)-cognito --region $(AWS_REGION) \
	  --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientId'].OutputValue" --output text) && \
	CLIENT_SECRET=$$(aws cloudformation describe-stacks --stack-name $(EKS_CLUSTER_NAME)-cognito --region $(AWS_REGION) \
	  --query "Stacks[0].Outputs[?OutputKey=='UserPoolClientSecret'].OutputValue" --output text) && \
	OIDC_URL="https://cognito-idp.$(AWS_REGION).amazonaws.com/$$USER_POOL_ID" && \
	$(KUBECTL_EKS) create namespace kcp --dry-run=client -o yaml | $(KUBECTL_EKS) apply -f - && \
	$(KUBECTL_EKS) create secret generic oidc-secret \
	  --namespace=kcp \
	  --from-literal=url=$$OIDC_URL \
	  --from-literal=client_id=$$CLIENT_ID \
	  --from-literal=client_secret=$$CLIENT_SECRET \
	  --dry-run=client -o yaml | $(KUBECTL_EKS) apply -f -
	
	$(call echo_up,Waiting for KCP ArgoCD Application to become healthy)
	$(call echo_up,Waiting for KCP application to be created and become healthy)
	$(KUBECTL_EKS) -n argocd wait --for=jsonpath='{.status.sync.status}'=Synced --timeout=300s application.argoproj.io/kcp-suite
	$(KUBECTL_EKS) -n argocd wait --for=jsonpath='{.status.health.status}'=Healthy --timeout=600s application.argoproj.io/kcp-suite

kcp-delete:
	$(call echo_down,Deleting KCP)
	@$(KUBECTL_EKS) delete clusterissuer selfsigned-cluster-issuer --ignore-not-found || true
	@$(KUBECTL_EKS) delete userpool kcp-userpool --ignore-not-found || true
	@echo "Note: Cognito resources are now managed via CloudFormation"
	@$(KUBECTL_EKS) -n argocd delete applicationset kcp-suite --ignore-not-found || true


# KCP Setup
kcp-setup-kubectl:
	$(call echo_up,Installing Krew and KCP plugins)
	@if ! command -v kubectl-krew > /dev/null 2>&1; then \
	  echo "Installing Krew using Homebrew..."; \
	  brew install krew; \
	fi
	@echo "Installing kcp plugins using Krew..."
	@kubectl krew index add kcp-dev https://github.com/kcp-dev/krew-index.git || true
	@kubectl krew install kcp-dev/kcp kcp-dev/ws kcp-dev/create-workspace
	@cp ${KREW_ROOT}/bin/kubectl-create_workspace ${KREW_ROOT}/bin/kubectl-create-workspace || true

kcp-create-kubeconfig:
	$(call echo_up,Generating KCP kubeconfig)
	@mkdir -p tmp
	$(KUBECTL_EKS) wait --for=create --timeout=480s customresourcedefinitions.apiextensions.k8s.io certificates.cert-manager.io
	$(KUBECTL_EKS) wait --for=create --timeout=120s -n cert-manager deployment cert-manager-webhook
	$(KUBECTL_EKS) wait --for=condition=Available --timeout=120s -n cert-manager deployment/cert-manager-webhook
	$(call echo_up,Waiting for cluster admin certificate to be ready)
	$(KUBECTL_EKS) -n kcp wait certificate.cert-manager.io --for=condition=ready cluster-admin-client-cert
	$(KUBECTL_EKS) -n kcp get secret kcp-front-proxy-cert -o=jsonpath='{.data.tls\.crt}' | base64 -d > tmp/ca.crt
	$(KUBECTL_EKS) -n kcp get secret cluster-admin-client-cert -o=jsonpath='{.data.tls\.crt}' | base64 -d > tmp/client.crt
	$(KUBECTL_EKS) -n kcp get secret cluster-admin-client-cert -o=jsonpath='{.data.tls\.key}' | base64 -d > tmp/client.key
	@chmod 600 tmp/client.crt tmp/client.key
	$(KUBECTL_KCP) config set-cluster base --server https://$(KCP_HOSTNAME):443 --certificate-authority=tmp/ca.crt
	$(KUBECTL_KCP) config set-cluster root --server https://$(KCP_HOSTNAME):443/clusters/root --certificate-authority=tmp/ca.crt
	$(KUBECTL_KCP) config set-credentials kcp-admin --client-certificate=tmp/client.crt --client-key=tmp/client.key
	$(KUBECTL_KCP) config set-context kcp-base --cluster=base --user=kcp-admin
	$(KUBECTL_KCP) config set-context kcp-root --cluster=root --user=kcp-admin
	$(KUBECTL_KCP) config use-context kcp-root

# Controllers Management
controllers-create-tls-secret:
	$(call echo_up,Creating/updating TLS secret)
	@for file in $(CLIENT_CERT_FILE) $(CLIENT_KEY_FILE) $(CA_CERT_FILE); do \
		if [ ! -f "$$file" ]; then \
			$(call echo_error,Error: $$file not found. Run 'make kcp-create-kubeconfig' first); \
			exit 1; \
		fi; \
	done
	@echo "Creating/Updating secret $(TLS_SECRET_NAME)..."
	@$(KUBECTL_EKS) create secret generic $(TLS_SECRET_NAME) \
		--from-file=tls.crt=$(CLIENT_CERT_FILE) \
		--from-file=tls.key=$(CLIENT_KEY_FILE) \
		--from-file=ca.crt=$(CA_CERT_FILE) \
		--namespace=$(K8S_NAMESPACE_FOR_SECRET) \
		--dry-run=client -o yaml | $(KUBECTL_EKS) apply -f -

kcp-deploy-sample:
	$(call echo_up,Deploying sample resources)
	@$(KUBECTL_KCP) --context kcp-root apply -f manifests/kcp/users/v1alpha1.users.yaml
	@$(KUBECTL_KCP) --context kcp-root apply -f manifests/kcp/users/workspace.yaml
	@$(KUBECTL_KCP) config set-cluster users --server https://$(KCP_HOSTNAME):443/clusters/root:users --certificate-authority=tmp/ca.crt
	@$(KUBECTL_KCP) config set-context users --cluster=users --user=kcp-admin
	@$(KUBECTL_KCP) --context users create namespace default || true
	@$(KUBECTL_KCP) --context users apply -n default -f manifests/kcp/users/sample-user.yml

ecr-clean:
	$(call echo_down,Cleaning Controllers ECR repository)
	@ECR_URI=$$(aws cloudformation describe-stacks --stack-name $(EKS_CLUSTER_NAME) --region $(AWS_REGION) --query "Stacks[0].Outputs[?OutputKey=='ControllersRepositoryUri'].OutputValue" --output text 2>/dev/null) && \
	if [ -z "$$ECR_URI" ]; then \
	  echo "No ControllersRepositoryUri found. Skipping ECR cleanup."; \
	else \
	  REPO=$$(echo $$ECR_URI | cut -d/ -f2-); \
	  COUNT=$$(aws ecr list-images --repository-name $$REPO --region $(AWS_REGION) --query 'length(imageIds)' --output text 2>/dev/null || echo 0); \
	  if [ "$$COUNT" -gt 0 ]; then \
	    IDS=$$(aws ecr list-images --repository-name $$REPO --region $(AWS_REGION) --query 'imageIds[*]' --output json); \
	    aws ecr batch-delete-image --repository-name $$REPO --region $(AWS_REGION) --image-ids "$$IDS"; \
	    echo "Deleted $$COUNT images from $$REPO."; \
	  else \
	    echo "ECR repo $$REPO is already empty."; \
	  fi; \
	fi
