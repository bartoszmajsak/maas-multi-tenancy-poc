# ODH Operator Enhancements for Multi-Tenancy

This document describes changes made to the `opendatahub-operator` to support multi-tenant Models-as-a-Service (MaaS).

## Overview

The standard ODH operator treats MaaS as a singleton component - one instance per cluster, deployed to a fixed namespace. For multi-tenancy, we need:

1. **Multiple MaaS instances** - one per tenant, each in its own namespace
2. **Per-tenant configuration** - different gateways, authentication providers, rate limits
3. **Tenant isolation** - resources scoped to prevent cross-tenant interference

## Key Changes

### 1. Tenant-as-Name Pattern

**What:** The `ModelsAsService` CR `metadata.name` serves as the tenant identifier and determines the target namespace.

**Why:** This removes the singleton constraint and enables multiple tenants. The name-as-namespace pattern is simple, intuitive, and ensures uniqueness.

```yaml
apiVersion: components.platform.opendatahub.io/v1alpha1
kind: ModelsAsService
metadata:
  name: tenant-a  # → deploys to namespace "tenant-a"
```

### 2. Gateway Reference (GatewayRef)

**What:** Each tenant references an existing Gateway instead of using a shared cluster gateway.

**Why:** Per-tenant gateways enable:
- Tenant-specific DNS/hostnames (`tenant-a.example.com`)
- Isolated TLS certificates
- Independent rate limiting and auth policies
- No cross-tenant traffic mixing

```yaml
spec:
  gatewayRef:
    namespace: openshift-ingress
    name: tenant-a-gateway  # must exist before ModelsAsService
```

The controller validates the gateway exists during reconciliation.

### 3. Flexible Authentication

**What:** Authentication is configured per-tenant with support for OIDC and/or Kubernetes cluster identities.

**Why:** Different tenants have different identity requirements:
- External users → OIDC (Keycloak, Okta, Dex)
- Internal services → Kubernetes TokenReview (pods, operators, CI)
- Hybrid → Both simultaneously

```yaml
# External users via Keycloak
spec:
  authentication:
    oidc:
      jwksUrl: http://keycloak.../certs
      issuer: http://keycloak.../realms/tenant-a

# Internal services via TokenReview
spec:
  authentication:
    clusterIdentities: {}

# Both (common production setup)
spec:
  authentication:
    oidc:
      jwksUrl: http://keycloak.../certs
    clusterIdentities: {}
```

> [!TIP]
> Hybrid authentication (OIDC + cluster identities) is fully supported. This enables external users to authenticate via OIDC while internal services use Kubernetes TokenReview simultaneously.

### 4. Tenant Namespace Management

**What:** The controller creates and manages the tenant namespace with proper labels.

**Why:** Automated namespace provisioning with:
- ODH management labels for tracking
- Pod security baseline enforcement
- Network policies for isolation

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: tenant-a
  labels:
    opendatahub.io/managed: "true"
    opendatahub.io/maas-tenant: tenant-a
    pod-security.kubernetes.io/audit: baseline
```

> [!NOTE]
> Pod Security uses `audit` mode for PoC flexibility (logs violations without blocking). For production, consider `enforce: baseline` or `enforce: restricted` for stronger isolation.

The controller also creates a **NetworkPolicy** in each tenant namespace that allows ingress traffic from:
- ODH-managed namespaces (`opendatahub.io/generated-namespace`)
- Application namespaces (`opendatahub.io/application-namespace`)
- Ingress controllers (`network.openshift.io/policy-group: ingress`) - required for Gateway traffic
- Host network namespace (kubelet probes)
- Monitoring namespace (`openshift-monitoring`)
- Observability operator namespace

This provides default-deny for unlisted sources while allowing legitimate traffic (gateway routing, health probes, monitoring).

### 5. Multi-Namespace Resource Deployment

**What:** Resources are deployed to multiple namespaces based on their function.

**Why:** Gateway-level resources (AuthPolicy, DestinationRule) must be in the gateway namespace to target the Gateway, while tenant resources (maas-api, HTTPRoute policies) belong in the tenant namespace.

| Resource | Namespace | Purpose |
|----------|-----------|---------|
| maas-api Deployment | tenant | Core API service |
| Gateway AuthPolicy | gateway | Authentication at gateway level |
| HTTPRoute AuthPolicy | tenant | Route-specific auth |
| DestinationRule | gateway | mTLS configuration |
| NetworkPolicy | tenant | Pod network isolation |

### 6. Tenant-Scoped Garbage Collection

**What:** Resource cleanup is scoped by tenant label to prevent cross-tenant deletion.

**Why:** In multi-tenant deployments, deleting `tenant-a` must not affect `tenant-b` resources. The `opendatahub.io/maas-tenant` label enables GC filtering.

### 7. Custom Client with Label-Filtered Cache

**What:** MaaS uses a dedicated client with a cluster-wide, label-filtered cache instead of the manager's default namespace-scoped cache.

**Why:** The standard controller-runtime cache is namespace-scoped. This creates a problem for multi-tenant MaaS:

- **The default cache limitation**: ODH operator's cache watches specific namespaces (operator namespace, DSC namespace). When MaaS dynamically creates tenant namespaces (`tenant-a`, `tenant-b`, etc.), the default cache doesn't see resources in those namespaces.

- **Cluster-wide cache problem**: A naive "watch everything" approach causes reconciliation storms - any ConfigMap or Deployment change anywhere in the cluster would trigger MaaS reconciliation.

**Solution:** A custom client with label filtering:

```go
// Filter: only watch resources with app.opendatahub.io/modelsasservice=true
maasCache, _ := cache.New(cfg, cache.Options{
    ByObject: map[client.Object]cache.ByObject{
        &corev1.ConfigMap{}:           {Label: maasLabelSelector},
        &corev1.Service{}:             {Label: maasLabelSelector},
        &appsv1.Deployment{}:          {Label: maasLabelSelector},
        &networkingv1.NetworkPolicy{}: {Label: maasLabelSelector},
    },
})
```

This gives us:
- Cluster-wide visibility (sees all tenant namespaces)
- Filtered watches (only MaaS-labeled resources trigger reconciliation)
- Proper cache coherence (reads return consistent state)

## Controller Behavior

### Reconciliation Flow

1. **Validate Gateway** - Ensure referenced gateway exists
2. **Ensure Namespace** - Create tenant namespace with labels
3. **Select Overlay** - Choose manifest overlay based on auth config:
   - OIDC configured → `overlays/odh-oidc`
   - SA-only → `overlays/odh`
4. **Deploy Resources** - Apply manifests with tenant-specific parameters
5. **Update Status** - Report resolved configuration

### Status Reporting

```yaml
status:
  tenantNamespace: tenant-a
  gatewayRef:
    namespace: openshift-ingress
    name: tenant-a-gateway
  conditions:
    - type: Ready
      status: "True"
      reason: ReconcileComplete
```

## Limitations & Future Work

1. **Gateway must pre-exist** - Controller validates gateway exists but doesn't create it. Deployment sequence: Gateway → ModelsAsService CR. The controller will retry reconciliation until the gateway is available.
2. **No automatic RBAC for models** - Tier-based RBAC must be explicitly defined (see [TENANCY_MODEL.md](./TENANCY_MODEL.md))
3. **Pod Security audit mode** - PoC uses `audit` for flexibility; production should use `enforce`

## Related Documentation

- [TENANCY_MODEL.md](./TENANCY_MODEL.md) - Overall multi-tenancy architecture
- [DEV.md](./DEV.md) - Building custom operator images
