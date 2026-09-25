# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Repository overview

Homelab GitOps repository for a **3-node bare-metal OKD 4.21 cluster** (OpenShift Kubernetes Distribution), managed declaratively by **ArgoCD** with an app-of-apps pattern and Helm templating.

- **Cluster domain:** `okd.sudops.pl`
- **Nodes:** 3 control-plane+worker; frontend `192.168.1.7–9`, storage backnet `192.168.10.2–4`. Frontend addresses come from MikroTik DHCP reservations (1-day lease, `node-dhcp` chart) since 2026-09-25 — the IPs must never change (etcd and kubelet cert SANs); a router outage longer than a day would drop them
- **Failure domains** (`topology.kubernetes.io/zone`): `fd-a → node4`, `fd-b → node5`, `fd-c → node6`
- **Ingress:** `*.apps.okd.sudops.pl` (wildcard, cert-manager)
- **API:** `api.okd.sudops.pl`
- **Git:** `git@github.com:sudoom/homelab.git` — `master` = production (ArgoCD tracks). Commits go straight to `master`; there is no working branch (see "Commit and branch conventions").

## Stack and tool versions

Pin these when generating manifests or commands — mismatched versions are the single largest source of wrong suggestions.

| Tool            | Version        | Notes                                                                 |
|---|---|---|
| OKD             | **4.21.0-okd-scos.11** (upgraded from 4.20 on 2026-09-08) | Kube API ≈ upstream **1.34** (mapping: OKD `4.N` → Kube `1.(N+13)`, so 4.22→1.35). SCOS 10, kubelet v1.34.6, cri-o 1.33.4. **4.22 is DEFERRED — `quay.io/okderators/catalog-index:4.22` does not exist.** |
| Helm            | local **v4.3.0**; ArgoCD uses its own bundled Helm 3 | Upstream ArgoCD v3.1.11 pins Helm 3.18.4 (`hack/tool-versions.sh`), so a local `helm template` can differ from what ArgoCD renders — check a version-sensitive change with `oc diff` against live. Helm v2 syntax is invalid; no Tiller |
| ArgoCD          | v3.1.11+cc053b2     | Server-side apply + sync-wave annotations used throughout             |
| OLM             | OKD-bundled    | `okderators` + `community-operators` CatalogSources                   |
| cert-manager    | v1.18.2     | OLM from `okderators`. **OUT OF MATRIX + EOL:** 1.18 supports Kube 1.29–1.33 and died 2026-03-10; we are on Kube 1.34. **No catalog offers newer** (okderators 1.18.0, community-operators 1.16.5, operatorhubio 1.16.5), so the only routes are the upstream Helm chart (built + parked on branch `cert-manager-helm-fallback`) or the upstream pipeline. **The pipeline route is now filed (2026-09-09): [okd-operator-pipeline#29](https://github.com/okd-project/okd-operator-pipeline/pull/29) bumps cert-manager to 1.20 on `release-4.21`, which is the branch that builds `catalog-index:4.21`; [#28](https://github.com/okd-project/okd-operator-pipeline/pull/28) does the same on `main` for 4.22. Neither helps until merged AND a catalog is rebuilt, so the Helm fallback stays the answer if the renewal date gets close.** **First ACME renewal on the out-of-matrix version: `homelab-wildcard` 2026-09-21.** |
| oc / kubectl    | client **4.22.14** (cluster 4.21) | One minor of client skew is within kubectl's support policy. Prefer `oc` for OpenShift-only kinds (Route, SCC, ImageStream) |
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
├── blog/                    # Working notes / draft posts — see "Blog notes" rule below
├── bugs/                    # Drafted upstream-issue bodies (filing-ready)
├── tests/                   # Manual-apply test artifacts not yet promoted to a chart
├── data/                    # Captured benchmark / SMART / log artifacts referenced from blog drafts
│                            # └── storage-throughput.md — ALL measured throughput figures, with conditions
├── docs/superpowers/specs/  # Design specs from brainstorming, reviewed before any implementation
├── .claude/
│   ├── settings.json        # Tracked: read-only allowlist + guardrail deny list (settings.local.json is not)
│   └── skills/              # On-demand instructions split out of this file — cluster-health,
│                            # network-change, rook-ceph (+ teardown.md, disk-ops.md), upstream-pr
└── CLAUDE.md
```

### Non-cluster infrastructure — `ansible/` vs `components/`

- `components/` + `bootstrap/` are what ArgoCD applies to the cluster. `ansible/` holds things outside the cluster
  that still need versioned, idempotent config — Technitium DNS (`dns-master` `.12` + `dns-slave` `.13`) and the
  TrueNAS NAS — kept off ArgoCD so DNS and the NAS never depend on the cluster being up.
- **Code-only: never propose a web-UI or manual fix for an Ansible-managed box.** Change the role, re-run the playbook.
- `ansible.builtin.*` modules only. Vault passwords are interactive, so **I can't run `ansible/technitium/playbook.yml`
  or `ansible/truenas/playbook.yml`**; `--syntax-check`, technitium `base-only.yml` and truenas `check.yml` I can.
- Full rules and the TrueNAS middleware traps: `ansible/CLAUDE.md`, which loads automatically when I read a file
  under `ansible/`.

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

- `okderators` (`quay.io/okderators/catalog-index:4.21` — bumped 2026-09-08 after the 4.21 hop) — OKD community operators. Use for **cert-manager**. **The tag flip delivered NOTHING**: cert-manager head is still v1.18.0, gitops still v1.19.0, and `cluster-logging` head is v6.3.0 — *older* than the installed v6.5.0. Zero InstallPlans generated. **All five okderators subscriptions were switched to `installPlanApproval: Manual` before the flip** (cert-manager, gitops, cluster-logging, loki, oadp) — do not revert that; on Automatic a tag flip auto-upgrades all five at once, including the operator running ArgoCD.
- `community-operators` — upstream OperatorHub.io. Use for **NMState** (the okderators build has an ImageStream bug).
- **The okderators build chain is per-OKD-release, and `main` is NOT the branch that builds our catalog (found 2026-09-09).** `okd-operator-pipeline` has `main` plus `release-4.18`/`release-4.20`/`release-4.21` branches. **`main` builds 4.22** (`common.sh` sets `OKD_VERSION=4.22.0-okd-scos.2`, 39 submodules pin `release-4.22`); **`release-4.21` builds our catalog** (`OKD_VERSION=4.21.0-okd-scos.10`) and is 34 commits behind main. So a fix contributed to `main` does NOT reach `catalog-index:4.21` — it has to land on `release-4.21` too. Same for `okderators-catalog-index`, which has its own `release-4.1x`/`release-4.21` branches.
- **A submodule's `.gitmodules` `branch =` is NOT what gets built.** `submodule_reset()` in the pipeline's `common.sh` ignores its `branch` argument and resets each submodule to the **recorded gitlink hash**; only `update` (not run by default) consults the branch. So a repo can declare `branch = release-4.21` while the gitlink is a 4.20 commit and every build silently produces 4.20 content — exactly the state nmstate was in on both branches (our PR #30). **When checking what an operator is pinned to, resolve the gitlink against the upstream branches (`gh api repos/<o>/<r>/compare/<branch>...<sha>`), don't read `.gitmodules`.**
- **OLM v1 (catalogd + operator-controller) is installed and unused (2026-09-14).** Zero `ClusterExtension`s; every operator here is an OLM v0 `Subscription`. The three Red Hat default `ClusterCatalog`s (`openshift-redhat-operators`, `-certified-operators`, `-redhat-marketplace`) are held at `availabilityMode: Unavailable` by `components/cluster-config/olm-v1-catalogs/` — no entitlement for their content, and the redhat one leaked 79 MB of catalog temp dirs per failed 10-minute poll into operator-controller's emptyDir on node5 (42 GiB in six days, Ceph `MON_DISK_LOW`; upstream fix operator-framework/operator-controller#2574 not in the 4.21 payload). `openshift-community-operators` stays Available. Do not "fix" the Unavailable catalogs back; do not confuse them with the OLM v0 `CatalogSource`s in `openshift-marketplace`, which are untouched.

### Operator patterns

- Every operator component = `Namespace + OperatorGroup + Subscription` (+ CR in a later sync wave if needed).
- **Cluster-scoped** operators (cert-manager): `OperatorGroup` with `spec: {}`.
- **NMState**: `OperatorGroup` with `spec: {}` too (AllNamespaces) — installed into `openshift-nmstate` (`.Values.namespace`), but its *operand* (handler DaemonSet, ServiceMonitor, RBAC) lands in a separate hardcoded `nmstate` namespace (`HANDLER_NAMESPACE`, baked into the CSV). **Two namespaces, both real** — a namespaced resource added to that chart MUST set `metadata.namespace: nmstate` explicitly, because the ArgoCD Application's `destination.namespace` is `openshift-nmstate` and it would otherwise land there, report Synced+Healthy, and grant nothing. (Corrected 2026-08-06: this line previously claimed `targetNamespaces`; the chart has always shipped `spec: {}`.)

### TLS / cert-manager

- Let's Encrypt **production**, DNS-01 via **Cloudflare**.
- The DNS-01 resolver uses public nameservers (`1.1.1.1`, `8.8.8.8`) — cluster DNS can't resolve external domains, and without this override the challenge fails.
- Wildcard cert `*.apps.okd.sudops.pl` → `openshift-ingress`.
- API cert `api.okd.sudops.pl` → `openshift-config`.
- Cloudflare API token is provisioned via the SealedSecret in `components/cluster-config/cert-manager-config/templates/sealed-cloudflare-api-token.yaml`. Rotation = re-`kubeseal` + commit (one-liner in that chart's `values.yaml`).
- **sealed-secrets controller runs `--key-renew-period=720h` (auto-rotation) — NEVER set it to `0`.** `0` disables rotation, which silently let the single sealing key's cert **expire 2026-05-28** with no replacement → `kubeseal` failed `expired certificate`, blocking ALL new sealing cluster-wide (existing SealedSecrets kept decrypting fine — expiry only breaks *sealing*, not decryption). Fixed 2026-06-27 (`720h` → controller minted a fresh 10-year key, old key retained for decryption). The controller's **public sealing cert is committed at `components/operators/sealed-secrets/sealed-secrets-pub.pem`** for offline `kubeseal --cert` (public key = seal-only, safe to commit; refresh after a rotation via `kubeseal --fetch-cert`).

## Storage (Rook-Ceph)

Rook v1.19.5 managing Ceph Squid 19.2.4 on three NVMe OSDs (`osd.0-2`, one per node, failure domain `host`). Two
pools: `nvme-replicated` (RBD, StorageClass `ceph-nvme-block`) and `.mgr`. The HDD tier, CephFS and the in-cluster
object store were retired 2026-09-07: RWX is the NFS classes (`nfs-csi`, `nfs-truenas-*`), S3 is garage on TrueNAS.
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
- **A pod that needs the NAS uses `192.168.1.25`** — pod-network → backnet (`192.168.10.x`) egress does not work.
- **Read per-pool `MAX AVAIL`, never cluster-level `avail`**, and re-measure hours after a snapshot deletion.
- **Every storage action goes in a blog draft** — no exception for small ones.
- Ceph-internal mutations (`ceph mgr fail`, `rbd trash purge schedule add`, …) may be appropriate — flag and confirm
  before running.

### Node drain and unplanned rerolls

- **Never run a 1-instance CNPG cluster on the master pool** — its primary PDB blocks every drain. Both clusters run
  2 instances since 2026-09-15.
- **Never delete the `powersave-experimental` Tuned CR by hand** — NTO drops `50-nto-master` and MCO rerolls a node.
  Change `bootArgs` in `components/cluster-config/power-tuning/values.yaml` instead.
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

- **No mutating cluster commands.** No `oc apply/delete/patch/scale/replace`, `kubectl apply/delete/patch`, `helm install/upgrade/uninstall/rollback`. ArgoCD owns cluster state; direct edits cause drift and are reverted.
- **No state mutation on external tools** (`terraform apply/destroy`, `terraform state mv/rm`, `argocd app sync --force` with prune).
- **No committed secrets.** No Cloudflare tokens, kubeconfigs, TLS private keys, OLM pull secrets. Reference secrets by name and assume they exist out-of-band.
- **No editing generated files**: `Chart.lock`, rendered manifest dumps, `*.orig`.
- **No OKD version bumps or cluster-wide CR changes** without an explicit ask — those are upgrade events, not routine edits.
- **Do not disable `automated.prune` or `selfHeal`** to "fix" a sync issue. Fix the manifest instead.

## Skills — the `superpowers` plugin

Installed 2026-09-09. Not every skill fits this repo; three of them contradict rules stated elsewhere in this
file. **A skill never overrides a guardrail.** If a skill's instructions conflict with the Guardrails section or
with a rule below, the repo rule wins and I say which one I am following and why.

**Use these by default, without being asked:**

- **`systematic-debugging`** — before proposing a fix for any incident, failed sync, or unexpected output. It
  guards against exactly this repo's recurring failure: guessing a cause from a plausible-looking signal. Real
  examples that would have been caught — reading "N OSDs slow" as "the HDDs" when it was NVMe osd.0/osd.1
  (2026-06-15); reading `.gitmodules` and concluding nmstate was on 4.21 when the gitlinks were 4.20
  (2026-09-09); assuming `PodNetworkConnectivityCheck` localises a `br-ex.forwarding` break when its source is a
  single-replica Deployment.
- **`verification-before-completion`** — before claiming anything is done, fixed, or passing, and before every
  commit. Pair it with the Validation workflow. This repo has repeatedly shipped a confident claim that was
  wrong: "27 of 27 orphaned VolumeAttachments" (my own broken check), "the collector is crashing" (my own manual
  run, not cron), the 2026-09-08 `br-ex.forwarding` cause I wrote up and retracted the same day.
- **`brainstorming`** — before designing something new: a new chart, a monitoring surface, a migration plan, an
  upstream contribution's shape. Not for routine edits, version bumps, or doc updates.
- **`writing-plans` / `executing-plans`** — multi-step supervised work with a degraded window or a rollback
  story: OKD minor upgrades, Rook/Ceph bumps, storage migrations, teardown+rebuild. These pair with the
  "no drain headroom" and "30-minute cap" rules rather than replacing them.
- **`requesting-code-review` / `receiving-code-review`** — upstream PR work, and any change to a chart that a
  degraded-window procedure depends on.

**These conflict with existing rules — the repo rule wins:**

- **`using-git-worktrees`, `finishing-a-development-branch`** assume a feature-branch workflow. This repo commits
  **direct to `master`** (ArgoCD watches it) — no feature branches, no PRs, per the standing instruction. Do not
  create a branch or worktree for homelab changes. **Exception:** upstream contribution clones under the
  scratchpad (`okd-operator-pipeline`, etc.) are separate repos with their own conventions, and there branches
  are correct.
- **`dispatching-parallel-agents`, `subagent-driven-development`** assume spawning subagents. The operating
  instructions for this project say not to use the Agent tool or workflows unless the user asks for it. Do not
  invoke these on my own initiative; suggest one if a task genuinely warrants it and let the user decide.
- **`test-driven-development`** assumes a unit-test suite. There isn't one. The analogue here is the
  **Validation workflow** (`helm lint` → `helm template` → `kubeconform` → `oc diff`) and, for upstream work,
  actually running `build_containers` / `make bundle` / `opm validate` before claiming a change works. Apply the
  spirit — demonstrate the failure, then demonstrate the fix — not the letter. The 2026-09-09 cert-manager PR is
  the model: `opm validate` was shown failing on the unfixed graph *and* passing on the fixed one.

**`using-superpowers`** is the meta-index for finding the others. **`writing-skills`** only applies when
authoring a new skill.

## Upstream PRs and comments

Every upstream PR is opened with `--draft` and stays draft — marking it ready and merging are the user's calls.
Write the change plainly: what changed, why, how it was checked; no debugging narrative. **Load the `upstream-pr`
skill (`.claude/skills/upstream-pr/SKILL.md`) before drafting any upstream PR, issue or comment** — it holds the
full writing rules.

## Commit and branch conventions

- Commit directly to `master` — ArgoCD watches it. No feature branches and no PRs for this repo; the only branches are upstream-contribution clones and the parked `cert-manager-helm-fallback`.
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
  actually decided, not a choice I left open: on 2026-09-24 I offered "replace the GitHub MCP server or drop
  it", got "go ahead", and dropped it without asking which.

## MCP servers

`.mcp.json` declares one project-scoped MCP server, launched via `npx` when Claude Code starts in this repo.

- **`kubernetes`** (`mcp-server-kubernetes@4.1.7`, pinned) — structured `kubectl_get` / `kubectl_describe` / `kubectl_logs` / `explain_resource` / `list_api_resources` tools. It runs as the **readonly `claude-reader` SA** (`KUBECONFIG_PATH=${HOME}/.kube/config-readonly`), so it keeps working when the operator's OAuth login expires. `ALLOW_ONLY_NON_DESTRUCTIVE_TOOLS=true` only removes the delete-type tools; `kubectl_apply`, `kubectl_patch`, `kubectl_scale` and `exec_in_pod` are still listed, and the SA's RBAC is what refuses them. That SA can read Secrets — never read a secret value through it either. Verified 2026-09-24: the server listed the three nodes while `oc whoami` on the operator kubeconfig returned `Unauthorized`.
- **GitHub: use `gh`, not an MCP server.** `@modelcontextprotocol/server-github` was removed 2026-09-24 — npm marks it deprecated ("Package no longer supported"), last release 2025.4.8. `gh` is not logged in on this workstation, so pass the token inline: `GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN" gh …`. Upstream cross-referencing works the same way (`gh issue view -R <owner>/<repo> <n>`, `gh search issues …`).

For mutations against the cluster (apply/delete/patch/scale, etc.), still go through the user.

Permissions: `.claude/settings.json` is tracked (since 2026-09-24) and holds the read-only allowlist plus the **guardrail deny list** — `oc`/`kubectl` mutating verbs in both `oc <verb>` and `oc -n <ns> <verb>` forms, `helm install/upgrade/uninstall/rollback`, `argocd app sync`, `gh pr merge/ready/review/close`, force-push/hard-reset, the token-printing `oc whoami -t` / `oc config view --raw`, and reads of kubeconfigs/`.env`/secrets. Deny beats allow, and a deny rule matches past a leading `KUBECONFIG=…` assignment. `.claude/settings.local.json` stays untracked (git, gh reads, ssh, WebFetch domains, MCP tool approvals). Editing either file from a session is blocked by auto mode as self-modification — the user applies settings changes.

## Reviewing open PRs (`sudoom/homelab`)

Check open PRs at session start and whenever a dependency PR is relevant, and give **APPROVE / HOLD / NOT-APPROVE**
per PR with a one-line reason. Storage version bumps (Rook, Ceph) default to NOT-APPROVE. I advise; the user merges.
Verdict rules and the `gh` commands: `cluster-health` skill.

## Session hygiene

- **Minimize Bash output tokens.** Long sessions on this repo routinely eat 20%+ of context on diagnostic dumps. Pipe through `head`, `tail`, `grep`, `awk` to extract only the lines that drive a decision. For files, use `Read` with `offset`/`limit` instead of `cat`. Specifically avoid: `oc describe pod ...` without a grep filter (the events tail is what matters, the spec block isn't), `oc get xxx -o yaml` for anything bigger than a small CR (jsonpath-targeted reads instead), `oc adm top` or `ceph -s` dumps where a single-line jsonpath would do. The 2026-05-20 / 2026-05-21 sessions both hit context-pressure warnings before reaching natural end of day specifically because of unfiltered diagnostic captures.
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

- **Before proposing anything that might already exist, check the docs first.** Re-reading at session start (above) isn't enough — when you're about to suggest "we should ship X" or "let's add Y", grep `blog/`, `CLAUDE.md`, `README.md`, `MEMORY.md`, and the relevant `components/<area>/` first. The 2026-06-08 incident: I proposed shipping CNPG `barmanObjectStore` as a follow-up — when CNPG-native backup had already been shipped 2026-05-18 with a passing 2026-05-20 restore drill, fully documented in `blog/blog-cnpg-draft.md`. The user shouldn't have to be the verifier-of-last-resort that I read what they already wrote down. Specifically: any "we should add Z" or "follow-up: ship Z" claim is a search trigger — `grep -ri "Z" blog/ CLAUDE.md README.md components/` before saying it. Same applies for "this isn't done yet" / "this is missing" / "we need to think about" — if the docs say it's done, it's done; trust the docs over your own model.

## Ending a session ("call it")

On "call it", "wrap up", "end of session" or similar, run the `cluster-health` skill's wrap-up before saying goodbye:
(1) docs drift — README TODO, CLAUDE.md, chart READMEs, blog drafts; (2) repo cleanup; (3) the cluster health sweep,
expected clean. Each pass is its own commit. End with a one-paragraph session ledger (commits + final state).

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

This repo's `.claude/settings.json` whitelists `Read(~/Library/Mobile Documents/iCloud~md~obsidian/Documents/Notatki/**)`; the vault's `.claude/settings.json` whitelists `Read(~/Projects/homelab/**)`. **Absolute paths in a permission rule need `~/` or `//` — a single leading `/` is relative to the project root.** Both files used `/Users/…` until 2026-09-24, so none of those rules ever matched, including the vault's `ask` rule meant to guard `Personal/**` edits. **One `Read(path)` rule covers every file-reading tool (Read, Glob, Grep) — separate `Glob(path)`/`Grep(path)` entries are no-ops** and Claude Code warns about them at startup (they were removed here 2026-07-27). Native Read works on absolute paths in both directions — no MCP needed for cross-repo reads.

### Downstream: the published blog (sudops.pl)

The `blog/*-draft.md` files in this repo are the **upstream raw material** for the public homelab blog at **[sudops.pl](https://sudops.pl)** — repo `/Users/vadzimdziadziulia-laptop/Projects/sudops.pl` ([sudoom/sudops.pl](https://github.com/sudoom/sudops.pl), Astro).

- Pipeline: this repo's `blog/*-draft.md` (raw session chronology) → `sudops.pl/posts/*.md` (gitignored raw draft) → `sudops.pl/src/content/blog/*.mdx` (published).
- The blog repo reads THIS repo for ground truth (manifests, versions, commands) and the vault for the "why". You don't push to the blog from here — keep the drafts current per the "Blog notes" rule above; the blog repo pulls from them.
- Same secret-hygiene rule applies: drafts feed a public site, so never put real tokens/keys/kubeconfigs in `blog/*-draft.md`.
