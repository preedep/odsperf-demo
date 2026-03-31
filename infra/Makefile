# =============================================================================
# ODS Performance Demo - Infrastructure Makefile
# Supports: Docker Desktop Kubernetes / minikube
# =============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Helm chart versions (pin for reproducibility)
# ---------------------------------------------------------------------------
ISTIO_VERSION           := 1.28.3
GATEWAY_API_VERSION     := v1.1.0
KUBE_PROMETHEUS_VERSION := 61.3.2
# Leave POSTGRESQL_VERSION / MONGODB_VERSION empty = use latest chart
# (Bitnami removes old image tags from Docker Hub; pinning old chart versions breaks image pulls)
POSTGRESQL_VERSION      :=
MONGODB_VERSION         :=

# ---------------------------------------------------------------------------
# Helm release names
# ---------------------------------------------------------------------------
PROMETHEUS_RELEASE  := kube-prometheus-stack
POSTGRESQL_RELEASE  := postgresql
MONGODB_RELEASE     := mongodb

# ---------------------------------------------------------------------------
# Detect Kubernetes context (Docker Desktop vs minikube)
# ---------------------------------------------------------------------------
K8S_CONTEXT := $(shell kubectl config current-context 2>/dev/null)

# ---------------------------------------------------------------------------
# Colors for output
# ---------------------------------------------------------------------------
GREEN  := \033[0;32m
YELLOW := \033[1;33m
RED    := \033[0;31m
NC     := \033[0m

# Fix: do NOT wrap $(1) with extra quotes inside define.
#      Callers must NOT pass quoted strings — just plain text.
define log_info
	@printf '$(GREEN)[INFO]$(NC) %s\n' '$(1)'
endef

define log_warn
	@printf '$(YELLOW)[WARN]$(NC) %s\n' '$(1)'
endef

define log_error
	@printf '$(RED)[ERROR]$(NC) %s\n' '$(1)'
endef

# =============================================================================
# HELP
# =============================================================================
.PHONY: help
help:
	@echo ""
	@echo "  ODS Performance Demo - Infrastructure"
	@echo "  ======================================"
	@echo ""
	@echo "  Usage: make <target>"
	@echo ""
	@echo "  Setup (run in order):"
	@echo "    prerequisites      Check required tools are installed"
	@echo "    all                Deploy everything (steps 1-6)"
	@echo ""
	@echo "  Individual steps:"
	@echo "    gateway-api-crds   Install Kubernetes Gateway API CRDs"
	@echo "    namespaces         Create Kubernetes namespaces"
	@echo "    istio              Install Istio via Helm"
	@echo "    gateway            Apply Istio Gateway + HTTPRoute resources"
	@echo "    monitoring         Install kube-prometheus-stack (Prometheus + Grafana)"
	@echo "    postgresql         Install PostgreSQL"
	@echo "    mongodb            Install MongoDB"
	@echo ""
	@echo "  Utilities:"
	@echo "    status             Show status of all deployments"
	@echo "    port-forward-grafana      Port-forward Grafana     -> localhost:3000"
	@echo "    port-forward-prometheus   Port-forward Prometheus  -> localhost:9090"
	@echo "    port-forward-postgresql   Port-forward PostgreSQL  -> localhost:5432"
	@echo "    port-forward-mongodb      Port-forward MongoDB     -> localhost:27017"
	@echo "    gateway-ip         Get Gateway external IP"
	@echo "    hosts-entry        Print /etc/hosts entries needed"
	@echo ""
	@echo "  Teardown:"
	@echo "    clean              Uninstall all Helm releases + namespaces"
	@echo "    clean-databases    Uninstall databases only (+ PVCs)"
	@echo ""
	@echo "  Current K8s context: $(K8S_CONTEXT)"
	@echo ""

# =============================================================================
# PREREQUISITES CHECK
# =============================================================================
.PHONY: prerequisites
prerequisites:
	$(call log_info,Checking prerequisites...)
	@command -v kubectl  >/dev/null 2>&1 || { echo "kubectl not found.  https://kubernetes.io/docs/tasks/tools/"; exit 1; }
	@command -v helm     >/dev/null 2>&1 || { echo "helm not found.     https://helm.sh/docs/intro/install/"; exit 1; }
	@command -v istioctl >/dev/null 2>&1 || { echo "istioctl not found. https://istio.io/latest/docs/setup/getting-started/"; exit 1; }
	@kubectl cluster-info >/dev/null 2>&1 || { echo "Cannot connect to Kubernetes. Is your cluster running?"; exit 1; }
	$(call log_info,All prerequisites satisfied)
	@echo "  kubectl  : $$(kubectl version --client 2>/dev/null | grep 'Client Version' | awk '{print $$3}' || kubectl version --client 2>/dev/null | head -1)"
	@echo "  helm     : $$(helm version 2>/dev/null | grep -o 'v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*' | head -1)"
	@echo "  istioctl : $$(istioctl version --remote=false 2>/dev/null | head -1)"
	@echo "  context  : $(K8S_CONTEXT)"

# =============================================================================
# ALL - Deploy everything in order
# =============================================================================
.PHONY: all
all: prerequisites gateway-api-crds namespaces istio gateway monitoring postgresql mongodb
	@echo ""
	$(call log_info,==========================================)
	$(call log_info,All infrastructure deployed successfully!)
	$(call log_info,==========================================)
	@$(MAKE) hosts-entry
	@$(MAKE) status

# =============================================================================
# STEP 1: Gateway API CRDs
# =============================================================================
.PHONY: gateway-api-crds
gateway-api-crds:
	$(call log_info,[1/6] Installing Kubernetes Gateway API CRDs $(GATEWAY_API_VERSION)...)
	kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/$(GATEWAY_API_VERSION)/standard-install.yaml
	$(call log_info,Gateway API CRDs installed)

# =============================================================================
# STEP 2: Namespaces
# =============================================================================
.PHONY: namespaces
namespaces:
	$(call log_info,[2/6] Creating namespaces...)
	kubectl apply -f namespaces.yaml
	$(call log_info,Namespaces created)

# =============================================================================
# STEP 3: Istio
# =============================================================================
.PHONY: istio
istio:
	$(call log_info,[3/6] Installing Istio $(ISTIO_VERSION) via Helm...)
	helm repo add istio https://istio-release.storage.googleapis.com/charts --force-update
	helm repo update istio
	helm upgrade --install istio-base istio/base \
		--namespace istio-system \
		--create-namespace \
		--version $(ISTIO_VERSION) \
		--set defaultRevision=default \
		--wait
	helm upgrade --install istiod istio/istiod \
		--namespace istio-system \
		--version $(ISTIO_VERSION) \
		--set pilot.env.PILOT_ENABLE_GATEWAY_API=true \
		--set pilot.env.PILOT_ENABLE_GATEWAY_API_STATUS=true \
		--wait
	$(call log_info,Istio installed)
	@istioctl verify-install 2>/dev/null || true

# =============================================================================
# STEP 4: Gateway API resources (Gateway + HTTPRoutes + ReferenceGrants)
# =============================================================================
.PHONY: gateway
gateway:
	$(call log_info,[4/6] Applying Istio Gateway API resources...)
	kubectl apply -f istio/gateway.yaml
	kubectl apply -f istio/reference-grants.yaml
	@echo "Waiting for Gateway to be programmed (up to 120s)..."
	@kubectl wait gateway/ods-gateway -n ingress \
		--for=condition=Programmed \
		--timeout=120s 2>/dev/null || true
	kubectl apply -f istio/httproute.yaml
	$(call log_info,Gateway + HTTPRoutes applied)

# =============================================================================
# STEP 5: Monitoring (Prometheus + Grafana)
# =============================================================================
.PHONY: monitoring
monitoring:
	$(call log_info,[5/6] Installing kube-prometheus-stack $(KUBE_PROMETHEUS_VERSION)...)
	helm repo add prometheus-community https://prometheus-community.github.io/helm-charts --force-update
	helm repo update prometheus-community
	helm upgrade --install $(PROMETHEUS_RELEASE) prometheus-community/kube-prometheus-stack \
		--namespace monitoring \
		--version $(KUBE_PROMETHEUS_VERSION) \
		--values monitoring/kube-prometheus-values.yaml \
		--wait \
		--timeout 10m
	$(call log_info,Monitoring stack installed)

# =============================================================================
# STEP 6a: PostgreSQL
# =============================================================================
.PHONY: postgresql
postgresql:
	$(call log_info,[6a/6] Installing PostgreSQL $(POSTGRESQL_VERSION)...)
	helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
	helm repo update bitnami
	helm upgrade --install $(POSTGRESQL_RELEASE) bitnami/postgresql \
		--namespace databases \
		$(if $(POSTGRESQL_VERSION),--version $(POSTGRESQL_VERSION),) \
		--values postgresql/values.yaml \
		--wait \
		--timeout 5m
	$(call log_info,PostgreSQL installed)
	@echo ""
	@echo "  Connection: postgresql://odsuser:odspassword@postgresql.databases.svc.cluster.local:5432/odsperf"

# =============================================================================
# STEP 6b: MongoDB
# =============================================================================
.PHONY: mongodb
mongodb:
	$(call log_info,[6b/6] Installing MongoDB $(MONGODB_VERSION)...)
	helm repo add bitnami https://charts.bitnami.com/bitnami --force-update
	helm repo update bitnami
	helm upgrade --install $(MONGODB_RELEASE) bitnami/mongodb \
		--namespace databases \
		$(if $(MONGODB_VERSION),--version $(MONGODB_VERSION),) \
		--values mongodb/values.yaml \
		--wait \
		--timeout 5m
	$(call log_info,MongoDB installed)
	@echo ""
	@echo "  Connection: mongodb://odsuser:odspassword@mongodb.databases.svc.cluster.local:27017/odsperf"

# =============================================================================
# UTILITIES
# =============================================================================

.PHONY: status
status:
	@echo ""
	@echo "=== Pods (monitoring) ==="
	@kubectl get pods -n monitoring 2>/dev/null || true
	@echo ""
	@echo "=== Pods (databases) ==="
	@kubectl get pods -n databases 2>/dev/null || true
	@echo ""
	@echo "=== Pods (ingress) ==="
	@kubectl get pods -n ingress 2>/dev/null || true
	@echo ""
	@echo "=== Gateway ==="
	@kubectl get gateway -n ingress 2>/dev/null || true
	@echo ""
	@echo "=== HTTPRoutes ==="
	@kubectl get httproutes -n ingress 2>/dev/null || true
	@echo ""
	@echo "=== Services (databases) ==="
	@kubectl get svc -n databases 2>/dev/null || true

.PHONY: gateway-ip
gateway-ip:
	@echo "Gateway external IP / Hostname:"
	@kubectl get gateway ods-gateway -n ingress \
		-o jsonpath='{.status.addresses[0].value}' 2>/dev/null && echo "" || echo "(not yet assigned)"

.PHONY: hosts-entry
hosts-entry:
	@GW_IP=$$(kubectl get gateway ods-gateway -n ingress \
		-o jsonpath='{.status.addresses[0].value}' 2>/dev/null); \
	if [ -z "$$GW_IP" ]; then \
		GW_IP="127.0.0.1"; \
		printf '$(YELLOW)[WARN]$(NC) Gateway IP not yet assigned, using 127.0.0.1 placeholder\n'; \
		echo "       Run 'make gateway-ip' later once the Gateway is ready."; \
	fi; \
	echo ""; \
	echo "Add to /etc/hosts (macOS/Linux) or C:\\Windows\\System32\\drivers\\etc\\hosts (Windows):"; \
	echo ""; \
	echo "  $$GW_IP  grafana.local"; \
	echo "  $$GW_IP  prometheus.local"; \
	echo "  $$GW_IP  ods.local"; \
	echo ""

.PHONY: port-forward-grafana
port-forward-grafana:
	$(call log_info,Grafana -> http://localhost:3000  login: admin / admin)
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-grafana 3000:80

.PHONY: port-forward-prometheus
port-forward-prometheus:
	$(call log_info,Prometheus -> http://localhost:9090)
	kubectl port-forward -n monitoring svc/kube-prometheus-stack-prometheus 9090:9090

.PHONY: port-forward-postgresql
port-forward-postgresql:
	$(call log_info,PostgreSQL -> localhost:5432)
	kubectl port-forward -n databases svc/postgresql 5432:5432

.PHONY: port-forward-mongodb
port-forward-mongodb:
	$(call log_info,MongoDB -> localhost:27017)
	kubectl port-forward -n databases svc/mongodb 27017:27017

# =============================================================================
# TEARDOWN
# =============================================================================
.PHONY: clean
clean:
	$(call log_warn,Removing all ODS performance demo infrastructure...)
	-helm uninstall $(MONGODB_RELEASE)    -n databases  2>/dev/null || true
	-helm uninstall $(POSTGRESQL_RELEASE) -n databases  2>/dev/null || true
	-helm uninstall $(PROMETHEUS_RELEASE) -n monitoring 2>/dev/null || true
	-kubectl delete -f istio/httproute.yaml        2>/dev/null || true
	-kubectl delete -f istio/reference-grants.yaml 2>/dev/null || true
	-kubectl delete -f istio/gateway.yaml          2>/dev/null || true
	-helm uninstall istiod     -n istio-system 2>/dev/null || true
	-helm uninstall istio-base -n istio-system 2>/dev/null || true
	-kubectl delete namespace istio-system ingress ods-service monitoring databases 2>/dev/null || true
	$(call log_info,Teardown complete)

.PHONY: clean-databases
clean-databases:
	$(call log_warn,Removing databases only...)
	-helm uninstall $(MONGODB_RELEASE)    -n databases 2>/dev/null || true
	-helm uninstall $(POSTGRESQL_RELEASE) -n databases 2>/dev/null || true
	-kubectl delete pvc --all -n databases 2>/dev/null || true
	$(call log_info,Databases removed)
