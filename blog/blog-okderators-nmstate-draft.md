# okderators NMState: a bundle OKD's OLM accepts, and this cluster on it

I run NMState on this cluster from the OperatorHub.io catalog (v0.87.0). It needs three local RBAC workarounds and its
metrics have never reached Prometheus. okderators (okd-project) ships NMState for OKD, but every catalog bundle of it
is broken, so I am fixing the build chain upstream (okd-operator-pipeline plus okderators-catalog-index) and moving
this cluster onto the result, the same way as for logging 6.6 and GitOps 1.22: build on the cluster, install a test
build, soak, then draft PRs with that as proof. This file is the chronology.

## 2026-10-23: design decisions

Why, in the operator's words: "the RBAC workarounds and the broken metrics" and "my intention to improve okderators".
Scope: pipeline `main`, `release-4.22`, `release-4.21`, `release-4.20`; catalogs 4.20, 4.21, 4.22. The release-4.22 PR
is filed together with the rest although this cluster only uses it after the OKD 4.22 hop.
Testing: "yes, it should be tested on the cluster" - every branch is built and checked here, only the 4.21 build is
installed.
Downgrade: v0.87.0 to the okderators 4.21 code (about upstream v0.85.1) - "yes, ok with downgrade".
Backnet: the handler re-applies every NNCP on start, so a short blip on the Ceph storage network is possible, one node
at a time and watched - "yes its acceptable".
Method: "i want to use the same approach as for logging".
4.22 catalog route: keep the deploy workflow's bot catalog PR, pointed at catalog `release-4.22` (`catalog_branch:
release-4.22`), and follow up on the bot's PR with our entry change.
Later in-place handler changes (test build to official 4.21, 4.21 to 4.22 after the hop): a watched rolling update, not
gated per node; per-node gating applies to the initial switch only.

## 2026-10-23: recon summary (read-only; all of it re-derivable from the sources)

Why the okderators bundle fails: pipeline PR #19 was meant to drop the ImageStream from the bundle. Upstream
`hack/ocp-update-bundle-manifests.sh` (line 63) writes it as the extensionless `manifests/stable/manifests/image-references`;
#19's `find manifests/stable -name '*.yaml'` never matches it, so the bundle still ships `kind: ImageStream`, which
OKD's OLM rejects (`UnsupportedResource`, okderators-catalog-index#45). Also: the 4.22 catalog bundle is built from
4.20 code (pipeline `release-4.22` gitlinks are 4.20 commits, `.gitmodules` says release-4.21), and the 4.21 bundle
from a 4.20 gitlink that only supports OwnNamespace/SingleNamespace, while this cluster's OperatorGroup is
AllNamespaces. The 4.21 code at `3af39b8` does support AllNamespaces. Both "Deploy NMState" runs failed before the bundle
step (main 2026-09-23; release-4.21 2026-10-22 on a quay push permission only the maintainers can grant).

What the okderators code already fixes vs community v0.87.0 (source.md): handler SCC `use` in the ClusterRole
(`IsOpenShift` hardcoded true), the `apiservers` read (not needed on 4.21, granted on 4.22), the `prometheus-k8s`
RoleBinding subject (`MONITORING_NAMESPACE=openshift-monitoring`), and the metrics NetworkPolicies.

Metrics root cause on community v0.87.0: `allow-metrics-ingress-8443` / `-443` NetworkPolicies
(`deploy/handler/network_policy.yaml`, lines 37-77) allow ingress only `from` the namespace `{{ .MonitoringNamespace }}`,
and that is filled from `MONITORING_NAMESPACE`, which the community CSV sets to `monitoring` (upstream Makefile default).
On OKD Prometheus lives in `openshift-monitoring`, so the scrape is dropped by the NetworkPolicy. The restriction
arrived upstream in c9752755 (#1555, 2026-07-21), first in v0.87.0. The `TLS handshake error ... EOF` log lines are the
kubelet's `tcpSocket` probes on the TLS port, about 12/min, cosmetic, and stay on the okderators build too. An
untested alternative on the community build: Subscription `spec.config.env MONITORING_NAMESPACE=openshift-monitoring`.

Switch facts (switch.md): the NMState CR has no finalizer, every operand object (including the MWC, VAP, ClusterRoles,
ConsolePlugin) is garbage-collected through its ownerReference to the CR; CRDs, NNCP/NNCE/NNS and the `nmstate` namespace
survive a CR delete and nothing changes on the nodes. A fresh handler re-applies every NNCP and calls NetworkManager
`Reapply` on every listed interface. The okderators MWC has two webhooks with the default `failurePolicy: Fail`, so
dead webhook pods block NNCP create/update and ArgoCD's dry-run diff. The new operator force-applies PSA `privileged` on
its namespace, so the chart's `restricted` label would ping-pong under selfHeal. There is no OLM edge from v0.87.0
(skipRange `>=4.3.0 <4.21.0`), so the switch is a CSV removal and a resubscribe. Safe order: CR deleted, old operand
gone, old CSV removed, then the new operator sees a new CR. Never disable the root-app entries (`enabled: false`): the
resources-finalizer would cascade-delete the Namespace, the CR and the NNCPs.

## 2026-10-23: Task 1, pins and upstream state

Commands (GitHub reads with `GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN" gh`, sandbox off; git reads in the existing clones
after `git fetch`):

    gh api repos/openshift/kubernetes-nmstate/branches/release-4.21 --jq .commit.sha
    gh api repos/openshift/kubernetes-nmstate/compare/release-4.21...<sha> --jq .status      # identical
    git -C pipeline ls-tree origin/<b> nmstate/operator nmstate/console-plugin
    git -C pipeline show origin/<b>:.gitmodules
    git -C catalog-index show upstream/<b>:catalog/kubernetes-nmstate-operator/kubernetes-nmstate-operator.yaml
    <bundle file> | python3 -I decode.py        # base64-decode every olm.bundle.object, list kinds

Upstream heads to pin (all six `compare ... = identical`):

| branch | kubernetes-nmstate | nmstate-console-plugin |
|---|---|---|
| release-4.20 | 6ecae5d514c0c1b76f452ec0af37c49d17b0c79e (2026-08-26) | 29b58cee99e828f4d87133125e2b901ddb0ad310 (2026-10-21) |
| release-4.21 | bc318d1723e2977b55007d84f877f97b2960709d (2026-10-12) | f280b31233a23be26f3f7aeede6b268b06d127ef (2026-10-21) |
| release-4.22 | 1d6d332026b97b6e48d1aff79ad442f9f0a86bd6 (2026-10-12) | 25b8f8153e3f32a913b809bf70a9cb03eb4c3bfa (2026-10-20) |

Pipeline gitlinks today (operator / plugin / `.gitmodules` branch):

| pipeline branch | operator | plugin | branch in .gitmodules |
|---|---|---|---|
| main | fffb76d | c5a1971 | release-5.0 |
| release-4.22 | b29ee7b | 0fd2bc0 | release-4.21 |
| release-4.21 | 3af39b8 | 3a7e261 | release-4.21 |
| release-4.20 | b29ee7b | 0fd2bc0 | release-4.20 |

release-4.22 carries release-4.20 commits (operator 8 behind release-4.20, plugin 47 behind); release-4.21's operator
is 2 commits and its plugin 30 commits behind the 4.21 heads. `nmstate/build.sh` is byte-identical on main, 4.21 and
4.22 (blob 42fe10c); release-4.20's is older (e2512c1), with no ImageStream line.

The failing state, decoded from the catalogs (`upstream/release-4.2x`, catalog/kubernetes-nmstate-operator/):

    release-4.20: kubernetes-nmstate-operator.v4.20.0-2025-12-27-212436  CRD nmstates.nmstate.io, ImageStream, CSV
    release-4.21: kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851  CRD nmstates.nmstate.io, ImageStream, CSV
    release-4.22: kubernetes-nmstate-operator.v4.22.0-2025-12-14-152353  CRD nmstates.nmstate.io, ImageStream, CSV

All three CSVs carry skipRange `>=4.3.0 <4.20.0` and installModes OwnNamespace and SingleNamespace only. The 4.22 bundle's
CSV `createdAt` is 2026-06-23 (a 4.20-content build under a December name). Channel `alpha` entries: 4.20 has the one
bundle; 4.21 has its bundle skipping `...v4.20.0-2025-12-27-212436`; 4.22 has its bundle skipping
`...v4.21.0-2026-05-05-165851`.

Finding that changes the recon: anonymous pulls from `registry.ci.openshift.org` work, the earlier 401 was a missing
token step. `GET /v2/` returns `WWW-Authenticate: Bearer realm="https://registry.ci.openshift.org/openshift/token"`
(no service), `GET <realm>?scope=repository:origin/scos-<v>:pull` returns a token, and then the manifest GET returns
200 for `scos-4.20`, `4.21`, `4.22` and `5.0` `:base-stream9`. amd64 digests: 4.20 sha256:7e75ff82..., 4.22
sha256:b24cab40..., 5.0 sha256:651b9784...; 4.21 is a single schema2 manifest (sha256:d286077d...), architecture not
confirmed from here. `ubi9/go-toolset:1.25` is a manifest list with amd64 sha256:0706c592....

`release-4.20` has `.github/workflows/operator-deploy.yaml` (`workflow_call`, inputs `operator` and `base_registry`) and
no `nmstate-deploy.yaml`. `deploy/handler/namespace.yaml` at the release-4.21 head (identical to the current gitlink's):
annotation `openshift.io/node-selector: ""`; labels `name`, PSA `enforce`/`audit`/`warn` = `privileged`, and
`openshift.io/cluster-monitoring: "true"` (annotation and monitoring label are under `IsOpenShift`, hardcoded true).
Full table with every 40-character SHA: pins.md in the session scratchpad.

## 2026-10-23 — the ImageStream fix

`nmstate/build.sh` removes the ImageStream with `find manifests/stable -name '*.yaml' -exec grep -l 'kind: ImageStream' {} \; | xargs rm -f`. Upstream `hack/ocp-update-bundle-manifests.sh:63` writes it with `cat > ${BUNDLE_DIR}/manifests/image-references <<EOF` — no extension — so the find never matched. Wrote a fixture test (`imagestream-test.sh <build.sh>`) that builds `manifests/stable/manifests/{image-references, ...clusterserviceversion.yaml, nmstate.io_nmstates.yaml}`, extracts the removal line (between `# Remove ImageStream` and `podman build`), runs it, and asserts.

Failing, against origin/main:

    removal command under test: find manifests/stable -name '*.yaml' -exec grep -l 'kind: ImageStream' {} \; | xargs rm -f
    FAIL: image-references still present

New line (content match, `-delete` is in both GNU and BSD find, exits 0 on no match, no xargs):

    find manifests/stable/manifests -type f -exec grep -q '^kind: ImageStream' {} \; -delete

Passing:

    case with-ImageStream: exit=0
    case without-ImageStream: exit=0
    PASS

`bash -n nmstate/build.sh` clean. Against release-4.20's build.sh (no removal line) the test fails with "no ImageStream removal line". Commit on pipeline branch `nmstate-bundle-fix`: a005aed `[nmstate] Remove the ImageStream from the bundle` (not pushed).

## 2026-10-23 — release branches

The ImageStream fix lives on `nmstate-bundle-fix` (a005aed, from `origin/main`). Each release branch gets the same `nmstate/build.sh`, release-matched submodule pins, and (4.22, 4.20) workflow/builder changes. Local branches in the pipeline clone, from `origin/release-4.N` after `git fetch origin`; not pushed yet.

Heads were re-checked right before committing with `git ls-remote https://github.com/openshift/<repo>.git refs/heads/release-4.N` (the `gh api .../compare` call returned 404 with this token; ls-remote of the branch head is the same fact): all six equal the pins.md section 1 values, none moved.

Commands per branch (v = 4.22, 4.21, 4.20):

    git checkout -b nmstate-bundle-fix-$v origin/release-$v
    git checkout nmstate-bundle-fix -- nmstate/build.sh
    git config -f .gitmodules submodule.nmstate/operator.branch release-$v      # and console-plugin
    git update-index --add --cacheinfo 160000,<sha>,nmstate/operator            # and console-plugin

RED before (imagestream-test.sh on each branch's own build.sh): 4.22 and 4.21 `FAIL: image-references still present`; 4.20 `FAIL: no ImageStream removal line`. 4.22 `nmstate-deploy.yaml` pushed on `main`; gitlinks were the 4.20 commits (4.22) / 4.21 older commits.

| branch | commits |
|---|---|
| nmstate-bundle-fix-4.22 | dc9c983 Remove the ImageStream from the bundle; ba19f6c Update submodules to release-4.22; 1a8d210 Build release-4.22 with Go 1.25 and npm; 06ea056 Deploy from release-4.22 to catalog release-4.22 |
| nmstate-bundle-fix-4.21 | c3f65f4 Remove the ImageStream from the bundle; 4657706 Update submodules to release-4.21 |
| nmstate-bundle-fix-4.20 | 51319a5 Remove the ImageStream from the bundle; e4ce05d Update submodules to release-4.20; 7da874a Add deploy workflow |

Pins: 4.22 operator 1d6d332, plugin 25b8f81; 4.21 operator bc318d1, plugin f280b31; 4.20 operator 6ecae5d, plugin 29b58ce.

4.22 Containerfiles: operator and handler go-toolset 1.24 -> 1.25; console-plugin takes main's build steps (`ENV CYPRESS_INSTALL_BINARY=0`, `npm ci && npm run build`, no yarn install); final FROM stays `scos-$OCP_SHORT`. 4.22 workflow: push branch `release-4.22`, `with: catalog_branch: release-4.22` (release-4.22's operator-deploy.yaml declares `catalog_branch`). 4.20 workflow is release-4.21's file with `release-4.20`; release-4.20's operator-deploy.yaml declares only `operator` and `base_registry`, so only `operator` is passed.

GREEN after, per branch: `git diff nmstate-bundle-fix -- nmstate/build.sh` empty; gitlinks and `.gitmodules` branches as above; `imagestream-test.sh` PASS on all three.

release-4.20 `build.sh` vs the fixed file: the only difference is the ImageStream removal (the 4 added lines: two comments, the `find ... -delete` line, a blank). No other line changes, so nothing depends on 4.20's `common.sh`. (release-4.20's old blob e2512c1 had no ImageStream line.)

## 2026-10-23 — the nmstate build Job

`tests/okderators-nmstate-build/` is the GitOps build Job (`tests/okderators-gitops-build/`) copied and
pointed at the pipeline's `nmstate/build.sh`. The mechanics are unchanged and byte-compatible: the
`STEP … START|END`, `DISK`, `PUSHED <ref>@<digest> <bytes>`, `CHECK <name> PASS|FAIL <detail>` and
`RESULT PASS|FAIL` lines, the contract and log files on the PVC, the shared `flock` on `/work/.lock`,
the registry guard (nothing pushed outside `zot.apps.okd.sudops.pl/okd-test`, no tag pushed twice), the
unconditional `podman system prune -af` with `DISK` before and after at the start of a full run, and
the tool pins. It reuses the `okd-build` namespace, the `builder` SA and PVC `build-storage` that the
logging directory owns; its kustomization only generates ConfigMap `nmstate-build-scripts`. Job
`nmstate-build-<MODE>-<DATE>`, log files `nmstate-build-<MODE>-<DATE>.{log,contract}`, reader pod
`nmstate-log-reader`.

What differs, and why:

- Two modes, `full` and `catalog`. No `check`: every pipeline branch (`nmstate-bundle-fix` from
  `main`, `nmstate-bundle-fix-4.22`, `-4.21`, `-4.20`) pins different operator code, so each gets its
  own full run with its own `DATE`. `PIPELINE_BRANCH` has no default. Each branch builds with its own
  `common.sh` `OKD_VERSION`, and `csv-name` takes `MAJOR.MINOR` from it (the `main` branch builds
  `kubernetes-nmstate-operator.v5.0.0-<DATE>`). `OKD_VERSION` stays empty: an override that leaves the
  branch's release ends the run at `gitmodules-branch`, before anything is built.
- The only external image is `IMG_KUBE_RBAC_PROXY`, from the payload, by digest.
- `gettext` is gone from the tool list: nothing in `nmstate/build.sh` or kubernetes-nmstate's Makefile
  and `hack/` runs `envsubst`.
- The checks are new (below). The GitOps `csv`, `skip-range`, `no-replaces`, `branding` and `provider`
  checks are dropped; the upstream bundle script adds `operators.openshift.io/valid-subscription:
  "false"`, which the GitOps branding check would have failed.
- The bundle is checked twice: as `opm render` objects and as the pushed image's files. The bug is
  `hack/ocp-update-bundle-manifests.sh` writing `manifests/image-references` (a `kind: ImageStream`
  heredoc) without an extension, so `find manifests/stable -name '*.yaml'` never matched it. The Job
  copies the pushed bundle with `skopeo copy docker://<repo>@<digest> dir:...`, unpacks the layers and
  greps the files.
- `catalog-edit.sh` takes one bundle per catalog branch (`BUNDLES='release-4.21=<ref@digest> …'`) and
  reads the per-branch values from `catalog-branches.tsv` instead of constants: `REMOVE` (the channel
  entries before the edit, whose entries and bundle files go), `SKIPS` (the new entry's skips) and
  `INSTALLED` (CSVs the walker starts from; `{DATE-1d}` / `{DATE+1d}` are the new bundle's DATE shifted
  by a day). `release-4.21` and `release-4.22` hold the plan's values; `release-4.20` holds that
  branch's current head, `kubernetes-nmstate-operator.v4.20.0-2025-12-27-212436`, its only entry, as
  both `REMOVE` and `SKIPS`, with `INSTALLED` `kubernetes-nmstate-operator.v4.20.0-{DATE-1d}`. A row
  holding `TO-FILL` (how the 4.20 row started, before that head was read) stops a catalog run before
  any edit.
  The edit replaces the broken entry instead of appending: the bundle file is written the way
  `hack/add-bundle.sh` writes it (`echo "$(opm render <bundle>@<digest> -o yaml)"`, without running the
  script, whose `podman create` fails on a `FROM scratch` bundle), the old bundle files are `git rm`ed,
  and the `alpha` `entries:` block is replaced as text by one entry with `skips` and
  `skipRange: '>=4.3.0 <4.N.0-<DATE>'`. `yq` then proves the entries are exactly that one and that the
  rest of the package file is the same documents.
- `catalog-walk.py` is byte-identical to the GitOps copy.

MODE=full checks, in run order:

| check | asserts |
|---|---|
| `gitmodules-branch` | right after the clone: `.gitmodules` declares `branch = release-<OCP_SHORT>` for both nmstate submodules, `OCP_SHORT` being `MAJOR.MINOR` of the `OKD_VERSION` in effect (`main`: `5.0` and `release-5.0`); a FAIL ends the run there |
| `operator-commit` | after `build_containers`, `nmstate/operator` `HEAD` = the branch's recorded gitlink, clean tree, no patch. The operator Containerfile sets no commit label and the repository's `.dockerignore` drops `.git`, so the image cannot name its own commit; this proves the tree the pipeline's `init` checked out (a commit-like label appearing in the Containerfile fails the check until it compares that label) |
| `nmstate-rpm` | `rpm -q nmstate` in the built handler image, recorded |
| `bundle-objects` | exactly CRD `nmstates.nmstate.io` + one CSV, and two files in `manifests/` |
| `no-imagestream` | no `ImageStream` object, no `kind: ImageStream` in any bundle file, no `image-references` file |
| `no-redhat-registry` | no `registry.redhat.io` (or the engineering proxy, brew) in the CSV, the objects, the files or the labels |
| `csv-name` | `kubernetes-nmstate-operator.v<MAJOR>.<MINOR>.0-<DATE>`, `spec.version` and the `olm.package` version |
| `csv-code-release` | the release the operator code declares: `spec.labels.olm-status-descriptors` = `kubernetes-nmstate-operator.vX.Y.0` and the `olm.skipRange` upper bound `<X.Y.0`, X.Y from `OKD_VERSION`. Both come from kubernetes-nmstate's CSV base at the gitlink, untouched by the pipeline |
| `images-by-digest` | every relatedImage, container image, `*_IMAGE`/`RELATED_IMAGE_*` env value and `containerImage` is `@sha256:`; the built ones are this run's digests under `<BASE_REGISTRY>/nmstate/` and all three are referenced; kube-rbac-proxy exactly |
| `install-modes` | recorded; `AllNamespaces` required (the homelab OperatorGroup is `spec: {}`) except on a 4.20 build |
| `operator-sdk-validate` | `operator-sdk bundle validate <unpacked dir> -o json-alpha1` passes |

MODE=catalog checks per branch: `branch-data`, `bundle`, `no-imagestream` (all three before any clone),
`negative-control-imagestream` (the unedited head bundle, through the same ImageStream count, must have
one), `bundles`, `edit`, `opm-validate`, `walk`, `negative-control-skiprange` (the entry without
`skipRange` still passes `opm validate`, and the walker must report exactly the `INSTALLED` CSVs that
`SKIPS` does not name as stranded), then `opm-validate-image` and `catalog-image` for
`<BASE_REGISTRY>/nmstate-catalog:<DATE>` from the edited `release-4.21` tree, package
`kubernetes-nmstate-operator` only.

Checks before any cluster run (all on the Mac):

- `bash -n build.sh`, `bash -n catalog-edit.sh`: OK. `python3 -I -m py_compile catalog-walk.py`: OK.
- `kubectl kustomize tests/okderators-nmstate-build/ | kubeconform -strict -ignore-missing-schemas`:
  `Valid: 1` (ConfigMap `okd-build/nmstate-build-scripts`, keys `build.sh`, `catalog-branches.tsv`,
  `catalog-edit.sh`, `catalog-walk.py`). The same for the `oc process --local` Job and for
  `log-reader.yaml`. (kubeconform needed the sandbox off: its schema download failed TLS verification
  through the sandbox proxy.)
- `KUBECONFIG=~/.kube/config-readonly oc diff -k tests/okderators-nmstate-build/` fails as it did for
  GitOps: `configmaps is forbidden: User "system:serviceaccount:automation:claude-reader" cannot create
  resource "configmaps" in API group "" in the namespace "okd-build"` (the server-side dry-run counts as
  create). Instead: `oc -n okd-build get configmap nmstate-build-scripts` returns NotFound; the namespace,
  SA `builder`, RoleBinding `builder-scc-privileged` and PVC `build-storage` (Bound, 100Gi) exist; the
  ConfigMaps there are `build-scripts` and `gitops-build-scripts`; no Jobs or pods.
- Walker unit run on a hand-made two-entry FBC (old entry
  `kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851`, head `v4.21.0-2026-10-23-120000` with `skips`
  and `skipRange: '>=4.3.0 <4.21.0-2026-10-23-120000'`), installed `v4.21.0-2026-10-22-120000` and
  `v4.20.0-2025-12-27-212436`:
  `PASS 2 entries + 2 CSVs absent from the channel reach kubernetes-nmstate-operator.v4.21.0-2026-10-23-120000`.
  The same file without `skipRange`: exit 1,
  `FAIL stranded: kubernetes-nmstate-operator.v4.21.0-2026-10-22-120000 (absent from the channel) dead ends: kubernetes-nmstate-operator.v4.21.0-2026-10-22-120000`.
- `catalog-edit.sh` in test mode against the real `release-4.20`/`-4.21`/`-4.22` catalog files
  (okderators-catalog-index upstream, via a local bare mirror) and test bundles made from each branch's
  broken head with the `ImageStream` object dropped and the CSV renamed to `…v4.N.0-2026-10-23-120000`:
  `release-4.21 release-4.22` with the committed data file, 19 checks PASS, 0 FAIL. The package-file diff
  is `+3 -1` per branch, for example on 4.21:

  ```
   entries:
  -  - name: kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851
  +  - name: kubernetes-nmstate-operator.v4.21.0-2026-10-23-120000
       skips:
  +      - kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851
         - kubernetes-nmstate-operator.v4.20.0-2025-12-27-212436
  +    skipRange: '>=4.3.0 <4.21.0-2026-10-23-120000'
  ```

  Both negative controls pass on both branches:
  `no-imagestream fails on the unedited head kubernetes-nmstate-operator.v4.21.0-2026-05-05-165851: 1 ImageStream object(s)`
  and `without skipRange opm validate passes and the walker reports stranded: kubernetes-nmstate-operator.v4.21.0-2026-10-22-120000`
  (4.22: both `v4.21.0-2026-10-22-120000` and `v4.21.0-2026-10-24-120000`). After the `release-4.20`
  row was filled, the committed data file on all three branches (`CATALOG_BRANCHES='release-4.21
  release-4.22 release-4.20'`, upstream heads release-4.20 `bfbb297`, release-4.21 `6c737c9`,
  release-4.22 `252d764`): exit 0, 28 PASS, 0 FAIL. On 4.20 the walk is
  `1 entries + 1 CSV absent from the channel reach kubernetes-nmstate-operator.v4.20.0-2026-10-23-120000`,
  the skipRange control reports `kubernetes-nmstate-operator.v4.20.0-2026-10-22-120000` stranded, and
  the package-file diff is `+4 -1` (the old entry had no `skips:` line):

  ```
   entries:
  -  - name: kubernetes-nmstate-operator.v4.20.0-2025-12-27-212436
  +  - name: kubernetes-nmstate-operator.v4.20.0-2026-10-23-120000
  +    skips:
  +      - kubernetes-nmstate-operator.v4.20.0-2025-12-27-212436
  +    skipRange: '>=4.3.0 <4.20.0-2026-10-23-120000'
  ```
- Failure paths: the data file while the `release-4.20` row was still `TO-FILL` →
  `branch-data-release-4.20 FAIL row incomplete`, stopped before any clone; a bundle that keeps the `ImageStream` → `bundle-… FAIL` and
  `no-imagestream-… FAIL`, stopped; a `REMOVE` that does not match the catalog → `edit-… FAIL channel alpha
  entries before the edit are […]`; a `BUNDLES` ref without a digest, a missing branch in `BUNDLES` and a
  push target outside zot `okd-test/` each stop the script with an `ERROR` line.
- The file-level checks of `build.sh` (`bundle-objects`, `no-imagestream`, `no-redhat-registry`,
  `operator-sdk-validate`; the functions sourced unchanged from `build.sh` under bash 3.2) on a directory
  shaped like an unpacked bundle: the broken 4.21 catalog bundle (with an extensionless
  `manifests/image-references`) fails three of them, and `operator-sdk` v1.36.1 itself rejects it with
  `Error: Value image.openshift.io/v1, Kind=ImageStream: unsupported media type registry+v1 for bundle object`;
  the fixed test bundle passes all four (operator-sdk: `passed: true`, one `minKubeVersion` warning).

Not run before the cluster: `build.sh` itself (it needs bash 4.3 namerefs and associative arrays, podman
and the registries), so `operator-commit`, `nmstate-rpm`, `csv-name`, `images-by-digest`,
`install-modes` and the `skopeo copy … dir:` unpack are exercised only by their jq filters and by the
first full run.

Review fix, same day. The first version could not catch code from the wrong release: `csv-name` takes
`MAJOR.MINOR`, `OCP_DATE` and the CSV name from the same sourced `common.sh`, and `operator-commit` only
proves `HEAD` is the gitlink. The 2026-05-05 4.21 bundle, 4.20 code named `v4.21.0`, would have passed both,
and only `install-modes` would have caught it, by accident. Two checks now close that.
`csv-code-release` reads the release the code itself declares. kubernetes-nmstate's CSV base at each gitlink
carries `spec.labels.olm-status-descriptors` and `olm.skipRange` for its own release, and the pipeline does not
touch either. `gitmodules-branch` stops a run whose `OKD_VERSION` contradicts the branch before anything is
built. Both were run under bash 3.2, sourced unchanged from `build.sh`:

```
nmstate-bundle-fix fffb76d: CHECK csv-code-release PASS release 5.0 code: olm-status-descriptors kubernetes-nmstate-operator.v5.0.0, olm.skipRange '>=4.3.0 <5.0.0'
nmstate-bundle-fix-4.22 1d6d332: CHECK csv-code-release PASS release 4.22 code: ... v4.22.0, '>=4.3.0 <4.22.0'
nmstate-bundle-fix-4.21 bc318d1: CHECK csv-code-release PASS release 4.21 code: ... v4.21.0, '>=4.3.0 <4.21.0'
nmstate-bundle-fix-4.20 6ecae5d: CHECK csv-code-release PASS release 4.20 code: ... v4.20.0, '>=4.3.0 <4.20.0'
release-4.21 head v4.21.0-2026-05-05-165851 as 4.21: CHECK csv-code-release FAIL olm-status-descriptors kubernetes-nmstate-operator.v4.20.0 (want kubernetes-nmstate-operator.v4.21.0), olm.skipRange '>=4.3.0 <4.20.0' upper bound '<4.20.0' (want <4.21.0)
release-4.22 head v4.22.0-2025-12-14-152353 as 4.22: CHECK csv-code-release FAIL ... v4.20.0 (want ...v4.22.0) ... (want <4.22.0)
4.21 code (bc318d1) as 4.22: CHECK csv-code-release FAIL ... v4.21.0 (want ...v4.22.0) ... (want <4.22.0)
nmstate-bundle-fix: CHECK gitmodules-branch PASS nmstate/operator=release-5.0 nmstate/console-plugin=release-5.0, the release of OCP_SHORT 5.0
nmstate-bundle-fix-4.22 / -4.21 / -4.20: CHECK gitmodules-branch PASS (release-4.22 / release-4.21 / release-4.20)
nmstate-bundle-fix-4.21 with OKD_VERSION 4.22: CHECK gitmodules-branch FAIL nmstate/operator=release-4.21 nmstate/console-plugin=release-4.21 in .gitmodules, want release-4.22
nmstate-bundle-fix (main) with OKD_VERSION 4.21: CHECK gitmodules-branch FAIL nmstate/operator=release-5.0 nmstate/console-plugin=release-5.0 in .gitmodules, want release-4.21
origin/release-4.22 today (.gitmodules says release-4.21): CHECK gitmodules-branch FAIL ... want release-4.22
```

The three built okderators catalog bundles behave as expected. The 4.20 head is 4.20 code named `v4.20.0` and
passes. The 4.21 head (2026-05-05) and the 4.22 head (2025-12-14) are both 4.20 code under a later name and
both fail. The README no longer suggests overriding `OKD_VERSION`.

## 2026-10-23, 16:50Z — paused before the first build

Tasks 1-4 are done and reviewed: the pins and recon, the ImageStream fix on `main`
(`nmstate-bundle-fix` a005aed), the three release branches (4.22 06ea056, 4.21 4657706, 4.20 7da874a, all on the fork),
and the build Job (`tests/okderators-nmstate-build/`, 6c4a41c). The Job's first review caught a gap: nothing proved
the operator code came from the release the branch claims, which is exactly the bug the current 4.21 and 4.22
catalog bundles have. Two checks close it: `csv-code-release` (the CSV base's `olm-status-descriptors` and
`olm.skipRange` upper bound must name the branch's release) and `gitmodules-branch` (both nmstate submodules must
declare `release-${OCP_SHORT}`, checked before anything builds).

The first run waits for me. Starting the Job is an `oc apply -k` plus an `oc process | oc create`; both are on the
repo's Claude deny list, and I was on a remote session with no shell to run them. Zot had 15.7 GiB free.

## 2026-10-23 evening — full builds: 4.21 and 4.22 pass, 4.20 stopped by CentOS metadata

Task 5 runs one `MODE=full` build per pipeline branch, 4.21 first, a new DATE each, deleting each finished Job before
the next. The operator ran each Job from the Mac:

```bash
oc apply -k tests/okderators-nmstate-build/                   # ConfigMap nmstate-build-scripts, once
oc -n okd-build delete job nmstate-build-full-<previous DATE> && {
  DATE=$(date -u +%Y-%m-%d-%H%M%S)
  oc process --local -f tests/okderators-nmstate-build/job-template.yaml \
    -p MODE=full -p PIPELINE_BRANCH=nmstate-bundle-fix-4.21 -p DATE=$DATE \
    | oc -n okd-build create -f - && echo DATE=$DATE; }
```

I followed each log read-only and collected the `STEP`/`CHECK`/`RESULT` lines.

| Branch | DATE | Result | Wall time | `build_containers` |
|---|---|---|---|---|
| `nmstate-bundle-fix-4.21` | 2026-10-23-181845 | `RESULT PASS full`, 11/11 CHECK | 59 min | 47 min 40 s |
| `nmstate-bundle-fix-4.22` | 2026-10-23-195655 | `RESULT PASS full`, 11/11 CHECK | 24 min | 14 min 24 s |
| `nmstate-bundle-fix-4.20` | 2026-10-23-202635 | `RESULT FAIL build_containers (exit 1)` | 10 min | failed in the handler image |

The 4.21 result is what the cluster will install:

```
CHECK gitmodules-branch PASS nmstate/operator=release-4.21 nmstate/console-plugin=release-4.21, the release of OCP_SHORT 4.21
CHECK operator-commit PASS nmstate/operator built from bc318d1723e2977b55007d84f877f97b2960709d = the recorded gitlink (.gitmodules branch release-4.21), clean tree, no patch; the Containerfile sets no commit label
CHECK nmstate-rpm PASS nmstate-2.2.62-3.el9.x86_64 in .../okd-test/nmstate/handler:4.21.0-2026-10-23-181845
CHECK bundle-objects PASS objects CustomResourceDefinition/nmstates.nmstate.io ClusterServiceVersion/kubernetes-nmstate-operator.v4.21.0-2026-10-23-181845
CHECK no-imagestream PASS no ImageStream object in opm render, no ImageStream in the bundle image's files, no image-references file
CHECK no-redhat-registry PASS ...
CHECK csv-name PASS kubernetes-nmstate-operator.v4.21.0-2026-10-23-181845 (OKD_VERSION 4.21.0-okd-scos.10)
CHECK csv-code-release PASS release 4.21 code: olm-status-descriptors kubernetes-nmstate-operator.v4.21.0, olm.skipRange '>=4.3.0 <4.21.0'
CHECK images-by-digest PASS 8 refs, all @sha256 ...
CHECK install-modes PASS OwnNamespace=true SingleNamespace=true MultiNamespace=false AllNamespaces=true
CHECK operator-sdk-validate PASS operator-sdk v1.36.1 bundle validate: passed, 1 warnings, 0 errors
RESULT PASS full 2026-10-23-181845
```

`no-imagestream` is the fix itself: the bundle has two objects and no `image-references` file. The `operator-sdk`
warning is `csv.Spec.minKubeVersion is not informed`. Bundles:

- 4.21: `okd-test/nmstate/bundle:4.21.0-2026-10-23-181845@sha256:753da256c9a3b17d10ecd158d7cfec5d6d6bbde49af7610eeaf729c66fef43cc`
- 4.22: `okd-test/nmstate/bundle:4.22.0-2026-10-23-195655@sha256:284ebfeaa858342c0768c850b84aee0c36adcfe3fa84560392af26882df8d724`

The repository is `bundle`, not `operator-bundle`.

4.22 is the retarget at work. Upstream `release-4.22` gitlinks are 4.20 commits; this build is
`kubernetes-nmstate-operator.v4.22.0-2026-10-23-195655` from `1d6d332`, with `csv-code-release` reading
`v4.22.0` / `<4.22.0`. It has 7 image refs to 4.21's 8. The 4.22 CSV no longer sets `KUBE_RBAC_PROXY_IMAGE`; 4.21
sets it to `quay.io/okd/scos-content@sha256:db030f09…`. That is upstream `release-4.22` commit `f1f0cda5`
"OCPBUGS-127277: operator: remove unused kube-rbac-proxy image plumbing (#1543)". I checked it by pulling both
bundle CSVs from zot. The 4.22 handler ships the same `nmstate-2.2.62-3.el9` as 4.21.

One wording bug in my own check. The `images-by-digest` PASS line ends with "external <scos-content ref>". That is the
external ref the check *allows* (from the payload), not one it found. On 4.22 the CSV has none. The verdict logic is
right; the wording gets fixed with the next `build.sh` change.

### 4.20: CentOS Stream 9 BaseOS metadata

The handler image's `RUN dnf -y update && dnf -y install nmstate iputils iproute` failed:

```
CentOS Stream 9 - BaseOS                        139  B/s | 2.1 kB     00:15
Errors during downloading metadata for repository 'baseos':
  - Downloading successful, but checksum doesn't match. Calculated: 2e8b57757552f85c…(sha512)  Expected: 6ff5c00467839a…
Error: Failed to download metadata for repo 'baseos': Cannot download repomd.xml: Cannot download repodata/repomd.xml: All mirrors were tried
```

The other repo error in that block, `rhel-9-server-ose` at `http://base-4-20-rhel9.ocp.svc/...`, is in all three
builds. It is a CI-internal repo in the `scos-*:base-stream9` images, and dnf skips it each time (`Ignoring repositories:
rhel-9-server-ose`). It is not the cause.

From the Mac, with `python3 -I` and urllib (read-only):

| Source | `repomd.xml` sha512 | Size |
|---|---|---|
| metalink `centos-baseos-9-stream` x86_64, timestamp 2026-10-23 17:48:56Z | expects `6ff5c00467839a…`, no alternates | 2142 |
| five mirrors from that metalink (20:4xZ) | `2e8b57757552f8…`, newest data 2026-10-21 20:59Z | 2142 |
| `mirror.stream.centos.org` (master), 20:4xZ | `2e8b57757552f8…` | 2142 |
| `mirror.stream.centos.org`, 21:02Z | `346a4df8ef6e4a…` | — |

The metalink expects a checksum that not even the master served. The master has since moved to another file, and the
metalink is still the 17:48Z one. That is CentOS infrastructure, not the pipeline or the fix. The 4.21 run (about
18:30Z) and the 4.22 run (about 20:05Z) passed the same `dnf` step. Building `main` now would hit the same step, so
4.20 and `main` wait until the metalink matches the master. Nothing was pushed for 4.20; the failed Job is deleted.

### Pod start on node5

The 4.21 and 4.22 pods each sat about 4.5 min in `CreateContainerError` on node5. 4.21 logged `stream terminated by
RST_STREAM with error code: CANCEL`, 4.22 `context deadline exceeded`. Each started on kubelet's retry. The GitOps
catalog run on 10-22 did the same. The 4.20 pod, also on node5, started in about a minute. The pod is `privileged`
SCC with no `seLinuxOptions`, so a volume relabel is unlikely. Without node-log access the cause stays open. It costs
minutes, not runs.

zot: 15.4 GiB free before, 16.1 GiB after both builds.

Stopped here for the night (operator, 21:05Z). Next: re-run 4.20 and `main` once CentOS has fixed its metadata. Then
one `MODE=catalog` run for release-4.20/4.21/4.22, Task 7, and the switch in a daytime window.

## 2026-10-26 — resuming 4.20: CentOS is fixed, the build image is gone

The CentOS check from the pause now matches:

```
$ python3 -I check-centos-metalink.py
MATCH master 346a4df8ef6e4a metalink expects ['346a4df8ef6e4a'] metalink timestamp 2026-10-23 20:06Z
```

`okd-build` was empty, the `nmstate-build-scripts` ConfigMap unchanged since it was applied, zot at 16.2 GiB free. The
operator started the 4.20 run (`nmstate-build-full-2026-10-26-112744`, 11:27:44Z). Its pod never started:

```
ErrImagePull: ... reading manifest sha256:dc02649067d5... in zot.apps.okd.sudops.pl/podman/stable:
  repository name not known to registry]): quay.io/podman/stable@sha256:dc02649067d5...:
  reading manifest sha256:dc02649067d5... in quay.io/podman/stable: manifest unknown
```

Every build Job here (logging, gitops, nmstate) and its log reader pinned
`quay.io/podman/stable:v5.8.9@sha256:dc02649067d5…`, the manifest list the tag pointed at on 2026-10-20. quay's tag
history shows why that stopped working:

```
sha256:2a53680d80c9 from 2026-10-26 03:46Z to -
sha256:55d98815a34b from 2026-10-23 03:43Z to 2026-10-26 03:46Z expired
sha256:4ed083a7631a from 2026-10-22 03:43Z to 2026-10-23 03:43Z expired
sha256:b1808d7a18da from 2026-10-21 03:41Z to 2026-10-22 03:43Z expired
sha256:dc02649067d5 from 2026-10-20 03:41Z to 2026-10-21 03:41Z expired
```

podman rebuilds `v5.8.9` every morning and quay expires the old manifest. The digest was the tag for one day, and five
days later quay no longer serves it. The 10-23 builds still ran because node5 had the image cached from the 10-20
logging build. The node5 image prune at 11:09Z the same morning (`blog-olmv1-catalog-cache-leak-draft.md`) removed
that cached copy, since no container was using it.

zot did not have it either. Its catalog holds images pulled by tag (14 tags of `immich-app/immich-server`) but no
repository that has only ever been pulled by digest: neither `podman/stable` nor `okd/scos-content` appears in it. So
a digest pin of a quay image that gets re-tagged lasts only as long as quay keeps the old digest, and re-pinning
to today's `2a53680d…` would have failed the same way within days.

Before fixing it I checked the prune had not exposed anything else the same way. Only one CronJob on the cluster
pins an image by digest, `openshift-image-registry/image-pruner` (`quay.io/okd/scos-content@sha256:24c90b37…`), and
quay still answers 200 for it.

The fix is our own copy in zot, which keeps what is pushed to it. linux/amd64 only, since all three nodes are amd64.
Today's index `2a53680d…` lists amd64 as `sha256:68e44184…`. Run by the operator on the Mac (`brew install skopeo`,
1.24.1):

```bash
skopeo copy --preserve-digests \
  docker://quay.io/podman/stable@sha256:68e4418474c7362e53000e1c6163bb4441c0ab15cf65d880cd6ffd2768143500 \
  docker://zot.apps.okd.sudops.pl/okd-test/podman/stable:v5.8.9-2026-10-26
```

`--preserve-digests` makes skopeo fail rather than rewrite the manifest. Read back from zot's registry API: the tag
resolves to `sha256:68e4418474c7…` (MATCH), a HEAD by digest returns 200, and the config says `linux amd64`, with
10 layers and 251 MB. All six manifests (`job-template.yaml` and `log-reader.yaml` in each of the three build directories)
now pin `zot.apps.okd.sudops.pl/okd-test/podman/stable:v5.8.9-2026-10-26@sha256:68e44184…`. Each rendered template
and each log reader passes `kubeconform -strict`. Cost: a build now needs zot up to start, which the push step
needed anyway.

## 2026-10-26 — 4.20 again: past CentOS, stopped by the console plugin's unlocked yarn install

With the build image fixed, the operator re-created the 4.20 run (`nmstate-build-full-2026-10-26-113855`). The pod
started 90 s after creation, with no `CreateContainerError` this time. The handler image's `dnf` step passed: the
CentOS metadata is fixed, and the `rhel-9-server-ose` `*.ocp.svc` lines are the same harmless error 4.21 and 4.22
print. The run then failed at 12:03:40Z in the console plugin image:

```
[1/2] STEP 4/4: RUN yarn install --frozen-lockfile && yarn build
yarn install v1.22.22
info No lockfile found.
...
/opt/app-root/src/node_modules/@openshift-console/dynamic-plugin-sdk-webpack/node_modules/webpack/lib/container/HoistContainerReferencesPlugin.js:224
					if (connection.module.is("external")) {
TypeError: connection.module.is is not a function
    ...
    at Compilation.seal (/opt/app-root/src/node_modules/webpack/lib/Compilation.js:3812:36)
```

Two webpacks in one process. The top-level copy (the one running `Compilation`) is pinned in the plugin's
`package.json` to `5.111.1`; `@openshift-console/dynamic-plugin-sdk-webpack` 4.20.0 depends on `webpack ^5.75.0`,
and yarn installed a newer copy under it. A plugin from that copy calls `Module.is()`, which `5.111.1` does not have.
I checked `lib/container/HoistContainerReferencesPlugin.js` at `v5.111.1`: it does not call `.is("external")`.

**Why yarn ran unlocked.** `info No lockfile found.` The pipeline's own `nmstate/images/console-plugin.Containerfile`
on `release-4.20` and `release-4.21` installs yarn and runs `yarn install --frozen-lockfile`, but
`openshift/nmstate-console-plugin` has no `yarn.lock` on those branches, only `package-lock.json`. Without a yarn
lockfile, `--frozen-lockfile` does not stop the install, so every build resolves fresh. Upstream's own `Dockerfile` on
the same commits runs `npm clean-install`. Upstream `main` of the pipeline already fixed this in `7c8e29f`
("[nmstate] Target OKD 5.0": "Build console-plugin with npm ci; upstream dropped yarn.lock"), and our 4.22 branch got
the same change on 10-23 (`1a8d210`), which is why 4.22 built. It never reached `release-4.20` or `release-4.21`.

Not explained: 4.21 built with the same yarn setup on 10-23 and passed. Its plugin pins the same webpack `5.111.1`,
and SDK 4.21.0 has the same `^5.75.0` range; webpack 5.112.2 was already published at 12:18Z that day. I have not
reproduced the 4.21 install to see how yarn laid it out, so "it got lucky" is a guess.

**Fix (operator's call: both branches).** Upstream's exact hunk from `7c8e29f`, applied in scratch worktrees
because the main clone's checked-out branch has unrelated deletions I did not want to carry:

```bash
git -C pipeline diff 7c8e29f5c~1 7c8e29f5c -- nmstate/images/console-plugin.Containerfile > npm-ci.patch
git -C wt/4.20 apply npm-ci.patch   # likewise wt/4.21
```

The resulting file is byte-identical to the 4.22 branch's. One commit per branch, `[nmstate] Build console-plugin
with npm ci`: `nmstate-bundle-fix-4.20` `7da874a..51ba5be`, `nmstate-bundle-fix-4.21` `4657706..6727222`, pushed to the
fork. The 4.20 and 4.21 PRs will each carry this commit. The 10-23 4.21 bundle came from the old Containerfile, so 4.21
is rebuilt too and the catalog run will use the new bundle.

### Do the logging and GitOps PRs have the same time bomb?

Both of today's failures were drift: a pin that quay expired, and an install with no lockfile. Neither needs a
rebuild to find, so instead of rebuilding eight branches I read the Containerfiles behind okd-operator-pipeline
#35-#42 for dependency installs and checked what each one locks against. None of those PRs has upstream CI checks;
upstream only builds after a merge.

- **Logging (#35-#38):** nine Containerfiles, identical on all four branches (same blob set). Go builds against
  `go.sum`; Vector runs upstream's `make build` with its committed `Cargo.lock` and a pinned Rust toolchain
  (`--default-toolchain 1.92.0`). No npm or yarn anywhere.
- **GitOps (#39-#42):** all four branches pin `rh-gitops-midstream/release` at `6c4a911`, whose Dockerfiles do the
  building. Every frontend install is locked: the console plugin and the Argo CD UI run `pnpm install
  --frozen-lockfile --offline` against committed `pnpm-lock.yaml`, and gitops-promoter's two UIs run `npm ci`.
- **cert-manager 1.20:** already built by upstream's own CI from `release-4.21` on 10-22; the catalog PRs (#60/#61)
  only add catalog entries.

So nmstate's yarn step was the only unlocked frontend install among our open PRs. What none of them can lock is the
environment: `dnf` against CentOS mirrors (the 10-23 failure) and `:latest` base images such as
`ubi9/nodejs-22:latest`. A rebuild today would not prove those for the day upstream builds after a merge either.
The one change that does touch the logging and GitOps Jobs is the podman image (`ae2fae9`), which only matters if we
build them again.

## 2026-10-26 — all four branches build

With the zot podman copy and `npm ci` on 4.20/4.21, the remaining runs went through one at a time (the operator
created and deleted each Job; I followed the logs read-only). 4.21 was rebuilt because its branch changed; the
10-23 4.21 bundle is superseded. 4.22 is unchanged since 10-23.

| Branch | Run (DATE) | Pipeline commit | Wall time | `build_containers` | Peak `DISK` after prune | Handler `nmstate` |
|---|---|---|---|---|---|---|
| release-4.21 | 2026-10-26-123722 | `6727222` | 17.5 min | 865 s | 12.2 GB | 2.2.62-3.el9 |
| release-4.20 | 2026-10-26-121658 | `51ba5be` | 18.0 min | 906 s | 13.2 GB | 2.2.62-3.el9 |
| main (OKD 5.0) | 2026-10-26-130048 | `a005aed` | 19.8 min | 991 s | 12.5 GB | 2.2.62-4.el10 |
| release-4.22 | 2026-10-23-195655 | (10-23) | — | — | — | (10-23 run) |

Every run ended `RESULT PASS` with all eleven checks PASS: gitmodules-branch, operator-commit, nmstate-rpm,
bundle-objects, no-imagestream, no-redhat-registry, csv-name, csv-code-release, images-by-digest, install-modes,
operator-sdk-validate. operator-sdk's one warning is the same on every branch and comes from upstream's CSV
(`csv.Spec.minKubeVersion is not informed`). Install modes: AllNamespaces=true on 4.21 and main, false on 4.20
(recorded; 4.20 does not need it). The handler `nmstate` RPM is 2.2.62 everywhere, newer than the 2.2.61 noted
before the switch planning (switch.md unknown 2).

The 10-23 runs took about an hour each; today's took 18-20 minutes. I did not measure why. One difference is that
the 10-23 pods waited ~4.5 min in `CreateContainerError` before starting and today's started in 60-90 s; the rest is
not explained by anything I checked.

Bundles (all `zot.apps.okd.sudops.pl/okd-test/nmstate/bundle`):

```
4.21.0-2026-10-26-123722@sha256:20131681a8c80b45996e097d79809a15861a09d9d920b47b161f866889295ad7
4.20.0-2026-10-26-121658@sha256:a3366cc773e41ee51f0e0df48c088b80d0f5b5af8e9db0e6878855d07c2e3023
5.0.0-2026-10-26-130048@sha256:290e248287ef8a708143056dec2fca0b777ca7c0ada83db57c487db651e31804
4.22.0-2026-10-23-195655@sha256:284ebfeaa858342c0768c850b84aee0c36adcfe3fa84560392af26882df8d724
```

CSV names: `kubernetes-nmstate-operator.v4.21.0-2026-10-26-123722` (OKD 4.21.0-okd-scos.10, skipRange
`>=4.3.0 <4.21.0`), `v4.20.0-2026-10-26-121658` (4.20.0-okd-scos.6), `v5.0.0-2026-10-26-130048` (5.0.0-okd-scos.0).
zot: 16.2 GiB free before today's runs, 15.7 GiB after 4.20.
