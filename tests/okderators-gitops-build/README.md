# okderators GitOps 1.22: in-cluster build Job

A one-off Job that runs okd-operator-pipeline's own `gitops/build.sh` on this cluster and pushes
the images and the bundle to zot under `okd-test/`. Container builds do not run on the Mac (arm64;
the images have to install on the amd64 nodes, CLAUDE.md "Container image builds run on the
cluster"). This is the GitOps counterpart of `tests/okderators-logging-build/`: same Job shape,
same contract lines, same log persistence, same push guards. What differs is listed
[below](#what-differs-from-the-logging-job).

Not ArgoCD-managed. The operator applies, runs and deletes everything in this directory.
Chronology and results: `blog/blog-okderators-gitops-1.22-draft.md`.

**Shared namespace.** This directory creates only the ConfigMap `gitops-build-scripts`. The
namespace `okd-build`, ServiceAccount `builder`, the privileged RoleBinding and PVC `build-storage`
are owned by `tests/okderators-logging-build/manifests.yaml` and already exist. If the namespace is
ever gone, apply the logging directory first (`oc apply -k tests/okderators-logging-build/`, which
also creates its own `build-scripts` ConfigMap), then this one. `oc delete -k` here removes only the
ConfigMap; deleting the namespace and PVC is `oc delete -k tests/okderators-logging-build/`.

## Files

| file | what |
|---|---|
| `kustomization.yaml` | ConfigMap `gitops-build-scripts` (no hash suffix), generated from `build.sh`, `catalog-edit.sh` and `catalog-walk.py` |
| `build.sh` | the Job's entry point, mounted at `/scripts/build.sh` |
| `catalog-edit.sh` | `MODE=catalog`: the okderators catalog edit, its checks and the test catalog image ([below](#modecatalog)) |
| `catalog-walk.py` | the upgrade-graph walker `catalog-edit.sh` runs (Python 3, standard library only); this copy adds `--hop FROM TO` |
| `job-template.yaml` | OpenShift Template for one run: Job `gitops-build-<MODE>-<DATE>` |
| `log-reader.yaml` | read-only pod `gitops-log-reader` for the log files on the PVC once a build pod is gone |

## Before each run (operator)

- **zot has at least 5 GiB free**, more for a full run: 12 images plus the bundle (check the
  `PUSHED` bytes of the previous run). In the console (Observe, Metrics):
  `kubelet_volume_stats_available_bytes{namespace="zot",persistentvolumeclaim="data-zot-0"}`.
  A full zot breaks image pulls for the whole cluster.
- **Copy anything you still need from `/work` first.** `MODE=full` and `MODE=catalog` wipe
  `/work/run` (the logging catalog run's diffs and renders are there), and a full run always prunes every
  unused image from the podman graph root (Ruling P2). The
  `/work/logs` contract and log files are never touched.
- **No other run is active** (the `flock` on `/work/.lock` is shared with the logging Job and makes
  a second run end `RESULT FAIL another run holds /work/.lock`).

## Apply, run, read, delete

```bash
# the script ConfigMap (re-run after editing any of the scripts)
oc apply -k tests/okderators-gitops-build/

# one run
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-gitops-build/job-template.yaml \
  -p MODE=full -p DATE=$DATE | oc -n okd-build create -f -

# watch, then pull out the contract lines
oc -n okd-build logs -f job/gitops-build-full-$DATE
oc -n okd-build logs job/gitops-build-full-$DATE | grep -E '^(STEP|DISK|ARGOCD_VERSION|PUSHED|CHECK|RESULT) '

# step durations (STEP times are epoch seconds)
oc -n okd-build logs job/gitops-build-full-$DATE | awk '$1=="STEP" && $3=="START" {s[$2]=$4} $1=="STEP" && $3=="END" {print $2, $4-s[$2] "s"}'
```

For the test build on this OKD 4.21 cluster, from the `main`-based `gitops-1.22` branch, pass the 4.21 payload (the value the pipeline's `release-4.21` branch uses); without it `main`'s default (`5.0.0-okd-scos.0`) applies:

```bash
oc process --local -f tests/okderators-gitops-build/job-template.yaml \
  -p MODE=full -p DATE=$DATE -p OKD_VERSION=4.21.0-okd-scos.10 | oc -n okd-build create -f -
```

`check` takes the `DATE` of the full run whose images it copies: `-p MODE=check -p DATE=<that DATE> -p PIPELINE_BRANCH=<branch>`. It pushes new tags under `check-<branch>/` and refuses to run if any exists, so it runs once per full-run `DATE` and branch; to redo, start a new full run with a new `DATE`.

Cleanup:

```bash
# a finished run (its contract and full log stay on the PVC, see below)
oc -n okd-build delete job gitops-build-full-$DATE

# this directory's ConfigMap
oc delete -k tests/okderators-gitops-build/
```

Test images in zot are deleted by digest once nothing runs on them; the `PUSHED` lines carry the
digests. zot's GC (`gcDelay` 1h, `gcInterval` 24h) then frees the blobs; measure zot again.

```bash
# contract file saved with the log-reader commands below
awk '$1=="PUSHED" {print $2}' gitops-build-full-$DATE.contract | sed 's/:[^:@/]*@/@/' \
  | while read -r ref; do skopeo delete "docker://$ref"; done   # wherever skopeo runs
```

## Reading the logs later

Same mechanism as the logging Job. `build.sh` writes on the PVC:

- `/work/logs/gitops-build-<MODE>-<DATE>.contract`: every contract line, appended synchronously
  before it is printed, including the final `RESULT` (also `RESULT FAIL <step> (terminated)` of a
  deadline kill);
- `/work/logs/gitops-build-<MODE>-<DATE>.log`: everything the run printed, copied by `tee`.

```bash
oc -n okd-build create -f tests/okderators-gitops-build/log-reader.yaml
oc -n okd-build wait --for=condition=Ready pod/gitops-log-reader --timeout=5m
oc -n okd-build exec gitops-log-reader -- ls -l /work/logs
oc -n okd-build exec gitops-log-reader -- cat /work/logs/gitops-build-full-$DATE.contract > gitops-build-full-$DATE.contract
oc -n okd-build exec gitops-log-reader -- cat /work/logs/gitops-build-full-$DATE.log > gitops-build-full-$DATE.log
oc -n okd-build delete pod gitops-log-reader
```

The pod is read-only, sleeps, ends by itself after an hour, and prefers the node of a running build
pod (the PVC is RWO). The log files stay until the PVC is deleted, so copy what the blog draft
needs first. A validation failure (bad `MODE`, `DATE` or `BASE_REGISTRY`) happens before the files
are opened and is in the pod log only.

## Modes

| `MODE` | does |
|---|---|
| `full` | tools, podman setup, **prune**, clone `PIPELINE_BRANCH`, tag check of every image and the bundle, `init`, `build_containers`, `push_containers`, **argocd-version**, `build_bundle`, `deinit`, verify. Each pipeline step is a separate `./build.sh <step>` run of `gitops/build.sh`, the same functions its `main` runs, so each is timed. |
| `check` | no image build. Tag check of every image and bundle tag under `check-<branch>/` (any existing tag ends the run before a push), then `skopeo copy --all` of every built `IMG_*` image of `DATE` from `${BASE_REGISTRY}/gitops/` to `${BASE_REGISTRY}/check-<branch>/gitops/`, then `init`, `build_bundle`, `deinit` against that registry, then verify. For the other pipeline branches. |
| `catalog` | tools, podman setup, tag check of `${BASE_REGISTRY}/gitops-catalog:<DATE>`, `/scripts/catalog-edit.sh` in an empty `/work/run`: the 1.22 entry added to each okderators catalog branch in `CATALOG_BRANCHES`, `opm validate`, graph walk with first-hop assertions, two negative controls, then the test catalog image. Its `CHECK` lines go into the contract, a `CHECK ... FAIL` or a non-zero exit fails the run, and `build.sh` prints `PUSHED` for the catalog image. [Details below](#modecatalog). |

`./build.sh update` never runs (it moves the gitlinks to branch tips).

**prune (Ruling P2, amended).** `MODE=full` always starts with `DISK`, `podman system prune -af`, `DISK`,
whatever is free. Nothing on the PVC needs keeping, and the command cannot be scoped to some images,
so it removes every unused one (the logging run left about 37 GB of layers). The hosted-runner
comparison is `peak = max(DISK)` over the run's contract lines after that prune: it approximates a
fresh runner because the base layers are pulled again. The stop rule is peak > 14 GB.

**argocd-version (Ruling P4).** After `push_containers`, the built Argo CD image runs
`argocd version --client --short` (`podman run --rm --entrypoint argocd <IMG_ARGOCD>`; plain
`--client` is the fallback). The first `vX.Y.Z` in the output becomes the contract line
`ARGOCD_VERSION <version>`; `CHECK argocd-version` passes only for exactly `v3.5.5` (`EXPECTED_ARGOCD_VERSION` at the top of `build.sh`), and a different or missing version is a `FAIL` that ends the
run `RESULT FAIL` after verify. Only `full` has the image locally, so `check` does not report it.

## Parameters

| parameter | default | meaning |
|---|---|---|
| `MODE` | required | `full`, `check` or `catalog` |
| `DATE` | required | `YYYY-MM-DD-HHMMSS`; the image tags end in `<MAJOR>.<MINOR>.0-<DATE>`. New for every full run. |
| `PIPELINE_REPO` | `https://github.com/sudoom/okd-operator-pipeline.git` | |
| `PIPELINE_BRANCH` | `gitops-1.22` | |
| `BASE_REGISTRY` | `zot.apps.okd.sudops.pl/okd-test` | anything outside `zot.apps.okd.sudops.pl/okd-test` is refused |
| `CATALOG_BRANCHES` | empty | `catalog` only: okderators-catalog-index branches, e.g. `release-4.21 release-4.22`; must include `release-4.21` (the test catalog's source) |
| `OKD_VERSION` | empty (pipeline default) | which OKD release payload the haproxy-router and must-gather images come from; exported to `gitops/build.sh`, where `common.sh` reads `${OKD_VERSION:-...}` (empty counts as unset). Logged as `INFO OKD_VERSION=`; the resolved image refs show in the `INFO var IMG_...` lines |
| `BUNDLES` | empty | `catalog` only: the one bundle ref, as the full run's `PUSHED` line prints it |

## Output contract

Free-form output (the pipeline's `set -x` trace, `INFO`, `ERROR`) is interleaved with these lines in
the pod log and the `.log` file; the `.contract` file holds only these lines:

| line | meaning |
|---|---|
| `STEP <name> START\|END <seconds>` | epoch seconds; the duration is END minus START |
| `DISK <bytes>` | `du -sx` of `/var/lib/containers` + `/work`, after every step, and around the prune; `max(DISK)` after the prune is the run's peak |
| `ARGOCD_VERSION <version>` | `full` only, see above |
| `PUSHED <ref>@<digest> <bytes>` | after `push_containers` / the `check` copy and after `build_bundle`; in `catalog`, for the catalog image. Digest = sha256 of the manifest bytes zot serves; bytes = config + layer sizes in that manifest |
| `CHECK <name> PASS\|FAIL <detail>` | verify, below; in `catalog`, the checks of [MODE=catalog](#modecatalog) |
| `RESULT PASS\|FAIL <reason>` | the last line; on an error or SIGTERM the reason is the step that was running |

## Verify

After the bundle is pushed, `opm render <bundle repo>@<digest>` for every `IMG_BUNDLE*` image:

| check | passes when |
|---|---|
| `csv/<pkg>` | package `gitops-operator`, CSV name `gitops-operator.v<MAJOR>.<MINOR>.0-<DATE>` and `spec.version` `<MAJOR>.<MINOR>.0-<DATE>` (the name `catalog-edit.sh` expects) |
| `max-openshift-version/<pkg>` | always PASS; reports `olm.maxOpenShiftVersion` (the pipeline sets none for gitops, and the 1.19 bundle in the catalog has none) |
| `images/<pkg>` | every `relatedImages[].image` and every `RELATED_IMAGE_*` / `*_IMAGE` env value in the CSV is `${BASE_REGISTRY}/...@sha256:...`, or one of the external images `gitops/build.sh` names (below) |
| `images-built/<pkg>` | each of those `${BASE_REGISTRY}` references is a digest this run pushed or copied |
| `external-images/<pkg>` | printed (PASS) when the bundle carries external images, with the exact references |
| `branding/<pkg>` | no `valid-subscription` anywhere and no `support` annotation naming Red Hat. Other "Red Hat" text is counted and sampled in the detail but does not fail: there is no accepted baseline for the gitops CSV yet, so the first full run sets it (the logging Job keeps one in `BRANDING_BASELINE`) |
| `provider/<pkg>` | `spec.provider.name` is `OKD Community` |
| `no-redhat-registry/<pkg>` | the whole serialised CSV has no match (any case) for `registry.redhat.io`, `registry-proxy.engineering.redhat.com` or `brew.registry` |
| `skip-range/<pkg>` | CSV annotation `olm.skipRange` is exactly `>=1.0.0 <1.22.0-<DATE>` |
| `no-replaces/<pkg>` | CSV `spec.replaces` is unset (the catalog entry carries `replaces`) |
| `argocd-version` | `full` only, see above; exactly `v3.5.5` |

The image list is never written down here: `build.sh` sources the cloned `gitops/build.sh` and reads
every `IMG_*` variable, so it follows the pipeline when the list changes. Names matching
`IMG_(KUBE_RBAC_PROXY|HAPROXY_ROUTER|REDIS)` are the external ones (`quay.io/okd/scos-content`
payload images and `quay.io/sclorg/redis-*`): never pushed, accepted in the bundle by their exact
digest (or, for a tag such as redis, by repository plus a digest). Any other `IMG_*` outside
`${BASE_REGISTRY}/gitops` is `RESULT FAIL`. Any verify `FAIL` ends the run `RESULT FAIL`.

## MODE=catalog

Adds the 1.22 bundle of a full run to the okderators catalog branches, proves the upgrade graph, and
builds the test catalog image for the homelab's GitOps test CatalogSource (a later step).

```bash
DATE=$(date -u +%Y-%m-%d-%H%M%S)      # new for the catalog run; it only names the image tag
oc process --local -f tests/okderators-gitops-build/job-template.yaml \
  -p MODE=catalog -p DATE=$DATE \
  -p CATALOG_BRANCHES='release-4.21 release-4.22' \
  -p BUNDLES='<operator-bundle ref@digest>' | oc -n okd-build create -f -
oc -n okd-build logs -f job/gitops-build-catalog-$DATE
oc -n okd-build logs job/gitops-build-catalog-$DATE | grep -E '^(STEP|PUSHED|CHECK|RESULT) '
```

`BUNDLES` is the `PUSHED` line of the full run's bundle
(`.../gitops/operator-bundle:1.22.0-<DATE>@sha256:...`); the tag is dropped before use (opm v1.74.0
refuses a reference with both a tag and a digest). The package is `gitops-operator` only. Per
branch, in a depth-1 clone of `okd-project/okderators-catalog-index`:

1. Channel `alpha` has exactly one head and it is `gitops-operator.v1.19.0-2026-02-07-151505` (what
   the homelab runs); any other head stops the run, so a catalog that moved on is not edited blind.
2. The bundle goes in with the branch's own `hack/add-bundle.sh`; if that fails (it `podman create`s
   a `FROM scratch` bundle, okderators-catalog-index PR #59) the same file is written with
   `opm render`.
3. `yq` appends one entry: `name: gitops-operator.v1.22.0-<DATE>`,
   `replaces: gitops-operator.v1.19.0-2026-02-07-151505`,
   `skipRange: '>=1.19.0-0 <1.22.0-<DATE>'`. The `-0` is needed: the installed 1.19.0 is a
   prerelease and `>=1.19.0` would exclude it.

| check | passes when |
|---|---|
| `bundle-version` | once, before any branch: the bundle is package `gitops-operator`, version `1.22.0-<DATE>`, CSV name `gitops-operator.v<version>` |
| `bundles-<branch>` | adding the bundle created exactly one new file and changed no tracked file |
| `edit-<branch>` | one head before the edit (the one above), the 1.22 CSV not in the channel yet, and the package file changed by exactly the three appended lines |
| `opm-validate-<branch>` | `opm validate catalog` passes on the edited tree |
| `walk-<branch>` | `catalog-walk.py`: every `alpha` entry, and the installed 1.19.0 CSV, reaches the single head by `replaces`, `skips` or `skipRange` edges with no other dead end; the head has the highest version; and the first hops are exact: from `gitops-operator.v1.13.0-2024-08-09-135916` only to the v1.16 entry, from v1.16 only to `v1.19.0-2026-02-07-151505`, from v1.19.0 only to the head |
| `negative-control-<branch>` | a copy where the bundle file is in `catalog/` but the channel has no entry for it fails `opm validate` with an error naming the new CSV |
| `negative-control-skiprange-<branch>` | a copy whose new entry has `skipRange: '>=1.0.0 <version'` still passes `opm validate`, and the walker fails it because 1.13 would jump straight to the head (`hop from ...v1.13... goes to ...v1.16..., ...v1.22...`) |
| `opm-validate-image`, `catalog-image` | the image context (`release-4.21` tree, package `gitops-operator` only) passes `opm validate`; the image, built from that branch's `catalog.Containerfile` with its `FROM quay.io/operator-framework/opm:latest` pinned to the v1.74.0 digest, is pushed, rendered back from zot, and has exactly the one package, the 1.22 head and the same walk. Not built when an earlier check failed |

The push target is fixed in `build.sh`: `${BASE_REGISTRY}/gitops-catalog:${DATE}`, through
`guard_registry` and the tag check, and `catalog-edit.sh` refuses anything outside
`zot.apps.okd.sudops.pl/okd-test/` again. `build.sh` prints `PUSHED` for it also when a later check
failed. Left in `/work/run` until the next run: `<branch>.diff` (the whole edit per branch, for the
catalog PRs), the `render-*.json` files, `catalog-edit.log`, the image context `catalog-image/`.

Test mode runs the same script on a laptop, without the Job, images or podman (bash 3.2 is enough;
`opm` v1.74.0, `yq` v4, `jq` and `git` on PATH). `CATALOG_EDIT_TEST_BUNDLES` points at a directory of
`olm.bundle` YAML documents that replace the add-bundle step; the image context is assembled and
validated but not built:

```bash
# T=<scratch dir>; CAT=<a clone of okderators-catalog-index with an upstream remote>
git init -q --bare $T/mirror.git
git -C $T/mirror.git fetch -q $CAT refs/remotes/upstream/release-4.21:refs/heads/release-4.21 \
  refs/remotes/upstream/release-4.22:refs/heads/release-4.22
mkdir $T/run
RUN_DIR=$T/run CATALOG_REPO=$T/mirror.git CATALOG_BRANCHES='release-4.21 release-4.22' \
  CATALOG_EDIT_TEST_BUNDLES=$T/bundles bash tests/okderators-gitops-build/catalog-edit.sh
```

A test bundle needs `schema: olm.bundle`, `name: gitops-operator.v1.22.0-<DATE>`,
`package: gitops-operator`, `image` and an `olm.package` property with `packageName` and `version`
`1.22.0-<DATE>`.

## What differs from the logging Job

- Runs `gitops/build.sh` (`NAMESPACE=gitops`, registry `<BASE_REGISTRY>/gitops`), single package,
  single bundle; names are `gitops-build-*`: Job, log files, ConfigMap `gitops-build-scripts`,
  Template `okderators-gitops-build`, pod `gitops-log-reader`. The pod labels `okd-build/mode` and
  `okd-build/date` are the same, so a reader's affinity finds either Job's pod.
- `PIPELINE_BRANCH` defaults to `gitops-1.22`.
- Tools: the same pins and checksums as the logging Job (the `/work/tools` and `/work/cache` it
  filled are reused), plus the Fedora package `gettext` for `envsubst`, which `build_bundle` runs. No
  Node or pnpm on the host: the Argo CD and console-plugin UI stages build inside podman.
- Added `prune` (unconditional) and `argocd-version` steps; the tag check covers every image and the bundle, not just
  the operator image, and `check` has one too.
- Verify: no `max-openshift-version` requirement and no Red Hat baseline (see above); `csv/<pkg>`
  and `external-images/<pkg>` are new; there is no loki or passthrough-gateway check.
- `catalog-walk.py` gained `--hop`; `catalog-edit.sh` has one package, one entry, and a different
  pair of negative controls.

## How it runs, and why

Unchanged from the logging Job, which documents it in full: privileged podman in a pod (SCC
`privileged` through the RoleBinding there), one PVC with two `subPath` mounts, pushes to zot
`okd-test/` only with no registry credentials in the pod, one run at a time via `flock`, no tag
pushed twice, `backoffLimit: 0`, 12 h `activeDeadlineSeconds` (a full gitops build compiles seven Go
components and two Node UIs, so raise it in `job-template.yaml` if the first run's step durations
say so), requests 2 CPU / 8 Gi, limits 14 CPU / 48 Gi, podman image pinned by digest. Expect about 3x
longer builds while the `powersave-experimental` Tuned profile pins cores at minimum frequency.
