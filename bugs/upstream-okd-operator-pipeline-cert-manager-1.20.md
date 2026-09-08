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

## What the PR changes (5 files, 18/18)

```
 .gitmodules                         |  4 ++--   cert-manager-1.18 -> 1.20, release-1.18 -> 1.20
 cert-manager/build.sh               |  2 +-    MINOR=18 -> 20
 cert-manager/cert-manager           |  2 +-    gitlink -> ddde1aa46c46994890adf8234266504f3efc0607
 cert-manager/operator               |  2 +-    gitlink -> bd768238b709eea3edc6f3fbf6cd50a480369b28
 cert-manager/patches/operator.patch | 26 +++--- REGENERATED (see below)
```

## The non-obvious part: the patch had to be regenerated

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

- **No container build was run.** The submodule bump and patch application are verified; `build_containers` /
  `build_bundle` are not. Our build host is arm64 and the target is amd64, so a local build would not have
  produced usable images anyway.
- **The bundle was not installed on a cluster.** The 1.20 CSV base declares `minKubeVersion: 1.27.0` and the
  1.20 branch targets cert-manager v1.20.3, but end-to-end install on OKD 4.21 is untested.

## Also worth a maintainer's attention (separate finding, same catalog)

`cluster-logging` regressed between catalog tags: `:4.20` alpha head is `v6.5.0-2026-06-04`, `:4.21` alpha head is
`v6.3.0-2025-08-08` — older by two minors and ten months. Consistent with the still-open
`okderators-catalog-index#44`. Filed as context in the companion issue draft, not fixed here.
