# [nmstate] okderators-catalog-index: replace the 4.21 bundle — DRAFT, blocked on a build

**Upstream:** https://github.com/okd-project/okderators-catalog-index, base `release-4.21`
**Status (2026-10-14):** not filed. It is blocked on
[okd-operator-pipeline#33](https://github.com/okd-project/okd-operator-pipeline/pull/33) (ready for review) and on
a maintainer then running "Deploy NMState" by `workflow_dispatch` on `release-4.21`. The bundle file is `opm render`
output of the pushed image, digests included, so it cannot be written before that run. Everything below marked
`<DATE>`, `<RUN_URL>` and `<SHA>` gets filled in from that run.
**No fork of the catalog repo exists yet** (`sudoom/okderators-catalog-index` → 404); `gh repo fork` at filing time.
**Effect on our cluster:** none expected. nmstate here comes from `community-operators`. A merge to `release-4.21`
rebuilds `quay.io/okderators/catalog-index:4.21` (`deploy-catalog.yml`, push to `release-*`), which our `okderators`
CatalogSource consumes. All five okderators subscriptions are `installPlanApproval: Manual`, and none of them is nmstate.

## Why the current entry has to go

`catalog/kubernetes-nmstate-operator/` on `release-4.21` holds one bundle,
`kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851` (CSV `createdAt: 2026-05-05T16:05:49Z`). Two pipeline fixes
reached `release-4.21` after it was built, and quay has no newer 4.21 nmstate image (newest tags 2026-10-14:
`4.22.0-2025-12-14-152353`, `4.21.0-2026-05-05-165851`, `4.20.0-2025-12-27-212436`).

| okd-operator-pipeline change | on `release-4.21` | what the 05-05 bundle shows |
|---|---|---|
| #19 remove the ImageStream from the bundle manifests | committed 2026-05-13 (`b8f3d39`) | bundle object 1 of 3 is `image.openshift.io/v1` `ImageStream`, the `UnsupportedResource` InstallPlan failure from catalog-index#45. #45 was closed 2026-05-13, but the 4.21 catalog still ships the object |
| #30 nmstate submodules to `release-4.21` | 2026-09-15 (`25c7e01`) | built while the gitlinks were `kubernetes-nmstate` `b29ee7b` and `nmstate-console-plugin` `0fd2bc0`, both release-4.20 commits |

Decoding the bundle objects of the 05-05 file (`python3`, base64 of each `olm.bundle.object`):

```
0 apiextensions.k8s.io/v1 CustomResourceDefinition nmstates.nmstate.io
1 image.openshift.io/v1 ImageStream None  tags=["quay.io/openshift/origin-kubernetes-nmstate-operator:4.21", "quay.io/openshift/origin-kubernetes-nmstate-handler:4.21", "quay.io/openshift/origin-nmstate-console-plugin:4.21", "quay.io/openshift/origin-kube-rbac-proxy:4.21"]
2 operators.coreos.com/v1alpha1 ClusterServiceVersion kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851  createdAt=2026-05-05T16:05:49Z
```

## Procedure (after the build)

`opm` is not installed on the workstation: fetch a pinned `operator-framework/operator-registry` release into the
scratchpad `bin/`, sha-checked, as was done for `promtool`. `add-bundle.sh` does `podman create` on the bundle,
which fails for a `FROM scratch` image (catalog-index#59, open); `opm render` alone produces the same file.

```bash
BUNDLE=quay.io/okderators/nmstate/bundle:4.21.0-<DATE>
D=catalog/kubernetes-nmstate-operator
gh repo fork okd-project/okderators-catalog-index --clone=false
git clone --branch release-4.21 --single-branch https://github.com/okd-project/okderators-catalog-index.git
cd okderators-catalog-index && git switch -c nmstate-4.21.0-<DATE>
opm render "$BUNDLE" -o yaml > "$D/kubernetes-nmstate-operator.v4.21.0-<DATE>.yaml"
git rm -q "$D/kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851.yaml"
# edit $D/kubernetes-nmstate-operator.yaml (below)
opm validate catalog/
```

Checks on the new bundle before filing:
- its objects are the CRD and the CSV, with no `ImageStream` (same decode as above);
- CSV name `kubernetes-nmstate-operator.v4.21.0-<DATE>`, `olm.package` version `4.21.0-<DATE>`;
- the operator, handler and console-plugin images in the CSV are `quay.io/okderators/nmstate/*@sha256:` digests
  pushed by `<RUN_URL>`;
- `opm validate catalog/` exits 0.
- optionally, `opm serve catalog/ --cache-only --cache-dir=$TMPDIR/c`, which is the step `catalog.Containerfile` runs.

Channel file after the edit (the existing entry already uses `skips` for the absent 4.20 bundle; the
maintainer replaced a superseded bundle in the same way in `a2ce063`):

```yaml
---
schema: olm.channel
package: kubernetes-nmstate-operator
name: alpha
entries:
  - name: kubernetes-nmstate-operator.v4.21.0-<DATE>
    skips:
      - kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851
      - kubernetes-nmstate-operator.v4.20.0-2025-12-27-212436
```

## PR

**Title:** `Update kubernetes-nmstate-operator to v4.21.0-<DATE>`

**Body:**

````markdown
Replaces the `release-4.21` nmstate bundle with `quay.io/okderators/nmstate/bundle:4.21.0-<DATE>`, built by <RUN_URL> from okd-operator-pipeline `release-4.21` @ `<SHA>`.

The current bundle, `kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851`, was built before two okd-operator-pipeline changes reached `release-4.21`:

| change | on `release-4.21` | effect on the 05-05 bundle |
|---|---|---|
| okd-project/okd-operator-pipeline#19, remove the ImageStream from the bundle | 2026-05-13 | the bundle still contains an `image.openshift.io/v1` `ImageStream` object (the #45 failure) |
| okd-project/okd-operator-pipeline#30, nmstate submodules to `release-4.21` | 2026-09-15 | built from `kubernetes-nmstate` `b29ee7b` and `nmstate-console-plugin` `0fd2bc0`, both `release-4.20` commits |

## Changes

- add `kubernetes-nmstate-operator.v4.21.0-<DATE>.yaml` (`opm render <bundle> -o yaml`)
- remove the 05-05 bundle file
- channel `alpha`: the new entry skips the 05-05 and 4.20 bundles, so existing installs upgrade

## Verification

```
$ opm validate catalog/
<output>
```

Objects in the new bundle: `CustomResourceDefinition` `nmstates.nmstate.io`, `ClusterServiceVersion` `kubernetes-nmstate-operator.v4.21.0-<DATE>`. No `ImageStream`.
````
