# okderators cert-manager 1.21: in-cluster build Job

A one-off Job that runs okd-operator-pipeline's own `cert-manager/build.sh` on this cluster (branch
`cert-manager-1.21` of `sudoom/okd-operator-pipeline`), pushes the four images and the bundle to zot
under `okd-test/cert-manager/`, and checks that the bundle is the 1.21 one this cluster can install.
Its second mode (`MODE=catalog`) builds the test catalog from `okderators-catalog-index` `release-5.0`.
Container builds do not run on the Mac (arm64; the images have to install on the amd64 nodes,
CLAUDE.md "Container image builds run on the cluster"). This is the cert-manager counterpart of the
NMState job (`tests/okderators-nmstate-build/`): same Job shape, same contract lines, same log
persistence, lock, prune and push guards. What differs from the NMState job is listed [at the end](#what-differs-from-the-nmstate-job).

Not ArgoCD-managed. The operator applies, runs and deletes everything in this directory.
Plan: `docs/superpowers/plans/2026-11-11-okd5-cert-manager.md` (local), Tasks 4 to 7. Chronology and
results: `blog/blog-okderators-cert-manager-draft.md`.

**Shared namespace.** The namespace `okd-build`, ServiceAccount `builder` and the privileged
RoleBinding are persistent and not owned by this directory (they come from
`tests/okderators-logging-build/manifests.yaml`; if the namespace is ever gone, apply that directory
first). This directory carries only its own PVC `cert-manager-build-storage` (`pvc.yaml`, 150Gi
`ceph-nvme-block`, applied with `oc apply -f`) and the ConfigMap `cert-manager-build-scripts`
(`oc apply -k`; `-k` on this directory produces the ConfigMap only). Never `oc delete -k` another
directory, never `oc delete ns okd-build`, never apply another plan's directory.

## Files

| file | what |
|---|---|
| `pvc.yaml` | PVC `cert-manager-build-storage` (150Gi `ceph-nvme-block`, RWO), applied with `oc apply -f`, not part of the kustomization |
| `kustomization.yaml` | ConfigMap `cert-manager-build-scripts` (no hash suffix), generated from `build.sh`, `catalog-edit.sh`, `catalog-walk.py` and `catalog-branches.tsv` |
| `build.sh` | the Job's entry point, mounted at `/scripts/build.sh`; also the laptop's bundle checks ([below](#bundle-checks-on-the-laptop)) |
| `job-template.yaml` | OpenShift Template for one run: Job `cert-manager-build-<MODE>-<DATE>` |
| `catalog-edit.sh` | `MODE=catalog`: the okderators catalog edit, its checks and the test catalog image ([below](#modecatalog)); also runs on the laptop in test mode |
| `catalog-walk.py` | the upgrade-graph walker `catalog-edit.sh` calls; byte-identical to `tests/okderators-nmstate-build/catalog-walk.py` |
| `catalog-branches.tsv` | per catalog branch: `REPLACES` (the channel's last entry the new one replaces) and `INSTALLED` (where the walk starts) |
| `log-reader.yaml` | read-only pod `cert-manager-log-reader` for the log files on the PVC once a build pod is gone |

## Before each run (operator)

The shared rules (`docs/superpowers/plans/2026-11-10-okd5-operators-shared.md`) apply; the plan's
Task 6 Step 1 runs them:

- **One plan's Job phase at a time**, and no build on a day an OKD update runs or while a node
  reboots (`ocr get mcp master` → `3/3/0`).
- **`okd-build` holds no PVC and no Job** at the start of the phase (all Jobs, not a name pattern):
  `KUBECONFIG=~/.kube/config-readonly oc -n okd-build get pvc,job` → `No resources found in okd-build namespace.`
  Anything listed: stop.
- **zot gate**: free ≥ 8 GiB **and** free − the plan's estimate ≥ 5 GiB, read before and after the
  phase and recorded in the ledger. A full zot breaks image pulls for the whole cluster. While
  cert-manager runs from zot images, zot's own route certificate is `okd-wildcard`, which cert-manager
  renews.
- **Copy anything you still need from `/work`.** Both modes wipe `/work/run`, and a full run always
  prunes every unused image from the podman graph root. The `/work/logs` files are never touched.
- The `flock` on `/work/.lock` guards this PVC only; a second run of this Job ends
  `RESULT FAIL another run holds /work/.lock`.

## Apply, run, read, delete

```bash
# the build PVC, then the script ConfigMap (re-apply -k after editing any file it is generated from)
oc apply -f tests/okderators-cert-manager-build/pvc.yaml
oc apply -k tests/okderators-cert-manager-build/

# the full run (plan Task 6); the pins are the ones Task 3 recorded
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-cert-manager-build/job-template.yaml -p MODE=full \
  -p PIPELINE_REPO=https://github.com/sudoom/okd-operator-pipeline -p PIPELINE_BRANCH=cert-manager-1.21 \
  -p OPERATOR_COMMIT=157e4aa1fd03e5e34ec0e6533555c94b98d729be \
  -p CERT_MANAGER_COMMIT=925c22283de556172d48d96a165dc2fa27f7a6ff \
  -p DATE=$DATE | oc -n okd-build create -f -

# watch (read-only), then pull out the contract lines
KUBECONFIG=~/.kube/config-readonly oc -n okd-build logs -f job/cert-manager-build-full-$DATE \
  | grep -E '^(STEP|DISK|PUSHED|EXTERNAL|CHECK|RESULT) '

# step durations (STEP times are epoch seconds)
KUBECONFIG=~/.kube/config-readonly oc -n okd-build logs job/cert-manager-build-full-$DATE \
  | awk '$1=="STEP" && $3=="START" {s[$2]=$4} $1=="STEP" && $3=="END" {print $2, $4-s[$2] "s"}'
```

The catalog run (plan Task 7), once the full run has printed its bundle `PUSHED` line
([MODE=catalog](#modecatalog)):

```bash
DATE2=$(date -u +%Y-%m-%d-%H%M%S)      # new for the catalog run; it only names the image tag
oc process --local -f tests/okderators-cert-manager-build/job-template.yaml -p MODE=catalog -p DATE=$DATE2 \
  -p CATALOG_BRANCHES=release-5.0 -p IMAGE_BRANCH=release-5.0 \
  -p BUNDLES='release-5.0=zot.apps.okd.sudops.pl/okd-test/cert-manager/operator-bundle:1.21.0-<DATE>@sha256:<bundle digest>' \
  | oc -n okd-build create -f -
KUBECONFIG=~/.kube/config-readonly oc -n okd-build logs -f job/cert-manager-build-catalog-$DATE2 \
  | grep -E '^(STEP|PUSHED|CHECK|RESULT) '
```

Cleanup, by name, at the end of the Job phase (plan Task 7):

```bash
# each run's Job, with that run's own DATE (a full run and a catalog run have different DATEs)
oc -n okd-build delete job cert-manager-build-full-<DATE> cert-manager-build-catalog-<DATE2> --ignore-not-found
oc -n okd-build delete pod cert-manager-log-reader --ignore-not-found
oc -n okd-build delete pvc cert-manager-build-storage                               # the logs go with it
```

The ConfigMap `cert-manager-build-scripts` stays at the end of the Job phase (plan Task 7 Step 4), like
the other build Jobs' ConfigMaps in `okd-build`; it is not part of this cleanup.

Test images in zot are deleted by digest once nothing runs on them and the plan says they go; the
`PUSHED` lines carry the digests. zot's GC (`gcDelay` 1h, `gcInterval` 24h) then frees the blobs;
measure zot again.

```bash
# contract file saved with the log-reader commands below
awk '$1=="PUSHED" {print $2}' cert-manager-build-full-$DATE.contract | sed 's/:[^:@/]*@/@/' \
  | while read -r ref; do skopeo delete "docker://$ref"; done   # wherever skopeo runs
```

## Reading the logs later

`build.sh` writes on the PVC:

- `/work/logs/cert-manager-build-<MODE>-<DATE>.contract`: every contract line, appended synchronously
  before it is printed, including the final `RESULT` (also `RESULT FAIL <step> (terminated)` of a
  deadline kill);
- `/work/logs/cert-manager-build-<MODE>-<DATE>.log`: everything the run printed, copied by `tee`.

```bash
oc -n okd-build create -f tests/okderators-cert-manager-build/log-reader.yaml
oc -n okd-build wait --for=condition=Ready pod/cert-manager-log-reader --timeout=5m
oc -n okd-build exec cert-manager-log-reader -- ls -l /work/logs
oc -n okd-build exec cert-manager-log-reader -- cat /work/logs/cert-manager-build-full-$DATE.contract > cert-manager-build-full-$DATE.contract
oc -n okd-build exec cert-manager-log-reader -- cat /work/logs/cert-manager-build-full-$DATE.log > cert-manager-build-full-$DATE.log
oc -n okd-build delete pod cert-manager-log-reader
```

`oc exec` is the operator's (a `!` one-liner). The pod is read-only, sleeps, ends by itself after an
hour, and prefers the node of a running build pod (the PVC is RWO). A validation failure (bad `MODE`,
`DATE`, `BASE_REGISTRY` or commit hash) happens before the files are opened and is in the pod log only.

## Modes

| `MODE` | does |
|---|---|
| `full` | tools, podman setup, **prune**, clone `PIPELINE_BRANCH`; there, before any build: `cert-manager/build.sh` must build `1.21` with `OCP_DATE` `1.21.0-<DATE>` and push under `<BASE_REGISTRY>/cert-manager`, **gitmodules-branch**, and the two gitlinks must equal `OPERATOR_COMMIT` / `CERT_MANAGER_COMMIT` (else `RESULT FAIL pins: ...`); tag check of every image and the bundle; `init`; the source checks **operator-commit**, **cert-manager-commit**, **patch-applied**, **feature-defaults** (any FAIL ends the run before the build); `build_containers`, `push_containers`, `build_bundle`, `deinit`, verify. Each pipeline step is a separate `./build.sh <step>` run of `cert-manager/build.sh`, the same functions its `main` runs, so each is timed |
| `catalog` | tools, podman setup, tag check of the catalog image, then `catalog-edit.sh` ([MODE=catalog](#modecatalog)); its `CHECK` lines go into the contract. The push target is fixed here: `${BASE_REGISTRY}/cert-manager-catalog:${DATE}` |

`./build.sh update` never runs (it moves the gitlinks to branch tips).

**prune.** `MODE=full` always starts with `DISK`, `podman system prune -af`, `DISK`. Nothing on the PVC
needs keeping, and the command cannot be scoped to some images. The run's peak is `max(DISK)` after
that prune.

## Parameters

| parameter | default | meaning |
|---|---|---|
| `MODE` | required | `full` or `catalog` |
| `DATE` | required | `YYYY-MM-DD-HHMMSS`, new for every run; in `full` the tags are `1.21.0-<DATE>` and the CSV `cert-manager-operator.v1.21.0-<DATE>`, in `catalog` it is the catalog image's tag |
| `PIPELINE_REPO` | `https://github.com/sudoom/okd-operator-pipeline` | |
| `PIPELINE_BRANCH` | empty | `full` only, required there: `cert-manager-1.21` |
| `OPERATOR_COMMIT` | empty | `full` only, required: the `cert-manager/operator` gitlink the branch must record, 40 hex (`157e4aa1fd03e5e34ec0e6533555c94b98d729be`, operator `master` at the #538 merge) |
| `CERT_MANAGER_COMMIT` | empty | `full` only, required: the `cert-manager/cert-manager` gitlink, 40 hex (`925c22283de556172d48d96a165dc2fa27f7a6ff`, tag `v1.21.3`) |
| `BASE_REGISTRY` | `zot.apps.okd.sudops.pl/okd-test` | anything outside `zot.apps.okd.sudops.pl/okd-test` is refused; images land in `<BASE_REGISTRY>/cert-manager/{operator,cert-manager,acme-solver,istio-csr,operator-bundle}` |
| `OKD_VERSION` | empty | leave empty: `cert-manager/build.sh` sets `MAJOR=1 MINOR=21` itself, so this only names the payload `common.sh` reads with `oc adm release info` when sourced |
| `CATALOG_BRANCHES` | empty | `catalog` only: `release-5.0` |
| `BUNDLES` | empty | `catalog` only: `release-5.0=<bundle ref@sha256:...>`, the full run's bundle `PUSHED` ref |
| `IMAGE_BRANCH` | `release-5.0` | `catalog` only: the branch whose edited tree becomes the test catalog image; must be in `CATALOG_BRANCHES` |

## Output contract

Free-form output (the pipeline's `set -x` trace, `INFO`, `ERROR`) is interleaved with these lines in
the pod log and the `.log` file; the `.contract` file holds only these lines:

| line | meaning |
|---|---|
| `STEP <name> START\|END <seconds>` | epoch seconds; the duration is END minus START |
| `DISK <bytes>` | `du -sx` of `/var/lib/containers` + `/work`, after every step, and around the prune |
| `PUSHED <ref>@<digest> <bytes>` | after `push_containers` (four images) and after `build_bundle`; in `catalog`, for the catalog image. Digest = sha256 of the manifest bytes zot serves; bytes = config + layer sizes |
| `EXTERNAL <ref>` | an image the CSV references that this Job does not build (trust-manager, approver-policy), by digest |
| `CHECK <name> PASS\|FAIL\|INFO\|SKIP <detail>` | the checks below; `INFO` is recorded only; `SKIP` only on the laptop (tool missing) |
| `RESULT PASS\|FAIL <reason>` | the last line; on an error or SIGTERM the reason is the step that was running |

## Verify

| check | when | passes when |
|---|---|---|
| `gitmodules-branch` | after the clone | `.gitmodules` declares `branch = cert-manager-1.21` for `cert-manager/operator` and `release-1.21` for `cert-manager/cert-manager` (`1.21` = `MAJOR.MINOR` of `cert-manager/build.sh`); `istio-csr`'s branch is recorded. A FAIL ends the run there. `.gitmodules` is not what gets built (the gitlink is), which is why the next two exist |
| `operator-commit` | after `init` | in the pipeline tree, `git -C cert-manager/operator rev-parse HEAD~1` = the branch's gitlink for `cert-manager/operator` = `OPERATOR_COMMIT`; `HEAD` is a different commit whose subject is the patch's (`OKDify`, from `patches/operator.patch`); clean tree |
| `cert-manager-commit` | after `init` | `cert-manager/cert-manager` `HEAD` = its gitlink = `CERT_MANAGER_COMMIT`, clean tree, no `patches/cert-manager.patch`. This is what proves the operand version (the CSV's version env carries the build tag, not `v1.21.3`). istio-csr's `HEAD` and gitlink are printed as `INFO` |
| `patch-applied` | after `init` | init's `git am -3` exited 0 (init runs under `set -e`), no `rebase-apply` left, the patch commit changes exactly the files the patch names (`Makefile`, the CSV base), and the CSV base carries `support: OKD Community` and `displayName: cert-manager Operator for OKD` |
| `feature-defaults` | after `init` | the operator's `api/operator/v1alpha1/features.go`: `HTTP01Proxy` `Default: false` (HTTP01Proxy writes a MachineConfig, i.e. a node reroll), and no gate other than `IstioCSR` defaults to true. All gates and defaults are in the detail |
| `bundle-objects` | verify | the bundle's objects by kind and name, both from the bundle image's `manifests/` files and from `opm render`, are exactly: one CSV `cert-manager-operator.v1.21.0-<DATE>`; the 13 CRDs `challenges`/`orders.acme.cert-manager.io`, `certificaterequests`/`certificates`/`clusterissuers`/`issuers.cert-manager.io`, `approverpolicymanagers`/`certmanagers`/`http01proxies`/`istiocsrs`/`trustmanagers.operator.openshift.io`, `certificaterequestpolicies.policy.cert-manager.io`, `bundles.trust.cert-manager.io`; Service `cert-manager-operator-controller-manager-metrics-service`, ClusterRole `cert-manager-operator-metrics-reader`, ConfigMap `cert-manager-operator-trusted-ca-bundle`; one file per object (17). A FAIL names what is missing and what is unexpected, for the files and, separately, for the render |
| `csv-name` | verify | CSV `cert-manager-operator.v1.21.0-<DATE>`, `spec.version` `1.21.0-<DATE>`, the bundle's package annotation `cert-manager-operator`, and in `opm render` the same package and `olm.package` version. The bundle's channels annotation is printed as `INFO` (the catalog entry decides the channel) |
| `skiprange` | verify | `olm.skipRange` `>=1.0.0 <1.21.0-<DATE>`, no `replaces`, no `skips` (what `cert-manager/build.sh` writes; the catalog entry carries the `replaces` edge) |
| `min-kube` | verify | `minKubeVersion` `1.31.0` |
| `no-max-openshift` | verify | no `olm.maxOpenShiftVersion` anywhere (CSV, bundle files, `opm render`): one would make the cluster report `Upgradeable=False` |
| `version-env` | verify | the CSV env `OPERAND_IMAGE_VERSION`, `ISTIOCSR_OPERAND_IMAGE_VERSION` and `OPERATOR_IMAGE_VERSION` are each `1.21.0-<DATE>`, which is what the pipeline writes. The other `*_VERSION` env values (trust-manager, approver-policy) are printed as `INFO` |
| `images-by-digest` | verify | every `relatedImages` entry (CSV and `opm render`), every deployment container image, every `RELATED_IMAGE_*` / `*_IMAGE` env value and the `containerImage` annotation is `@sha256:`; refs under `<BASE_REGISTRY>/cert-manager/` are digests this run pushed, and each of the four pushed images is referenced. The only other refs allowed are `quay.io/jetstack/trust-manager@sha256:...` and `quay.io/jetstack/cert-manager-approver-policy@sha256:...`: the operator's own defaults, which `cert-manager/build.sh` does not replace; each is printed as an `EXTERNAL` line and named in the detail, and both are **required**, each by exactly one digest (absent = FAIL `external missing`). `opm render` lists the bundle image itself in the olm.bundle's `relatedImages`; that one exact ref (the bundle's `repo@digest` this run pushed) is dropped from the render's list only, so the bundle under another digest, or anywhere in the CSV, still fails |
| `no-redhat-registry` | verify | no `registry.redhat.io`, `registry-proxy.engineering.redhat.com` or `brew.registry` (any case) in the CSV, the rendered objects, the bundle image's files or its labels |
| `install-modes` | verify | `AllNamespaces` supported (the homelab `OperatorGroup` is `spec: {}`); all modes recorded |
| `machineconfig-permission` | verify | `INFO` only: whether the CSV's `clusterPermissions` include `machineconfigs`, with the verbs (the 1.21 operator has them for HTTP01Proxy; plan Review Focus 1) |
| `operator-sdk-validate` | verify | `operator-sdk bundle validate <bundle files> -o json-alpha1` (v1.36.1, default validators) exits 0 with `passed: true`; warnings counted and printed as `INFO` |

The image list is never written down here: `build.sh` sources the cloned `cert-manager/build.sh` and
reads every `IMG_*` variable (`IMG_OPERATOR`, `IMG_CERT_MANAGER`, `IMG_ACME_SOLVER`, `IMG_ISTIO_CSR`,
`IMG_BUNDLE`). Any `IMG_*` outside `<BASE_REGISTRY>/cert-manager` is `RESULT FAIL` before anything is
built. Any `FAIL` ends the run `RESULT FAIL`.

## Bundle checks on the laptop

The verify checks (`bundle-objects` to `operator-sdk-validate`) use plain variables and bash 3.2, so
they run on the Mac against any extracted bundle, with the expectations given in `CHECK_*`. The
extraction is the Job's own `bundle_extract` (`skopeo copy` to a `dir:` layout, layers unpacked into
`<dir>/fs`). `jq`, `yq` v4 and `skopeo` are needed; without `opm` the render parts are reported as
`not run`, without `operator-sdk` that check is `SKIP`. Registry reads run outside the Bash sandbox
(its proxy breaks TLS).

```bash
B=tests/okderators-cert-manager-build/build.sh; W=$T/b120          # T = a scratch directory
bash $B extract-bundle quay.io/okderators/cert-manager/operator-bundle:1.20.0-2026-10-22-132146 $W

# 1.21 expectations (the default object list): csv-name, skiprange, version-env, bundle-objects FAIL
CHECK_MINOR=21 CHECK_DATE=2026-11-20-000000 CHECK_REGISTRY=quay.io/okderators/cert-manager \
  CHECK_PUSHED="<repo@digest of operator, cert-manager, acme-solver, istio-csr>" \
  bash $B check-bundle $W/fs $W

# its own expectations: all PASS (operator-sdk-validate SKIP without operator-sdk)
CHECK_MINOR=20 CHECK_DATE=2026-10-22-132146 CHECK_OBJECTS="$(cat <13 Kind/name lines, the 1.20 set>)" \
  CHECK_REGISTRY=quay.io/okderators/cert-manager CHECK_PUSHED="<the same four>" CHECK_EXTERNAL=trust-manager \
  bash $B check-bundle $W/fs $W
```

| variable | default | meaning |
|---|---|---|
| `CHECK_DATE` | required | with `CHECK_MAJOR` (1) and `CHECK_MINOR` (21): the expected version `<MAJOR>.<MINOR>.0-<DATE>` |
| `CHECK_OBJECTS` | the 1.21 list above | the expected objects besides the CSV, `Kind/name`, whitespace-separated |
| `CHECK_REGISTRY`, `CHECK_PUSHED` | empty (then `images-by-digest` fails) | the registry path of the built images, and their `repo@digest` refs (`skopeo inspect --raw docker://<ref> \| shasum -a 256` gives the digest) |
| `CHECK_MIN_KUBE` | `1.31.0` | |
| `CHECK_EXTERNAL` | `trust-manager cert-manager-approver-policy` | the `quay.io/jetstack/<repo>` images the CSV must reference by digest (1.20: `trust-manager` only) |
| `CHECK_BUNDLE_REF` | empty | the bundle's `repo@digest`, dropped from a `render.json`'s `relatedImages` as in the Job |

The second argument is the work directory (`files.json`, `csv.json`, `images.txt`, ...); a
`render.json` from `opm render <ref> -o json` placed there is used as in the Job. The source checks
(`gitmodules-branch` to `feature-defaults`) need the Job's pipeline tree and bash 4.

## MODE=catalog

Appends the full run's bundle to `okderators-catalog-index` `release-5.0`, proves the upgrade graph
from this cluster's CSV, and builds the test catalog image for the homelab's cert-manager test
CatalogSource. Package `cert-manager-operator` only, channel `alpha` (the default and only channel).
Run command: [above](#apply-run-read-delete). `BUNDLES` is the full run's bundle `PUSHED` ref
(`.../cert-manager/operator-bundle:1.21.0-<DATE>@sha256:...`); the tag is dropped before use (opm
v1.74.0 refuses a reference with both a tag and a digest).

`catalog-branches.tsv` holds, per catalog branch (tab-separated, three columns):

| column | meaning |
|---|---|
| `REPLACES` | the `alpha` channel's last entry before the edit, exactly one name; it must also be the channel's single head. The new entry gets `replaces: <REPLACES>` |
| `INSTALLED` | comma-separated CSVs a cluster may run; the walker starts from them too |

`release-5.0` (read 2026-11-20, upstream `72eb5d93b1a7` of 2026-11-08): `alpha` is a `replaces` chain
v1.14.0 → v1.15.0 → v1.18.0 (two builds) → `cert-manager-operator.v1.20.0-2026-10-22-132146`, with no
`skipRange` and no `skips`; that 1.20 build is both `REPLACES` and `INSTALLED` (this cluster's CSV since
2026-10-27). An `edit` FAIL saying the last entry differs means upstream added an entry: re-read the
channel, fix the row, re-run.

Per branch, in a depth-1 clone:

1. The bundle file `catalog/cert-manager-operator/<CSV>.yaml` is written the way `hack/add-bundle.sh`
   writes it: `RENDERED=$(opm render <bundle>@<digest> -o yaml)`, `echo "$RENDERED" > <file>`.
2. Two lines are appended after the last entry of the package file's `alpha` `entries:` block,
   indented like the others: `- name: <CSV>` and `replaces: <REPLACES>`. No `skipRange`, no `skips`:
   the shape of every existing cert-manager entry. `yq` then proves the entries are the old ones plus
   exactly that one, and that with the `alpha` entries emptied the old and new files are the same
   documents; the diff is `+2 -0` lines.

| check | passes when |
|---|---|
| `branch-data-<branch>` | before anything else: one row, no `TO-FILL`, `REPLACES` one name, every name a `cert-manager-operator.v...` CSV name |
| `bundle-<branch>` | before any clone: package `cert-manager-operator`, `olm.package` version `1.21.0-<DATE>`, `olm.bundle` name `cert-manager-operator.v<version>`, exactly one CSV object and it has that name, and (in the Job) `image` is the `BUNDLES` ref |
| `bundles-<branch>` | adding the bundle file is the only change in the clone at that point |
| `edit-<branch>` | before the edit: the channel's last entry is `REPLACES`, `REPLACES` is the single head and has its bundle file, the new CSV is not an entry yet; after it: see 2. |
| `opm-validate-<branch>` | `opm validate catalog` passes on the edited tree (every package of the branch). Before the edit the unedited clone is validated too and its verdict printed as `INFO ... baseline: ...`; a `FAIL` repeats it, so a defect that predates the edit is visible as such |
| `walk-<branch>` | `catalog-walk.py`: the new CSV is the single head with the highest version, and every entry and every `INSTALLED` CSV reaches it with no other dead end |
| `negative-control-replaces-<branch>` | a copy with the new entry's `replaces` removed (two heads), rendered by `yq` (opm render never runs on the broken graph): the walker fails and reports as stranded exactly every older entry and every `INSTALLED` CSV, so the appended edge is the one that carries the upgrade |
| `negative-control-replaces-opm-<branch>` | `opm validate` rejects that copy with `multiple channel heads`; a pass, or a failure for another reason, is `FAIL`. `SKIP` in test mode without `opm` |
| `opm-validate-image`, `catalog-image` | the image context (the `IMAGE_BRANCH` tree, package `cert-manager-operator` only) passes `opm validate`; the image, built from that branch's `catalog.Containerfile` with its `FROM quay.io/operator-framework/opm:latest` pinned to the v1.74.0 digest, is pushed, rendered back from zot, and has exactly the one package, the new head and the same walk. Not built when an earlier check failed |

A `FAIL` in the first two, or `IMAGE_BRANCH` missing from `CATALOG_BRANCHES` (`catalog-image FAIL`,
checked first), stops the run before any clone. A package file without a final newline gets one from
the edit; the `+2 -0` count ignores that (an `INFO` line says so). `catalog-edit.sh` refuses a push target
outside `zot.apps.okd.sudops.pl/okd-test/` on its own too. Left in `/work/run` until the next run:
`release-5.0.diff` (the whole edit), the `render-*.json` files, `catalog-edit.log`, the image context
`catalog-image/`.

**`release-5.0.diff` is not the catalog PR.** Its package-file hunk (two lines, `- name:` and
`replaces:`) is the shape the upstream PR adds, but its bundle file is this test build's: `image` and the
bundle's own `relatedImages` row are the zot digest ref (`zot.apps.okd.sudops.pl/okd-test/...@sha256:...`),
and the official okderators build has its own DATE, so the CSV name, the file name and both package
lines differ too. The PR (plan Task 11) adds the official quay bundle with `hack/add-bundle.sh
<quay.io/okderators/cert-manager/operator-bundle:<tag>>`, as every upstream bundle file is written, and
uses that CSV name in the two package lines; never paste the diff.

Test mode runs the same script on a laptop, without the Job, images or podman (bash 3.2, `yq` v4,
`jq`, `git`, `python3`). `CATALOG_EDIT_TEST_BUNDLES` points at a directory with one `olm.bundle` YAML
file per branch, `<branch>.yaml`, which replaces the bundle render; the image context is assembled but
not built. **Without `opm` (only allowed in test mode):** `opm-validate-<branch>` and
`opm-validate-image` print `CHECK ... SKIP` (never `PASS`), and the catalogs the walker reads are the
FBC files converted by `yq` instead of `opm render`. Outside test mode a missing `opm` is
`ERROR opm is not on PATH` before any check.

```bash
# T=<scratch dir>; mirror the catalog index branch over HTTPS (outside the Bash sandbox)
git init -q --bare $T/mirror.git
git -C $T/mirror.git fetch -q --depth 50 https://github.com/okd-project/okderators-catalog-index.git \
  refs/heads/release-5.0:refs/heads/release-5.0
mkdir -p $T/run $T/bundles     # $T/bundles/release-5.0.yaml: the test bundle, see below
RUN_DIR=$T/run CATALOG_REPO=$T/mirror.git CATALOG_BRANCHES=release-5.0 IMAGE_BRANCH=release-5.0 \
  CATALOG_EDIT_TEST_BUNDLES=$T/bundles bash tests/okderators-cert-manager-build/catalog-edit.sh
```

`RUN_DIR` must be an absolute, existing, empty directory. A test bundle is the catalog's own
`catalog/cert-manager-operator/cert-manager-operator.v1.20.0-2026-10-22-132146.yaml` (opm-rendered
upstream) with the 1.21 test names: `name` and the CSV object's `metadata.name`
`cert-manager-operator.v1.21.0-2026-11-20-000000`, the CSV's `spec.version` and the `olm.package`
version `1.21.0-2026-11-20-000000`.

## What differs from the NMState job

- Runs `cert-manager/build.sh` (`NAMESPACE=cert-manager`, registry `<BASE_REGISTRY>/cert-manager`):
  four images (`operator`, `cert-manager`, `acme-solver`, `istio-csr`) and `operator-bundle`; names
  are `cert-manager-build-*`: Job, log files, ConfigMap `cert-manager-build-scripts`, Template
  `okderators-cert-manager-build`, pod `cert-manager-log-reader`, PVC `cert-manager-build-storage`. The
  pod labels `okd-build/mode` and `okd-build/date` are the same, so a reader's affinity finds any build
  Job's pod.
- New parameters `OPERATOR_COMMIT` and `CERT_MANAGER_COMMIT`: the pins are inputs, checked against the
  branch's gitlinks before any build. `cert-manager/build.sh` hardcodes `MAJOR=1 MINOR=21`, so
  `OKD_VERSION` names nothing; the run fails if the branch builds another release.
- No external `IMG_*` (no payload `kube-rbac-proxy`); the CSV's external images are trust-manager and
  approver-policy from `quay.io/jetstack`, by digest, listed as `EXTERNAL`.
- Checks: the NMState job's handler-RPM check, `csv-code-release` and `no-imagestream` are gone; `operator-commit` now expects
  the patch commit on top of the gitlink (the cert-manager pipeline patches the operator); new are
  `cert-manager-commit`, `patch-applied`, `feature-defaults`, `skiprange`, `min-kube`,
  `no-max-openshift`, `version-env` and `machineconfig-permission`; `bundle-objects` expects 17 objects.
  The four source checks run right after `init` and stop the run before the build on a FAIL.
- The verify checks are bash 3.2 code with plain-variable inputs, callable on the laptop
  (`extract-bundle`, `check-bundle`). The traps are installed in `main`, so the laptop commands do not
  print a `RESULT FAIL` on exit.
- `IMAGE_BRANCH` defaults to `release-5.0`; the catalog image is `cert-manager-catalog:<DATE>`.
- `catalog-edit.sh` appends one entry with `replaces` (the NMState job's removed the broken entries and
  added one with `skips` and a `skipRange`); `catalog-branches.tsv` has `REPLACES` and `INSTALLED` instead
  of `REMOVE`, `SKIPS` and templated `INSTALLED`; the bundle check is on the three names, not a fixed
  object list (the full run checks the objects); the ImageStream check and its control are gone, and
  the negative control removes the new entry's `replaces` instead of its `skipRange`. Without `opm`,
  test mode reports the opm checks `SKIP`. `catalog-walk.py` is unchanged (its `--hop` is unused here).
- Tools: the same pins and checksums (`/work/tools` and `/work/cache` are per PVC, so this PVC fills
  them again). The operator's Makefile fetches its own operator-sdk, controller-gen and kustomize for
  `make bundle` into its `bin/`; the pinned operator-sdk v1.36.1 only validates. Go 1.26.10 covers the
  operator's `go 1.26.0`.

## How it runs, and why

Unchanged from the logging Job, which documents it in full: privileged podman in a pod (SCC
`privileged` through the RoleBinding there), one PVC with two `subPath` mounts, pushes to zot
`okd-test/` only with no registry credentials in the pod, one run at a time via `flock`, no tag
pushed twice, `backoffLimit: 0`, 12 h `activeDeadlineSeconds`, requests 2 CPU / 8 Gi, limits
14 CPU / 48 Gi, podman image pinned by digest. A full cert-manager build is the operator, four
cert-manager binaries built twice (the `cert-manager` and `acme-solver` Containerfiles each build all
four), and istio-csr, all with `CGO_ENABLED=1` on `ubi9/go-toolset:1.26`. Expect about 3x longer
builds while the `powersave-experimental` Tuned profile pins cores at minimum frequency.
