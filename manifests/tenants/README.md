# Tenants

Per-tenant configuration using kustomize overlays.

## Structure

```
tenants/
├── base/                    # Shared components
│   ├── maas-api/           # MaaS API deployment base
│   ├── maas-api-replacements/  # Shared kustomize replacements
│   └── policies/           # Auth/rate-limit policies (from upstream)
├── tenant-a/               # Tenant A overlay
└── tenant-b/               # Tenant B overlay
```

## Tenant Overlay Contents

Each tenant directory contains:

- `kustomization.yaml` - Assembles all tenant resources
- `params.env` - Tenant-specific config (static defaults, uses internal service URLs)
- `tier-mapping-configmap.yaml` - User tier definitions for rate limiting
- `maas-api/` - MaaS API deployment overlay
- `models/` - Tenant-specific model definitions
- `policies/` - AuthPolicy, RateLimitPolicy, TokenRateLimitPolicy

## Namespaces

- Tenant resources deploy to `tenant-a` / `tenant-b` namespaces
- Policies deploy to `openshift-ingress` (co-located with gateways)
