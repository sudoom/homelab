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
