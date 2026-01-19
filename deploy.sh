#!/bin/bash
# Multi-Tenant MaaS PoC - Quickstart Deployment
# 
# Prerequisites (install with ./scripts/prerequisites.sh):
#   - OpenShift cluster with Gateway API enabled
#   - Kuadrant operators installed
#   - ODH/RHOAI with KServe installed
#   - Keycloak operator installed
#
# Usage: ./deploy.sh [--install-prereqs] [--maas-api-image IMAGE]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source helper functions
source "$SCRIPT_DIR/scripts/deployment-helpers.sh"

# Parse flags
INSTALL_PREREQS=false
MAAS_API_IMAGE=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --install-prereqs) INSTALL_PREREQS=true; shift ;;
    --maas-api-image)
      MAAS_API_IMAGE="$2"
      shift 2
      ;;
    --maas-api-image=*)
      MAAS_API_IMAGE="${1#*=}"
      shift
      ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --install-prereqs        Run prerequisites.sh before deploying"
      echo "  --maas-api-image IMAGE   Override maas-api container image"
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
echo "🚀 Multi-Tenant MaaS PoC Deployment"
echo "========================================="
echo ""

# Check prerequisites
echo "📋 Checking prerequisites..."
command -v kubectl >/dev/null 2>&1 || { echo "❌ kubectl not found"; exit 1; }
command -v kustomize >/dev/null 2>&1 || { echo "❌ kustomize not found"; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "❌ jq not found"; exit 1; }

# Check if running on OpenShift
if ! oc get routes -A &>/dev/null; then
    echo "❌ This script requires an OpenShift cluster"
    echo "   Please ensure you are logged in: oc login"
    exit 1
fi
echo "   ✅ OpenShift cluster detected"

# Run prerequisites if requested
if [[ "$INSTALL_PREREQS" == true ]]; then
    echo ""
    echo "📦 Installing prerequisites..."
    "$SCRIPT_DIR/scripts/prerequisites.sh"
    echo ""
fi

# Check if required CRDs exist
echo ""
echo "📋 Verifying required CRDs..."
require_crd keycloaks.k8s.keycloak.org "Keycloak operator"
require_crd authpolicies.kuadrant.io "Kuadrant operators"
require_crd gateways.gateway.networking.k8s.io "Gateway API"
require_crd llminferenceservices.serving.kserve.io "KServe/ODH (LLMInferenceService)"

# Auto-detect and configure cluster
echo ""
echo "1️⃣  Detecting cluster configuration..."

# Source obtain-cluster-config.sh to get the configure_cluster function
source "$SCRIPT_DIR/scripts/obtain-cluster-config.sh"

# Run configuration (exports CLUSTER_DOMAIN, KEYCLOAK_HOST, etc.)
configure_cluster || exit 1

# Create namespaces
echo ""
echo "2️⃣  Creating namespaces..."
for ns in keycloak-system tenant-a tenant-b shared-models; do
    kubectl create namespace $ns 2>/dev/null && echo "   Created: $ns" || echo "   Exists: $ns"
done

# Override maas-api image if specified
if [[ -n "$MAAS_API_IMAGE" ]]; then
    echo ""
    echo "🐳 Overriding maas-api image: $MAAS_API_IMAGE"
    for tenant in tenant-a tenant-b; do
        PARAMS_FILE="$SCRIPT_DIR/manifests/tenants/$tenant/params.env"
        if [[ -f "$PARAMS_FILE" ]]; then
            sed -i "s|^maas-api-image=.*|maas-api-image=$MAAS_API_IMAGE|" "$PARAMS_FILE"
            echo "   ✅ Updated $tenant/params.env"
        fi
    done
fi

# Deploy Gateways (uses kustomize with params.env)
echo ""
echo "3️⃣  Deploying Gateways..."
kubectl apply -k "$SCRIPT_DIR/manifests/gateways/"
echo "   ✅ GatewayClass + Gateways deployed"

# Deploy Keycloak
echo ""
echo "4️⃣  Deploying Keycloak..."
kubectl apply -k "$SCRIPT_DIR/manifests/keycloak/"
echo "   ✅ Keycloak deployed"

# Deploy Tenant-A (includes gateway policies + RBAC + tier mapping)
echo ""
echo "5️⃣  Deploying Tenant-A..."
kubectl apply -k "$SCRIPT_DIR/manifests/tenants/tenant-a/"
echo "   ✅ Tenant-A deployed (+ gateway policies)"

# Deploy Tenant-B (includes gateway policies + RBAC + tier mapping)
echo ""
echo "6️⃣  Deploying Tenant-B..."
kubectl apply -k "$SCRIPT_DIR/manifests/tenants/tenant-b/"
echo "   ✅ Tenant-B deployed (+ gateway policies)"

# Deploy Shared Models
echo ""
echo "7️⃣  Deploying Shared Models..."
kubectl apply -k "$SCRIPT_DIR/manifests/shared-models/"
echo "   ✅ Shared models deployed"

# Configure Authorino TLS (Kuadrant)
echo ""
echo "8️⃣  Configuring Kuadrant Authorino for TLS..."
AUTHORINO_TLS_SCRIPT="$SCRIPT_DIR/scripts/configure-authorino-tls.sh"
if [[ -f "$AUTHORINO_TLS_SCRIPT" ]]; then
    "$AUTHORINO_TLS_SCRIPT" 2>&1 || echo "   ⚠️  Authorino TLS configuration had issues (non-fatal)"
else
    echo "   ⚠️  Authorino TLS script not found: $AUTHORINO_TLS_SCRIPT"
fi

# Wait for AuthPolicies to exist before patching
echo ""
echo "9️⃣  Waiting for MaaS API AuthPolicies to be created..."
for tenant in tenant-a tenant-b; do
    echo "   Waiting for maas-api-auth-policy in $tenant..."
    for i in {1..30}; do
        if kubectl get authpolicy maas-api-auth-policy -n "$tenant" &>/dev/null; then
            echo "   ✅ AuthPolicy exists in $tenant"
            break
        fi
        if [[ $i -eq 30 ]]; then
            echo "   ⚠️  AuthPolicy not found in $tenant after 30s"
        fi
        sleep 1
    done
done

# Patch tenant MaaS API AuthPolicy audiences
echo ""
echo "🔟  Patching tenant MaaS API AuthPolicy audiences..."
TENANT_AUD_SCRIPT="$SCRIPT_DIR/scripts/policy.audience.patch.sh"
if [[ -f "$TENANT_AUD_SCRIPT" ]]; then
    "$TENANT_AUD_SCRIPT" 2>&1 || echo "   ⚠️  Tenant AuthPolicy audience patch had issues (non-fatal)"
else
    echo "   ⚠️  Tenant AuthPolicy patch script not found: $TENANT_AUD_SCRIPT"
fi

# Wait for Keycloak
echo ""
echo "1️⃣1️⃣ Waiting for Keycloak to be ready..."
wait_for_pods "keycloak-system" "app=keycloak" 300 || \
    echo "   ⚠️  Keycloak not ready yet, check: kubectl -n keycloak-system get pods"

# Wait for Gateways
echo ""
echo "1️⃣2️⃣ Waiting for Gateways to be programmed..."
echo "   Note: This may take a few minutes if Service Mesh is being installed..."
kubectl wait --for=condition=Programmed gateway tenant-a-gateway -n openshift-ingress --timeout=300s 2>/dev/null || \
    echo "   ⚠️  Tenant-A gateway not ready"
kubectl wait --for=condition=Programmed gateway tenant-b-gateway -n openshift-ingress --timeout=60s 2>/dev/null || \
    echo "   ⚠️  Tenant-B gateway not ready"
kubectl wait --for=condition=Programmed gateway keycloak-gateway -n openshift-ingress --timeout=60s 2>/dev/null || \
    echo "   ⚠️  Keycloak gateway not ready"

echo ""
echo "1️⃣3️⃣ Restarting Kuadrant operator to handle OSSM GatewayClass..."
KUADRANT_POD=$(kubectl -n kuadrant-system get pods -l app.kubernetes.io/component=manager,app.kubernetes.io/name=kuadrant-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || \
               kubectl -n kuadrant-system get pods | grep kuadrant-operator-controller-manager | awk '{print $1}' | head -1)
if [[ -n "$KUADRANT_POD" ]]; then
    kubectl -n kuadrant-system delete pod "$KUADRANT_POD" 2>/dev/null || true
    sleep 10
    # Wait for Kuadrant to be ready
    for i in {1..30}; do
        STATUS=$(kubectl get kuadrant kuadrant -n kuadrant-system -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || echo "")
        if [[ "$STATUS" == "True" ]]; then
            echo "   ✅ Kuadrant is ready"
            break
        fi
        [[ $i -eq 30 ]] && echo "   ⚠️  Kuadrant not ready yet, check: kubectl get kuadrant kuadrant -n kuadrant-system -o yaml"
        sleep 5
    done
else
    echo "   ⚠️  Kuadrant operator pod not found"
fi

echo ""
echo "========================================="
echo "✅ Deployment Complete!"
echo "========================================="
echo ""
echo "📊 Endpoints:"
echo "   Keycloak:  https://${KEYCLOAK_HOST}"
echo "   Tenant-A:  https://${TENANT_A_HOST}"
echo "   Tenant-B:  https://${TENANT_B_HOST}"
echo ""
echo "👥 Test Users:"
echo "   Tenant-A: alice_lead / letmein (Engineering, Project-Alpha)"
echo "   Tenant-A: bob_sre / letmein (Site-Reliability)"
echo "   Tenant-B: charlie_sec_lead / letmein (Product-Security, Project-Omega)"
echo "   Tenant-B: grace_dev / letmein (Project-Omega)"
echo ""
echo "🔑 Get a token:"
echo "   TOKEN=\$(curl -sk -X POST \"https://${KEYCLOAK_HOST}/realms/tenant-a/protocol/openid-connect/token\" \\"
echo "     -d \"client_id=test-client\" -d \"grant_type=password\" \\"
echo "     -d \"username=alice_lead\" -d \"password=letmein\" | jq -r '.access_token')"
echo ""
echo "🧪 Test realm:"
echo "   curl -sk https://${KEYCLOAK_HOST}/realms/tenant-a/.well-known/openid-configuration | jq .issuer"
echo ""
echo "📋 Check status:"
echo "   kubectl -n keycloak-system get pods"
echo "   kubectl -n tenant-a get pods"
echo "   kubectl -n tenant-b get pods"
echo "   kubectl get gateway -A"
echo ""
echo "🔧 Troubleshooting:"
echo "   If gateways are not ready, check Service Mesh:"
echo "   kubectl get pods -n openshift-ingress"
echo "   kubectl describe gateway tenant-a-gateway -n openshift-ingress"
