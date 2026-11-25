# CLAUDE.md

Guidance for Claude Code when working in this repository.

**What belongs in this file:** rules, guardrails and the current state a session needs to act safely, plus pointers to
where the detail lives. History (timelines, durations, incident narratives, retracted causes, finished PRs) goes to the
topic's `blog/*-draft.md`; long designs for unbuilt work go to `backlog/`. A dated operator decision keeps its date and
quote. When state changes, replace the old state here and record the change in the draft.

## Repository overview

Homelab GitOps repository for a **3-node bare-metal OKD 5.0 cluster** (OpenShift Kubernetes Distribution), managed declaratively by **ArgoCD** with an app-of-apps pattern and Helm templating.

- **Cluster domain:** `okd.sudops.pl`
- **Nodes:** 3 control-plane+worker; frontend `192.168.1.7–9`, storage backnet `192.168.10.2–4`. Frontend addresses come from MikroTik DHCP reservations (1-day lease, `node-dhcp` chart) — the IPs must never change (etcd and kubelet cert SANs); a router outage longer than a day would drop them
- **Failure domains** (`topology.kubernetes.io/zone`): `fd-a → node4`, `fd-b → node5`, `fd-c → node6`
- **Ingress:** `*.apps.okd.sudops.pl` (wildcard, cert-manager)
- **API:** `api.okd.sudops.pl`
- **Git:** `git@github.com:sudoom/homelab.git` — `master` = production (ArgoCD tracks). Commits go straight to `master`; there is no working branch (see "Commit and branch conventions").

## Stack and tool versions

Pin these when generating manifests or commands — mismatched versions are the single largest source of wrong suggestions.

| Tool            | Version        | Notes                                                                 |
|---|---|---|
| OKD             | **5.0.0-okd-scos.8** (since 2026-11-20) | Kube API **1.36**. **Update service:** Cincinnati `https://updates.okd.io/api/updates/graph`, channel `stable-5.0`. Updates use the runbook `tests/okd-5.0-upgrade/` (reused for 5.0.z, no minimum age); the cluster-health sweep reports running and offered versions. **etcd automatic defrag is OFF since 2026-11-10** (ConfigMap `openshift-etcd-operator/etcd-disable-defrag`, condition `DefragControllerDisabled=True`) because of okd#2384 (members diverge after the automatic defrag on 3-master 5.0). scos.8 does not carry the fix. Re-enable only once a build with the fix runs here: `oc -n openshift-etcd-operator delete configmap etcd-disable-defrag`. **Never run a manual `etcdctl defrag` on 5.0 while okd#2384 is open** (every 5.0 defrag takes the non-blocking path). Consequence: `etcdDatabaseHighFragmentationRatio` (warning) fires and is left firing on purpose, not silenced (operator) — known, not actionable while defrag is off; the 8 GiB backend quota is the limit that matters. The etcd consistency check `tests/okd-5.0-upgrade/etcd-consistency.sh` (operator-run) is not scheduled; re-run it after any etcd-operator restart. `ClusterNotUpgradeable` (`Upgradeable=False`, info): the zot test build of the descheduler caps `maxOpenShiftVersion` at 4.23 (= 5.0), which blocks 5.1 but not 5.0.z; its 5.0 build is a follow-up (README TODO "OKD 5.0 follow-ups"). Logging and Loki stopped blocking on 2026-11-25 (the reworked 6.6.0 build caps at 5.1). Record: `blog/blog-okd-5.0-upgrade-draft.md` (and `blog/blog-okd-4.22-upgrade-draft.md` for the previous hop). |
| Helm            | local **v4.3.0**; ArgoCD uses its own bundled Helm (**4.2.4** since 2026-10-22) | GitOps 1.22 bundles Helm 4.2.4. A local `helm template` can still differ from what ArgoCD renders, so check a version-sensitive change with `oc diff` against live. Helm v2 syntax is invalid; no Tiller |
| ArgoCD          | **v3.5.5+a5038b0** (official okderators GitOps 1.22, CSV `gitops-operator.v1.22.0-2026-11-06-221018`) | The operator comes from `okderators` (Subscription `bootstrap/phase0/02_gitops_operator.yaml`, Manual). The Argo CD images are pinned by digest on quay; zot does not cache digest-only pulls, so they need quay.io reachable through the mirror fallback. Server-side apply + sync-wave annotations used throughout. **The ArgoCD CR carries a hand-applied CephCluster health override** (`bootstrap/phase0/06_argocd_cephcluster_health.yaml`, applied 2026-10-22): Argo CD 3.3+ maps Ceph `HEALTH_WARN` to Degraded, which would fail every `rook-ceph-cluster` multi-wave sync on this permanently-WARN Ceph. The CR is operator-defaulted, not in git, so re-apply the patch after any GitOps reinstall (`bootstrap/phase0/readme.md`, Step 8) |
| OLM             | OKD-bundled    | `okderators` + `operatorhubio-catalog` CatalogSources (both in `bootstrap/phase0/01_catalog_source.yaml`), plus the marketplace-managed `community-operators` (`community-operator-index:v5.0`) and five zot test catalogs (`okd-test-logging`, `okd-test-nmstate`, `okd-test-oadp`, `okd-test-descheduler`, `okd-test-cert-manager`) |
| cert-manager    | **v1.21.3** (operator CSV `cert-manager-operator.v1.21.0-2026-11-21-163714`, our okderators test build) | OLM from the zot test catalog `okd-test-cert-manager` (`alpha`, Manual) since 2026-11-22, until okderators publishes 1.21; 1.21 supports Kube 1.33–1.36. The 1.20 build it replaced (`cert-manager-operator.v1.20.0-2026-10-22-132146`, okderators) ran out of matrix on Kube 1.36 from 2026-11-10. The 1.21 operator can create MachineConfigs (alpha HTTP01Proxy, off by default) and must never have that gate enabled. Rollback to 1.20 and the zot loop: `components/operators/cert-manager/README.md`; follow-ups in README TODO "OKD 5.0 follow-ups" (4)(d). The parked Helm fallback (branch `cert-manager-helm-fallback`) can be retired; deleting the branch is the operator's call. |
| oc / kubectl    | client **4.22.22** against a **5.0** cluster (one minor behind; a 5.0 client is a follow-up) | Prefer `oc` for OpenShift-only kinds (Route, SCC, ImageStream) |
| kubeconform     | latest         | Use with OpenShift CRD schema location (see Validation)               |
| Renovate        | GitHub App     | Handles image tag bumps; PRs labeled `dependencies`                   |

## Repository layout

```
.
├── bootstrap/
│   ├── phase0/              # One-time manual bootstrap: CatalogSource, GitOps operator, RBAC, root App
│   └── root-app/            # Helm chart that generates all child Applications
│       ├── values.yaml      # ← central registry of managed apps (enable/disable + sync wave)
│       └── templates/applications.yaml
├── components/              # Everything ArgoCD deploys; one Helm chart per component
│   ├── cluster-topology/    # Wave 0 — node labels, failure domains
│   ├── operators/           # Wave 1 — OLM Subscriptions (cert-manager, NMState)
│   ├── cluster-config/      # Wave 2 — ClusterIssuer, Certificates, NNCPs
│   └── storage/             # Wave 3+ — storage + TLS consumers
├── ansible/                 # Non-cluster home infra, NOT ArgoCD-managed (see below)
│   ├── CLAUDE.md            # ansible rules; Claude Code loads it when a file under ansible/ is read
│   ├── technitium/          # Technitium DNS Server — dns-master + dns-slave (2× RPi 3B+), CLUSTERED
│   └── truenas/             # TrueNAS SCALE NAS config via midclt over SSH (replacing the Synology)
├── macmini/                 # Mac mini (192.168.1.3) helpers installed by hand with their own install.sh (ollama-think-proxy)
├── blog/                    # Working notes / draft posts — see "Blog notes" rule below
├── bugs/                    # Drafted upstream-issue bodies (filing-ready)
├── backlog/                 # Long write-ups of unbuilt TODO items; README TODO is the index
├── tests/                   # Manual-apply test artifacts not yet promoted to a chart
├── data/                    # Captured benchmark / SMART / log artifacts referenced from blog drafts
│                            # └── storage-throughput.md — ALL measured throughput figures, with conditions
├── docs/superpowers/        # GITIGNORED — local specs and plans while work is in flight; the design record goes to blog/ afterwards
├── .claude/
│   ├── settings.json        # Tracked: read-only allowlist + guardrail deny list (settings.local.json is not)
│   └── skills/              # On-demand instructions split out of this file — cluster-health,
│                            # network-change, rook-ceph (+ teardown.md, disk-ops.md), upstream-pr
└── CLAUDE.md
```

**Never write `$` followed by a digit in a `.claude/skills/*/SKILL.md`** (awk fields like `$2`, shell positional
args): Claude Code substitutes the skill's invocation arguments into `$1`, `$2`, … when it loads the skill, so the
command arrives mangled. Use jsonpath filters or `grep` instead. Reference files read directly (`teardown.md`,
`disk-ops.md`) are not substituted.

### Non-cluster infrastructure — `ansible/` vs `components/`

- `components/` + `bootstrap/` are what ArgoCD applies to the cluster. `ansible/` holds things outside the cluster
  that still need versioned, idempotent config — Technitium DNS (`dns-master` `.12` + `dns-slave` `.13`) and the
  TrueNAS NAS — kept off ArgoCD so DNS and the NAS never depend on the cluster being up.
- **Code-only: never propose a web-UI or manual fix for an Ansible-managed box.** Change the role, re-run the playbook.
- `ansible.builtin.*` modules only. Vault passwords are interactive, so **I can't run `ansible/technitium/playbook.yml`
  or `ansible/truenas/playbook.yml`**; `--syntax-check`, technitium `base-only.yml` and truenas `check.yml` I can.
- Full rules and the TrueNAS middleware traps: `ansible/CLAUDE.md`, which loads automatically when I read a file
  under `ansible/`.
- **The Immich photo library lives on TrueNAS since 2026-10-11** (`tank/immich`, static PV
  `truenas-immich-library`, PVC `immich-library-nfs`); its Postgres stays on Ceph.
  Two nightly TrueNAS Cloud Sync tasks copy the photos off that box, to the Synology (`COPY` on purpose, so a deletion in Immich never propagates there) and to a Hetzner Storage Box
  (`blog/blog-offsite-backup-draft.md`). Retiring the old Synology Hyper Backup-to-C2 task is the operator's step; until then it keeps
  reporting green against a frozen directory. Both tasks alert in the cluster when stale (`TrueNASCloudSyncStale`).
  **To stop `immich-server`, set `hpa.enabled: false` in git first** — ArgoCD ignores
  replicas and the HPA undoes `oc scale --replicas=0` within ~30 s. Runbook: `tests/immich-truenas-migration/`.
- **The TrueNAS apps answer at `https://<app>.homelab.sudops.pl` since 2026-11-06** (paperless, syncthing, garage, s3 +
  `*.s3`, truenas, traefik), through the catalog Traefik app: Let's Encrypt wildcard by Cloudflare DNS-01, renewed on
  the box, records in `ansible/technitium`. The TrueNAS UI moved to 8443 (`https://192.168.1.25:8443` is the direct
  fallback) and the plain app ports stay open. The cluster's S3 consumers (Velero BSL, Loki) use
  `https://s3.homelab.sudops.pl`, so they depend on the LAN DNS (Technitium). Probe and alerts: `homelab-tls-probe`.
  Record: `blog/blog-truenas-https-draft.md`.

## Architecture

### App-of-apps + sync waves

The root app at `bootstrap/root-app/` reads `values.yaml` and renders one `Application` per enabled entry. Sync waves enforce ordering:

- **Wave 0** — Cluster topology (node labels, failure domains)
- **Wave 1** — Operators via OLM (Subscription only)
- **Wave 2** — Cluster config that depends on operator CRDs (ClusterIssuer, Certificates, NNCPs)
- **Wave 3** — TLS consumers (IngressController default cert, APIServer serving cert) + storage

For operators bringing CRDs, use **intra-chart** sync-wave annotations: `Subscription` at wave 1, CR (`Certificate`, `NodeNetworkConfigurationPolicy`, …) at wave 5. This avoids CRD-not-yet-installed races on first sync.

### Sync policy (default for all managed Applications)

`automated` (prune + selfHeal), `ServerSideApply=true`, `SkipDryRunOnMissingResource=true`, `CreateNamespace=true`, retry 5× with exponential backoff (5s → 3m).

Argo CD hooks are outside the app's diff, so a value used only by a hook needs a non-hook carrier (e.g. a hash annotation on a normal resource) or the change never syncs (logging-stack, 2026-11-06).

### OLM catalogs

- `okderators` (`quay.io/okderators/catalog-index:5.0`, since 2026-11-10) — OKD community operators. Use for **GitOps** (and cert-manager's way back once okderators publishes 1.21).
- `okd-test-logging` — **Logging and Loki no longer come from `okderators`:** their Subscriptions use the test CatalogSource `okd-test-logging` (`components/operators/logging-test-catalog/`, a zot image under `okd-test/`; installed 6.6.0-2026-11-24-190056 since 2026-11-25, built from Red Hat's 6.6.2 commits by the reworked pipeline PRs #35–#38; soak until 2026-11-26 12:24Z) until okderators publishes 6.6, so a zot outage or data loss stops logging pods from restarting.
- **Every Subscription here is `installPlanApproval: Manual`:** cert-manager, gitops, cluster-logging, loki, oadp, kube-descheduler, NMState, and CNPG and grafana-operator (since 2026-11-10, channel and source unchanged); do not revert that; on Automatic a catalog tag change (e.g. `catalog-index:5.0` moving to a new digest) auto-upgrades all of them at once, including the operator running ArgoCD.
- `operatorhubio-catalog` — upstream OperatorHub.io (`quay.io/operatorhubio/catalog:latest`). Use for **CNPG**, and it is NMState's rollback target (v0.87.0, `components/operators/nmstate/README.md`). In `bootstrap/phase0/01_catalog_source.yaml` with a **24h** registry poll, because every new digest of `:latest` left another index image on the catalog pod's node, node5, which carries mon c (README TODO "Stop the catalog image churn").
- `okd-test-nmstate` — **NMState**: our okderators **5.0** test build (`kubernetes-nmstate-operator.v5.0.0-2026-11-24-184558` since 2026-11-25, catalog `okd-test/nmstate-catalog:2026-11-25-120918`; the refreshed #43, operator `release-5.0` `5f4a6d0`, el10 handler; soak until 2026-11-26 12:31Z, rollback `v5.0.0-2026-11-10-162515`) from the zot catalog in `components/operators/nmstate-test-catalog/`, until okderators publishes the fixed bundle (README TODO "NMState from `okderators`"). Like logging, a zot outage stops NMState pods from restarting.
- `okd-test-oadp` — **OADP**: our okderators 1.6 test build (`oadp-operator.v1.6.0-2026-11-02-205027`) from the zot catalog in `components/operators/oadp-test-catalog/`, until okderators publishes 1.6 (README TODO "OKD 5.0 follow-ups"). Like logging and NMState, a zot outage stops OADP pods (operator, Velero, node-agent) from restarting.
- `okd-test-descheduler` — **the Kube Descheduler**: our okderators 5.4 test build (`clusterkubedescheduleroperator.v5.4.0-2026-11-03-074110`) from the zot catalog in `components/operators/descheduler-test-catalog/`, until okderators publishes 5.4 (README TODO "OKD 5.0 follow-ups" (3)). Like logging, NMState and OADP, a zot outage stops descheduler pods from restarting. It never evicts pods in `openshift-*`, `kube-system` or `hypershift`, by design. 5.4 adds NetworkPolicy `descheduler-operand` (ingress 10258 from monitoring namespaces only), so the `oc get --raw …/services/https:metrics:10258/proxy/metrics` read times out from apiservers on other nodes: read the metrics with PromQL, where the metric's own `namespace` label is `exported_namespace`.
- `okd-test-cert-manager` — **cert-manager 1.21 test build** (`cert-manager-operator.v1.21.0-2026-11-21-163714`, catalog `okd-test/cert-manager-catalog:2026-11-21-170350`) from the zot catalog in `components/operators/cert-manager-test-catalog/`, added 2026-11-21; the Subscription reads it since 2026-11-22 (README TODO "OKD 5.0 follow-ups" (4)(d)). Like the other test catalogs, a zot outage stops cert-manager pods from restarting, and zot's own route certificate is `okd-wildcard`, which this cert-manager renews.
- `community-operators` — a different source: Red Hat's `community-operator-index`, owned by the marketplace operator (240m poll, not ours to change). Used only by **grafana-operator**.
- **The okderators build chain is per-OKD-release.** `okd-operator-pipeline` has `main` plus `release-4.18`/`release-4.20`/`release-4.21`/`release-4.22` branches and no `release-5.0` (checked with `gh` 2026-11-20): **`main` builds OKD 5.0**, `release-4.22` builds 4.22. Same for `okderators-catalog-index`, which has its own `release-4.1x`/`release-4.21`/`release-4.22`/`release-5.0` branches; the cluster reads `release-5.0` (`catalog-index:5.0`). A fix lands on every branch whose catalog it must reach: a `main`-only fix does not reach a release branch's catalog.
- **A submodule's `.gitmodules` `branch =` is NOT what gets built.** `submodule_reset()` in the pipeline's `common.sh` ignores its `branch` argument and resets each submodule to the **recorded gitlink hash**; only `update` (not run by default) consults the branch. So a repo can declare `branch = release-4.21` while the gitlink is a 4.20 commit and every build silently produces 4.20 content. **When checking what an operator is pinned to, resolve the gitlink against the upstream branches (`gh api repos/<o>/<r>/compare/<branch>...<sha>`), don't read `.gitmodules`.**
- **OLM v1 (catalogd + operator-controller) is installed and unused.** Every operator here is an OLM v0 `Subscription`. The three Red Hat default `ClusterCatalog`s (`openshift-redhat-operators`, `-certified-operators`, `-redhat-marketplace`) are held at `availabilityMode: Unavailable` by `components/cluster-config/olm-v1-catalogs/` — no entitlement for their content, and the redhat one leaked catalog temp dirs into operator-controller's emptyDir on node5 until Ceph raised `MON_DISK_LOW` (upstream fix operator-framework/operator-controller#2574; record `blog/blog-olm-v1-catalogs-draft.md`). `openshift-community-operators` stays Available. Do not "fix" the Unavailable catalogs back; do not confuse them with the OLM v0 `CatalogSource`s in `openshift-marketplace`, which are untouched.

### Operator patterns

- Every operator component = `Namespace + OperatorGroup + Subscription` (+ CR in a later sync wave if needed).
- **Cluster-scoped** operators (cert-manager): `OperatorGroup` with `spec: {}`.
- **NMState**: `OperatorGroup` with `spec: {}` too (AllNamespaces), installed into `openshift-nmstate`. With the okderators build the operand lives there too (`HANDLER_NAMESPACE` from `metadata.namespace`). The handler DaemonSet runs on every node (CR `spec: {}`). The rollback to the community build re-adds a per-node gate in its own commit (`components/operators/nmstate/README.md`). An NNCP whose node has no handler reports `NoMatchingNode`/`Ignored` and `nmstate-nncp` reads `Suspended`; the node keeps its network config.

### TLS / cert-manager

- Let's Encrypt **production**, DNS-01 via **Cloudflare**.
- The DNS-01 resolver uses public nameservers (`1.1.1.1`, `8.8.8.8`) — cluster DNS can't resolve external domains, and without this override the challenge fails.
- Wildcard cert `*.apps.okd.sudops.pl` → `openshift-ingress`.
- API cert `api.okd.sudops.pl` → `openshift-config`.
- Cloudflare API token is provisioned via the SealedSecret in `components/cluster-config/cert-manager-config/templates/sealed-cloudflare-api-token.yaml`. Rotation = re-`kubeseal` + commit (one-liner in that chart's `values.yaml`).
- **sealed-secrets controller runs `--key-renew-period=720h` (auto-rotation) — NEVER set it to `0`.** `0` disables rotation, which once let the sealing key's cert expire and blocked ALL new sealing cluster-wide (decryption kept working; history in `components/operators/sealed-secrets/README.md`). The controller's **public sealing cert is committed at `components/operators/sealed-secrets/sealed-secrets-pub.pem`** for offline `kubeseal --cert` (public key = seal-only, safe to commit; refresh after a rotation via `kubeseal --fetch-cert`).

## Storage (Rook-Ceph)

Rook v1.21.1 (since 2026-11-06) managing Ceph Tentacle 20.2.5 (since 2026-11-09) on three NVMe OSDs (`osd.0-2`, one per node, failure domain `host`). Upgrade runbook `tests/rook-ceph-upgrade/README.md`, record `blog/blog-rook-ceph-draft.md`. Open items are in README TODO "OKD 5.0 follow-ups" (2). CSI keys stay `aes` by design; four `AUTH_INSECURE_*` health checks are muted (`muteHealthWarning` in the cluster chart's `values.yaml`) and still show as `(MUTED, STICKY)` in `ceph health detail`, the CephCluster status and the dashboard. **Standing health is Ceph HEALTH_WARN from `BLUESTORE_SLOW_OP_ALERT` only (known-benign); `AUTH_INSECURE_SERVICE_KEY_TYPE` / `AUTH_INSECURE_SERVICE_TICKETS` (HEALTH_ERR) would be new and real.** Two
pools: `nvme-replicated` (RBD, StorageClass `ceph-nvme-block`) and `.mgr`. There is no HDD tier, CephFS or in-cluster
object store: RWX is the NFS classes (`nfs-csi`, `nfs-truenas-*`), S3 is garage on TrueNAS.
Charts: operator `components/operators/rook-ceph/`, cluster `components/storage/rook-ceph-cluster/` (OSD devices,
pools and CRUSH live in its `values.yaml`).

**Load the `rook-ceph` skill (`.claude/skills/rook-ceph/SKILL.md`) before any Ceph, RBD or CSI diagnosis, any storage
change, and any Rook/Ceph PR review.** Teardown and drive-hardware procedures are reference files inside it.

Rules that hold even when the skill is not loaded:

- **No drain headroom** — 3 OSDs on 3 nodes, so any OSD-affecting change is a degraded window. Never run two
  OSD-impacting changes at once; never propose `oc cordon node{4,5,6}` without an explicit ask.
- **Rook and Ceph are bumped by hand, never by Renovate** — both Rook charts at the same version, Rook↔Ceph
  compatibility checked, Ceph only after Rook. Storage version PRs default to NOT-APPROVE.
- **No `network.provider` or Multus change without `kubectl-rook-ceph multus validation run` first**, and a
  30-minute cap on storage-mode debugging before tearing down.
- **Don't touch `enp1s0f0np0`, `ceph-shim` or `192.168.10.0/24` routing** without reading
  `blog/blog-multus-ceph-migration-draft.md` — those routes are load-bearing.
- **A pod that needs the NAS uses `192.168.1.25`** (S3 by name, `s3.homelab.sudops.pl`, which resolves to it) — pod-network → backnet (`192.168.10.x`) egress does not work.
- **Read per-pool `MAX AVAIL`, never cluster-level `avail`**, and re-measure hours after a snapshot deletion.
- **Every storage action goes in a blog draft** — no exception for small ones.
- Ceph-internal mutations (`ceph mgr fail`, `rbd trash purge schedule add`, …) may be appropriate — flag and confirm
  before running.

### Node drain and unplanned rerolls

- **Never run a 1-instance CNPG cluster on the master pool** — its primary PDB blocks every drain. media-postgres,
  immich-postgres and homebox-postgres run 2 instances.
- **Never delete the `powersave-experimental` Tuned CR by hand** — NTO drops `50-nto-master` and MCO rerolls a node.
  Change `bootArgs` in `components/cluster-config/power-tuning/values.yaml` instead.
  The way to take it off temporarily without the double reboot: switch off auto-sync on **both** `power-tuning` and
  `root-app` first, then delete the CR — one clean three-node reroll. While `root-app` auto-sync is off, a change to
  `bootstrap/root-app/values.yaml` does not reach the cluster. Switching `root-app` auto-sync back on restores
  `power-tuning`'s policy and the CR, which is a second clean reroll. The CR pins every core at its minimum frequency
  (passive driver + `powersave` governor); see `blog/blog-power-consumption-draft.md` 2026-10-16.
- The unblock recipe and the full history: `network-change` skill.

## Validation workflow

Every change to a chart must pass **lint → template → schema-validate → diff** before commit. Don't skip steps.

```bash
# 1. Lint the chart
helm lint components/<category>/<name>/

# 2. Render templates (catches missing values, bad Go templating)
helm template <release> components/<category>/<name>/ \
  -n <target-ns> -f components/<category>/<name>/values.yaml

# 3. Schema-validate (including CRDs) against upstream + OpenShift schemas
helm template <release> components/<category>/<name>/ | \
  kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# 4. Read-only diff against the live cluster before committing
helm template ... | oc diff -f -
```

Render the root app itself to inspect generated `Application` resources:

```bash
helm template root-app bootstrap/root-app/ -f bootstrap/root-app/values.yaml
```

## Adding a new ArgoCD-managed component

1. Create the Helm chart at `components/<category>/<name>/` (`operators`, `cluster-config`, `storage`, `cluster-topology`).
2. Add an entry in `bootstrap/root-app/values.yaml` with `enabled: true` and the correct sync wave.
3. Render `bootstrap/root-app/` locally and confirm the generated `Application` looks right.
4. If it installs an operator with CRDs: `Subscription` at wave 1, CRs at wave 5 (intra-chart annotations).
5. Run the full validation workflow above.
6. Commit directly to `master`; ArgoCD picks it up on its next poll.

## Debugging order of operations

When an Application is `OutOfSync`, `Degraded`, or just "stuck", check in this order — don't skip ahead:

1. `oc -n openshift-gitops get application <name> -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}{.status.operationState.message}{"\n"}'` — sync status, health, last operation message. (The `argocd` CLI is installed but not logged in, and `argocd login` is denied.)
2. `oc get events -n <namespace> --sort-by=.lastTimestamp | tail -30` — admission/validation failures.
3. `oc describe <kind> <name> -n <ns>` — per-resource conditions.
4. For operator-managed resources: `oc get csv -n <operator-ns>` and `oc get subscription -n <operator-ns>` first — a stuck CSV blocks everything downstream.
5. For cert-manager: `oc describe certificate <name> -n <ns>` → `CertificateRequest` → `Order` → `Challenge`. DNS-01 failures are almost always Cloudflare token expired or wrong zone.

### Network-stack changes and pod-egress breaks

**Load the `network-change` skill before any NNCP, MachineConfig, `Network/cluster`, IPsec or MTU change, a planned
node reboot or 10G-switch firmware work — and when pods lose egress after a link event.** It holds the pre-flight
runbook, the node-drain blockers and the `br-ex.forwarding` mechanism. The one check to remember:
`net.ipv4.conf.br-ex.forwarding` must read `1` on every node; `0` means pod→remote-host egress is broken on that node,
and restarting its `ovnkube-node` fixes it.

## Guardrails — do not do these

Claude should refuse these actions and explain why briefly:

- **Mutating cluster commands only with the operator's explicit approval (operator, 2026-11-02).** `oc`/`kubectl` `apply`, `create`, `delete`, `patch`, `replace`, `edit`, `scale`, `rollout`, `label`, `annotate` and `set` are `ask` rules in `.claude/settings.json`, so each one prompts, in auto mode too. I say what I am about to run and why, and the operator's answer to that prompt is the approval. It covers that command only: not a later one, and approving a plan approves no command in it. Subagents never run these. `oc adm`, `oc cp`, `helm install/upgrade/uninstall/rollback` stay denied. ArgoCD still owns cluster state, so a change that belongs in git goes in git; a direct edit to an ArgoCD-managed resource drifts and is reverted.
- **No state mutation on external tools** (`terraform apply/destroy`, `terraform state mv/rm`, `argocd app sync --force` with prune).
- **No committed secrets.** No Cloudflare tokens, kubeconfigs, TLS private keys, OLM pull secrets. Reference secrets by name and assume they exist out-of-band.
- **No editing generated files**: `Chart.lock`, rendered manifest dumps, `*.orig`.
- **No OKD version bumps or cluster-wide CR changes** without an explicit ask — those are upgrade events, not routine edits.
- **Do not disable `automated.prune` or `selfHeal`** to "fix" a sync issue. Fix the manifest instead.

## Skills — the `superpowers` plugin

Not every skill fits this repo; some contradict rules stated elsewhere in this
file. **A skill never overrides a guardrail.** If a skill's instructions conflict with the Guardrails section or
with a rule below, the repo rule wins and I say which one I am following and why.

**Use these by default, without being asked:**

- **`systematic-debugging`** — before proposing a fix for any incident, failed sync, or unexpected output. It
  guards against exactly this repo's recurring failure: guessing a cause from a plausible-looking signal. Real example that would have been caught:
  reading `.gitmodules` instead of resolving the gitlinks (more in the vault note `_memory/chats/homelab/2026-11-20-claude-code-tooling-history.md`).
- **`verification-before-completion`** — before claiming anything is done, fixed, or passing, and before every
  commit. Pair it with the Validation workflow. This repo has repeatedly shipped a confident claim that was
  wrong, often from my own broken check or manual run.
- **`brainstorming`** — before designing something new: a new chart, a monitoring surface, a migration plan, an
  upstream contribution's shape. Not for routine edits, version bumps, or doc updates.
- **`writing-plans` / `executing-plans`** — multi-step supervised work with a degraded window or a rollback
  story: OKD minor upgrades, Rook/Ceph bumps, storage migrations, teardown+rebuild. These pair with the
  "no drain headroom" and "30-minute cap" rules rather than replacing them.
- **`requesting-code-review` / `receiving-code-review`** — upstream PR work, and any change to a chart that a
  degraded-window procedure depends on.
- **Agents — use them as much as possible (operator, 2026-10-14).**
  Execute a written plan with `subagent-driven-development`, and hand research, broad code search, reviews and
  other independent work to the Agent tool (`dispatching-parallel-agents` when several pieces are independent).
  Subagents work on `master` like I do, with no worktree and no branch (rule below), and never push. Every
  dispatch prompt repeats the rules its task touches: secrets, the commit message style, no `Co-Authored-By`
  trailer. The Workflow tool's multi-agent scripts are not covered by this and still need the operator's ask.
- **Every proposed plan gets an Opus review (operator, 2026-11-02; reviewer model changed from Fable to Opus on
  2026-11-20: "remove fable as mandatory reviewer (keep opus)").** Anything I ask the operator to approve as a plan (a
  plan, a design, a spec, a runbook), whether it sits in a file or in chat, gets one read-only review agent with
  `model: "opus"` before I ask for approval or start the work. Give it the plan, the spec and the facts it needs, not my
  conclusions. Fix the findings that hold up, then present the plan with what the review found, what I changed and what
  I rejected and why. A single-step suggestion is not a plan. Every other review keeps the skills' normal model choice:
  per-task reviews and scoped re-reviews in `subagent-driven-development`, final whole-branch reviews, and PR reviews.

**These conflict with existing rules — the repo rule wins:**

- **`using-git-worktrees`, `finishing-a-development-branch`** assume a feature-branch workflow. This repo commits
  **direct to `master`** (ArgoCD watches it) — no feature branches, no PRs, per the standing instruction. Do not
  create a branch or worktree for homelab changes. **Exception:** upstream contribution clones under the
  scratchpad (`okd-operator-pipeline`, etc.) are separate repos with their own conventions, and there branches
  are correct.
- **`test-driven-development`** assumes a unit-test suite. There isn't one. The analogue here is the
  **Validation workflow** (`helm lint` → `helm template` → `kubeconform` → `oc diff`) and, for upstream work,
  actually running `build_containers` / `make bundle` / `opm validate` before claiming a change works. Apply the
  spirit — demonstrate the failure, then demonstrate the fix — not the letter (e.g. `opm validate` failing on the
  unfixed graph *and* passing on the fixed one).
- **`brainstorming`, `writing-plans`** say to commit the spec and plan. In this repo they stay local
  (`docs/superpowers/` is gitignored; the repo is public). After implementation the design and its reasons go into
  the blog draft and both files are deleted (operator, 2026-10-14).

**`using-superpowers`** is the meta-index for finding the others. **`writing-skills`** only applies when
authoring a new skill.

## Upstream PRs and comments

Every upstream PR is opened with `--draft` and stays draft — marking it ready and merging are the user's calls.
Write the change plainly: what changed, why, how it was checked; no debugging narrative. **Load the `upstream-pr`
skill (`.claude/skills/upstream-pr/SKILL.md`) before drafting any upstream PR, issue or comment** — it holds the
full writing rules.

**Container image builds run on the cluster, not on the Mac (operator, 2026-10-20).** Any build of operator or
other container images (okd-operator-pipeline `build.sh`, bundles, test catalogs) runs as a one-off Job on this
cluster: the nodes are amd64 like upstream's CI runners, so the images can also be installed here, while the Mac is
arm64 and emulating amd64 is far too slow. Shape: a throwaway namespace; podman in a pod, which needs the `privileged` SCC (image: our own zot copy `okd-test/podman/stable:v5.8.9-2026-10-26@sha256:68e44184…`, because quay expires old `podman/stable` digests; why and how to refresh it under a new dated tag: `tests/okderators-logging-build/README.md`); build storage on a
temporary `ceph-nvme-block` PVC, never node root disks (each carries a mon, and node5's has crossed the
`MON_DISK_LOW` line twice); images pushed to zot under `okd-test/`, never under a path that matches a real upstream
repository (zot is the cluster's pull-through mirror for quay.io, docker.io, ghcr.io and registry.k8s.io, so such a
push would shadow the real image cluster-wide). zot's PVC is 48 GiB: measure after
a build and delete test images when done, because a full zot breaks image pulls for the whole cluster. The Job
manifests live under `tests/`; the operator applies and deletes them. Expect roughly 3× longer builds while the
`powersave-experimental` Tuned pins cores at minimum frequency. Local tools for the Mac itself (e.g. the patched
`immich-go`) still build on the Mac.

## Commit and branch conventions

- Commit directly to `master` — ArgoCD watches it. No feature branches and no PRs for this repo; the only branches are upstream-contribution clones and the parked `cert-manager-helm-fallback`.
- **Commits and SSH pushes need the operator's YubiKey (since 2026-11-16).** Commits are SSH-signed with a hardware key, which needs a touch and sometimes a PIN, so I cannot commit or push. I stage as I go, and at each break point (always at "call it") I hand over one command for the operator's own terminal that chains the commits and the push. Not with `!`: that has no TTY, so the PIN prompt fails. Subagents stage and never commit. No commits through the GitHub API with a token (rejected 2026-11-17).
- Commit messages: `<scope>: <imperative summary>` — e.g. `cert-manager: bump to v1.16.2`, `root-app: add monitoring stack`, `storage: enable fd-b zone`.
- One logical change per commit. The rendered-manifest diff should be predictable from the message alone.
- Renovate PRs (label `dependencies`) are reviewed, not rewritten.

## Communication preferences

- Be concise and technically precise. Skip hedging, flattery, and recap of what I just said.
- Surface trade-offs honestly. If there's a simpler or more idiomatic approach than what I asked for, say so before implementing.
- When proposing a change, include the exact commands to validate it locally.
- Cite OKD, Helm, ArgoCD, or cert-manager docs by version when version-specific behavior matters.
- Prefer a short correct answer with one follow-up question over a long answer that guessed at my intent.
- **If something is unclear, ask — don't assume.** When a request, an unpicked option, or a fact I can't verify
  leaves more than one reasonable reading, stop and ask before acting on it. A "go ahead" covers what was
  actually decided, not a choice I left open.

## MCP servers

`.mcp.json` declares one project-scoped MCP server, launched via `npx` when Claude Code starts in this repo.

- **`kubernetes`** (`mcp-server-kubernetes@4.2.3`, pinned; Renovate tracks the pin through a custom manager on `.mcp.json`) — structured `kubectl_get` / `kubectl_describe` / `kubectl_logs` / `explain_resource` / `list_api_resources` tools. It runs as the **readonly `claude-reader` SA** (`KUBECONFIG_PATH=${HOME}/.kube/config-readonly`), so it keeps working when the operator's OAuth login expires. `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS=true` only removes the delete-type tools; `kubectl_apply`, `kubectl_patch` and `kubectl_scale` are still listed, and the SA's RBAC is what refuses them (the flag does hide `exec_in_pod`). That SA can read Secrets — never read a secret value through it either.
- **Only `kubernetes` is meant to load here (2026-10-14).** The operator's user-scope servers `azure`,
  `azure-devops` and `obsidian-vault` are disabled for this project with `/mcp disable <name>` (stored per project in
  `~/.claude.json` as `disabledMcpServers`). The claude.ai connectors are off via `"disableClaudeAiConnectors": true`
  and the claude.ai-synced `design` plugin via `"enabledPlugins": {"design@synced": false}`, both in
  `.claude/settings.local.json`. The two Azure servers run unpinned (`@latest`) with Azure CLI credentials. Re-enable one with
  `/mcp enable <name>` when a task needs it.
- **GitHub: use `gh`, not an MCP server.** `@modelcontextprotocol/server-github` is deprecated on npm. `gh` is not logged in on this workstation, so pass the token inline: `GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN" gh …`. Upstream cross-referencing works the same way (`gh issue view -R <owner>/<repo> <n>`, `gh search issues …`).

Mutations against the cluster need the operator's explicit approval (Guardrails); the MCP server's readonly SA cannot do them at all.

Permissions: `.claude/settings.json` is tracked and holds the read-only allowlist, the **`ask` list** (`oc`/`kubectl` create, apply, patch, delete and the other mutating verbs in both `oc <verb>` and `oc -n <ns> <verb>` forms; since 2026-11-02 they prompt instead of being denied) and the **guardrail deny list** — `oc adm`/`cp`/`port-forward`, `kubectl cordon/drain/debug/exec/cp/port-forward`, `helm install/upgrade/uninstall/rollback`, `argocd app sync`, `gh pr merge/ready/review/close`, force-push/hard-reset, the token-printing `oc whoami -t` / `oc config view --raw`, and reads of kubeconfigs/`.env`/secrets. Deny beats ask, ask beats allow, and deny and ask rules match past a leading `KUBECONFIG=…` assignment and on any part of a compound command. "Don't ask again" on a prompt cannot override a project `ask` rule, so each command keeps prompting. `.claude/settings.local.json` stays untracked (git, gh reads, ssh, WebFetch domains, MCP tool approvals). Editing either file from a session is blocked by auto mode as self-modification — the user applies settings changes.

## Reviewing open PRs (`sudoom/homelab`)

Check open PRs at session start and whenever a dependency PR is relevant, and give **APPROVE / HOLD / NOT-APPROVE**
per PR with a one-line reason. Storage version bumps (Rook, Ceph) default to NOT-APPROVE. I advise; the user merges.
Verdict rules and the `gh` commands: `cluster-health` skill.

## Session hygiene

- **Minimize Bash output tokens.** Long sessions on this repo routinely eat 20%+ of context on diagnostic dumps. Pipe through `head`, `tail`, `grep`, `awk` to extract only the lines that drive a decision. For files, use `Read` with `offset`/`limit` instead of `cat`. Specifically avoid: `oc describe pod ...` without a grep filter (the events tail is what matters, the spec block isn't), `oc get xxx -o yaml` for anything bigger than a small CR (jsonpath-targeted reads instead), `oc adm top` or `ceph -s` dumps where a single-line jsonpath would do.
- Before the context window is compacted, run `/export` to preserve the full conversation.
- When diagnosing a live issue, paste real `oc` / `argocd` output into chat rather than describing it — diagnoses from raw output are much better than from paraphrase.
- **At session start and immediately after a context compaction**, re-read the markdown files that carry working state, in this order — don't rely on the post-compaction summary alone:
  1. `CLAUDE.md` (this file) — rules may have tightened since the snapshot.
  2. Any `blog/blog-*-draft.md` files relevant to the work in flight — these are the chronological notes for what was tried, what worked, and what's still open.
  3. The TODO list at the bottom of `README.md` — confirm what's still queued vs. shipped.
  4. Auto-memory `MEMORY.md` (loaded automatically) plus the linked memory files — re-skim before assuming a remembered fact still holds.

  Compaction summaries are lossy by design; the markdown is the source of truth.

- **Session start: run the `cluster-health` skill before the first real work** — health sweep (readonly
  kubeconfig), open-PR verdicts, firing-alert triage. A dirty sweep or an actionable alert blocks the requested work
  until it is surfaced.

- **Before proposing anything that might already exist, check the docs first.** Re-reading at session start (above) isn't enough — when you're about to suggest "we should ship X" or "let's add Y", grep `blog/`, `CLAUDE.md`, `README.md`, `MEMORY.md`, and the relevant `components/<area>/` first. The user shouldn't have to be the verifier-of-last-resort that I read what they already wrote down. Specifically: any "we should add Z" or "follow-up: ship Z" claim is a search trigger — `grep -ri "Z" blog/ CLAUDE.md README.md components/` before saying it. Same applies for "this isn't done yet" / "this is missing" / "we need to think about" — if the docs say it's done, it's done; trust the docs over your own model.

## Ending a session ("call it")

On "call it", "wrap up", "end of session" or similar, run the `cluster-health` skill's wrap-up before saying goodbye:
(1) docs drift — README TODO, CLAUDE.md, chart READMEs, blog drafts; (2) repo cleanup; (3) the cluster health sweep,
expected clean. Each pass is its own commit. End with a one-paragraph session ledger (commits + final state).

## Blog notes — keep them current

Every session that diagnoses an issue, changes infrastructure, or runs a non-trivial benchmark should be captured in a blog-style draft under `blog/`. These drafts are the working memory for future write-ups.

- **File naming:** `blog/blog-<topic>-draft.md` (e.g. `blog/blog-rook-ceph-draft.md`, `blog/blog-cert-manager-draft.md`). One file per topic, appended over time.
- **If a relevant draft exists:** update it. Add new sections rather than rewriting old ones, so the chronology survives.
- **If no relevant draft exists:** create one. Lead with a one-paragraph framing, then the technical content.
- **What to capture:**
  - Every meaningful command run (with the exact invocation, not paraphrased — `oc -n rook-ceph exec ...`, full `helm template` lines, etc.).
  - Raw output snippets that drove a decision (errors, `ceph -s`, `oc describe` excerpts).
  - The decision made and *why*, including alternatives ruled out.
  - Sequencing: a rolling restart, a network change, a PG bump — list the steps in order so it can be retraced.
- **Tone:** technical, first-person, no marketing fluff. These are notes that may become posts later, not the posts themselves.
- **Not to capture:** secrets, tokens, raw kubeconfigs, anything that would be a problem if the draft were committed publicly. Reference secrets by name.

Update the draft as you work, not at the end. If a session does something undocumented, that's a regression — flag it.

**Don't ask for permission to create or update blog drafts, READMEs, or any documentation that this CLAUDE.md says to keep current.** Just do it as part of the work, in the same commit/series as the change that prompted it. Asking "should I write this up?" is friction; the answer is always yes when the rule applies.

## TODO list lives at the bottom of README.md

The repo's TODO list is the structured section at the bottom of `README.md` (categories: In flight, Queued — observability, Queued — storage, Queued — platform plumbing, Queued — operators / catalog, Queued — platform expansion). Treat it as the single source of truth for tracked work.

- **When you suggest a new TODO** (e.g. you spot a gap during a session and the user agrees it should be tracked): add it to the appropriate category in `README.md`. Do not invent a separate TODO file. Match the existing item style — bold lead-in, then the *why* / *what* / *how to validate* in one or two sentences.
- **When the user gives input that refines an existing TODO** (more context, a chosen approach, a deadline, a reason it's deprioritized): update that item in place rather than appending a duplicate. Preserve chronology only when it matters; otherwise rewrite for clarity.
- **When a TODO ships:** remove it from the README in the same commit that lands the change. Don't leave checked-off items as historical record — the git log is the historical record.
- **Don't reorganize categories or split items into subsections without an explicit ask** — the existing structure is deliberate.
- **An item carries what is open, why, and how to validate.** Its history goes to its blog draft, with a link.
- **Long design or assessment of work not yet built lives in `backlog/<topic>.md`** (`backlog/README.md`): the TODO item
  keeps 1–2 lines and the link; delete the file when the item ships and move its record to the blog draft. This is the
  one exception to "Do not invent a separate TODO file": the README TODO stays the index.

## README files — keep them current

Whenever you change something that a `README.md` describes, update that README in the same change. READMEs that drift out of sync are worse than no README at all — readers trust them and end up running stale commands.

- **Scope:** every `README.md` in the repo (root, `components/<component>/README.md`, `bootstrap/<thing>/README.md`, etc.). Find them with `find . -name README.md -not -path './charts/*'` before assuming there's only one.
- **Triggers that require a README update:**
  - Bootstrap steps changed (commands, file paths, prerequisites).
  - A component's purpose, sync wave, or values surface changed.
  - Architecture diagram in the README no longer reflects what's deployed.
  - Repository layout changed (directory moved/renamed).
  - A new component was added that belongs in the top-level overview.
- **What good looks like:** the README's commands, paths, and version pins match `git ls-files` reality. Sync waves listed in the README match `bootstrap/root-app/values.yaml`. If you can't run a command from the README copy-paste and have it succeed, the README is broken.
- **If a README is wrong but unrelated to your change:** flag it, don't silently fix it in an unrelated commit. Open a separate `docs(readme): …` commit.

Treat outdated READMEs the same as undocumented sessions — a regression to flag.

## Companion knowledge base — Obsidian vault

This codebase pairs with a personal+work Obsidian vault that holds long-form context this repo's CLAUDE.md / READMEs intentionally don't.

- **Vault path:** `/Users/vadzimdziadziulia-laptop/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notatki/`
- The vault is its own git repo with auto-commit on save; iCloud handles cross-device sync.

### What lives there (not here)

- **Decisions journal** for homelab work — `_memory/chats/homelab/YYYY-MM-DD-<topic>.md`. Use for non-trivial decisions whose "why" is worth preserving past a commit message (drive choice, NAS migration plan, capacity sizing).
- **Synthesized knowledge** — `wiki/{sources,entities,concepts,domains}/` — built up over time from `/wiki-ingest` of READMEs, ADRs, conversations.
- **Operating-state notes** — `Infrastructure/Homelab.md` (IP plan, VLAN plan, rack layout, port plan). Excalidraw diagram lives in `Excalidraw/`.
- **Navigation back to this repo** — `Infrastructure/Homelab repo.md` (where in the codebase to look for what).

### When to read from the vault from here

- Looking for the **rationale** behind a hardware/architecture decision that isn't obvious from the manifests (e.g., "why these NVMe drives", "why this VLAN plan"). The commit message usually points; the decision lives in vault `_memory/chats/homelab/`.
- Looking for **operating state** the repo doesn't track — what's racked vs on the shelf, last burn-in date, drive serials.
- Looking for **cross-domain context** the repo doesn't own (interactions with personal finance buckets, broader IP plan beyond the cluster, etc.).

### When to write to the vault from here

- After a non-trivial homelab decision: file a `_memory/chats/homelab/YYYY-MM-DD-<topic>.md` chat-memory note (preferred via vault `/save`; or write directly with the frontmatter required by the vault's `CLAUDE.md`).
- After a meaningful architectural change: trigger `/wiki-ingest` against the changed README or component from within the vault.

### Read permissions

This repo's `.claude/settings.json` whitelists `Read(~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notatki/**)`; the vault's `.claude/settings.json` whitelists `Read(~/Projects/homelab/**)`. **Absolute paths in a permission rule need `~/` or `//` — a single leading `/` is relative to the project root.** **One `Read(path)` rule covers every file-reading tool (Read, Glob, Grep) — separate `Glob(path)`/`Grep(path)` entries are no-ops** and Claude Code warns about them at startup. Native Read works on absolute paths in both directions — no MCP needed for cross-repo reads.

### Downstream: the published blog (sudops.pl)

The `blog/*-draft.md` files in this repo are the **upstream raw material** for the public homelab blog at **[sudops.pl](https://sudops.pl)** — repo `/Users/vadzimdziadziulia-laptop/Projects/sudops.pl` ([sudoom/sudops.pl](https://github.com/sudoom/sudops.pl), Astro).

- Pipeline: this repo's `blog/*-draft.md` (raw session chronology) → `sudops.pl/posts/*.md` (gitignored raw draft) → `sudops.pl/src/content/blog/*.mdx` (published).
- The blog repo reads THIS repo for ground truth (manifests, versions, commands) and the vault for the "why". You don't push to the blog from here — keep the drafts current per the "Blog notes" rule above; the blog repo pulls from them.
- Same secret-hygiene rule applies: drafts feed a public site, so never put real tokens/keys/kubeconfigs in `blog/*-draft.md`.
