# [cert-manager] Bump to 1.20 — OPEN as okd-operator-pipeline#28

**PRs (opened 2026-09-09, all `MERGEABLE`/`CLEAN`; the repo has no CI, so these are human reviews):**

| PR | change | base |
|---|---|---|
| [#28](https://github.com/okd-project/okd-operator-pipeline/pull/28) | cert-manager -> 1.20 | `main` |
| [#29](https://github.com/okd-project/okd-operator-pipeline/pull/29) | cert-manager -> 1.20 (cherry-pick of the same 3 commits, identical diff) | `release-4.21` |
| [#30](https://github.com/okd-project/okd-operator-pipeline/pull/30) | nmstate gitlinks release-4.20 -> release-4.21 | `release-4.21` |
| [#31](https://github.com/okd-project/okd-operator-pipeline/issues/31) | *issue* — publish a per-branch operator support matrix | — |

**#31 came out of a question rather than a defect, and the tone matters.** The first draft was an audit:
three failure classes, red crosses, two implementation proposals. Rewritten against the register of
[argo-cd#12276](https://github.com/argoproj/argo-cd/issues/12276) — Summary / Motivation / Proposal, first
person from an actual use case, ~230 words instead of ~500, acknowledging the current state before critiquing,
and citing Argo CD's own tested-versions table as precedent. The CI pin-check proposal was cut entirely: it is
a second ask and belongs in its own issue if this one lands.

**Evidence gathered for it, all from `build.sh` + `.gitmodules` across the three branches:**

| branch | builds OKD | cert-manager | gitops | nmstate declares |
|---|---|---|---|---|
| `release-4.20` | 4.20.0-okd-scos.6 | 1.18 | 1.19 | `release-4.20` |
| `release-4.21` | 4.21.0-okd-scos.10 | 1.18 | 1.19 | `release-4.21` |
| `main` | 4.22.0-okd-scos.2 | 1.18 | 1.19 | `release-4.21` |

Two findings beyond the cert-manager one this file already covers. **`main`'s nmstate declares `release-4.21`
while `main` builds 4.22** and its other 39 submodules pin `release-4.22` — a third nmstate defect, distinct
from the gitlink drift #30 fixes. And **gitops is pinned three minors behind**: 1.19 ships Argo CD 3.1, which
predates Argo CD's tested-versions table (3.3/3.4/3.5 against K8s 1.32-1.36); OpenShift GitOps 1.20 ships
Argo CD 3.3, and `rh-gitops-midstream/release` carries `release-1.20` through `release-1.22`.

**Why two cert-manager PRs — a branch model I had wrong at first.** The pipeline has per-release branches
(`release-4.18`, `release-4.20`, `release-4.21`) and `main` has moved on to 4.22: `main`'s `common.sh` sets
`OKD_VERSION=4.22.0-okd-scos.2` and 39 of its submodules pin `release-4.22`, whereas `release-4.21` sets
`4.21.0-okd-scos.10`. **`release-4.21` still carries `MINOR=18`,** so a fix landing only on `main` would have
fixed the 4.22 catalog and left `catalog-index:4.21` — the tag this cluster actually consumes — on the EOL
cert-manager. I targeted `main` first without checking that. #29 is the one that matters for us.

**The nmstate finding (#30), which came out of assuming the same thing in reverse.** `.gitmodules` declares
`branch = release-4.21` for both nmstate submodules on *both* branches, but the committed gitlinks are
release-4.20 commits (`b29ee7b` is an ancestor of release-4.20, 8 behind its tip; `0fd2bc0` likewise, 21 behind).
Reading `.gitmodules` alone says "already on 4.21" and is wrong. What decides the build is the gitlink, because
`submodule_reset()` **ignores its `branch` argument entirely** and resets to the recorded hash — only `update`,
which is not run by default, consults the branch. So `init` pinned 4.20 content while every piece of metadata
claimed 4.21.
`sudoom:feature/cert-manager-1.20` @ `fd314fc` -> `okd-project:main` @ `73f8e01`, 3 commits, 9 files, 64/24.

**Still to do:** the companion `okderators-catalog-index` change adding the `olm.channel` entry. It cannot be
written until this PR merges and a build is published, because the entry has to name the resulting
`cert-manager-operator.v1.20.0-<date>` CSV.


**Upstream:** https://github.com/okd-project/okd-operator-pipeline
**Ready-to-apply patch:** `bugs/patches/okd-operator-pipeline-cert-manager-1.20.patch`
**Companion issue draft:** `bugs/upstream-okderators-421-ships-cert-manager-incompatible-with-421.md`
**Precedent:** our own `okd-operator-pipeline#19` (merged 2026-05-13) fixing
`okderators-catalog-index#45` — same repo, same shape, same author.

## Why

okderators `catalog-index:4.21` ships `cert-manager-operator.v1.18.0`, which deploys upstream cert-manager
**v1.18.2** (confirmed on our cluster: `oc -n cert-manager get deploy cert-manager -o
jsonpath='{.metadata.labels.app\.kubernetes\.io/version}'` → `v1.18.2`).

cert-manager 1.18 supports **Kubernetes 1.29–1.33** and went **EOL 2026-03-10**. **OKD 4.21 is Kubernetes 1.34.**
The catalog built for 4.21 therefore ships a cert-manager that does not support 4.21.

The version is pinned here, not in the catalog repo:

```bash
# cert-manager/build.sh
MAJOR=1
MINOR=18            # <- drives submodule branches via ${OCP_SHORT}
```

## Why 1.20 and not 1.19 or 1.21

| candidate | upstream K8s range | OKD minors | upstream status | branch exists? |
|---|---|---|---|---|
| 1.19 | 1.31 → 1.35 | 4.18–4.22 | EOL 2026-07-08 | yes |
| **1.20** | **1.32 → 1.35** | **4.19–4.22** | **supported** | **yes** |
| 1.21 | 1.33 → 1.36 | 4.20–4.23 | supported | **NO** — `openshift/cert-manager-operator` has no `cert-manager-1.21` branch |

1.20 is the newest buildable option, and it covers 4.21 *and* 4.22 in one bump — so the not-yet-created
`release-4.22` catalog branch needs no follow-up.

## What the PR changes (3 commits, 9 files, 79/24)

```
 .gitmodules                             |  4 +--   cert-manager-1.18 -> 1.20, release-1.18 -> 1.20
 cert-manager/build.sh                   | 17 +++-   MINOR=18 -> 20, plus the upgrade-graph rewrite
 cert-manager/cert-manager               |  2 +-   gitlink -> ddde1aa46c46994890adf8234266504f3efc0607
 cert-manager/operator                   |  2 +-   gitlink -> bd768238b709eea3edc6f3fbf6cd50a480369b28
 cert-manager/acme-solver.Containerfile  |  2 +-   go-toolset 1.24 -> 1.26
 cert-manager/cert-manager.Containerfile |  2 +-   go-toolset 1.24 -> 1.26
 cert-manager/istio-csr.Containerfile    |  2 +-   go-toolset 1.24 -> 1.26 (pre-existing breakage, see below)
 cert-manager/operator.Containerfile     | 21 ++++   go-toolset 1.26 + direct `go build` instead of `make build`
 cert-manager/patches/operator.patch     | 51 ++---  REGENERATED + Makefile guard (see below)
```

Split into three commits so a maintainer can take them independently:

| commit | subject |
|---|---|
| `6db11a4` | `[cert-manager] Update to 1.20` |
| `3f508d4` | `[cert-manager] Update the istio-csr builder to Go 1.26` |
| `8565c5f` | `[cert-manager] Set the okderators upgrade graph on the bundle` |

## The upgrade-graph defect: the bundle offers no edge any okderators user can take

Found by review, not by the build -- `operator-sdk bundle validate` passes either way, because this is a
*graph* defect, not a schema one.

The generated CSV inherits Red Hat's upgrade graph verbatim:

```yaml
olm.skipRange: '>=1.19.0 <1.20.0'
replaces: cert-manager-operator.v1.19.0
```

**okderators has never published a 1.19 build.** Its entire published history for this package is:

```
$ ls catalog/cert-manager-operator/          # okderators-catalog-index, release-4.21
cert-manager-operator.v1.14.0-2024-08-09-204321.yaml
cert-manager-operator.v1.15.0-2025-05-30-151158.yaml
cert-manager-operator.v1.18.0-2025-09-22-144722.yaml
cert-manager-operator.v1.18.0-2025-12-25-214537.yaml
```

So the installed head, `1.18.0-2025-12-25-214537`, falls outside `>=1.19.0 <1.20.0` and the `replaces` names a
CSV that does not exist in the catalog. Checked against `blang/semver/v4`, the library OLM resolves
`olm.skipRange` with:

```
>=1.19.0 <1.20.0                       1.18.0-2025-12-25-214537 -> false
>=1.0.0 <1.20.0-2026-09-08-213954      1.18.0-2025-12-25-214537 -> true
```

The fix follows `kube-descheduler/build.sh` and `vertical-pod-autoscaler/build.sh`, which already do exactly
this -- widen `olm.skipRange` to cover every published okderators build and delete the dangling `replaces`:

```bash
export OLM_SKIP_RANGE=">=1.0.0 <${OCP_DATE}"
yq e -i '.metadata.annotations["olm.skipRange"] = strenv(OLM_SKIP_RANGE)' "${CSV_BASE}"
yq e -i 'del(.spec.replaces)' "${CSV_BASE}"
yq e -i 'del(.spec.skips)' "${CSV_BASE}"
```

Verified on the generated bundle:

```
$ yq e '{"version": .spec.version, "skipRange": .metadata.annotations["olm.skipRange"],
         "replaces": .spec.replaces}' bundle/manifests/cert-manager-operator.clusterserviceversion.yaml
version: 1.20.0-2026-09-08-213954
skipRange: '>=1.0.0 <1.20.0-2026-09-08-213954'
replaces: null
```

**Nuance worth stating to the maintainer, because it changes how urgent this is.** In okderators the
load-bearing upgrade edge is not the CSV at all -- `hack/add-bundle.sh` runs `opm render` and writes the bundle
verbatim, and the graph lives in the hand-authored `olm.channel` entries in
`catalog/cert-manager-operator/cert-manager-operator.yaml`:

```yaml
schema: olm.channel
entries:
  - name: cert-manager-operator.v1.18.0-2025-12-25-214537
    replaces: cert-manager-operator.v1.18.0-2025-09-22-144722
```

That is why the existing 1.15 -> 1.18 hop works despite the same class of stale CSV metadata (the shipped 1.18
build still carries `olm.skipRange: '>=1.17.0 <1.18.0'`). So the **companion catalog-index PR must add**:

```yaml
  - name: cert-manager-operator.v1.20.0-<date>
    replaces: cert-manager-operator.v1.18.0-2025-12-25-214537
```

`replaces` edges do not require the intermediate versions to exist, so this jumps 1.18 -> 1.20 directly. The
build.sh change is therefore belt-and-braces rather than the sole mechanism -- but it makes the bundle
self-describing, matches the other okderators operators, and removes a `replaces` pointing at a CSV that is not
in the catalog.

## Only findable by running the build: istio-csr does not compile on main

`istio-csr` tracks `main`, not `cert-manager-${OCP_SHORT}`, so this is **upstream-current breakage unrelated to
the 1.20 bump** -- `./build.sh build_containers` fails on `main` today:

```
[1/2] STEP 1/8: FROM registry.access.redhat.com/ubi9/go-toolset:1.24 AS builder
[1/2] STEP 8/8: RUN cd $HOME/cmd && go build -o $HOME/_output/cert-manager-istio-csr ...
go: ../go.mod requires go >= 1.25.0 (running go 1.24.6; GOTOOLCHAIN=local)
```

`cert-manager/istio-csr/go.mod` declares `go 1.25.0`. Bumped to `go-toolset:1.26`, matching the other three.

## Upstream Dockerfile comparison (AGENTS.md requirement)

```bash
./scripts/rhcatalog.sh containerfiles cert-manager 4.21
```

Two things a reviewer should know about this step for cert-manager specifically:

- **Red Hat has not published 1.20 images.** The catalog's newest bundle for `openshift-cert-manager-operator`
  is **1.18.0**, so `dump-containerfiles ... v1.20.0` returns `no bundle found`. A 1.20 comparison is not
  possible; 1.18 is the only available baseline.
- **The operator image is not in the bundle's `related_images`.** The five components the catalog returns are
  `cert-manager-istiocsr`, `cert-manager-acmesolver`, `cert-manager-webhook`, `cert-manager-ca-injector` and
  `cert-manager-controller` -- all operands. So the operator Containerfile cannot be diffed this way at all.

For the five operand Dockerfiles the comparison is clean: the `ENV GO_BUILD_TAGS` / `GOEXPERIMENT` /
`CGO_ENABLED=1` / `GOFLAGS=""` block and the `go build ... -tags ${GO_BUILD_TAGS} main.go` lines match ours
exactly. The only differences are the two base images AGENTS.md explicitly lists as ignorable
(`brew.registry.redhat.io/rh-osbs/openshift-golang-builder` vs `registry.access.redhat.com/ubi9/go-toolset`,
`registry.redhat.io/rhel9-4-els/rhel:9.4` vs `quay.io/centos/centos:stream9`) plus the Go version, which has to
differ because RH's baseline is 1.18 and 1.20's go.mod requires newer.

Note also `scripts/rhcatalog.sh` needs **bash 4+** for its `declare -A`; it cannot run under macOS's system
bash 3.2 (`line 9: acm: unbound variable`).

## VERIFIED BY BUILDING IT

### All four container images build

```
$ cd cert-manager && BASE_REGISTRY=quay.io/sudoom ./build.sh build_containers
Successfully tagged quay.io/sudoom/cert-manager/operator:1.20.0-2026-09-08-212653
Successfully tagged quay.io/sudoom/cert-manager/cert-manager:1.20.0-2026-09-08-212653
Successfully tagged quay.io/sudoom/cert-manager/acme-solver:1.20.0-2026-09-08-212653
Successfully tagged quay.io/sudoom/cert-manager/istio-csr:1.20.0-...       (after the Go 1.26 bump)
```

`operator.Containerfile`'s replacement `RUN go build -o cert-manager-operator -ldflags '-w -s' -tags
"${GO_BUILD_TAGS}" main.go` compiles clean, which is what the `make build` -> `go build` change exists to prove.

**Workstation trap, cost ~30 min, nothing to do with the code.** An earlier build filled the host disk; the
podman VM recorded a writeback error, and every subsequent `podman build` then died at
`STEP 1: FROM ...` with an `input/output error` that looks like image corruption. Re-pulling the base image does
not fix it. The real message is in the VM's kernel log:

```
$ podman machine ssh 'sudo dmesg -T | tail -3'
overlayfs: Cannot mount volatile when upperdir has an unseen error. Sync upperdir fs to clear state.
```

podman mounts build layers `volatile`; overlayfs refuses that while the filesystem holds an unseen error.
A `sync` inside the VM does **not** clear it -- `podman machine stop && podman machine start` does, and
preserves all images (no `podman system reset` needed).

### make bundle + operator-sdk bundle validate

```
$ make bundle BUNDLE_VERSION=1.20.0-2026-09-08-200000 \
    IMG=quay.io/sudoom/cert-manager/operator:1.20.0-2026-09-08-200000 ...
> downloading operator-sdk v1.25.1
Building sigs.k8s.io/kustomize/kustomize/v5...
Building sigs.k8s.io/controller-tools/cmd/controller-gen...
... operator-sdk generate bundle -q --overwrite=false --version 1.20.0-2026-09-08-200000
... operator-sdk bundle validate ./bundle
level=info msg="All validation tests have completed successfully"
$ echo $?
0
```

Generated CSV:

```
name:        cert-manager-operator.v1.20.0-2026-09-08-200000
version:     1.20.0-2026-09-08-200000
displayName: cert-manager Operator for OKD
support:     OKD Community
advertises:  cert-manager v1.20.3
OKD strings: 7    Red Hat strings: 1 (see residue note below)
```

The generated name/version match okderators' existing scheme exactly, so the channel entry slots in unchanged.

## Only findable by running the build: a new semver guard

The 1.20 Makefile added a guard that 1.18 does not have:

```make
define validate-semver
$(shell echo '$(1)' | grep -Eq '^([0-9]+\.[0-9]+\.[0-9]+|latest)$$' && echo valid)
endef
...
ifneq ($(call validate-semver,$(BUNDLE_VERSION)),valid)
$(error BUNDLE_VERSION '$(BUNDLE_VERSION)' is not valid semver (expected: Major.Minor.Patch))
endif
```

It accepts only bare `X.Y.Z`. But `common.sh` builds `OCP_DATE="${MAJOR}.${MINOR}.0-${DATE}"`, so the very first
`make bundle` hard-errors:

```
Makefile:42: *** BUNDLE_VERSION '1.20.0-2026-09-08-200000' is not valid semver (expected: Major.Minor.Patch).  Stop.
```

The date suffix is load-bearing for this catalog — `cert-manager-operator.yaml` already lists **two** builds of
`1.18.0` distinguished only by it. And `1.20.0-2026-09-08-200000` **is** valid semver: the spec allows a
hyphen-prefixed pre-release identifier, so the guard is stricter than the thing it is named after. The patch
therefore relaxes it to `^([0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?|latest)$` with a comment explaining why.

This is worth raising upstream separately — arguably `openshift/cert-manager-operator` should accept full semver
rather than a subset — but patching it here unblocks the bump without waiting on that.

## The other non-obvious part: the patch had to be regenerated

`common.sh` applies it with `git am -3`, and the existing patch's hunk context contains a version-specific line:

```
     olm.skipRange: '>=1.18.0 <1.18.1'
```

The 1.20 CSV base has `'>=1.19.0 <1.20.0'` there, so the patch fails:

```
$ git am -3 ../patches/operator.patch
Applying: OKDify
error: sha1 information is lacking or useless (config/manifests/bases/cert-manager-operator.clusterserviceversion.yaml).
error: could not build fake ancestor
Patch failed at 0001 OKDify

$ git apply -3 --verbose ../patches/operator.patch
error: repository lacks the necessary blob to perform 3-way merge.
Falling back to direct application...
error: while searching for:
    olm.skipRange: '>=1.18.0 <1.18.1'
```

The regenerated patch makes the **same eight substitutions** against the 1.20 base — uninstall-message, drop
`valid-subscription`, `support:`, description ×2, `displayName:`, icon, `maintainers:`, `provider.name` — and
applies cleanly:

```
$ git am -3 ../patches/operator.patch
Applying: OKDify
$ echo $?
0
```

Verified against a fresh `--branch cert-manager-1.20` checkout, 7 OKD strings present afterwards, zero remaining
`Red Hat` / `redhat` / `valid-subscription` occurrences.

## IN-CLUSTER TEST: the upgrade graph is now proven by `opm`, install still gated on arch

Two corrections to the earlier plan in this section, both found by trying it:

**1. The internal registry is not available on this cluster.** `configs.imageregistry/cluster` reads
`managementState: Removed`, there is no registry Deployment, no `image-registry-storage` PVC and no route —
only the operator and the `node-ca` DaemonSet. It *was* used (the `nmstate-bundle-{broken,fixed}` and
`nmstate-test-catalog-*` ImageStreams from four months ago are still there), but it has since been removed and
its storage released. Re-enabling means creating the PVC and flipping `managementState` — a platform change, not
a test step.

**2. There is a better registry already running: zot.** `components/apps/zot/` deploys zot in-cluster at
`zot.apps.okd.sudops.pl` (50Gi, `ceph-nvme-block`), and `components/cluster-config/image-mirror-zot/` already
points the whole cluster's pulls at it via IDMS/ITMS. Its config declares no `auth` and no `accessControl`
block, so it accepts anonymous pushes, and the route carries the trusted LE wildcard. The bundle pushed first
try:

```
$ podman push zot.apps.okd.sudops.pl/okd-test/cert-manager-operator-bundle:1.20.0-2026-09-08-213954
Writing manifest to image destination
```

Use an `okd-test/` prefix. The IDMS maps `source: quay.io` (and docker.io, ghcr.io, registry.k8s.io) to
`mirrors: [zot.apps.okd.sudops.pl]`, so zot's repository namespace is shared across all four upstreams — a test
push under a path that matches a real upstream repo would shadow it for the entire cluster.

### The upgrade graph, proven both ways

`opm render` against the pushed bundle, assembled into a catalog with the four published okderators bundles and
the channel entry the companion catalog-index PR would add:

```
  - name: cert-manager-operator.v1.20.0-2026-09-08-213954
    replaces: cert-manager-operator.v1.18.0-2025-12-25-214537

$ opm validate /cat && echo OK
OK
```

And the same catalog with the **unfixed** graph — i.e. what the bundle ships today, `replaces:
cert-manager-operator.v1.19.0` against a 1.19 that okderators never published:

```
$ opm validate /cat
level=fatal msg="invalid index:
└── invalid package \"cert-manager-operator\":
    └── invalid channel \"alpha\":
        └── multiple channel heads found in graph:
            cert-manager-operator.v1.18.0-2025-12-25-214537,
            cert-manager-operator.v1.20.0-2026-09-08-213954"
```

**Two disconnected channel heads.** This is the defect stated in the tool's own words rather than as semver
reasoning: 1.20 is not reachable from 1.18, so OLM keeps 1.18 as the head and never offers the upgrade. It is
also a stronger result than a runtime test would give, because it fails at catalog-build time.

### Why `operator-sdk run bundle` is not the answer *here*

`BUILDING.md` documents `operator-sdk run bundle <bundle-image>` (+ `operator-sdk cleanup <package>`) as the
simplest cluster deployment, and for a plain install test it is the right tool. It does not fit this particular
verification, for three separate reasons:

- **It cannot see the defect.** `run bundle` synthesises a single-entry catalog with no upgrade graph. There is
  no 1.18 to upgrade from, so the `replaces`/`skipRange` problem is invisible to it by construction.
- **cert-manager is installed AllNamespaces on this cluster.** The `OperatorGroup` in `cert-manager-operator`
  has `spec: {}`, so the live CSV is copied into every namespace — including any scratch namespace `run bundle`
  would target. A second CSV owning the same seven cluster-scoped CRDs (`Certificate`, `Issuer`,
  `ClusterIssuer`, …) collides with the operator that issues this cluster's wildcard and API certificates. The
  live Subscription is `installPlanApproval: Manual` and pinned to `source: okderators`, so it will not switch
  sources on its own — but this is a production TLS path, not a test surface.
- **Arch.** `run bundle` waits for the CSV to reach `Succeeded`. The operand images are arm64; it would fail at
  the pod having already proven only the resolution step.

**What would make `run bundle` the right call:** amd64 operand images. Build them in-cluster (the nodes are
amd64) and push to zot, then run it against a cluster that is not serving this one's certificates — or accept
the CRD-ownership collision as the expected, and safe, failure mode and read only the resolution result.

## IN-CLUSTER amd64 BUILD — DONE. The arch gap is closed.

The workstation is arm64 and the cluster is amd64, which is why every earlier note here said the images
"cannot run on the cluster". Solved by building them **on** the cluster with OpenShift binary builds and
pushing to zot. Four `BuildConfig`s in a scratch namespace, `source.type: Binary`, `strategy: Docker`, and --
because the internal registry is `Removed` and the usual ImageStream output has nowhere to go --
`output.to.kind: DockerImage` pointing straight at zot:

```yaml
  output:
    to:
      kind: DockerImage
      name: zot.apps.okd.sudops.pl/okd-test/cert-manager-operator:1.20.0-2026-09-08-220000
```

No push secret: zot declares no `auth`/`accessControl`, so the push is anonymous. Prerequisites worth
checking before copying this recipe elsewhere: `system:build-strategy-docker-binding` must exist (it does
here, so Docker strategy is allowed) and `builds.config.openshift.io/cluster` should be empty of overrides.

All four succeeded, ~11.5 min each, all scheduled onto node6:

| build | duration | pushed digest |
|---|---|---|
| `cm-istio-csr` | 12m10s | `cert-manager-istio-csr@sha256:9643363178744…` |
| `cm-cert-manager` | 11m36s | `cert-manager@sha256:0065cebf7abf43…` |
| `cm-acme-solver` | 11m31s | `cert-manager-acme-solver@sha256:1413c36eb4f41a…` |
| `cm-operator` | 11m31s | `cert-manager-operator@sha256:6a6903db17a6ff…` |

**Order the builds cheapest-context-first.** They were run istio-csr (1.1 MB) -> cert-manager (16 MB) ->
acme-solver (16 MB) -> operator (326 MB), fail-fast. The first build is what proves the whole path -- binary
upload, base-image pull, Go module egress, and the zot push -- for the price of the smallest upload. The
operator's 326 MB context is mostly `operator/vendor` (164 MB), which is required by `-mod=vendor`.

The one genuinely unknown step was whether a build pod could push to zot through its own ingress route
(`zot.apps.okd.sudops.pl` resolves to the ingress VIP on frontnet). It can:

```
Successfully pushed zot.apps.okd.sudops.pl/okd-test/cert-manager-istio-csr@sha256:9643363178744…
Push successful
```

If it had not, the fallback is the in-cluster Service `zot.zot.svc.cluster.local:5000` with `insecure: true`.

### Bundle rebuilt against the amd64 images, with digests

With the operand images actually present in a registry, `--use-image-digests` works for the first time (the
earlier local runs had to drop it -- operator-sdk resolves every `RELATED_IMAGE_*` against the registry and
failed `UNAUTHORIZED` on unpushed quay tags). The regenerated CSV:

```
name:      cert-manager-operator.v1.20.0-2026-09-08-220000
skipRange: '>=1.0.0 <1.20.0-2026-09-08-220000'
replaces:  null
cert-manager-operator   -> zot.../cert-manager-operator@sha256:6a6903db17a6ff…
cert_manager_controller -> zot.../cert-manager@sha256:0065cebf7abf43…
cert-manager-acmesolver -> zot.../cert-manager-acme-solver@sha256:1413c36eb4f41a…
cert-manager-istiocsr   -> zot.../cert-manager-istio-csr@sha256:9643363178744…
```

`trust-manager` correctly stays on `quay.io/jetstack/trust-manager` -- the pipeline does not rebuild it.

**Cosmetic upstream quirk, NOT introduced here:** the generated `relatedImages` contains an entry with an
empty `name`. The already-published okderators 1.18 bundle has the same thing (two of them), so it is
operator-sdk behaviour rather than a regression from this change. Flagging, not fixing.

### Catalog image

Built with an explicit `--platform linux/amd64` (the workstation would otherwise produce an arm64 catalog that
cannot run on the cluster -- the operand images were safe from this only because the cluster built them):

```
$ podman image inspect …/cert-manager-test-catalog:v1 --format '{{.Architecture}}/{{.Os}}'
amd64/linux
$ opm validate /cat && echo OK
OK
```

### VERIFIED ON THE CLUSTER: OLM resolves the channel head to 1.20

The catalog image was served to OLM through a **namespace-scoped** `CatalogSource` in the scratch namespace
(not `openshift-marketplace`, so it is invisible to every Subscription outside it -- the live cert-manager
Subscription cannot see or resolve against it). The catalog pod came up `READY` on the first try, which also
confirms the `--platform linux/amd64` catalog build was necessary and correct:

```
$ oc -n cert-manager-build get pods
cert-manager-120-test-jw72p   1/1   Running

$ oc -n cert-manager-build get packagemanifest cert-manager-operator -o jsonpath=...
channel      = alpha
currentCSV   = cert-manager-operator.v1.20.0-2026-09-08-220000
version      = 1.20.0-2026-09-08-220000
skipRange    = >=1.0.0 <1.20.0-2026-09-08-220000
installModes = OwnNamespace=true SingleNamespace=true MultiNamespace=false AllNamespaces=true
```

**`currentCSV` is the 1.20 bundle.** That is the whole fix, confirmed by OLM on a live OKD 4.21 cluster rather
than by reasoning: with the corrected graph OLM computes 1.20 as the head of the `alpha` channel, and the
`olm.skipRange` it parsed is the widened one this PR sets. Taken together with the `opm validate` negative
result -- where the shipped `replaces: cert-manager-operator.v1.19.0` produces *two disconnected channel
heads* and 1.18 stays the head -- the defect and its fix are now demonstrated at both the catalog-build layer
and the cluster resolution layer.

### And OLM generates a valid InstallPlan for it

Second stage: a namespace-scoped `OperatorGroup` plus a `Manual` Subscription in the same scratch namespace.

```
=== InstallPlan ===
name=install-pbw5k
approved=false
phase=RequiresApproval
csvs=["cert-manager-operator.v1.20.0-2026-09-08-220000"]
```

OLM resolved the subscription to the 1.20 CSV and produced an InstallPlan for it. **It was deliberately not
approved** -- approving would install a second cert-manager operator whose CSV owns the same seven
cluster-scoped CRDs as the one issuing this cluster's wildcard and API certificates. Resolution and InstallPlan
generation are the layer a catalog defect lives in, so this is the end of the useful test, not a limitation.

**The isolation was verified, not assumed.** After both stages, the live operator was untouched:

```
$ oc -n cert-manager-operator get subscription cert-manager-operator -o jsonpath=...
installedCSV = cert-manager-operator.v1.18.0-2025-12-25-214537
state        = AtLatestKnown
source       = okderators
```

No new InstallPlan appeared in any namespace other than the scratch one, the live CSV stayed `Succeeded`, and
every `Certificate` in the cluster stayed `Ready`. That is the point of putting the `CatalogSource` outside
`openshift-marketplace`: a catalog there is global and would have been a candidate upgrade source for the live
Subscription, whereas a namespace-scoped one is only visible to Subscriptions in its own namespace.

### What is left, and why it stops here

Everything needed for a cluster test is now in zot. The remaining step is an OLM resolution test, scripted at
`scratchpad/olm-resolution-test.sh` in two deliberately separated stages:

- `--catalog` (safe): a **namespace-scoped** `CatalogSource` in the scratch namespace. Because it is not in
  `openshift-marketplace` it is invisible to every Subscription outside that namespace, so the live
  cert-manager Subscription cannot see or resolve against it. Asserts the catalog serves and OLM parses the
  package and channel.
- `--subscribe` (opt-in): adds an `OperatorGroup` scoped to that namespace and a `Manual` Subscription, and
  asserts an InstallPlan naming the 1.20 CSV is generated. **The InstallPlan is deliberately never approved.**

Approving it would install a second cert-manager operator whose CSV owns the same seven cluster-scoped CRDs
(`Certificate`, `Issuer`, `ClusterIssuer`, …) as the operator issuing this cluster's wildcard and API
certificates. Resolution and InstallPlan generation happen before any of that, and they are the layer a
catalog defect lives in -- so stopping there is the right trade, not a limitation.

## SUPERSEDED PLAN (kept for the steps, which still apply if the internal registry is ever re-enabled)
## PLANNED NEXT: in-cluster bundle test via the internal registry

The one remaining gap is that the bundle has never been resolved by OLM on a real 4.21 cluster. That is testable
**without** solving the arm64/amd64 problem, because a bundle image is metadata only (~300 kB, no compiled
binaries) and therefore architecture-independent. This is the same method already used successfully on this
cluster to prove the nmstate ImageStream defect (okderators-catalog-index#45 → okd-operator-pipeline#19); the
leftover images were still on the workstation as
`default-route-openshift-image-registry.apps.okd.sudops.pl/openshift/nmstate-test-catalog-*`.

**Steps (all operator-run — they push to a registry and create a CatalogSource):**

1. Log the local podman into the cluster registry:
   ```bash
   oc registry login --skip-check
   REG=default-route-openshift-image-registry.apps.okd.sudops.pl/openshift
   ```
2. Build and push ONLY the bundle image (skip `build_containers` — not needed for a resolution test):
   ```bash
   cd cert-manager/operator
   make bundle BUNDLE_VERSION=1.20.0-<date> IMG=$REG/cert-manager-operator:1.20.0-<date>
   podman build -f bundle.Dockerfile -t $REG/cert-manager-bundle:1.20.0-<date> .
   podman push $REG/cert-manager-bundle:1.20.0-<date>
   ```
3. Render a single-package test catalog around it and push:
   ```bash
   opm render $REG/cert-manager-bundle:1.20.0-<date> -o yaml > catalog/cert-manager.yaml
   # add the olm.package + olm.channel stanzas (copy the shape from
   # okderators catalog/cert-manager-operator/cert-manager-operator.yaml)
   opm validate catalog/
   podman build -f catalog.Containerfile -t $REG/cert-manager-test-catalog:v1 .
   podman push $REG/cert-manager-test-catalog:v1
   ```
4. Create a **temporary** CatalogSource pointing at it (NOT the okderators one -- do not disturb the live
   catalog), in `openshift-marketplace`, then a Subscription in a scratch namespace with
   `installPlanApproval: Manual`.
5. **The assertion:** the InstallPlan is created and reaches `Complete` (or at least resolves all components
   without `UnsupportedResource`). That is exactly the failure mode nmstate exhibited, and exactly what a catalog
   contribution needs to prove.
6. Tear down: delete the Subscription, InstallPlan, CSV, scratch namespace and the temporary CatalogSource.

**Known limitation:** the CSV references the operator/cert-manager/acme-solver images by tag, and those will not
exist unless `build_containers` has also been run and pushed. So the operator POD will not start. That is fine for
this test -- resolution and InstallPlan creation happen before any image pull, and that is the layer a catalog bug
lives in.

**GATE NOW CLEAR (2026-09-08, later the same evening).** This plan set its own precondition on pool headroom.
It briefly failed — `nvme-replicated` hit **84.53% / 70 GiB MAX AVAIL** against the 85% nearfull threshold — for
a reason unrelated to this work: CNPG volume snapshots had never been pruned. After deleting the 167-snapshot
backlog the pool reads **74.66% / 114 GiB MAX AVAIL** (see `blog/blog-cnpg-draft.md` 2026-09-08). The internal
registry is Ceph-backed, so that headroom is the constraint that matters, and there is now ~10pp of it. The bundle-only variant (~300 kB) is not meaningfully gated by
capacity, but it still needs a CatalogSource + Subscription, which is a mutation next to the live cert-manager
operator and therefore an explicit operator decision, not an unattended one.

**Better variant once the gate clears — build the operand images IN the cluster and solve the arch problem at
the same time.** The nodes are amd64, so a BuildConfig against this branch produces artefacts that can actually
run, which the arm64 workstation build never will. That turns the "operator POD will not start" limitation below
into a real end-to-end install test rather than a resolution-only one. Cost is the same Ceph headroom, so it
queues behind the same reclaim.

## What has NOT been verified

Honest scope, so a reviewer knows what to re-check:

- **The images are arm64, the cluster is amd64.** `build_containers` now succeeds for all four images, which
  proves the Containerfile changes compile — but the build host is Apple Silicon with Rosetta off, so these
  artefacts cannot run on the cluster. An amd64 build under qemu with `CGO_ENABLED=1` +
  `strictfipsruntime,openssl` would be slow and would prove little extra; building on amd64 nodes (the
  in-cluster route below) is the better confirmation.
- **Nothing was pushed.** `build_bundle`'s `podman push` was stripped for these runs, so no image reached
  `quay.io/sudoom`. Consequence: `make bundle` had to run **without** `--use-image-digests`, because
  operator-sdk resolves each `RELATED_IMAGE_*` against the registry and fails
  `UNAUTHORIZED ... /v2/sudoom/cert-manager/cert-manager/manifests/...` on unpushed tags. Digest pinning is
  orthogonal to everything verified here, but it is untested.
- **The bundle was not installed on a cluster.** `operator-sdk bundle validate` passes, but an actual
  `InstallPlan` on OKD 4.21 is untested.
- **Cosmetic residue, deliberately not fixed:** the generated CSV still contains one `redhat.com` string —
  `"email": "aos-ci-cd@redhat.com"` inside the `alm-examples` annotation, sourced from
  `config/samples/letsencrypt/cert-manager.io_v1_issuer.yaml`. It is a sample ACME registration address in an
  example CR, not user-visible branding, and the existing OKDify patch never touched `config/samples/`. Flagging
  rather than silently extending the patch's scope.

## Also worth a maintainer's attention (separate finding, same catalog)

`cluster-logging` regressed between catalog tags: `:4.20` alpha head is `v6.5.0-2026-06-04`, `:4.21` alpha head is
`v6.3.0-2025-08-08` — older by two minors and ten months. Consistent with the still-open
`okderators-catalog-index#44`. Filed as context in the companion issue draft, not fixed here.
