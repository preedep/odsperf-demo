#!/usr/bin/env bash
# =============================================================================
# deploy-ods.sh — Build and Deploy ODS Service to Kubernetes
#
# Usage:
#   ./scripts/deploy-ods.sh                    # Build + Deploy
#   ./scripts/deploy-ods.sh --skip-build       # Deploy only (image exists)
#   ./scripts/deploy-ods.sh --build-only       # Build only (no deploy)
# =============================================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────────────────────
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Config ────────────────────────────────────────────────────────────────────
IMAGE_NAME="odsperf-demo"
IMAGE_TAG="latest"
NAMESPACE="ods-service"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Flags ─────────────────────────────────────────────────────────────────────
DO_BUILD=true
DO_DEPLOY=true
DO_RESTART=false

for arg in "$@"; do
  case "$arg" in
    --skip-build)  DO_BUILD=false  ;;
    --build-only)  DO_DEPLOY=false ;;
    --restart)     DO_RESTART=true ;;
    --help|-h)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --skip-build   Skip Docker build (use existing image)"
      echo "  --build-only   Build image only (no deploy)"
      echo "  --restart      Force rollout restart after deploy"
      echo "  --help, -h     Show this help"
      exit 0 ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────────────
log_ok()   { printf "${GREEN}✔${NC}  %s\n" "$1"; }
log_fail() { printf "${RED}✘${NC}  %s\n" "$1"; exit 1; }
log_info() { printf "${YELLOW}ℹ${NC}  %s\n" "$1"; }
log_step() { printf "\n${BOLD}${CYAN}══════ %s ══════${NC}\n" "$1"; }

# ── Banner ────────────────────────────────────────────────────────────────────
printf "${BOLD}${CYAN}"
printf "╔══════════════════════════════════════════════════════════════╗\n"
printf "║          ODS Service — Build & Deploy Pipeline              ║\n"
printf "╚══════════════════════════════════════════════════════════════╝\n"
printf "${NC}"

cd "$PROJECT_ROOT"

# ── Detect Kubernetes context ────────────────────────────────────────────────
K8S_CONTEXT=$(kubectl config current-context 2>/dev/null || echo "unknown")
log_info "Kubernetes context: ${K8S_CONTEXT}"

# Detect if using minikube
IS_MINIKUBE=false
if [[ "$K8S_CONTEXT" == *"minikube"* ]]; then
  IS_MINIKUBE=true
  log_info "Detected minikube environment"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 1: Build Docker Image
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_BUILD" = true ]; then
  log_step "Step 1 — Build Docker Image"
  
  log_info "Building ${IMAGE_NAME}:${IMAGE_TAG}..."
  log_info "This may take 5-10 minutes on first build (downloading crates + compilation)"
  
  # For minikube, use minikube's docker daemon
  if [ "$IS_MINIKUBE" = true ]; then
    log_info "Using minikube docker daemon..."
    eval $(minikube docker-env)
  fi
  
  docker build -t "${IMAGE_NAME}:${IMAGE_TAG}" . || log_fail "Docker build failed"
  
  log_ok "Image built: ${IMAGE_NAME}:${IMAGE_TAG}"
  
  # Show image info
  docker images "${IMAGE_NAME}:${IMAGE_TAG}" --format "table {{.Repository}}\t{{.Tag}}\t{{.Size}}\t{{.CreatedAt}}"
fi

# ─────────────────────────────────────────────────────────────────────────────
# STEP 2: Deploy to Kubernetes
# ─────────────────────────────────────────────────────────────────────────────
if [ "$DO_DEPLOY" = true ]; then
  log_step "Step 2 — Deploy to Kubernetes"
  
  # Check if namespace exists
  if ! kubectl get namespace "$NAMESPACE" > /dev/null 2>&1; then
    log_fail "Namespace '${NAMESPACE}' does not exist. Run 'make namespaces' first."
  fi
  
  log_info "Deploying to namespace: ${NAMESPACE}"
  
  # Apply deployment and service
  kubectl apply -f infra/ods-service/deployment.yaml || log_fail "Failed to apply deployment"
  kubectl apply -f infra/ods-service/service.yaml || log_fail "Failed to apply service"
  
  log_ok "Manifests applied"
  
  # Wait for deployment to be ready
  log_info "Waiting for deployment to be ready (timeout: 120s)..."
  if kubectl rollout status deployment/ods-service -n "$NAMESPACE" --timeout=120s 2>/dev/null; then
    log_ok "Deployment is ready"
  else
    log_fail "Deployment failed to become ready. Check logs with:
    kubectl logs -n ${NAMESPACE} -l app=ods-service"
  fi
  
  # Rollout restart if requested (forces new image pull)
  if [ "$DO_RESTART" = true ]; then
    log_step "Step 3 — Rollout Restart"
    log_info "Forcing rollout restart to pull new image..."
    kubectl rollout restart deployment/ods-service -n "$NAMESPACE" || log_fail "Rollout restart failed"
    
    log_info "Waiting for rollout to complete..."
    if kubectl rollout status deployment/ods-service -n "$NAMESPACE" --timeout=120s 2>/dev/null; then
      log_ok "Rollout complete"
    else
      log_fail "Rollout failed"
    fi
  fi
  
  # Show pod status
  echo ""
  printf "${CYAN}Pod Status:${NC}\n"
  kubectl get pods -n "$NAMESPACE" -l app=ods-service
  
  # Show service
  echo ""
  printf "${CYAN}Service:${NC}\n"
  kubectl get svc -n "$NAMESPACE"
  
  # Show recent logs
  echo ""
  printf "${CYAN}Recent Logs (last 20 lines):${NC}\n"
  kubectl logs -n "$NAMESPACE" -l app=ods-service --tail=20 2>/dev/null || echo "No logs available yet"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
printf "${GREEN}${BOLD}✓ ODS Service deployment complete!${NC}\n\n"

if [ "$DO_DEPLOY" = true ]; then
  printf "Next steps:\n"
  printf "  1. Test health endpoint:\n"
  printf "     ${CYAN}kubectl port-forward -n ${NAMESPACE} svc/ods-service 8080:80${NC}\n"
  printf "     ${CYAN}curl http://localhost:8080/health${NC}\n\n"
  printf "  2. Test via Istio Gateway:\n"
  printf "     ${CYAN}curl http://ods.local/health${NC}\n\n"
  printf "  3. Run API tests:\n"
  printf "     ${CYAN}./scripts/test-api.sh${NC}\n\n"
  printf "  4. View logs:\n"
  printf "     ${CYAN}kubectl logs -n ${NAMESPACE} -l app=ods-service -f${NC}\n\n"
fi
