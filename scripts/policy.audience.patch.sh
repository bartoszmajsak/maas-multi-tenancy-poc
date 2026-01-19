#!/bin/bash
#
# Patch AuthPolicy audiences for tenant-specific maas-api policies.
# Detects Kubernetes audience and applies it to maas-api-auth-policy in each tenant namespace.

set -euo pipefail

TENANTS=${TENANTS:-"tenant-a tenant-b"}
POLICY_NAME="maas-api-auth-policy"

echo "========================================="
echo "🔧 Tenant MaaS API AuthPolicy Audience Patching"
echo "========================================="
echo ""
echo "   Policy:  $POLICY_NAME"
echo "   Tenants: $TENANTS"
echo ""

echo "Attempting to detect audience..."
TOKEN=$(kubectl create token default --duration=10m 2>/dev/null || echo "")
if [ -z "$TOKEN" ]; then
    echo "   ❌ Could not create token, cannot detect audience"
    exit 1
fi

echo "   Token created successfully"
JWT_PAYLOAD=$(echo "$TOKEN" | cut -d. -f2 2>/dev/null || echo "")
if [ -z "$JWT_PAYLOAD" ]; then
    echo "   ❌ Could not extract JWT payload"
    exit 1
fi

echo "   JWT payload extracted"
DECODED_PAYLOAD=$(echo "$JWT_PAYLOAD" | jq -Rr '@base64d | fromjson' 2>/dev/null || echo "")
if [ -z "$DECODED_PAYLOAD" ]; then
    echo "   ❌ Could not decode base64 payload"
    exit 1
fi

echo "   Payload decoded successfully"
AUD=$(echo "$DECODED_PAYLOAD" | jq -r '.aud[0]' 2>/dev/null || echo "")
if [ -z "$AUD" ] || [ "$AUD" == "null" ]; then
    echo "   ❌ Could not extract audience from token"
    exit 1
fi

echo "   Detected audience: $AUD"
echo ""

for tenant in $TENANTS; do
    echo "🔎 Patching AuthPolicy ${POLICY_NAME} in ${tenant}..."

    if kubectl patch authpolicy "$POLICY_NAME" -n "$tenant" \
        --type='json' \
        -p "[{\"op\":\"replace\",\"path\":\"/spec/rules/authentication/openshift-identities/kubernetesTokenReview/audiences/0\",\"value\":\"$AUD\"}]"; then
        echo "   ✅ Audience replaced"
        continue
    fi

    if kubectl patch authpolicy "$POLICY_NAME" -n "$tenant" \
        --type='json' \
        -p "[{\"op\":\"add\",\"path\":\"/spec/rules/authentication/openshift-identities/kubernetesTokenReview/audiences\",\"value\":[\"$AUD\"]}]"; then
        echo "   ✅ Audience list added"
    else
        echo "   ⚠️  Failed to patch ${POLICY_NAME} in ${tenant}"
    fi
done

echo ""
echo "========================================="
echo "✅ Tenant MaaS API AuthPolicy Audience Patching Complete!"
echo "========================================="
