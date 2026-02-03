# Tenants

Per-tenant configuration using the ModelsAsService Custom Resource.

## Structure

```
tenants/
├── tenant-a/
│   ├── modelsasservice.yaml        # ModelsAsService CR (triggers operator)
│   ├── tier-mapping-configmap.yaml # User tier definitions
│   ├── token-rate-limits.yaml      # Token rate limiting policy
│   └── models/                     # Tenant-specific model definitions
└── tenant-b/
    ├── modelsasservice.yaml
    ├── tier-mapping-configmap.yaml
    ├── token-rate-limits.yaml
    └── models/
```

## How It Works

The operator-driven approach simplifies tenant deployment:

1. **Apply the ModelsAsService CR** - The operator handles:
   - Creating the tenant namespace
   - Deploying maas-api with tenant-specific configuration
   - Configuring AuthPolicy with OIDC + SA token authentication
   - Setting up gateway integration (DestinationRule, HTTPRoute)

2. **Apply tenant-specific resources** (managed by tenant admin):
   - `tier-mapping-configmap.yaml` - Maps user groups to tiers
   - `token-rate-limits.yaml` - Defines rate limits per tier
   - `models/` - Tenant's model definitions and RBAC

## Rate Limiting: A Business Decision

**Rate limiting is intentionally not managed by the operator.** Each tenant configures their own `TokenRateLimitPolicy` because:

- **Different pricing models** - A startup platform might offer generous free tiers to encourage adoption, while an enterprise platform might have conservative limits with premium SLAs.
- **Different user segments** - Tenant-A might prioritize open-source contributors, while Tenant-B might prioritize paying customers.
- **Different cost structures** - GPU costs vary; tenants need flexibility to balance usage vs. budget.
- **Regulatory requirements** - Some tenants may have compliance requirements affecting rate limits.

### Example: Two Different Approaches

**Tenant-A (Startup Platform)** - Generous limits to drive adoption:
| Tier | Limit | Target Users |
|------|-------|--------------|
| free | 15K tokens/min | All authenticated users |
| premium | 80K tokens/min | Active contributors |
| enterprise | 300K tokens/min | Core team |

**Tenant-B (Enterprise Platform)** - Conservative limits with clear SLAs:
| Tier | Limit | Target Users |
|------|-------|--------------|
| basic | 10K tokens/min | Contractors |
| pro | 60K tokens/min | Employees |
| max | 200K/min + 2M/hour burst | Executives |

> **Sizing guidance**: A typical LLM request uses 2K-8K tokens (prompt + response). 
> 10K tokens/min allows ~3-5 requests/min, while 100K+ enables comfortable interactive use.

## Deploying a Tenant

```bash
# 1. Apply the ModelsAsService CR (operator creates namespace + maas-api)
kubectl apply -f tenant-a/modelsasservice.yaml

# 2. Wait for namespace to be created, then apply tenant config
kubectl apply -f tenant-a/tier-mapping-configmap.yaml
kubectl apply -f tenant-a/token-rate-limits.yaml

# 3. Apply tenant models
kubectl apply -k tenant-a/models/
```

## ModelsAsService CR

The CR specifies:
- **metadata.name** - Tenant identifier (also determines namespace)
- **spec.gatewayRef** - Reference to the tenant's gateway
- **spec.authentication** - OIDC and/or cluster identity auth config

Example:
```yaml
apiVersion: components.platform.opendatahub.io/v1alpha1
kind: ModelsAsService
metadata:
  name: tenant-a
spec:
  gatewayRef:
    namespace: openshift-ingress
    name: tenant-a-gateway
  authentication:
    oidc:
      jwksUrl: http://keycloak.../realms/tenant-a/protocol/openid-connect/certs
    clusterIdentities: {}
```

## Tier Mapping

The `tier-to-group-mapping` ConfigMap maps identity provider groups to rate limit tiers:

```yaml
data:
  tiers: |
    - name: free
      displayName: "Free"
      level: 0
      groups:
        - system:authenticated    # Default for all users

    - name: premium
      displayName: "Premium"
      level: 1
      groups:
        - Engineering            # Keycloak group

    - name: enterprise
      displayName: "Enterprise"
      level: 2
      groups:
        - Site-Reliability       # Highest priority
```

The `level` field determines priority when a user belongs to multiple groups - higher level wins.
