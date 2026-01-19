# Multi-Tenant MaaS PoC

A proof-of-concept demonstrating multi-tenant Model-as-a-Service on OpenShift with:
- **Tenant isolation** via separate Gateways and Keycloak realms
- **Per-tenant models** with separate tiers, and rate limiting policies
- **Tier-based access control** (free/premium/enterprise) with fine-grained permissions via Kubernetes RBAC
- **Shared models** accessible by multiple tenants

> [!IMPORTANT]
> **Requires changes in maas-api for shared models.** Install with:
> ```bash
> ./deploy.sh --install-prereqs --maas-api-image quay.io/bmajsak/maas-api:gw
> ```
> Depends on https://github.com/opendatahub-io/models-as-a-service/pull/360

## Notes

- MaaS API AuthPolicy now normalizes identity fields for both Keycloak JWT and service-account tokens (see `manifests/tenants/*/maas-api/kustomization.yaml`). This differs from the original setup at the moment.
- This setup allows users without cluster identities to log in and use inference tokens.

## Requirements

- OpenShift 4.19.9+
- `oc`, `kubectl`, `kustomize`, `jq`, `make`, `git`

> [!NOTE]
> ODH/KServe is installed automatically by `./scripts/prerequisites.sh`

> [!IMPORTANT]
> **RBAC for models is explicitly defined**
> 
> This PoC does **not** use the `alpha.maas.opendatahub.io/tiers: '[]'` alpha annotation for automatic RBAC generation. That annotation-based approach is not supported in multi-tenant scenarios.
> 
> Instead, RBAC (Role + RoleBinding) must be explicitly defined in the manifests for each model namespace. See `manifests/tenants/tenant-a/models/rbac.yaml` and `manifests/shared-models/rbac.yaml` for examples.
> 
> Each tier requires a RoleBinding that grants access to the tier-specific service account group:
> ```yaml
> subjects:
>   - kind: Group
>     name: system:serviceaccounts:<maas-instance-name>-tier-<tier>
> ```

## Quick Start

```bash
# Install prerequisites + deploy
./deploy.sh --install-prereqs

# Or if prerequisites already installed
./deploy.sh

# Run tests
./test.sh
```

## Architecture

See [TENANCY_MODEL.md](TENANCY_MODEL.md) for detailed diagrams.

| Component | Tenant-A | Tenant-B | Shared |
|-----------|----------|----------|--------|
| Keycloak Realm | `tenant-a` | `tenant-b` | - |
| Gateway | `tenant-a-gateway` | `tenant-b-gateway` | - |
| Namespace | `tenant-a` | `tenant-b` | `shared-models` |
| MaaS API | ✅ | ✅ | - |
| Models | CodeLlama-7b | Mistral-Security | Llama3-8B |

## Testing

### Users

| Realm | Username | Password | Groups | Tier |
|-------|----------|----------|--------|------|
| tenant-a | alice_lead | letmein | Engineering, Project-Alpha | Premium |
| tenant-a | bob_sre | letmein | Site-Reliability | Enterprise |
| tenant-b | charlie_sec_lead | letmein | Product-Security, Project-Omega | Enterprise |
| tenant-b | grace_dev | letmein | Project-Omega | Premium |

###  Scripts

| Script | Purpose |
|--------|---------|
| `deploy.sh [flags]` | Automate deployment (flags: `--install-prereqs`, `--maas-api-image IMAGE`) |
| `test.sh [mode]` | Run tests (modes: `tokens`, `access`, `models`, or all if omitted) |

### Manual Testing

```bash
# Get token for tenant-a user
TOKEN=$(curl -sk -X POST "https://keycloak.$DOMAIN/realms/tenant-a/protocol/openid-connect/token" \
  -d "client_id=test-client" -d "grant_type=password" \
  -d "username=alice_lead" -d "password=letmein" | jq -r '.access_token')

# List models
curl -sk -H "Authorization: Bearer $TOKEN" "https://tenant-a.$DOMAIN/maas-api/v1/models"

# Cross-tenant test (should fail with 401)
curl -sk -H "Authorization: Bearer $TOKEN" "https://tenant-b.$DOMAIN/maas-api/v1/models"
```

## Directory Structure

```
tenant-poc/
├── deploy.sh                     # Main deployment script
├── test.sh                       # Combined test script
├── params.env                    # Cluster configuration (generated)
├── params.env.example            # Configuration template
└── manifests/
    ├── gateways/                 # All gateways (openshift-ingress ns)
    │   ├── gateway-class.yaml
    │   ├── keycloak-gateway.yaml
    │   ├── tenant-a-gateway.yaml
    │   ├── tenant-b-gateway.yaml
    │   └── kustomization.yaml
    ├── keycloak/                 # Keycloak instance + realms
    │   ├── keycloak-instance.yaml
    │   ├── realms-configmap.yaml
    │   ├── http-route.yaml
    │   └── kustomization.yaml
    ├── shared-models/            # Models accessible by multiple tenants
    │   ├── model.yaml
    │   ├── rbac.yaml
    │   └── kustomization.yaml
    └── tenants/
        ├── base/                 # Shared base resources
        │   ├── maas-api/
        │   ├── maas-api-replacements/ # Kustomize Component for tenant value injection
        │   └── policies/
        ├── tenant-a/
        │   ├── kustomization.yaml
        │   ├── params.env
        │   ├── tier-mapping-configmap.yaml
        │   ├── maas-api/
        │   ├── models/
        │   │   ├── model.yaml
        │   │   └── rbac.yaml
        │   └── policies/
        └── tenant-b/
            ├── kustomization.yaml
            ├── params.env
            ├── tier-mapping-configmap.yaml
            ├── maas-api/
            ├── models/
            │   ├── model.yaml
            │   └── rbac.yaml
            └── policies/
```
