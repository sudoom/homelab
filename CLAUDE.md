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
├── *-values.yaml            # Helm values for tools installed OUTSIDE the root app
│                            # (Cilium, Istio, Prometheus, ArgoCD itself, Kiali)
└── CLAUDE.md
```

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
- Cloudflare API token is created **manually** today. Planned migration: ESO + Bitwarden.

## Storage (Rook-Ceph)

The cluster's storage is **Rook-managed Ceph Squid (19.2.3)**. The operator is shipped via the upstream `rook-ceph` Helm chart; the `CephCluster` CR + pools + StorageClasses are vendored as raw manifests under `components/storage/` (not the `rook-ceph-cluster` subchart yet — see TODO). Suggestions and changes around storage need to respect the constraints below.

### Topology

- **3 OSDs total**, one per node, each on a single NVMe device. Failure domain is `host` (the failure-domain labels are `fd-a/fd-b/fd-c`, one per node).
- **No drain headroom.** Any rolling change to OSDs (rebuild, encrypt-at-rest, redeploy) goes through a degraded window — there is no fourth node to absorb the missing OSD. Plan accordingly: schedule during quiet IO, never run two OSD-impacting changes at once, never propose `oc cordon node{4,5,6}` without an explicit ask.
- **Mons:** 3-of-3, one per node. Same topology constraint applies.
- **Network:** Frontnet (VLAN 5) for clients; storage backnet (VLAN 10, 192.168.10.2-4) for OSD ↔ OSD replication. Multus migration drafted in `blog-multus-ceph-migration-draft.md` but **not pursued for throughput** — Mikrotik traffic data showed the bottleneck is media, not switch.

### Hardware migration in flight (PNY → PM9A1)

- Original 3× PNY consumer NVMes had pathological commit latency (~95 ms `kv_commit_lat` lifetime average; observed cluster-side fsync latency in seconds). One PM9A1 swap on node4 (osd.0) validated 04/2026: **~20× speedup** to ~4 ms `kv_commit_lat`.
- 2× more PM9A1 ordered late 04/2026; node5 swaps next (it was the worse of the two remaining PNYs under fio), then node6.
- `BLUESTORE_SLOW_OP_ALERT` HEALTH_WARN is **hardware-bound** on the PNYs — won't clear until the swap finishes. Do not propose tuning, deep-scrub adjustments, or pool-config changes to "fix" it; the only fix is the swap.
- Defer big storage refactors (subchart migration, OSD encryption, large topology changes) until **after** node5 + node6 swaps complete.

### Pools and pg_num

- Primary pool: `nvme-replicated` (`size=3`, `min_size=2`, CRUSH rule on `device_class=nvme`, `bulk: true`). Backs the only StorageClass today (`ceph-nvme-block`, RBD provisioner).
- **Target `pg_num` is 128** for `nvme-replicated`: 100 PGs/OSD × 3 OSDs / replication 3 = 100 → next pow2 = 128. Use `pg_num_min: 128` in the BlockPool to enforce — the autoscaler is **not** applying the `bulk` hint correctly (sits at 32 because data utilization is ~4% and `ceph osd pool autoscale-status` returns `[]`; root cause likely a Squid 19.2.3 quirk, tracked as an open TODO).
- When proposing pool changes: floor with `pg_num_min`, don't disable autoscale. Don't suggest manual `pg_num` bumps unless paired with the autoscaler diagnosis.

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

### When proposing storage changes

- Always state the impact on the degraded window first. "Rolling restart of OSDs" = degraded cluster, not a free operation.
- For pool/CRUSH changes: `helm template … | oc diff -f -` against the live `CephCluster` / `CephBlockPool` so the deltas are inspected before commit.
- The toolbox is `oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph …`. Read-only `ceph` commands are fine; Ceph-internal mutations (e.g. `ceph mgr fail`, `ceph orch ...`, `rbd trash purge schedule add`) are different from K8s mutations and may be appropriate — but flag them and confirm before running.

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

## Session hygiene

- Before the context window is compacted, run `/export` to preserve the full conversation.
- When diagnosing a live issue, paste real `oc` / `argocd` output into chat rather than describing it — diagnoses from raw output are much better than from paraphrase.
- **At session start and immediately after a context compaction**, re-read the markdown files that carry working state, in this order — don't rely on the post-compaction summary alone:
  1. `CLAUDE.md` (this file) — rules may have tightened since the snapshot.
  2. Any `blog-*-draft.md` files at the repo root that are relevant to the work in flight — these are the chronological notes for what was tried, what worked, and what's still open.
  3. The TODO list at the bottom of `README.md` — confirm what's still queued vs. shipped.
  4. Auto-memory `MEMORY.md` (loaded automatically) plus the linked memory files — re-skim before assuming a remembered fact still holds.

  Compaction summaries are lossy by design; the markdown is the source of truth.

## Blog notes — keep them current

Every session that diagnoses an issue, changes infrastructure, or runs a non-trivial benchmark should be captured in a blog-style draft at the repo root. These drafts are the working memory for future write-ups.

- **File naming:** `blog-<topic>-draft.md` at the repo root (e.g. `blog-rook-ceph-draft.md`, `blog-cert-manager-draft.md`). One file per topic, appended over time.
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