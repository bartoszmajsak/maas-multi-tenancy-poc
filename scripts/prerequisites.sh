#!/bin/bash
# Multi-Tenant MaaS PoC - Prerequisites Installation
#
# Installs required platform components:
#   - Kuadrant operators (via OLM)
#   - ODH/KServe (if not already present)
#   - Keycloak operator
#
# Requires: OpenShift 4.19.9+ (for native Gateway API support)
#
# Usage: ./scripts/prerequisites.sh [--skip-odh] [--skip-kuadrant] [--skip-keycloak]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/deployment-helpers.sh"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# Parse flags
SKIP_ODH=false
SKIP_KUADRANT=false
SKIP_KEYCLOAK=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --skip-odh) SKIP_ODH=true; shift ;;
    --skip-kuadrant) SKIP_KUADRANT=true; shift ;;
    --skip-keycloak) SKIP_KEYCLOAK=true; shift ;;
    -h|--help)
      echo "Usage: $0 [OPTIONS]"
      echo ""
      echo "Options:"
      echo "  --skip-odh        Skip ODH/KServe installation"
      echo "  --skip-kuadrant   Skip Kuadrant installation"
      echo "  --skip-keycloak   Skip Keycloak operator installation"
      echo "  -h, --help        Show this help"
      exit 0
      ;;
    *)
      echo "Unknown option: $1"
      exit 1
      ;;
  esac
done

echo "========================================="
echo "🔧 Multi-Tenant MaaS PoC Prerequisites"
echo "========================================="
echo ""

# Check if running on OpenShift
if ! oc get routes -A &>/dev/null; then
    echo "❌ This script requires an OpenShift cluster"
    echo "   Please ensure you are logged in: oc login"
    exit 1
fi
echo "✅ OpenShift cluster detected"

# Check prerequisites
echo "📋 Checking tools..."
echo "   oc: $(oc version --client 2>/dev/null | head -n1 || echo 'not found')"
echo "   kubectl: $(kubectl version --client 2>/dev/null | head -n1 || echo 'not found')"
echo "   kustomize: $(kustomize version --short 2>/dev/null || echo 'not found')"
echo ""

# ============================================
# Step 1: Gateway API (requires OCP 4.19.9+)
# ============================================
echo "1️⃣  Checking OpenShift version..."

OCP_VERSION=$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo "unknown")
echo "   OpenShift version: $OCP_VERSION"

if [[ "$OCP_VERSION" == "unknown" ]]; then
    echo -e "   ${RED}❌ Could not determine OpenShift version${NC}"
    echo "   Please ensure you are logged in: oc login"
    exit 1
fi

if version_compare "$OCP_VERSION" "4.19.9"; then
    echo "   ✅ Gateway API supported natively (OCP >= 4.19.9)"
else
    echo -e "   ${RED}❌ OpenShift $OCP_VERSION is not supported${NC}"
    echo "   This PoC requires OpenShift 4.19.9 or higher for Gateway API support."
    exit 1
fi

# ============================================
# Step 2: Kuadrant Operators
# ============================================
if [[ "$SKIP_KUADRANT" == false ]]; then
  echo ""
  echo "2️⃣  Installing Kuadrant operators..."

  # Create namespace
  kubectl create namespace kuadrant-system 2>/dev/null || echo "   Namespace kuadrant-system exists"

  # Check if already installed
  EXISTING_CSV=$(find_csv_with_min_version "kuadrant-operator" "$KUADRANT_MIN_VERSION" "kuadrant-system" || echo "")
  if [ -n "$EXISTING_CSV" ]; then
      echo "   ✅ Kuadrant already installed: $EXISTING_CSV"
      
      # Always check/patch for OpenShift Gateway Controller support
      if ! kubectl -n kuadrant-system get deployment kuadrant-operator-controller-manager \
          -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="ISTIO_GATEWAY_CONTROLLER_NAMES")]}' 2>/dev/null | grep -q "ISTIO_GATEWAY_CONTROLLER_NAMES"; then
          echo "   Patching Kuadrant for OpenShift Gateway Controller..."
          kubectl patch csv "$EXISTING_CSV" -n kuadrant-system --type='json' -p='[
            {
              "op": "add",
              "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-",
              "value": {
                "name": "ISTIO_GATEWAY_CONTROLLER_NAMES",
                "value": "istio.io/gateway-controller,openshift.io/gateway-controller/v1"
              }
            }
          ]' 2>/dev/null && echo "   ✅ Kuadrant operator patched" || echo "   ⚠️  Patch may already exist"
          
          # Wait for operator to restart
          sleep 5
          kubectl rollout status deployment/kuadrant-operator-controller-manager -n kuadrant-system --timeout=60s 2>/dev/null || true
      else
          echo "   ✅ Kuadrant already configured for OpenShift Gateway Controller"
      fi
  else
      echo "   Creating Kuadrant OperatorGroup..."
      kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: kuadrant-operator-group
  namespace: kuadrant-system
spec: {}
EOF

      echo "   Creating Kuadrant CatalogSource..."
      kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: CatalogSource
metadata:
  name: kuadrant-operator-catalog
  namespace: kuadrant-system
spec:
  displayName: Kuadrant Operators
  grpcPodConfig:
    securityContextConfig: restricted
  image: 'quay.io/kuadrant/kuadrant-operator-catalog:v1.3.1'
  publisher: grpc
  sourceType: grpc
EOF

      echo "   Creating Kuadrant Subscription..."
      kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: kuadrant-operator
  namespace: kuadrant-system
spec:
  channel: stable
  installPlanApproval: Automatic
  name: kuadrant-operator
  source: kuadrant-operator-catalog
  sourceNamespace: kuadrant-system
EOF

      # Wait for operators
      echo "   Waiting for Kuadrant operators..."
      ATTEMPTS=0
      MAX_ATTEMPTS=12
      while true; do
          if kubectl get deployment/kuadrant-operator-controller-manager -n kuadrant-system &>/dev/null; then
              break
          fi
          ATTEMPTS=$((ATTEMPTS+1))
          if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
              echo "   ❌ Kuadrant deployment not found after $MAX_ATTEMPTS attempts"
              exit 1
          fi
          echo "   Waiting for Kuadrant deployment... ($ATTEMPTS/$MAX_ATTEMPTS)"
          sleep 15
      done

      wait_for_deployment "kuadrant-operator-controller-manager" "kuadrant-system" 300
      wait_for_deployment "limitador-operator-controller-manager" "kuadrant-system" 120
      wait_for_deployment "authorino-operator" "kuadrant-system" 120

      # Patch for OpenShift Gateway Controller
      echo "   Patching Kuadrant for OpenShift Gateway Controller..."
      KUADRANT_CSV=$(find_csv_with_min_version "kuadrant-operator" "$KUADRANT_MIN_VERSION" "kuadrant-system" || echo "")
      if [ -n "$KUADRANT_CSV" ]; then
        kubectl patch csv "$KUADRANT_CSV" -n kuadrant-system --type='json' -p='[
          {
            "op": "add",
            "path": "/spec/install/spec/deployments/0/spec/template/spec/containers/0/env/-",
            "value": {
              "name": "ISTIO_GATEWAY_CONTROLLER_NAMES",
              "value": "istio.io/gateway-controller,openshift.io/gateway-controller/v1"
            }
          }
        ]' 2>/dev/null || echo "   (patch may already exist)"
      fi

      # Verify CRDs
      echo "   Verifying Kuadrant CRDs..."
      wait_for_crd "kuadrants.kuadrant.io" 60
      wait_for_crd "authpolicies.kuadrant.io" 30
      wait_for_crd "ratelimitpolicies.kuadrant.io" 30
  fi
else
  echo ""
  echo "2️⃣  Skipping Kuadrant installation (--skip-kuadrant)"
fi

# ============================================
# Step 3: ODH / KServe
# ============================================
if [[ "$SKIP_ODH" == false ]]; then
  echo ""
  echo "3️⃣  Installing ODH/KServe..."

  if kubectl get crd llminferenceservices.serving.kserve.io &>/dev/null 2>&1; then
      echo "   ✅ KServe CRDs already present (ODH/RHOAI detected)"
  else
      echo "   Installing OpenDataHub operator from source..."
      
      # Check for required tools
      if ! command -v make &>/dev/null; then
          echo -e "   ${RED}❌ 'make' not found - required for ODH installation${NC}"
          exit 1
      fi
      
      ODH_OPERATOR_NS="opendatahub-operator-system"
      ODH_OPERATOR_IMAGE="${ODH_OPERATOR_IMAGE:-quay.io/opendatahub/opendatahub-operator:latest}"
      
      echo "   Using operator image: $ODH_OPERATOR_IMAGE"
      
      # Create namespace
      kubectl create namespace "$ODH_OPERATOR_NS" 2>/dev/null || true
      
      # Clone and build ODH operator
      TMP_DIR=$(mktemp -d)
      echo "   Cloning opendatahub-operator..."
      
      if ! git clone -q --depth 1 "https://github.com/opendatahub-io/opendatahub-operator.git" "$TMP_DIR/opendatahub-operator"; then
          echo -e "   ${RED}❌ Failed to clone ODH operator repository${NC}"
          rm -rf "$TMP_DIR"
          exit 1
      fi
      
      pushd "$TMP_DIR/opendatahub-operator" > /dev/null
      
      echo "   Building manifests..."
      cp config/manager/kustomization.yaml.in config/manager/kustomization.yaml
      make manifests 2>/dev/null
      
      # Replace image placeholder
      sed -i "s#REPLACE_IMAGE:latest#${ODH_OPERATOR_IMAGE}#g" config/manager/manager.yaml
      
      echo "   Deploying ODH operator..."
      kustomize build config/default | kubectl apply --namespace "$ODH_OPERATOR_NS" -f -
      
      popd > /dev/null
      rm -rf "$TMP_DIR"
      
      echo "   Waiting for ODH operator..."
      kubectl wait deployment/opendatahub-operator-controller-manager -n "$ODH_OPERATOR_NS" \
          --for=condition=Available --timeout=300s 2>/dev/null || \
          echo "   ⚠️  ODH operator not ready yet, continuing..."
      
      # Create DSCInitialization
      echo "   Creating DSCInitialization..."
      kubectl apply -f - <<EOF
apiVersion: dscinitialization.opendatahub.io/v2
kind: DSCInitialization
metadata:
  name: default-dsci
spec:
  applicationsNamespace: opendatahub
  monitoring:
    managementState: Managed
    namespace: opendatahub
    metrics: {}
  trustedCABundle:
    managementState: Managed
EOF

      echo "   Waiting for DSCInitialization..."
      for i in {1..30}; do
          if kubectl get dscinitializations default-dsci -o jsonpath='{.status.phase}' 2>/dev/null | grep -q "Ready"; then
              echo "   ✅ DSCInitialization ready"
              break
          fi
          [[ $i -eq 30 ]] && echo "   ⚠️  DSCInitialization not ready yet"
          sleep 10
      done

      # Create DataScienceCluster with KServe only
      echo "   Creating DataScienceCluster (KServe only)..."
      kubectl apply -f - <<EOF
apiVersion: datasciencecluster.opendatahub.io/v2
kind: DataScienceCluster
metadata:
  name: default-dsc
spec:
  components:
    kserve:
      managementState: Managed
      nim:
        managementState: Managed
      rawDeploymentServiceConfig: Headed
    dashboard:
      managementState: Removed
    workbenches:
      managementState: Removed
    aipipelines:
      managementState: Removed
    ray:
      managementState: Removed
    kueue:
      managementState: Removed
    modelregistry:
      managementState: Removed
    trustyai:
      managementState: Removed
    trainingoperator:
      managementState: Removed
    feastoperator:
      managementState: Removed
    llamastackoperator:
      managementState: Removed
EOF

      echo "   Waiting for DataScienceCluster (this may take several minutes)..."
      for i in {1..60}; do
          PHASE=$(kubectl get datasciencecluster default-dsc -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
          if [[ "$PHASE" == "Ready" ]]; then
              echo "   ✅ DataScienceCluster ready"
              break
          fi
          [[ $((i % 6)) -eq 0 ]] && echo "      Status: $PHASE ($i/60)"
          [[ $i -eq 60 ]] && echo "   ⚠️  DataScienceCluster not fully ready, continuing..."
          sleep 10
      done
      
      # Wait for LLMInferenceService CRD
      echo "   Waiting for LLMInferenceService CRD..."
      wait_for_crd "llminferenceservices.serving.kserve.io" 120 || \
          echo "   ⚠️  LLMInferenceService CRD not ready"
  fi
else
  echo ""
  echo "3️⃣  Skipping ODH installation (--skip-odh)"
fi

# ============================================
# Step 4: Keycloak Operator
# ============================================
if [[ "$SKIP_KEYCLOAK" == false ]]; then
  echo ""
  echo "4️⃣  Installing Keycloak operator..."

  # Create namespace
  kubectl create namespace keycloak-system 2>/dev/null || echo "   Namespace keycloak-system exists"

  # Check if already installed
  if kubectl get crd keycloaks.k8s.keycloak.org &>/dev/null 2>&1; then
      echo "   ✅ Keycloak operator already installed"
  else
      echo "   Creating Keycloak OperatorGroup..."
      kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1
kind: OperatorGroup
metadata:
  name: keycloak-operator-group
  namespace: keycloak-system
spec:
  targetNamespaces:
  - keycloak-system
EOF

      echo "   Creating Keycloak Subscription..."
      kubectl apply -f - <<EOF
apiVersion: operators.coreos.com/v1alpha1
kind: Subscription
metadata:
  name: keycloak-operator
  namespace: keycloak-system
spec:
  channel: fast
  name: keycloak-operator
  source: community-operators
  sourceNamespace: openshift-marketplace
EOF

      echo "   Waiting for Keycloak operator..."
      ATTEMPTS=0
      MAX_ATTEMPTS=12
      while true; do
          if kubectl get deployment -n keycloak-system -l app.kubernetes.io/name=keycloak-operator &>/dev/null; then
              break
          fi
          ATTEMPTS=$((ATTEMPTS+1))
          if [[ $ATTEMPTS -ge $MAX_ATTEMPTS ]]; then
              echo "   ⚠️  Keycloak operator deployment not found, continuing..."
              break
          fi
          echo "   Waiting for Keycloak operator deployment... ($ATTEMPTS/$MAX_ATTEMPTS)"
          sleep 15
      done

      # Wait for CRD
      wait_for_crd "keycloaks.k8s.keycloak.org" 120 || echo "   ⚠️  Keycloak CRD not ready"
  fi
else
  echo ""
  echo "4️⃣  Skipping Keycloak installation (--skip-keycloak)"
fi

# ============================================
# Step 5: Create Kuadrant Instance
# ============================================
echo ""
echo "5️⃣  Creating Kuadrant instance..."

if kubectl get kuadrant kuadrant -n kuadrant-system &>/dev/null 2>&1; then
    echo "   ✅ Kuadrant instance already exists"
else
    kubectl apply -f - <<EOF
apiVersion: kuadrant.io/v1beta1
kind: Kuadrant
metadata:
  name: kuadrant
  namespace: kuadrant-system
spec: {}
EOF
    echo "   ✅ Kuadrant instance created"
fi

# ============================================
# Summary
# ============================================
echo ""
echo "========================================="
echo "✅ Prerequisites Installation Complete!"
echo "========================================="
echo ""
echo "Installed components:"
echo "   - Gateway API (feature gates if needed)"
[[ "$SKIP_KUADRANT" == false ]] && echo "   - Kuadrant operators"
[[ "$SKIP_KEYCLOAK" == false ]] && echo "   - Keycloak operator"
[[ "$SKIP_ODH" == false ]] && echo "   - ODH/KServe (check status)"
echo ""
echo "📋 Verify installation:"
echo "   kubectl get pods -n kuadrant-system"
echo "   kubectl get pods -n keycloak-system"
echo "   kubectl get crd | grep -E 'kuadrant|keycloak|kserve'"
echo ""
echo "🚀 Next step: Run ./deploy.sh to deploy the PoC"
