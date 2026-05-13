# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Repository overview

Homelab GitOps repository for a **3-node bare-metal OKD 4.20 cluster** (OpenShift Kubernetes Distribution), managed declaratively by **ArgoCD** with an app-of-apps pattern and Helm templating.

- **Cluster domain:** `okd.sudops.pl`
- **Nodes:** 3 control-plane+worker; frontend `192.168.1.7–9`, storage backnet `192.168.10.2–4`
- **Failure domains** (`topology.kubernetes.io/zone`): `fd-a → node4`, `fd-b → node5`, `fd-c → node6`
- **Ingress:** `*.apps.okd.sudops.pl` (wildcard, cert-manager)
- **API:** `api.okd.sudops.pl`
- **Git:** `git@github.com:sudoom/homelab.git` — `master` = production (ArgoCD tracks), `develop` = working branch

## Stack and tool versions

Pin these when generating manifests or commands — mismatched versions are the single largest source of wrong suggestions.

| Tool            | Version        | Notes                                                                 |
|---|---|---|
| OKD             | 4.20           | Kube API ≈ upstream 1.31                                              |
| Helm            | v3             | Helm v2 syntax is invalid; no Tiller                                  |
| ArgoCD          | v3.1.11+cc053b2     | Server-side apply + sync-wave annotations used throughout             |
| OLM             | OKD-bundled    | `okderators` + `community-operators` CatalogSources                   |
| cert-manager    | v1.18.2     | Installed via OLM from `okderators`                                   |
| oc / kubectl    | matching 4.20  | Prefer `oc` for OpenShift-only kinds (Route, SCC, ImageStream)        |
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
│   └── technitium/          # Technitium DNS Server (replaces pi-hole; RPi 3B+ on the LAN)
├── *-values.yaml            # Helm values for tools installed OUTSIDE the root app
│                            # (Cilium, Istio, Prometheus, ArgoCD itself, Kiali)
├── blog/                    # Working notes / draft posts — see "Blog notes" rule below
├── bugs/                    # Drafted upstream-issue bodies (filing-ready)
├── tests/                   # Manual-apply test artifacts not yet promoted to a chart
├── data/                    # Captured benchmark / SMART / log artifacts referenced from blog drafts
└── CLAUDE.md
```

### Non-cluster infrastructure — when to use `ansible/` vs `components/`

- `components/` and `bootstrap/` are for things ArgoCD applies to the OKD cluster. Single source of truth, automated sync, selfHeal, etc.
- `ansible/` is for things that live **outside the cluster** but still need version-controlled, idempotent configuration — e.g. the home DNS server (`technitium/dns-master` on an RPi 3B+ on the LAN).
- **Why split this way:** DNS (and similar foundational LAN services) must not be circularly dependent on the OKD cluster being up. If the cluster's storage hangs (2026-05-12 incident), the dashboards go dark — losing DNS at the same time would compound the outage.
- Each `ansible/<topic>/` directory is a self-contained Ansible playbook: `inventory.yml`, `playbook.yml`, role dirs, and a `README.md` with the bootstrap walkthrough + day-2 flow. Apply manually from a workstation; do not wire into ArgoCD.
- **All-builtin invariant**: `ansible/` playbooks use `ansible.builtin.*` modules only — no `community.general` / `ansible.posix` / etc. Keeps the operator workstation setup to a single `ansible-core` install.
- Secrets live in `vars/vault.yml` (Ansible Vault encrypted, gitignored). A `vars/vault.yml.example` template is committed alongside.
- **Vault password is interactive each run** (`--ask-vault-pass`). No `--vault-password-file`, no env-var, no on-disk password file — deliberate. Practical consequence for Claude: **I can't run vault-requiring playbooks** (`playbook.yml`, `upgrade.yml`) on the user's behalf via Bash, because Bash tool calls aren't interactive. The operator runs those manually. Claude *can* run `base-only.yml` (validates SSH + sudo + base role end-to-end without the vault) and `--syntax-check` on anything; that's the scoped subset.
- **Code-only changes — never propose web UI / manual fixes for `ansible/`-managed boxes.** If a change needs to happen on `dns-master` (or any future Ansible-managed host), it goes through the Ansible role + a playbook re-run. Don't suggest "fix it in the Technitium web UI now" as a quick path — even when it's faster — because the next playbook run won't preserve the manual change unless it's also in the role. If the playbook isn't doing what's expected, debug the role; don't bypass it. Same principle as ArgoCD for the cluster: code is the source of truth.

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

### OLM catalogs

- `okderators` (`quay.io/okderators/catalog-index:4.20`) — OKD community operators. Use for **cert-manager**.
- `community-operators` — upstream OperatorHub.io. Use for **NMState** (the okderators build has an ImageStream bug).

### Operator patterns

- Every operator component = `Namespace + OperatorGroup + Subscription` (+ CR in a later sync wave if needed).
- **Cluster-scoped** operators (cert-manager): `OperatorGroup` with `spec: {}`.
- **Namespace-scoped** operators (NMState): `OperatorGroup` with `targetNamespaces`.

### TLS / cert-manager

- Let's Encrypt **production**, DNS-01 via **Cloudflare**.
- The DNS-01 resolver uses public nameservers (`1.1.1.1`, `8.8.8.8`) — cluster DNS can't resolve external domains, and without this override the challenge fails.
- Wildcard cert `*.apps.okd.sudops.pl` → `openshift-ingress`.
- API cert `api.okd.sudops.pl` → `openshift-config`.
- Cloudflare API token is provisioned via the SealedSecret in `components/cluster-config/cert-manager-config/templates/sealed-cloudflare-api-token.yaml`. Rotation = re-`kubeseal` + commit (one-liner in that chart's `values.yaml`).

## Storage (Rook-Ceph)

The cluster's storage is **Rook-managed Ceph Squid (19.2.3)**. The operator is shipped via the upstream `rook-ceph` Helm chart; the `CephCluster` CR + pools + StorageClasses are vendored as raw manifests under `components/storage/` (not the `rook-ceph-cluster` subchart yet — see TODO). Suggestions and changes around storage need to respect the constraints below.

### Topology

- **3 OSDs total**, one per node, each on a single NVMe device. Failure domain is `host` (the failure-domain labels are `fd-a/fd-b/fd-c`, one per node).
- **No drain headroom.** Any rolling change to OSDs (rebuild, encrypt-at-rest, redeploy) goes through a degraded window — there is no fourth node to absorb the missing OSD. Plan accordingly: schedule during quiet IO, never run two OSD-impacting changes at once, never propose `oc cordon node{4,5,6}` without an explicit ask.
- **Mons:** 3-of-3, one per node. Same topology constraint applies.
- **Network:** Frontnet (VLAN 5) for clients; storage backnet (VLAN 10, 192.168.10.2-4) for OSD ↔ OSD replication. Multus migration in flight (2026-05-11): NADs + per-node macvlan host-shim (`ceph-shim`, IPs `.16/.17/.18`) shipped, pod range shifted to `192.168.10.128/25` with an explicit `/25 dev ceph-shim` route for the kernel-RBD-client hairpin fix. **CephCluster spec flip + mon/OSD roll still pending** (degraded-window event). Full design + ops history in `blog/blog-multus-ceph-migration-draft.md`. **Don't touch `enp1s0f0np0`, `ceph-shim`, or `192.168.10.0/24` routing without checking that draft first** — the routing setup is load-bearing: `/24 master metric 100`, `/24 shim metric 410`, `/25 dev shim static`. Reordering or simplifying breaks pod↔host reachability.

### Hardware: 3× Samsung PM9A1 512GB

- Migration from PNY CS1030 → PM9A1 completed 2026-05-07. Per-OSD `kv_commit_lat` dropped from ~95 ms (worn PNY lifetime) to ~3 ms (PM9A1). `BLUESTORE_SLOW_OP_ALERT` cleared and stays clear at the new hardware. Full chronology + bottleneck sweep in `blog/blog-rook-ceph-draft.md`.
- For future drive purchases at this cluster scale, stay on PM9A1-class consumer NVMe — full PLP enterprise (Micron 7450 PRO etc.) is not justified by the workload. The bottleneck post-swap is replication-amplification at `size=3`, not per-drive fsync latency.

### Pools and pg_num

- Primary pool: `nvme-replicated` (`size=3`, `min_size=2`, CRUSH rule on `device_class=nvme`, `bulk: true`). Backs the only block StorageClass today (`ceph-nvme-block`, RBD provisioner).
- **Target `pg_num` is 128** for `nvme-replicated`: 100 PGs/OSD × 3 OSDs / replication 3 = 100 → next pow2 = 128. Use `pg_num_min: 128` in the BlockPool to enforce — the autoscaler is **not** applying the `bulk` hint correctly (`ceph osd pool autoscale-status` returns `[]`; root cause likely a Squid 19.2.3 quirk, tracked as an open TODO). Same quirk hit the RGW data pool on 2026-05-10; same fix shape.
- When proposing pool changes: floor with `pg_num_min`, don't disable autoscale. Don't suggest manual `pg_num` bumps unless paired with the autoscaler diagnosis.
- **`pg_num_min` chicken-and-egg:** Ceph rejects `pg_num_min > current pg_num` with `EINVAL`. Pure-GitOps `pg_num_min` enforcement requires a **one-time toolbox bump** of `pg_num` to bootstrap each new pool past 1 (`ceph osd pool set <pool> pg_num <floor>; ceph osd pool set <pool> pgp_num <floor>`); the chart's `pg_num_min` then enforces the floor going forward. Confirmed twice (`nvme-replicated` originally, RGW data pool 2026-05-10). Capture the exact toolbox commands in the topical blog draft.

### Object storage (RGW)

- **`CephObjectStore` `ceph-objectstore` shipped 2026-05-01** — chart at `components/storage/ceph-object-store/`, single RGW gateway (`gateway.instances: 1`), HTTP-only on port 80; TLS terminated at the OpenShift Route `s3.apps.okd.sudops.pl`. **In-cluster S3 clients should use the in-cluster Service `rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80`** — bypasses Route + edge TLS, faster + more reliable.
- **Pool tiers:** `metadataPool.deviceClass: nvme` permanently; `dataPool.deviceClass: nvme` interim, flips to `hdd` when bulk drives land (single-line CRUSH-rule change in `values.yaml`; rebalance is automatic, RGW endpoint + bucket names + client config unchanged).
- **`pg_num_min: "32"` floored on the data pool** (commit `32b2e64`); metadata pool stays at the chart-default 8 PGs (it's tiny and not on the hot path).
- **Active consumers:** Loki (33+ GiB / 53k+ chunks in `ceph-objectstore.rgw.buckets.data` as of 2026-05-10). OADP queued; CNPG `barmanObjectStore` will land on the same RGW with a separate `CephObjectStoreUser` per cluster.
- **Bucket-creds plumbing precedent:** Loki's `logging-stack` chart uses an `ObjectBucketClaim` + secret-translator pattern to land RGW credentials in a SealedSecret-shaped Secret. Reuse that pattern for OADP / CNPG / future S3 consumers — don't ship `CephObjectStoreUser` + manual SealedSecret.
- **Toolbox gotcha:** `radosgw-admin user list` / `bucket list` from the toolbox default to the orphan `default` zone (a leftover from RGW first-bring-up; cosmetic-cleanup TODO). Real data lives in the `ceph-objectstore` zone — pass `--rgw-realm=ceph-objectstore --rgw-zonegroup=ceph-objectstore --rgw-zone=ceph-objectstore` to inspect it, or just look at `ceph-objectstore.rgw.*` pools in `ceph df`.

### CephFS plan (not yet shipped)

- **Two storage classes** against a **single `CephFilesystem` CR** — not two filesystems.
- One filesystem with metadata pool on NVMe and **two `dataPools` entries**: `deviceClass: nvme` (low-latency RWX) + `deviceClass: hdd` (bulk RWX).
- Two `StorageClass` objects against the same filesystem, differing only in the `pool` parameter.
- **Sequencing:** the NVMe SC can ship before HDDs land — no HDD dependency for the NVMe tier. The HDD SC waits on bulk HDDs being added to the chassis.
- Don't propose pure-NVMe CephFS as the long-term answer; the two-tier shape is the chosen plan.

### RBD CSI quirks

- The CSI driver does **deferred delete**: PVC removal calls `rbd trash mv`, not `rbd rm`. Trashed images keep consuming pool space until purged. Manual purge in 04/2026 reclaimed ~600 GiB.
- Need a periodic `rbd trash purge schedule` (use Ceph's built-in scheduler, not a CronJob — it lives in mgr config).
- Occasionally an image refuses removal with `image has watchers` — usually a stuck CSI nodeplugin attachment; investigate the node, don't force-delete the image.

### Network provider — locked on `host`, do not attempt `multus` migration

The `CephCluster.spec.network.provider` is `host` and **must stay there** until the cluster has drain headroom (4+ OSDs). A 2026-05-12 attempt to follow Rook's documented `host → "" → multus` two-step path failed cleanly and required a manual rollback. The failure mode is reproducible on this topology and is not a one-off; future sessions should not retry the same shape. Full chronology in `blog/blog-multus-ceph-migration-draft.md` (Phase 2 section).

What actually breaks:

1. Rook's admission webhook refuses a direct `host → multus` transition (`network provider must be disabled (reverted to empty string) before a new provider is enabled`). The documented escape is the two-step.
2. During the intermediate `provider: ""` state, the first-rolled OSD goes onto the pod network while the other two stay on host network. **PG peering hangs indefinitely under that mixed-network shape** — 220/220 PGs stuck `peering`, slow ops climbing monotonically, client I/O blocked. The connectivity exists (OVN passes pod↔host traffic) but msgr2 session establishment between asymmetric-address peers stalls.
3. Rook's own `ceph osd ok-to-stop` safety check then refuses to roll any OSD because peering is hung — including the one that needs to roll back to host network to fix the situation. **Chicken-and-egg deadlock with no Rook-native escape.**
4. Bonus snag: the operator updates Deployment shape on a provider change but does **not** clear `public_network` from the Ceph config DB. The first OSD on the new shape then crashloops because it can't find an interface matching the stale CIDR. Has to be cleared manually from the toolbox.

Recovery from that state required `oc patch` directly on the OSD-0 Deployment to set `hostNetwork: true`, bypassing Rook's safety check. That's a direct GitOps-owner-bypassing mutation — only justifiable here because Rook was deadlocked applying its *own* desired state. Don't ever do that to "speed up" a non-stuck reconciliation.

**Rule:** do not change `network.provider` away from `host` on this cluster. If a future session is tempted, this paragraph is the answer. Revisit when a 4th OSD exists or a non-empty-intermediate path is found upstream.

**Scheduling implication of host network: RGW must avoid router-co-located nodes.** With `network.provider: host`, every Ceph daemon binds the node's host ports. RGW listens on `:80` (`gateway.port: 80`). The cluster's edge `openshift-ingress/router-default` IngressController also runs hostNetwork on `:80/:443`, and the default HA mode places 2 router replicas on a 3-node bare-metal cluster — meaning 2 of 3 nodes have host port 80 occupied at all times. RGW therefore has exactly one collision-free node available. 2026-05-13 incident: a Multus rollback rescheduled RGW onto a router-co-located node, RGW crashlooped silently for ~21h with `EADDRINUSE` (exit 98), and Loki's S3 path was non-functional throughout. The `components/storage/ceph-object-store/` chart now carries a `required` podAntiAffinity selecting on `ingresscontroller.operator.openshift.io/deployment-ingresscontroller=default` in `openshift-ingress` namespace; **don't remove or downgrade to `preferred`** — co-residence is functionally broken and Pending+observable is the right alarm shape. Any future RGW-class daemon (multi-instance RGW, NFS-ganesha, an NVMe-of gateway) binding host ports needs the same anti-affinity treatment.

### `CephCluster` SSA gotcha — `managedFields: []` makes field removal sticky

The live `CephCluster/rook-ceph` resource has empty `metadata.managedFields` (it was created via non-SSA apply originally, never migrated). Server-side apply removes fields only for the manager that *owns* them — with no ownership tracked, fields rendered out of the Helm manifest **don't get removed from the live spec** on apply. ArgoCD's `selfHeal` may eventually clear them on a re-establish-ownership cycle, but timing is unpredictable (minutes, not seconds).

Practical implication: when a chart change *removes* a field from the rendered `CephCluster` spec, expect the live spec to keep the old value. `oc diff` will look empty even though the manifest no longer contains the field, which is confusing. The 2026-05-12 Multus attempt hit this with `addressRanges`.

If a future spec change needs guaranteed field removal: either re-establish SSA ownership first (`oc apply --server-side --force-conflicts -f -` on a hand-rendered manifest, once, to make ArgoCD the canonical owner) or do a direct `oc patch --type=json` `op: remove` (after confirming nothing else depends on the field). Plain Helm-template-removal alone is not reliable.

### When proposing storage changes

- Always state the impact on the degraded window first. "Rolling restart of OSDs" = degraded cluster, not a free operation.
- For pool/CRUSH changes: `helm template … | oc diff -f -` against the live `CephCluster` / `CephBlockPool` so the deltas are inspected before commit.
- The toolbox is `oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph …`. Read-only `ceph` commands are fine; Ceph-internal mutations (e.g. `ceph mgr fail`, `ceph orch ...`, `rbd trash purge schedule add`) are different from K8s mutations and may be appropriate — but flag them and confirm before running.
- **Observability stack is on Ceph-RBD PVCs** (Prometheus TSDB, Grafana, Loki, ArgoCD repo cache). When Ceph I/O hangs, all dashboards go dark — confirmed by the 2026-05-12 incident. Don't rely on Grafana to debug a storage incident; use the toolbox + `oc -n rook-ceph logs/exec` directly. If observability is dark during an incident, that's a *symptom* of the storage problem, not a separate failure to chase.

### Storage actions are always blog-worthy

Storage is the most load-bearing, hardest-to-roll-back part of this cluster. **Every storage action must be captured in a blog draft — no judgement call, no "is this big enough to write up."** This is stricter than the general "Blog notes" rule below: storage doesn't get the "non-trivial" qualifier.

- **Scope:** any change to `components/storage/`, any `ceph` / `rbd` / `rados` command beyond pure read-only inspection, any pool/CRUSH/StorageClass/CephFilesystem edit, any OSD operation, any hardware swap, any CSI / SealedSecret change touching storage credentials.
- **Drafts:** prefer to extend the existing topical draft (`blog/blog-rook-ceph-draft.md`, `blog/blog-multus-ceph-migration-draft.md`) over creating a new one. Create a new draft only when the topic is genuinely new (e.g. CephFS rollout when it lands).
- **What to capture:** the exact `ceph -s` / `ceph osd pool ls detail` / `rbd trash ls` output that drove the decision, the exact mutation command, the post-state output, and the *why*. Storage debugging six months later relies on this — paraphrase doesn't survive.
- **No exceptions for "small" actions.** A `ceph mgr fail` to refresh orchestrator inventory is small but it's still a mutation on the storage layer; write it up. Future-you will thank current-you when an unrelated symptom turns out to be the same root cause.

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
6. Commit on `develop`, open PR into `master`.

## Debugging order of operations

When an Application is `OutOfSync`, `Degraded`, or just "stuck", check in this order — don't skip ahead:

1. `argocd app get <name>` — sync status, health, last operation error.
2. `oc get events -n <namespace> --sort-by=.lastTimestamp | tail -30` — admission/validation failures.
3. `oc describe <kind> <name> -n <ns>` — per-resource conditions.
4. For operator-managed resources: `oc get csv -n <operator-ns>` and `oc get subscription -n <operator-ns>` first — a stuck CSV blocks everything downstream.
5. For cert-manager: `oc describe certificate <name> -n <ns>` → `CertificateRequest` → `Order` → `Challenge`. DNS-01 failures are almost always Cloudflare token expired or wrong zone.

## Guardrails — do not do these

Claude should refuse these actions and explain why briefly:

- **No mutating cluster commands.** No `oc apply/delete/patch/scale/replace`, `kubectl apply/delete/patch`, `helm install/upgrade/uninstall/rollback`. ArgoCD owns cluster state; direct edits cause drift and are reverted.
- **No state mutation on external tools** (`terraform apply/destroy`, `terraform state mv/rm`, `argocd app sync --force` with prune).
- **No committed secrets.** No Cloudflare tokens, kubeconfigs, TLS private keys, OLM pull secrets. Reference secrets by name and assume they exist out-of-band.
- **No editing generated files**: `Chart.lock`, rendered manifest dumps, `*.orig`.
- **No OKD version bumps or cluster-wide CR changes** without an explicit ask — those are upgrade events, not routine edits.
- **Do not disable `automated.prune` or `selfHeal`** to "fix" a sync issue. Fix the manifest instead.

## Commit and branch conventions

- Work on `develop`, PR into `master`. ArgoCD watches `master`.
- Commit messages: `<scope>: <imperative summary>` — e.g. `cert-manager: bump to v1.16.2`, `root-app: add monitoring stack`, `storage: enable fd-b zone`.
- One logical change per commit. The rendered-manifest diff should be predictable from the message alone.
- Renovate PRs (label `dependencies`) are reviewed, not rewritten.

## Communication preferences

- Be concise and technically precise. Skip hedging, flattery, and recap of what I just said.
- Surface trade-offs honestly. If there's a simpler or more idiomatic approach than what I asked for, say so before implementing.
- When proposing a change, include the exact commands to validate it locally.
- Cite OKD, Helm, ArgoCD, or cert-manager docs by version when version-specific behavior matters.
- Prefer a short correct answer with one follow-up question over a long answer that guessed at my intent.

## MCP servers

`.mcp.json` declares two project-scoped MCP servers. They auto-launch via `npx -y` when Claude Code starts in this repo.

- **`kubernetes`** (`mcp-server-kubernetes`) — structured `kubectl_get` / `kubectl_describe` / `kubectl_logs` / `kubectl_explain` / `kubectl_diff` tools that talk to whatever cluster is in `~/.kube/config` (i.e. the OKD cluster after `oc login`). Prefer these over shelling out to `oc` for read-only inspection — fewer permission prompts (allowlist already covers `kubectl_*` reads), and the model gets structured JSON instead of parsing terminal output.
- **`github`** (`@modelcontextprotocol/server-github`) — read-only access to the `sudoom/homelab` repo and any other GitHub repo (good for cross-referencing upstream Rook / cert-manager / loki-operator issues). Requires `GITHUB_PERSONAL_ACCESS_TOKEN` exported in the shell before `claude` launches; minimum scope `public_repo` + `read:org`. Allowlisted: `mcp__github__get_*`, `mcp__github__list_*`, `mcp__github__search_*`. Mutations (`create_*`, `update_*`, `delete_*`, `merge_*`, `push_*`) are NOT allowlisted — they'll prompt; never approve them without an explicit user request.

For mutations against the cluster (apply/delete/patch/scale, etc.), still go through the user — `kubectl_apply` and friends from the kubernetes MCP are denied by the same guardrails as `oc apply` in plain Bash.

## Session hygiene

- Before the context window is compacted, run `/export` to preserve the full conversation.
- When diagnosing a live issue, paste real `oc` / `argocd` output into chat rather than describing it — diagnoses from raw output are much better than from paraphrase.
- **At session start and immediately after a context compaction**, re-read the markdown files that carry working state, in this order — don't rely on the post-compaction summary alone:
  1. `CLAUDE.md` (this file) — rules may have tightened since the snapshot.
  2. Any `blog/blog-*-draft.md` files relevant to the work in flight — these are the chronological notes for what was tried, what worked, and what's still open.
  3. The TODO list at the bottom of `README.md` — confirm what's still queued vs. shipped.
  4. Auto-memory `MEMORY.md` (loaded automatically) plus the linked memory files — re-skim before assuming a remembered fact still holds.

  Compaction summaries are lossy by design; the markdown is the source of truth.

## Ending a session ("call it")

When the user says **"call it"**, **"call it for the night"**, **"wrap up"**, **"end of session"**, or anything semantically equivalent, treat it as a trigger to do a final pass *before* the goodbye summary — don't just summarize and stop. Two things, in order:

1. **Doublecheck docs for drift from today's work.**
   - `README.md` TODO: every shipped item removed; every newly-discovered item added; every still-queued item refreshed (rationale, blockers, status) if today changed it.
   - `CLAUDE.md`: any subsystem that today's work made load-bearing or whose constraints changed should be reflected here. Today's stack-shape changes belong here, not buried in the blog.
   - Per-chart `README.md` files for any chart touched: commands, paths, file tables match `git ls-files` reality.
   - Blog drafts: the relevant `blog/blog-*-draft.md` has a section covering today's work; "to be filled in once X reconciles" placeholders are filled in with actual observed state.
   - Run a targeted grep for the kinds of staleness today's commits would create — phrases like `blocked on <thing-that-just-shipped>`, `<thing> is queued`, old resource names, old field names.
2. **Clean up the repo.**
   - Stale comments in code / templates / values files (e.g. `# TODO ...` that's now done, `# old: ...` markers, debug commentary).
   - Unused `values.yaml` keys that no template references; dead Helm template branches behind `if` conditions that can never be true given current values.
   - Temporary experiment files / one-off scripts / dump artifacts left in the repo root or `tests/` that shouldn't be checked in long-term — propose deletion with rationale, don't silently delete.
   - Unused imports, dead-letter Kustomize patches, etc.
   - Use `git status --short` + `git ls-files --others --exclude-standard` to check for tracked-but-orphaned and untracked files.

Both passes are *additional* commits on top of whatever the session shipped. End with a one-paragraph session ledger (commits + final state) — that part stays as-is.

## Blog notes — keep them current

Every session that diagnoses an issue, changes infrastructure, or runs a non-trivial benchmark should be captured in a blog-style draft at the repo root. These drafts are the working memory for future write-ups.

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

The repo's TODO list is the structured section at the bottom of `README.md` (categories: In flight, Queued — observability, Queued — storage, Queued — operators / catalog, Queued — platform expansion, Documentation hygiene). Treat it as the single source of truth for tracked work.

- **When you suggest a new TODO** (e.g. you spot a gap during a session and the user agrees it should be tracked): add it to the appropriate category in `README.md`. Do not invent a separate TODO file. Match the existing item style — bold lead-in, then the *why* / *what* / *how to validate* in one or two sentences.
- **When the user gives input that refines an existing TODO** (more context, a chosen approach, a deadline, a reason it's deprioritized): update that item in place rather than appending a duplicate. Preserve chronology only when it matters; otherwise rewrite for clarity.
- **When a TODO ships:** remove it from the README in the same commit that lands the change. Don't leave checked-off items as historical record — the git log is the historical record.
- **Don't reorganize categories or split items into subsections without an explicit ask** — the existing structure is deliberate.

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