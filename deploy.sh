#!/bin/bash
# Multi-Tenant MaaS PoC - Quickstart Deployment
# 
# Prerequisites (install with ./scripts/prerequisites.sh):
#   - OpenShift cluster with Gateway API enabled
#   - Kuadrant operators installed
#   - ODH/RHOAI with KServe installed
#   - Keycloak operator installed
#   - ODH operator with ModelsAsService component
#
# Usage: ./deploy.sh [--install-prereqs]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helper functions
source "$SCRIPT_DIR/scripts/deployment-helpers.sh"

# Parse flags
INSTALL_PREREQS=false
while [[ $# -gt 0 ]]; do
  case $1 in
    --install-prereqs) INSTALL_PREREQS=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --install-prereqs        Run prerequisites.sh before deploying"
      echo "  -h, --help               Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "========================================="
echo "Multi-Tenant MaaS PoC Deployment"
echo "   Mode: Operator-driven (ModelsAsService CRs)"
echo "========================================="
echo ""

# Check prerequisites
echo "Checking prerequisites..."
command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found"; exit 1; }
command -v kustomize >/dev/null 2>&1 || { echo "kustomize not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "jq not found"; exit 1; }

# Check if running on OpenShift
if ! oc get routes -A &>/dev/null; then
    echo "This script requires an OpenShift cluster"
    echo "   Please ensure you are logged in: oc login"
    exit 1
fi
echo "   OpenShift cluster detected"

# Run prerequisites if requested
if [[ "$INSTALL_PREREQS" == true ]]; then
    echo ""
    echo "Installing prerequisites..."
    "$SCRIPT_DIR/scripts/prerequisites.sh"
    echo ""
fi

# Check if required CRDs exist
echo ""
echo "Verifying required CRDs..."
require_crd keycloaks.k8s.keycloak.org "Keycloak operator"
require_crd authpolicies.kuadrant.io "Kuadrant operators"
require_crd gateways.gateway.networking.k8s.io "Gateway API"
require_crd llminferenceservices.serving.kserve.io "KServe/ODH (LLMInferenceService)"

# ModelsAsService CRD check (soft - may not be installed yet)
if kubectl get crd modelsasservices.components.platform.opendatahub.io &>/dev/null; then
    echo "   ModelsAsService CRD found"
else
    echo "   ModelsAsService CRD not found (will fail on tenant deployment)"
    echo "   Ensure ODH operator with MaaS component is installed"
fi

# Auto-detect and configure cluster
echo ""
echo "1. Detecting cluster configuration..."

# Source obtain-cluster-config.sh to get the configure_cluster function
source "$SCRIPT_DIR/scripts/obtain-cluster-config.sh"

# Run configuration (exports CLUSTER_DOMAIN, KEYCLOAK_HOST, etc.)
configure_cluster || exit 1

# Create namespaces (shared-models only - tenant namespaces are created by operator)
echo ""
echo "2. Creating shared namespaces..."
for ns in keycloak-system shared-models; do
    kubectl create namespace $ns 2>/dev/null && echo "   Created: $ns" || echo "   Exists: $ns"
done

# Deploy Gateways (uses kustomize with params.env)
echo ""
echo "3. Deploying Gateways..."
kubectl apply -k "$SCRIPT_DIR/manifests/gateways/"
echo "   GatewayClass + Gateways deployed"

# Deploy Keycloak
echo ""
echo "4. Deploying Keycloak..."
kubectl apply -k "$SCRIPT_DIR/manifests/keycloak/"
echo "   Keycloak deployed"

# Deploy Tenants via ModelsAsService CRs
echo ""
echo "5. Deploying Tenant-A (via ModelsAsService CR)..."

# Apply CR (controller creates namespace and deploys resources)
kubectl apply -f "$SCRIPT_DIR/manifests/tenants/tenant-a/modelsasservice.yaml"

# Tier mapping must be applied by tenant admin after namespace exists
echo "   Waiting for namespace..."
for i in {1..30}; do
    kubectl get ns tenant-a &>/dev/null && break
    sleep 1
done
kubectl apply -f "$SCRIPT_DIR/manifests/tenants/tenant-a/tier-mapping-configmap.yaml" 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/manifests/tenants/tenant-a/token-rate-limits.yaml" 2>/dev/null || true
kubectl apply -k "$SCRIPT_DIR/manifests/tenants/tenant-a/models/" 2>/dev/null || true
echo "   Tenant-A deployed"

echo ""
echo "6. Deploying Tenant-B (via ModelsAsService CR)..."
kubectl apply -f "$SCRIPT_DIR/manifests/tenants/tenant-b/modelsasservice.yaml"
echo "   Waiting for namespace..."
for i in {1..30}; do
    kubectl get ns tenant-b &>/dev/null && break
    sleep 1
done
kubectl apply -f "$SCRIPT_DIR/manifests/tenants/tenant-b/tier-mapping-configmap.yaml" 2>/dev/null || true
kubectl apply -f "$SCRIPT_DIR/manifests/tenants/tenant-b/token-rate-limits.yaml" 2>/dev/null || true
kubectl apply -k "$SCRIPT_DIR/manifests/tenants/tenant-b/models/" 2>/dev/null || true
echo "   Tenant-B deployed"

# Deploy Shared Models
echo ""
echo "7. Deploying Shared Models..."
kubectl apply -k "$SCRIPT_DIR/manifests/shared-models/"
echo "   Shared models deployed"

# Configure Authorino TLS (Kuadrant)
echo ""
echo "8. Configuring Kuadrant Authorino for TLS..."
AUTHORINO_TLS_SCRIPT="$SCRIPT_DIR/scripts/configure-authorino-tls.sh"
if [[ -f "$AUTHORINO_TLS_SCRIPT" ]]; then
    "$AUTHORINO_TLS_SCRIPT" 2>&1 || echo "   Authorino TLS configuration had issues (non-fatal)"
else
    echo "   Authorino TLS script not found: $AUTHORINO_TLS_SCRIPT"
fi

# Wait for AuthPolicies to exist before patching
echo ""
echo "9. Waiting for MaaS API AuthPolicies to be created..."
for tenant in tenant-a tenant-b; do
    echo "   Waiting for maas-api-auth-policy in $tenant..."
    for i in {1..30}; do
        if kubectl get authpolicy maas-api-auth-policy -n "$tenant" &>/dev/null; then
            echo "   AuthPolicy exists in $tenant"
            break
        fi
        if [[ $i -eq 30 ]]; then
            echo "   AuthPolicy not found in $tenant after 30s"
        fi
        sleep 1
    done
done

# Patch tenant MaaS API AuthPolicy audiences
echo ""
echo "10. Patching tenant MaaS API AuthPolicy audiences..."
TENANT_AUD_SCRIPT="$SCRIPT_DIR/scripts/policy.audience.patch.sh"
if [[ -f "$TENANT_AUD_SCRIPT" ]]; then
    "$TENANT_AUD_SCRIPT" 2>&1 || echo "   Tenant AuthPolicy audience patch had issues (non-fatal)"
else
    echo "   Tenant AuthPolicy patch script not found: $TENANT_AUD_SCRIPT"
fi

# Wait for Keycloak
echo ""
echo "11. Waiting for Keycloak to be ready..."
wait_for_pods "keycloak-system" "app=keycloak" 300 || \
    echo "   Keycloak not ready yet, check: kubectl -n keycloak-system get pods"

# Wait for Gateways
echo ""
echo "12. Waiting for Gateways to be programmed..."
echo "   Note: This may take a few minutes if Service Mesh is being installed..."
kubectl wait --for=condition=Programmed gateway tenant-a-gateway -n openshift-ingress --timeout=300s 2>/dev/null || \
    echo "   Tenant-A gateway not ready"
kubectl wait --for=condition=Programmed gateway tenant-b-gateway -n openshift-ingress --timeout=60s 2>/dev/null || \
    echo "   Tenant-B gateway not ready"
kubectl wait --for=condition=Programmed gateway keycloak-gateway -n openshift-ingress --timeout=60s 2>/dev/null || \
    echo "   Keycloak gateway not ready"

echo ""
echo "13. Restarting Kuadrant operator to handle OSSM GatewayClass..."
KUADRANT_POD=$(kubectl -n kuadrant-system get pods -l app.kubernetes.io/component=manager,app.kubernetes.io/name=kuadrant-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
               kubectl -n kuadrant-system get pods | grep kuadrant-operator-controller-manager | awk '{print $1}' | head -1)
if [[ -n "$KUADRANT_POD" ]]; then
    kubectl -n kuadrant-system delete pod "$KUADRANT_POD" 2>/dev/null || true
    sleep 10
    # Wait for Kuadrant to be ready
    for i in {1..30}; do
        STATUS=$(kubectl get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$STATUS" == "True" ]]; then
            echo "   Kuadrant is ready"
            break
        fi
        [[ $i -eq 30 ]] && echo "   Kuadrant not ready yet, check: kubectl get kuadrant kuadrant -n kuadrant-system -o yaml"
        sleep 5
    done
else
    echo "   Kuadrant operator pod not found"
fi

echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""
echo "Endpoints:"
echo "   Keycloak:  https://${KEYCLOAK_HOST}"
echo "   Tenant-A:  https://${TENANT_A_HOST}"
echo "   Tenant-B:  https://${TENANT_B_HOST}"
echo ""
echo "Test Users:"
echo "   Tenant-A: alice_lead / letmein (Engineering, Project-Alpha)"
echo "   Tenant-A: bob_sre / letmein (Site-Reliability)"
echo "   Tenant-B: charlie_sec_lead / letmein (Product-Security, Project-Omega)"
echo "   Tenant-B: grace_dev / letmein (Project-Omega)"
echo ""
echo "Get a token:"
echo "   TOKEN=\$(curl -sk -X POST \"https://${KEYCLOAK_HOST}/realms/tenant-a/protocol/openid-connect/token\" \\"
echo "     -d \"client_id=test-client\" -d \"grant_type=password\" \\"
echo "     -d \"username=alice_lead\" -d \"password=letmein\" | jq -r '.access_token')"
echo ""
echo "Test realm:"
echo "   curl -sk https://${KEYCLOAK_HOST}/realms/tenant-a/.well-known/openid-configuration | jq .issuer"
echo ""
echo "Check status:"
echo "   kubectl get modelsasservice"
echo "   kubectl -n keycloak-system get pods"
echo "   kubectl -n tenant-a get pods"
echo "   kubectl -n tenant-b get pods"
echo "   kubectl get gateway -A"
echo ""
echo "Troubleshooting:"
echo "   If gateways are not ready, check Service Mesh:"
echo "   kubectl get pods -n openshift-ingress"
echo "   kubectl describe gateway tenant-a-gateway -n openshift-ingress"
