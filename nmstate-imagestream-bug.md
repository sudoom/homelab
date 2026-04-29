## NMState Operator ImageStream Bug — Context for PR

### The Problem

The `kubernetes-nmstate-operator` bundle in the `okderators` catalog (`quay.io/okderators/catalog-index:4.20`) includes an `ImageStream` as an `olm.bundle.object`. OKD 4.20 marks this as `UnsupportedResource`, causing the InstallPlan to fail immediately. The operator cannot be installed from `okderators` — users must fall back to `community-operators`.

### Issue

https://github.com/okd-project/okderators-catalog-index/issues/45

### Root Cause

The `make ocp-update-bundle-manifests` step in the build pipeline (inherited from `openshift/kubernetes-nmstate`) injects an ImageStream manifest into the bundle. This is an OpenShift build artifact — the CSV already references all container images by digest, so the ImageStream serves no runtime purpose.

### Where to Fix

**Repo:** https://github.com/okd-project/okd-operator-pipeline
**File:** `nmstate/build.sh`
**Function:** `build_bundle()`

After the `make ocp-update-bundle-manifests` call and before `podman build`, add a step to remove any ImageStream manifests from the bundle:

```bash
# Remove ImageStream — it's an OpenShift build artifact not supported by OKD's OLM
find manifests/stable -name '*.yaml' -exec grep -l 'kind: ImageStream' {} \; | xargs rm -f
```

### The build.sh (current)

```bash
build_bundle() {
    convert_all_images_to_digest

    pushd operator

    yq e -i ".metadata.annotations.support = \"OKD Community\" |
.metadata.annotations.containerImage = env(IMG_OPERATOR) |
.metadata.annotations.categories = \"OKD Optional\" |
.spec.provider.name = \"OKD Community\" |
.spec.maintainers[0].name = \"OKD Community\" |
.spec.maintainers[0].email = \"maintainers@okd.io\"" ./manifests/bases/kubernetes-nmstate-operator.clusterserviceversion.yaml

    namespace=openshift-nmstate
    export VERSION="${OCP_DATE}"

    make ocp-update-bundle-manifests KUBE_RBAC_PROXY_IMAGE=$IMG_KUBE_RBAC_PROXY HANDLER_IMAGE=${IMG_HANDLER} \
     PLUGIN_IMAGE=${IMG_CONSOLE_PLUGIN} OPERATOR_IMAGE=${IMG_OPERATOR} BUNDLE_IMG=${IMG_BUNDLE} \
     "BUNDLE_METADATA_OPTS=${BUNDLE_METADATA_OPTS}" MANIFEST_BASES_DIR=manifests/bases MONITORING_NAMESPACE=openshift-monitoring \
     HANDLER_NAMESPACE=$namespace OPERATOR_NAMESPACE=$namespace PLUGIN_NAMESPACE=$namespace

    podman build -f manifests/stable/bundle.Dockerfile -t "${IMG_BUNDLE}" .
    podman push "${IMG_BUNDLE}"

    popd
}
```

### Related Catalog File

https://github.com/okd-project/okderators-catalog-index/blob/release-4.20/catalog/kubernetes-nmstate-operator/kubernetes-nmstate-operator.v4.20.0-2025-12-27-212436.yaml

### Validation

After the fix, the rebuilt bundle should not contain any `ImageStream` objects. Verify with:
```bash
oc image extract <bundle-image> --path /manifests/:./manifests/
grep -r 'kind: ImageStream' ./manifests/
# Should return nothing
```

### Notes
- Other operators in the pipeline (e.g., cert-manager) may also have this issue if they use similar OpenShift Makefile targets
- The `community-operators` catalog version of NMState works fine because it doesn't go through the OpenShift build pipeline
