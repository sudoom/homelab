# [cert-manager] Bump to 1.20 — PR ready for `okd-project/okd-operator-pipeline`

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

## What the PR changes (5 files, 42/19)

```
 .gitmodules                         |  4 +--   cert-manager-1.18 -> 1.20, release-1.18 -> 1.20
 cert-manager/build.sh               |  2 +-   MINOR=18 -> 20
 cert-manager/cert-manager           |  2 +-   gitlink -> ddde1aa46c46994890adf8234266504f3efc0607
 cert-manager/operator               |  2 +-   gitlink -> bd768238b709eea3edc6f3fbf6cd50a480369b28
 cert-manager/patches/operator.patch | 51 ++--- REGENERATED + Makefile guard (see below)
```

## VERIFIED BY BUILDING IT

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

## Second blocker, only findable by running the build: a new semver guard

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

## What has NOT been verified

Honest scope, so a reviewer knows what to re-check:

- **No container images were built.** `make bundle` is verified end to end; `build_containers` is not. The build
  host is arm64 and the target amd64, and the Containerfiles use `CGO_ENABLED=1` with
  `strictfipsruntime,openssl` — a cross-arch emulated CGO build would prove little even if it succeeded.
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
