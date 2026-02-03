# Developer Guide (Building Custom Images)

This section describes how to build and deploy custom operator images with your own code changes and manifests.

## Prerequisites

- `podman` or `docker` installed
- Access to a container registry (e.g., quay.io)
- `make` and Go toolchain

## Build & Push All Images

```bash
cd ../opendatahub-operator

export IMAGE_TAG_BASE=quay.io/<username>/opendatahub-operator
export IMG_TAG=v3.3.0-maas-multitenant-poc
export IMG=${IMAGE_TAG_BASE}:${IMG_TAG}
export BUNDLE_IMG=${IMAGE_TAG_BASE}-bundle:${IMG_TAG}
export CATALOG_IMG=${IMAGE_TAG_BASE}-catalog:${IMG_TAG}
export VERSION=3.3.0-maas-multitenant-poc
```

> [!IMPORTANT]
> You must set `IMAGE_TAG_BASE` and `IMG_TAG` separately. Setting only `IMG` does not propagate the operator image into the bundle CSV.

**Build & push operator image:**

```bash
make image
```

To use custom MaaS manifests from a different repository:

```bash
# Format: org:repo:ref:path
export MAAS_REPO="your-org:maas-billing:your-branch:deployment"
make image IMAGE_BUILD_FLAGS+=" --build-arg OVERWRITE_MANIFESTS=\"--maas=${MAAS_REPO}\""
```

**Build & push bundle image:**

```bash
make bundle-build bundle-push
```

**Build & push catalog image** (must be done after bundle is pushed):

```bash
make catalog
```

## Build maas-api Image

```bash
cd ../models-as-a-service
export MAAS_API_IMG=quay.io/<username>/maas-api:latest
podman build -t ${MAAS_API_IMG} -f Dockerfile .
podman push ${MAAS_API_IMG}
```

## Verify Images

```bash
# Verify bundle has correct operator image
podman create --name temp-bundle ${BUNDLE_IMG}
podman cp temp-bundle:/manifests/opendatahub-operator.clusterserviceversion.yaml /tmp/csv.yaml
podman rm temp-bundle
grep "image:" /tmp/csv.yaml | head -5

# Verify catalog has correct images
grep "${IMAGE_TAG_BASE}" catalog/catalog.yaml
```

## Deploy Custom Images

Update the CatalogSource image in the [Quick Start](README.md#quick-start) section with your custom `CATALOG_IMG`, then deploy.
