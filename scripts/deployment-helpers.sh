#!/bin/bash

# Deployment helper functions for Multi-Tenant MaaS PoC

# Minimum version requirements
export KUADRANT_MIN_VERSION="1.3.1"
export AUTHORINO_MIN_VERSION="0.22.0"
export LIMITADOR_MIN_VERSION="0.16.0"

# Helper function to extract version from CSV name (e.g., "operator.v1.2.3" -> "1.2.3")
extract_version_from_csv() {
  local csv_name="$1"
  echo "$csv_name" | sed -n 's/.*\.v\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p'
}

# Helper function to compare semantic versions (returns 0 if version1 >= version2)
version_compare() {
  local version1="$1"
  local version2="$2"
  
  local v1=$(echo "$version1" | awk -F. '{printf "%03d%03d%03d", $1, $2, $3}')
  local v2=$(echo "$version2" | awk -F. '{printf "%03d%03d%03d", $1, $2, $3}')
  
  [ "$v1" -ge "$v2" ]
}

# Helper function to find CSV by operator name and check minimum version
find_csv_with_min_version() {
  local operator_prefix="$1"
  local min_version="$2"
  local namespace="${3:-kuadrant-system}"
  
  local csv_name=$(kubectl get csv -n "$namespace" --no-headers 2>/dev/null | grep "^${operator_prefix}" | head -n1 | awk '{print $1}')
  
  if [ -z "$csv_name" ]; then
    return 1
  fi
  
  local installed_version=$(extract_version_from_csv "$csv_name")
  if [ -z "$installed_version" ]; then
    return 1
  fi
  
  if version_compare "$installed_version" "$min_version"; then
    echo "$csv_name"
    return 0
  fi
  
  return 1
}

# Check if a CRD exists, exit if not
require_crd() {
  local crd="$1"
  local friendly_name="${2:-$crd}"
  
  if kubectl get crd "$crd" &>/dev/null; then
    echo "   ✅ ${friendly_name}"
  else
    echo "   ❌ ${friendly_name} CRD not found"
    echo ""
    echo "   For Kuadrant/Keycloak: ./scripts/prerequisites.sh"
    echo "   For KServe/ODH: Install OpenDataHub operator from OperatorHub,"
    echo "   then create a DataScienceCluster with kserve: Managed"
    exit 1
  fi
}

# Helper function to wait for CRD to be established
wait_for_crd() {
  local crd="$1"
  local timeout="${2:-120}"
  local interval=5
  local elapsed=0

  echo "   ⏳ Waiting for CRD ${crd} (timeout: ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    if kubectl get crd "$crd" &>/dev/null; then
      if kubectl wait --for=condition=Established --timeout=30s "crd/$crd" 2>/dev/null; then
        echo "   ✅ CRD ${crd} established"
        return 0
      fi
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "   ❌ Timeout waiting for CRD $crd"
  return 1
}

# Helper function to wait for CSV to reach Succeeded state
wait_for_csv() {
  local csv_name="$1"
  local namespace="${2:-kuadrant-system}"
  local timeout="${3:-300}"
  local interval=10
  local elapsed=0

  echo "   ⏳ Waiting for CSV ${csv_name} (timeout: ${timeout}s)..."
  while [ $elapsed -lt $timeout ]; do
    local phase=$(kubectl get csv -n "$namespace" "$csv_name" -o jsonpath='{.status.phase}' 2>/dev/null || echo "NotFound")

    case "$phase" in
      "Succeeded")
        echo "   ✅ CSV ${csv_name} succeeded"
        return 0
        ;;
      "Failed")
        echo "   ❌ CSV ${csv_name} failed"
        return 1
        ;;
      *)
        if [ $((elapsed % 30)) -eq 0 ]; then
          echo "      Status: ${phase} (${elapsed}s)"
        fi
        ;;
    esac

    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "   ❌ Timeout waiting for CSV ${csv_name}"
  return 1
}

# Wait for deployment to be available
wait_for_deployment() {
  local deployment="$1"
  local namespace="$2"
  local timeout="${3:-300}"
  
  echo "   ⏳ Waiting for deployment ${deployment} in ${namespace}..."
  kubectl wait deployment/"$deployment" -n "$namespace" --for=condition=Available --timeout="${timeout}s" 2>/dev/null || {
    echo "   ⚠️  Deployment ${deployment} not ready within timeout"
    return 1
  }
  echo "   ✅ Deployment ${deployment} ready"
  return 0
}

# Wait for pods with label to be ready
wait_for_pods() {
  local namespace="$1"
  local label="$2"
  local timeout="${3:-300}"
  
  echo "   ⏳ Waiting for pods with label ${label} in ${namespace}..."
  kubectl -n "$namespace" wait --for=condition=ready pod -l "$label" --timeout="${timeout}s" 2>/dev/null || {
    echo "   ⚠️  Pods not ready within timeout"
    return 1
  }
  echo "   ✅ Pods ready"
  return 0
}
