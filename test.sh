#!/bin/bash
# Multi-Tenant MaaS PoC - Test Script
# Usage: ./test.sh [tokens|access|models|all] [--verbose]

set -e

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# Parse args
VERBOSE=false
CMD="all"
for arg in "$@"; do
    case "$arg" in
        --verbose|-v) VERBOSE=true ;;
        tokens|access|models|all) CMD="$arg" ;;
    esac
done

# Detect cluster
CLUSTER_DOMAIN=$(kubectl get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}' 2>/dev/null)
[[ -z "$CLUSTER_DOMAIN" ]] && { echo -e "${RED}❌ Could not detect cluster${NC}"; exit 1; }

KEYCLOAK="https://keycloak.${CLUSTER_DOMAIN}"
TENANT_A="https://tenant-a.${CLUSTER_DOMAIN}"
TENANT_B="https://tenant-b.${CLUSTER_DOMAIN}"

# Helper: get token
get_token() {
    curl -sk -X POST "${KEYCLOAK}/realms/$1/protocol/openid-connect/token" \
        -d "client_id=test-client" -d "grant_type=password" \
        -d "username=$2" -d "password=$3" 2>/dev/null | jq -r '.access_token // empty'
}

# Helper: decode JWT payload
decode_jwt() {
    echo "$1" | cut -d. -f2 | tr '_-' '/+' | base64 -d 2>/dev/null | jq . 2>/dev/null
}

# Helper: HTTP status check
http_status() {
    curl -sk -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $2" "$1"
}

# Helper: get inference token from MaaS API
# Usage: get_inference_token <tenant_url> <auth_token> <model_id>
get_inference_token() {
    local tenant_url="$1" auth_token="$2" model_id="$3"
    curl -sk -X POST -H "Authorization: Bearer $auth_token" -H "Content-Type: application/json" \
        -d "{\"model\":\"$model_id\"}" "${tenant_url}/maas-api/v1/tokens" 2>/dev/null | jq -r '.token // empty'
}

# Helper: get first model ID from tenant
# Usage: get_first_model <tenant_url> <auth_token>
get_first_model() {
    local tenant_url="$1" auth_token="$2"
    curl -sk -H "Authorization: Bearer $auth_token" "${tenant_url}/v1/models" 2>/dev/null | jq -r '.data[0].id // empty'
}

# ============================================
# TEST: Tokens
# ============================================
test_tokens() {
    echo -e "\n${CYAN}═══ TOKEN TESTS ═══${NC}\n"
    
    local users=("tenant-a:alice_lead:letmein" "tenant-a:bob_sre:letmein" 
                 "tenant-b:charlie_sec_lead:letmein" "tenant-b:grace_dev:letmein")
    
    for u in "${users[@]}"; do
        IFS=':' read -r realm user pass <<< "$u"
        token=$(get_token "$realm" "$user" "$pass")
        
        if [[ -n "$token" ]]; then
            claims=$(decode_jwt "$token")
            groups=$(echo "$claims" | jq -r '.groups // [] | join(", ")')
            echo -e "${GREEN}✅ $user@$realm${NC} → groups: ${groups:-none}"
            
            if [[ "$VERBOSE" == true ]]; then
                echo "   Subject:  $(echo "$claims" | jq -r '.sub')"
                echo "   Issuer:   $(echo "$claims" | jq -r '.iss')"
                echo "   Expires:  $(date -d @$(echo "$claims" | jq -r '.exp') 2>/dev/null || echo "$(echo "$claims" | jq -r '.exp')")"
                echo ""
            fi
        else
            echo -e "${RED}❌ $user@$realm${NC} → token failed"
        fi
    done
    
    # User/tier reference table
    echo -e "\n📋 ${BLUE}Test Users:${NC}"
    echo "┌─────────────┬─────────────────────┬────────────────────────────────┬──────────────┐"
    echo "│ Realm       │ Username            │ Groups                         │ Expected Tier│"
    echo "├─────────────┼─────────────────────┼────────────────────────────────┼──────────────┤"
    echo "│ tenant-a    │ alice_lead          │ Engineering, Project-Alpha     │ Premium      │"
    echo "│ tenant-a    │ bob_sre             │ Site-Reliability               │ Enterprise   │"
    echo "│ tenant-b    │ charlie_sec_lead    │ Product-Security, Project-Omega│ Enterprise   │"
    echo "│ tenant-b    │ grace_dev           │ Project-Omega                  │ Premium      │"
    echo "└─────────────┴─────────────────────┴────────────────────────────────┴──────────────┘"
    
    echo -e "\n📋 ${BLUE}Copy-paste commands:${NC}"
    echo "TOKEN_A=\$(curl -sk -X POST \"${KEYCLOAK}/realms/tenant-a/protocol/openid-connect/token\" -d \"client_id=test-client\" -d \"grant_type=password\" -d \"username=alice_lead\" -d \"password=letmein\" | jq -r '.access_token')"
    echo "TOKEN_B=\$(curl -sk -X POST \"${KEYCLOAK}/realms/tenant-b/protocol/openid-connect/token\" -d \"client_id=test-client\" -d \"grant_type=password\" -d \"username=charlie_sec_lead\" -d \"password=letmein\" | jq -r '.access_token')"
}

# ============================================
# TEST: Access Control
# ============================================
test_access() {
    echo -e "\n${CYAN}═══ ACCESS CONTROL TESTS ═══${NC}\n"
    
    # Check Keycloak OIDC endpoints first
    echo -e "${BLUE}Keycloak OIDC Configuration:${NC}"
    OIDC_A=$(curl -sk "${KEYCLOAK}/realms/tenant-a/.well-known/openid-configuration" | jq -r '.issuer // empty')
    OIDC_B=$(curl -sk "${KEYCLOAK}/realms/tenant-b/.well-known/openid-configuration" | jq -r '.issuer // empty')
    
    [[ -n "$OIDC_A" ]] && echo -e "  ${GREEN}✅${NC} tenant-a: $OIDC_A" || echo -e "  ${RED}❌${NC} tenant-a realm not accessible"
    [[ -n "$OIDC_B" ]] && echo -e "  ${GREEN}✅${NC} tenant-b: $OIDC_B" || echo -e "  ${RED}❌${NC} tenant-b realm not accessible"
    echo ""
    
    TOKEN_A=$(get_token "tenant-a" "alice_lead" "letmein")
    TOKEN_B=$(get_token "tenant-b" "charlie_sec_lead" "letmein")
    
    [[ -z "$TOKEN_A" ]] && { echo -e "${RED}❌ Failed to get tenant-a token${NC}"; return 1; }
    [[ -z "$TOKEN_B" ]] && { echo -e "${RED}❌ Failed to get tenant-b token${NC}"; return 1; }
    
    echo -e "${BLUE}JWT token isolation (MaaS API):${NC}"
    
    # tenant-a token → tenant-a (should work)
    code=$(http_status "${TENANT_A}/maas-api/health" "$TOKEN_A")
    [[ "$code" =~ ^(200|201|204)$ ]] && echo -e "  ${GREEN}✅${NC} tenant-a JWT → tenant-a ($code)" || echo -e "  ${RED}❌${NC} tenant-a JWT → tenant-a ($code)"
    
    # tenant-a token → tenant-b (should fail)
    code=$(http_status "${TENANT_B}/maas-api/health" "$TOKEN_A")
    [[ "$code" =~ ^(401|403)$ ]] && echo -e "  ${GREEN}✅${NC} tenant-a JWT → tenant-b DENIED ($code)" || echo -e "  ${YELLOW}⚠️${NC}  tenant-a JWT → tenant-b ($code)"
    
    # tenant-b token → tenant-b (should work)
    code=$(http_status "${TENANT_B}/maas-api/health" "$TOKEN_B")
    [[ "$code" =~ ^(200|201|204)$ ]] && echo -e "  ${GREEN}✅${NC} tenant-b JWT → tenant-b ($code)" || echo -e "  ${RED}❌${NC} tenant-b JWT → tenant-b ($code)"
    
    # tenant-b token → tenant-a (should fail)
    code=$(http_status "${TENANT_A}/maas-api/health" "$TOKEN_B")
    [[ "$code" =~ ^(401|403)$ ]] && echo -e "  ${GREEN}✅${NC} tenant-b JWT → tenant-a DENIED ($code)" || echo -e "  ${YELLOW}⚠️${NC}  tenant-b JWT → tenant-a ($code)"
    
    # no token (should fail)
    code=$(curl -sk -o /dev/null -w "%{http_code}" "${TENANT_A}/maas-api/health")
    [[ "$code" =~ ^(401|403)$ ]] && echo -e "  ${GREEN}✅${NC} no token → DENIED ($code)" || echo -e "  ${YELLOW}⚠️${NC}  no token ($code)"
    
    # Inference token isolation tests
    echo -e "\n${BLUE}Inference token isolation:${NC}"
    
    MODEL_A=$(get_first_model "$TENANT_A" "$TOKEN_A")
    MODEL_B=$(get_first_model "$TENANT_B" "$TOKEN_B")
    
    if [[ -z "$MODEL_A" || -z "$MODEL_B" ]]; then
        echo -e "  ${YELLOW}⚠️${NC}  Skipping inference token tests (models not available)"
        echo "     Tenant-A model: ${MODEL_A:-none}"
        echo "     Tenant-B model: ${MODEL_B:-none}"
    else
        INF_TOKEN_A=$(get_inference_token "$TENANT_A" "$TOKEN_A" "$MODEL_A")
        INF_TOKEN_B=$(get_inference_token "$TENANT_B" "$TOKEN_B" "$MODEL_B")
        
        if [[ -z "$INF_TOKEN_A" ]]; then
            echo -e "  ${YELLOW}⚠️${NC}  Could not get inference token for tenant-a"
        else
            echo -e "  ${GREEN}✅${NC} Got inference token for tenant-a ($MODEL_A)"
        fi
        
        if [[ -z "$INF_TOKEN_B" ]]; then
            echo -e "  ${YELLOW}⚠️${NC}  Could not get inference token for tenant-b"
        else
            echo -e "  ${GREEN}✅${NC} Got inference token for tenant-b ($MODEL_B)"
        fi
        
        if [[ -n "$INF_TOKEN_A" && -n "$INF_TOKEN_B" ]]; then
            # Get model URLs for cross-tenant tests
            model_url_a=$(curl -sk -H "Authorization: Bearer $TOKEN_A" "${TENANT_A}/v1/models" 2>/dev/null | jq -r '.data[0].url // empty')
            model_url_b=$(curl -sk -H "Authorization: Bearer $TOKEN_B" "${TENANT_B}/v1/models" 2>/dev/null | jq -r '.data[0].url // empty')
            
            echo ""
            # tenant-a inference token → tenant-a model (should work)
            if [[ -n "$model_url_a" ]]; then
                code=$(http_status "${model_url_a}/v1/models" "$INF_TOKEN_A")
                [[ "$code" =~ ^(200|201|204)$ ]] && echo -e "  ${GREEN}✅${NC} tenant-a inf token → tenant-a model ($code)" || echo -e "  ${YELLOW}⚠️${NC}  tenant-a inf token → tenant-a model ($code)"
            fi
            
            # tenant-a inference token → tenant-b model (should fail)
            if [[ -n "$model_url_b" ]]; then
                code=$(http_status "${model_url_b}/v1/models" "$INF_TOKEN_A")
                [[ "$code" =~ ^(401|403)$ ]] && echo -e "  ${GREEN}✅${NC} tenant-a inf token → tenant-b model DENIED ($code)" || echo -e "  ${YELLOW}⚠️${NC}  tenant-a inf token → tenant-b model ($code)"
            fi
            
            # tenant-b inference token → tenant-b model (should work)
            if [[ -n "$model_url_b" ]]; then
                code=$(http_status "${model_url_b}/v1/models" "$INF_TOKEN_B")
                [[ "$code" =~ ^(200|201|204)$ ]] && echo -e "  ${GREEN}✅${NC} tenant-b inf token → tenant-b model ($code)" || echo -e "  ${YELLOW}⚠️${NC}  tenant-b inf token → tenant-b model ($code)"
            fi
            
            # tenant-b inference token → tenant-a model (should fail)
            if [[ -n "$model_url_a" ]]; then
                code=$(http_status "${model_url_a}/v1/models" "$INF_TOKEN_B")
                [[ "$code" =~ ^(401|403)$ ]] && echo -e "  ${GREEN}✅${NC} tenant-b inf token → tenant-a model DENIED ($code)" || echo -e "  ${YELLOW}⚠️${NC}  tenant-b inf token → tenant-a model ($code)"
            fi
        fi
    fi
    
    # Summary table
    echo -e "\n${BLUE}Expected Behavior:${NC}"
    echo "┌─────────────────────────┬────────────────────┬────────────────────┐"
    echo "│ Token                   │ Tenant-A Gateway   │ Tenant-B Gateway   │"
    echo "├─────────────────────────┼────────────────────┼────────────────────┤"
    echo "│ tenant-a JWT            │ ✅ Allowed         │ ❌ Denied          │"
    echo "│ tenant-b JWT            │ ❌ Denied          │ ✅ Allowed         │"
    echo "│ tenant-a inference tok  │ ✅ Own models      │ ❌ Denied          │"
    echo "│ tenant-b inference tok  │ ❌ Denied          │ ✅ Own models      │"
    echo "│ no token                │ ❌ Denied          │ ❌ Denied          │"
    echo "└─────────────────────────┴────────────────────┴────────────────────┘"
}

# ============================================
# TEST: Models (including shared)
# ============================================
test_models() {
    echo -e "\n${CYAN}═══ MODEL TESTS ═══${NC}\n"
    
    TOKEN_A=$(get_token "tenant-a" "alice_lead" "letmein")
    TOKEN_B=$(get_token "tenant-b" "charlie_sec_lead" "letmein")
    
    echo -e "${BLUE}Tenant-A models:${NC}"
    
    # List models via MaaS API
    models_a=$(curl -sk -H "Authorization: Bearer $TOKEN_A" "${TENANT_A}/v1/models" 2>/dev/null)
    count_a=$(echo "$models_a" | jq -r '.data | length // 0' 2>/dev/null)
    echo -e "  Found: ${GREEN}$count_a${NC} model(s)"
    echo "$models_a" | jq -r '.data[]? | "    • \(.id)"' 2>/dev/null
    
    echo -e "\n${BLUE}Tenant-B models:${NC}"
    models_b=$(curl -sk -H "Authorization: Bearer $TOKEN_B" "${TENANT_B}/v1/models" 2>/dev/null)
    count_b=$(echo "$models_b" | jq -r '.data | length // 0' 2>/dev/null)
    echo -e "  Found: ${GREEN}$count_b${NC} model(s)"
    echo "$models_b" | jq -r '.data[]? | "    • \(.id)"' 2>/dev/null
    
    # Get inference tokens for each tenant
    echo -e "\n${BLUE}Getting inference tokens:${NC}"
    
    model_id_a=$(echo "$models_a" | jq -r '.data[0].id // empty' 2>/dev/null)
    model_id_b=$(echo "$models_b" | jq -r '.data[0].id // empty' 2>/dev/null)
    model_url_a=$(echo "$models_a" | jq -r '.data[0].url // empty' 2>/dev/null)
    model_url_b=$(echo "$models_b" | jq -r '.data[0].url // empty' 2>/dev/null)
    
    INF_TOKEN_A=""
    INF_TOKEN_B=""
    
    if [[ -n "$model_id_a" ]]; then
        INF_TOKEN_A=$(get_inference_token "$TENANT_A" "$TOKEN_A" "$model_id_a")
        if [[ -n "$INF_TOKEN_A" ]]; then
            echo -e "  ${GREEN}✅${NC} Tenant-A: $model_id_a"
            [[ "$VERBOSE" == true ]] && echo "     Token (truncated): ${INF_TOKEN_A:0:50}..."
        else
            echo -e "  ${YELLOW}⚠️${NC}  Tenant-A: failed to get token for $model_id_a"
        fi
    else
        echo -e "  ${YELLOW}⚠️${NC}  Tenant-A: no models available"
    fi
    
    if [[ -n "$model_id_b" ]]; then
        INF_TOKEN_B=$(get_inference_token "$TENANT_B" "$TOKEN_B" "$model_id_b")
        if [[ -n "$INF_TOKEN_B" ]]; then
            echo -e "  ${GREEN}✅${NC} Tenant-B: $model_id_b"
            [[ "$VERBOSE" == true ]] && echo "     Token (truncated): ${INF_TOKEN_B:0:50}..."
        else
            echo -e "  ${YELLOW}⚠️${NC}  Tenant-B: failed to get token for $model_id_b"
        fi
    else
        echo -e "  ${YELLOW}⚠️${NC}  Tenant-B: no models available"
    fi
    
    # Test inference if models exist
    echo -e "\n${BLUE}Testing inference:${NC}"
    
    if [[ -n "$model_url_a" && -n "$INF_TOKEN_A" ]]; then
        echo -n "  Tenant-A ($model_id_a): "
        resp=$(curl -sk -H "Authorization: Bearer $INF_TOKEN_A" -H "Content-Type: application/json" \
            -d "{\"model\":\"$model_id_a\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":10}" \
            -w "\n%{http_code}" "${model_url_a}/v1/chat/completions" 2>/dev/null)
        code=$(echo "$resp" | tail -1)
        [[ "$code" == "200" ]] && echo -e "${GREEN}✅ OK${NC}" || echo -e "${YELLOW}HTTP $code${NC}"
        [[ "$VERBOSE" == true ]] && echo "$resp" | head -n -1 | jq . 2>/dev/null
    elif [[ -n "$model_url_a" ]]; then
        echo -e "  ${YELLOW}⚠️${NC}  Tenant-A: no inference token"
    else
        echo -e "  ${YELLOW}⚠️${NC}  Tenant-A: no models"
    fi
    
    if [[ -n "$model_url_b" && -n "$INF_TOKEN_B" ]]; then
        echo -n "  Tenant-B ($model_id_b): "
        resp=$(curl -sk -H "Authorization: Bearer $INF_TOKEN_B" -H "Content-Type: application/json" \
            -d "{\"model\":\"$model_id_b\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"max_tokens\":10}" \
            -w "\n%{http_code}" "${model_url_b}/v1/chat/completions" 2>/dev/null)
        code=$(echo "$resp" | tail -1)
        [[ "$code" == "200" ]] && echo -e "${GREEN}✅ OK${NC}" || echo -e "${YELLOW}HTTP $code${NC}"
        [[ "$VERBOSE" == true ]] && echo "$resp" | head -n -1 | jq . 2>/dev/null
    elif [[ -n "$model_url_b" ]]; then
        echo -e "  ${YELLOW}⚠️${NC}  Tenant-B: no inference token"
    else
        echo -e "  ${YELLOW}⚠️${NC}  Tenant-B: no models"
    fi
    
    # Shared model test: both tenants should see llama3 if deployed
    echo -e "\n${BLUE}Shared model access:${NC}"
    llama_a=$(echo "$models_a" | jq -r '.data[] | select(.id | contains("llama")) | .id' 2>/dev/null | head -1)
    llama_b=$(echo "$models_b" | jq -r '.data[] | select(.id | contains("llama")) | .id' 2>/dev/null | head -1)
    
    if [[ -n "$llama_a" && -n "$llama_b" ]]; then
        echo -e "  ${GREEN}✅${NC} Shared model visible to both tenants"
        echo "    Tenant-A sees: $llama_a"
        echo "    Tenant-B sees: $llama_b"
    else
        echo -e "  ${YELLOW}⚠️${NC}  Shared model not found (may not be deployed)"
    fi
}

# ============================================
# Main
# ============================================
echo "========================================="
echo "🧪 Multi-Tenant MaaS PoC Tests"
echo "========================================="
echo "Keycloak: $KEYCLOAK"
echo "Tenant-A: $TENANT_A"
echo "Tenant-B: $TENANT_B"

case "$CMD" in
    tokens)  test_tokens ;;
    access)  test_access ;;
    models)  test_models ;;
    all)     test_tokens; test_access; test_models ;;
    *)       echo "Usage: $0 [tokens|access|models|all] [--verbose]"; exit 1 ;;
esac

echo -e "\n${BLUE}Debug commands:${NC}"
echo "  kubectl get authpolicy -A"
echo "  kubectl describe authpolicy -n tenant-a"
echo "  kubectl -n tenant-a logs -l app.kubernetes.io/name=maas-api"

echo -e "\n${CYAN}═══ DONE ═══${NC}\n"
