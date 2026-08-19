# CLAUDE.md

Guidance for Claude Code when working in this repository.

> **Reusable template for a Kubernetes / OpenShift GitOps repo**, distilled from a battle-tested
> homelab `CLAUDE.md`. It keeps the transferable *working discipline* — history processing, session
> hygiene, session start/end rituals, guardrails, the validation gate, PR review, and docs currency —
> and replaces cluster-specific facts with placeholders.
>
> Two kinds of section:
> - `<!-- PROJECT -->` — fill in per cluster/repo. The scaffolding shows *what* to document; the
>   content is yours (cluster domain, versions, component list, exact device/pool names, …).
> - `<!-- PROCESS -->` — transferable rules. Adopt as-is or tune the file names / commands. The
>   *shape* of the rule is the point.
>
> The examples assume **Helm charts + ArgoCD (app-of-apps) on OpenShift/OKD**, since that's the
> lineage. If you use Kustomize / Flux / vanilla `kubectl`, swap the tool names — the disciplines are
> identical. Delete this blockquote and the `<!-- ... -->` legends once specialized.

---

## Cluster & repository overview <!-- PROJECT -->

One paragraph: what this repo deploys, to what cluster, and the single most important mental model —
e.g. "GitOps repo for an N-node cluster; **ArgoCD owns cluster state, git is the source of truth**,
app-of-apps + Helm."

Then the load-bearing facts:

- **What owns cluster state** — ArgoCD / Flux / CI. Name it; it drives the guardrails below.
- **Cluster coordinates** — domain (`*.apps.<cluster>`), API endpoint, node count/roles, failure
  domains / topology labels, any storage backnet or special networking.
- **Git flow** — which branch the GitOps controller tracks (production) and which is the working
  branch. `git@…` remote.
- **Any host/service that lives *outside* the cluster** but is version-controlled (a foundational
  service — DNS, load-balancer — that must not be circularly dependent on the cluster being up).
  Say where its config lives and that it's applied through its own path, not the GitOps controller.

## Stack and tool versions <!-- PROJECT -->

Pin these. **Version mismatch is the single largest source of wrong suggestions** — a manifest
apiVersion, CRD field, or `oc`/`kubectl` flag that's right for one release is silently wrong for the
next.

| Tool | Version | Notes |
|---|---|---|
| Kubernetes / OKD / OpenShift | _x.y_ | _Kube API level; distro→Kube mapping if OKD/OCP; node OS + kernel_ |
| Helm | v3 | _v2 syntax is invalid; no Tiller_ |
| ArgoCD / Flux | _x.y.z_ | _SSA, sync-wave annotations, etc._ |
| Operator framework | OLM / _n/a_ | _which CatalogSources_ |
| cert-manager / ingress / CNI / CSI | _x.y.z_ | _install path (OLM vs Helm), known gotchas_ |
| oc / kubectl | _matching cluster_ | _prefer `oc` for OpenShift-only kinds: Route, SCC, ImageStream_ |
| kubeconform | latest | _use with the OpenShift/CRD schema locations (see Validation)_ |
| Dependency bot | Renovate / Dependabot | _how image/chart bumps arrive; PR label_ |

State any **compatibility gate** explicitly: "component A minor N supports component B range M–P;
never bump B ahead of an A that supports it, and a `allowUnsupported: false`-style flag will *refuse*
an unsupported pairing." Compatibility gates are where the expensive, hard-to-roll-back mistakes
live — call them out, don't bury them.

## Repository layout <!-- PROJECT -->

```
.
├── bootstrap/            # one-time manual bootstrap + the root app-of-apps chart
├── components/           # everything the GitOps controller deploys; one chart per component
│   ├── <topology>/       # wave 0 — node labels / failure domains
│   ├── operators/        # wave 1 — OLM Subscriptions
│   ├── cluster-config/   # wave 2 — CRs that depend on operator CRDs
│   └── storage/          # wave 3+ — storage + consumers
├── <ansible|terraform>/  # non-cluster infra, NOT GitOps-managed (foundational services)
└── CLAUDE.md
```

If two directories exist for a reason (in-cluster vs. out-of-cluster; "must not be circularly
dependent on the cluster"), write the *why* — it's load-bearing and non-obvious. Update this section
whenever a directory is added, moved, or renamed (see **Documentation currency**).

## Source of truth <!-- PROCESS + PROJECT -->

The most important operating principle: **know what owns each piece of state, and never bypass the
owner.**

- If the GitOps controller reconciles a resource, **change it by editing its declaration and letting
  the controller apply it** — never hand-edit the live object. Direct `oc edit`/`patch` causes drift
  and gets reverted; a "quick fix in the console" doesn't survive the next reconcile unless it's also
  in the chart.
- Out-of-cluster foundational services still get version-controlled, idempotent config (Ansible /
  Terraform) — applied through *their* path, never the cluster's. Document that path. Never propose a
  web-UI/manual fix for a box managed by code; if the automation isn't doing what's expected, debug
  the role/module, don't bypass it.
- **Code is the source of truth.** When something's wrong, debug the declaration; don't patch around
  it — disabling the reconcile to mask a symptom is drift, not a fix (see **Guardrails**).

---

## Working memory & history processing <!-- PROCESS -->

Context windows are lossy — compaction summaries drop detail by design. **Durable markdown files are
the source of truth for working state**, not your recollection or a summary.

### Worklog / session notes (the chronological record)

Keep a running, append-only worklog for any non-trivial diagnosis, cluster change, or benchmark — the
working memory future sessions rely on. (In the source repo these are `blog/blog-<topic>-draft.md`;
name them whatever fits.)

- **One file per topic**, appended over time. Add new sections; don't rewrite old ones, so the
  chronology survives.
- **Capture** the exact command (not paraphrased — full `oc -n … exec …`, full `helm template …`),
  the raw output that drove a decision (`ceph -s`, `oc describe` excerpt, an error, a diff), the
  decision and *why* (alternatives ruled out), and the ordered steps for anything multi-step (a
  rolling restart, a network change, a PG bump).
- **Update as you work, not at the end.** A session that does something undocumented is a regression.
- Some subsystems deserve a **stricter rule**: for the most load-bearing, hardest-to-roll-back layer
  (storage on most clusters), capture **every** mutation — no "is this big enough to write up"
  judgment call. A read-only `ceph -s` is fine to skip; any `ceph`/`rbd` mutation, pool/CRUSH edit,
  or OSD op gets written up.
- **Never** put secrets, tokens, or raw kubeconfigs in a worklog — assume it may be published.
- **Don't ask permission to write/update a worklog, README, or any doc these rules say to keep
  current.** Just do it, in the same commit series. "Should I write this up?" is friction; the answer
  is yes when the rule applies.

### Persistent memory

If the harness provides file-based memory, use it for facts that outlive a session: who the user is
and how they work, confirmed guidance/corrections (with the *why*), and constraints not derivable
from code or git history. Don't store what the repo already records. Re-verify any remembered fact
that names a file/flag/resource before relying on it — memories reflect what was true when written.

### Companion knowledge base (optional) <!-- PROJECT -->

If a paired notes vault / wiki holds the long-form *why* (decision journals, capacity sizing,
hardware rationale, operating state the repo doesn't track), name its path and say what lives there
vs. here. Rule of thumb: the commit message *points* to a decision; the *why* lives in the KB.
**When to write to it:** after a non-trivial decision whose *why* outlives a commit message, file a
dated decision note; after a meaningful architectural change, re-ingest the changed README/component
into the wiki.

### Re-read state at session start and after every compaction <!-- PROCESS -->

Don't rely on a post-compaction summary alone. Re-read the markdown that carries working state, in
order:

1. `CLAUDE.md` (this file) — rules may have tightened since the snapshot.
2. Any worklog relevant to work in flight — the chronology of what was tried and what's open.
3. The TODO list — shipped vs. still queued.
4. Persistent-memory index + linked memory files — re-skim before assuming a fact still holds.

---

## Session hygiene <!-- PROCESS -->

- **Minimize tool-output tokens.** Cluster diagnostics eat context fast. Pipe through
  `head`/`tail`/`grep`/`awk` for only the decision-driving lines. For files, `Read` with
  `offset`/`limit`, not `cat`. Avoid: `oc describe pod` without a grep filter (the events tail is
  what matters, not the spec block); `oc get … -o yaml` for anything bigger than a small CR (use
  `-o jsonpath` targeted reads); `oc adm top` / `ceph -s` dumps where a single-line query would do.
  Context pressure is self-inflicted — spend the budget on thinking, not re-reading noise.
- **Export / checkpoint before the context window compacts** if the harness supports it.
- **When diagnosing a live issue, paste real `oc`/`argocd` output into chat** rather than describing
  it — a diagnosis from raw output beats one from paraphrase.

---

## Session start ritual <!-- PROCESS + PROJECT -->

Before the first real work in a new session, sweep. Starting on a stale assumption about cluster
state is how a silent outage survives — a problem existing "until someone happens to notice" is
unbounded; a start-of-session **and** end-of-session sweep bounds it to one session length.

Use a **read-only kubeconfig** for all of this (`KUBECONFIG=~/.kube/config-readonly` or equivalent) —
every check is a read; none needs `oc login`.

1. **Re-read state files** — per **Re-read state at session start** above.
2. **Cluster health sweep** — the concrete list under **Ending a session** (it's the same sweep). A
   clean sweep is **one line** in the first reply ("sweep clean: HEALTH_OK / N apps Synced+Healthy /
   no outliers"). A **dirty sweep blocks the user's requested work until surfaced** — even if the
   symptom looks unrelated, raise it before proceeding.
3. **Re-verdict open PRs** — dependency bots refresh these between sessions. Re-pull (read-only) and
   give a fresh **APPROVE / HOLD / NOT-APPROVE** per PR (see **Reviewing open PRs**), so the queue
   doesn't go stale and a risky storage/operator/major bump isn't blindly merged. One line if
   nothing changed.
4. **Triage firing alerts** — *classify*, don't just list. For each firing Prometheus alert, decide
   **known-benign** (documented false positive on this cluster) vs **actionable** (one-line root
   cause + suggested fix, flagging whether the fix is a guardrail-gated mutation the user must run).
   Note the alert API usually needs **more than a read-only kubeconfig** — the Thanos/Prometheus
   `/api/v1/alerts` read is privileged and the `prometheus-k8s` pod-exec fallback needs `pods/exec`;
   if only a read-only credential is available, **skip this step rather than block on it** (the exact
   read path is <!-- PROJECT -->-specific). A clean board is one line; an actionable alert blocks
   requested work until surfaced.

---

## Ending a session ("call it") <!-- PROCESS -->

When the user says **"call it"**, **"wrap up"**, **"end of session"**, or anything equivalent, do a
final pass *before* the goodbye summary — don't just summarize and stop. Three passes, in order, each
an *additional commit* on top of what the session shipped:

1. **Doc-drift check.** Reconcile docs with today's work:
   - TODO list: every shipped item removed; every newly-discovered item added; every still-queued
     item refreshed if today changed its status/blockers.
   - `CLAUDE.md`: any subsystem today's work made load-bearing, or whose constraints changed, is
     reflected here — not buried only in a worklog.
   - Every `README.md` for a chart/component touched: commands, paths, sync waves, version pins match
     reality (`git ls-files`).
   - Worklogs: the relevant draft has a section covering today; "fill in once X reconciles"
     placeholders are filled with actual observed state.
   - **Grep for the staleness today's commits create** — `blocked on <thing that just shipped>`,
     `<thing> is queued`, renamed resources, old field/pool/device names.
2. **Repo cleanup.**
   - Stale comments (`# TODO` that's done, `# old:` markers, debug commentary) in charts/values.
   - Unused `values.yaml` keys no template references; dead Helm `if` branches that can't be true.
   - Temp experiment files / one-off manifests / dump artifacts in the repo root or `tests/` —
     **propose deletion with rationale, don't silently delete.**
   - `git status --short` + `git ls-files --others --exclude-standard` for tracked-orphaned and
     untracked files.
3. **Cluster health sweep — expected result: no surprise.** Read-only kubeconfig. Check, in order:
   - **Nodes:** `oc get nodes` — all `Ready`.
   - **GitOps apps:** `oc -n <gitops-ns> get applications` — every app `Synced` + `Healthy`
     (`OutOfSync` right after a push is normal; if it persists >5 min, dig).
   - **CSVs:** `oc get csv -A | awk 'NR==1 || $NF!="Succeeded"'` — only the header should print.
   - **Certificates:** `oc get certificate -A` — every entry `Ready=True` (renewal failures are
     silent otherwise).
   - **Restart outliers:** `oc get pods -A -o jsonpath='{range .items[?(@.status.containerStatuses[0].restartCount>10)]}{.metadata.namespace}/{.metadata.name} restarts={.status.containerStatuses[0].restartCount}{"\n"}{end}'`
     — every entry should be a *known* recurring item (long-uptime cumulative restarts, a known
     upstream bug); anything new → investigate.
   - **Non-Running pods:** `oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded`
     — empty.
   - **Storage health:** read the storage CR's `.status` health field (e.g. Ceph
     `HEALTH_OK`/known-benign `HEALTH_WARN`). Prefer the CR status field over a toolbox exec —
     `pods/exec` is denied under a read-only SA; the CR carries the same answer.
   - **Firing alerts** (if a read path exists) — otherwise skip rather than block goodbye on it.

   A **new outlier this session caused or missed is a goodbye-blocker** — investigate before the
   ledger, even if it means another commit.

End with a **one-paragraph session ledger**: commits landed + final state. Clean sweep = one line in
it; a dirty sweep gets its own paragraph (symptom + what was done).

---

## Validation workflow <!-- PROCESS + PROJECT -->

Every chart change passes **lint → template → schema-validate → diff** before commit. Don't skip
steps.

```bash
# 1. Lint
helm lint components/<category>/<name>/

# 2. Render (catches missing values, bad Go templating)
helm template <release> components/<category>/<name>/ \
  -n <target-ns> -f components/<category>/<name>/values.yaml

# 3. Schema-validate incl. CRDs (upstream + OpenShift schemas)
helm template <release> components/<category>/<name>/ | \
  kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'

# 4. Read-only diff against the live cluster before committing
helm template ... | oc diff -f -
```

The `oc diff` step is non-negotiable for anything mutating shared state — inspect the delta before it
lands. **Watch for render≠deploy traps:** if `charts/`/`Chart.lock` are gitignored the controller
runs `helm dependency update` and pulls the version named in `Chart.yaml` fresh at sync time, while
local `helm template` uses a possibly-stale vendored tgz — so local render ≠ what deploys. For
version changes, `helm dependency update` locally first to confirm the target chart even exists.

## Adding a new GitOps-managed component <!-- PROCESS + PROJECT -->

1. Create the chart at `components/<category>/<name>/`.
2. Register it in the root app's `values.yaml` with `enabled: true` and the correct **sync wave**.
3. Render the root app locally; confirm the generated `Application` looks right.
4. If it installs an operator with CRDs: `Subscription` at the operator wave, CRs at a **later**
   intra-chart wave — this avoids CRD-not-yet-installed races on first sync.
5. Run the full validation workflow above.
6. Commit on the working branch, PR into the tracked branch.

## Debugging order of operations <!-- PROCESS + PROJECT -->

When an Application is `OutOfSync`/`Degraded`/stuck, check in this order — **don't skip ahead**;
skipping is how you chase the wrong symptom for hours:

1. `argocd app get <name>` — sync status, health, last-operation error.
2. `oc get events -n <ns> --sort-by=.lastTimestamp | tail -30` — admission/validation failures.
3. `oc describe <kind> <name> -n <ns>` — per-resource conditions.
4. Operator-managed resources: `oc get csv`/`subscription -n <operator-ns>` **first** — a stuck CSV
   blocks everything downstream.
5. cert-manager: `certificate → certificaterequest → order → challenge`. DNS-01 failures are almost
   always an expired/ wrong-zone DNS-provider token.

**Pre-flight for CSI-mount-dependent work.** Some failure classes leave cluster-wide poison that
survives pod/operator restarts (orphan `Released` PVs, stuck `VolumeAttachments`, in-plugin operation
locks). Before applying a test PVC or re-running a failed mount, check for and clear these *first* —
chasing the per-volume "operation already exists" lock when the real cause is a different volume's
stuck `DeleteVolume` blocking the serialized provisioner is a multi-hour rabbit hole. Document the
project's exact checks + clear commands, and run them before the retry, not after the third failure.

**Pre-flight for network / infra-state changes.** A distinct, higher-blast-radius class than a
single chart change: anything that reloads the CNI / gateway / host-network state (a CNI/pod-overlay
MTU change, an IPsec flip, an nmstate/NNCP interface change, a MachineConfig reroll) — **and any full
node power-cycle** — can silently break pod→host egress and hang voluntary evictions cluster-wide.
The transferable before/during/after shape:
- **Before:** check disruption budgets (`oc get pdb -A`, ALLOWED DISRUPTIONS ≥ 1 everywhere — a
  `MinAvailable == replicas` PDB has *zero* budget and hangs a drain forever); ensure any hostNetwork
  daemon that binds a fixed port (an S3 gateway, a router) still has a schedulable node after you
  drain one; schedule with 2h+ headroom.
- **During:** watch for stuck `VolumeAttachments` staying bound to the old node after a pod moves;
  force-clear their finalizers.
- **After:** restart **all** overlay/network pods (e.g. every `ovnkube-node`), not a subset — a node
  whose network pod wasn't restarted keeps *silently* broken pod→remote-host egress that only
  surfaces when a pod later lands on it (it can still reach its own host IP, so it looks fine). Then
  restart the GitOps repo-server (clears manifest-gen `DeadlineExceeded`) and sweep for **long-fuse
  external-egress retriers** — pods polling external endpoints on a schedule longer than the cascade
  window (cert-manager→ACME, anything calling a DNS/cloud API) keep retrying stale connections and
  won't self-recover; bounce them.

Keep the exact pod labels/namespaces as <!-- PROJECT --> detail; the *shape* (protect budgets → apply
→ restart ALL network pods → sweep retriers) transfers. Symptom of skipping the after-step: GitOps
`sync=Unknown` (repo-server can't reach the git host) and etcd CO degrades (`EtcdMembersAvailable: 1
of 3`) though etcd itself is healthy — confirm etcd real-vs-inferred with
`etcdctl endpoint health --cluster` before touching it.

**Time-box destructive-change debugging.** If a topology / network-mode / storage-mode mutation
breaks a subsystem and isn't recovered within ~30 min of focused debugging, **stop and
teardown/rebuild** instead of continuing — a polluted intermediate state is often far harder to debug
than a clean rebuild, and teardown is cheap on a cluster with no client load. (Only when no client
workload is at risk; with live load the trade-off differs — but then you shouldn't be making the
change in the first place.)

**Dark dashboards during an infra incident are a symptom, not a second failure.** If
Prometheus/Grafana/Loki (or the GitOps UI) run on the same storage/infra layer as the incident, a
storage hang takes the dashboards with it. Debug via the toolbox / `oc logs` / `oc exec` directly —
don't chase the dark dashboards as a separate problem.

---

## Guardrails — do not do these <!-- PROCESS + PROJECT -->

Refuse these and explain why briefly:

- **No mutating cluster commands.** No `oc/kubectl apply|delete|patch|scale|replace`, no
  `helm install|upgrade|uninstall|rollback`. The GitOps controller owns cluster state; direct edits
  cause drift and are reverted. (Read-only `oc get/describe/logs` and toolbox read-only `ceph`/`rbd`
  are fine.)
- **No state mutation on external tools** — `terraform apply|destroy|state mv|rm`,
  `argocd app sync --force` with prune.
- **No committed secrets** — Cloudflare/registry tokens, kubeconfigs, TLS private keys, pull secrets.
  Reference secrets by name; assume they exist out-of-band (SealedSecret/ESO).
- **No editing generated files** — `Chart.lock`, rendered manifest dumps, `*.orig`.
- **No cluster version bumps or cluster-wide CR changes without an explicit ask** — those are
  supervised upgrade events, not routine edits.
- **No `cordon`/`drain` on a no-drain-headroom cluster without an explicit ask.** Where the cluster
  has no spare capacity to absorb a lost node (e.g. this repo's 3-node bare-metal cluster, one
  replica per failure domain), any rolling storage/quorum change (OSD, mon) goes through a *degraded
  window* — never propose it casually, never run two such changes at once.
- **Don't disable `automated.prune` / `selfHeal`** (or auto-rotation, a health gate) to "fix" a sync
  issue. Fix the manifest. Disabling the alarm is not fixing the fire.

For anything hard to reverse or outward-facing, confirm first unless durably authorized. Approval in
one context doesn't extend to the next. Ceph-internal mutations (`ceph mgr fail`, `ceph osd …`) are a
different class from K8s mutations and *may* be appropriate — but flag them and confirm first.

## Commit and branch conventions <!-- PROCESS + PROJECT -->

- Work on the working branch, PR into the tracked branch. Commit/push only when asked; if on the
  tracked branch, branch first.
- `<scope>: <imperative summary>` — e.g. `cert-manager: bump to v1.16.2`, `root-app: add monitoring`.
- One logical change per commit — the rendered-manifest diff should be predictable from the message.
- Dependency-bot PRs are reviewed, not rewritten.

## Reviewing open PRs <!-- PROCESS + PROJECT -->

When asked to look at the repo, at session start, or when a dependency PR is relevant, **give an
explicit verdict per open PR** (read-only). I review and recommend; **I never merge — merge is the
user's.**

Lead with **APPROVE / HOLD / NOT-APPROVE** + a one-line reason, judged against the guardrails and the
relevant procedure. Cite the file/diff; name the guardrail or procedure it trips.

- **Storage bumps** (Rook/Ceph, storage charts, `quay.io/ceph/ceph`) → default **NOT-APPROVE**;
  these follow a supervised version-coherence + compatibility procedure, not a bot merge. A **major**
  bump (e.g. Ceph 19→20 while the operator doesn't support 20) is always NOT-APPROVE.
- **Operator / CRD-bearing bumps** (cert-manager, logging, CNPG, OADP, nmstate, gitops) → check the
  OKD/Kube compatibility matrix + whether the catalog has the build; **HOLD** if it crosses a support
  matrix or needs a catalog that doesn't exist yet.
- **App image tag bumps** (non-load-bearing) → usually **APPROVE** if patch/minor with no CRD/schema
  change; skim the changelog for breaking changes.

---

## Documentation currency <!-- PROCESS -->

Docs that drift are worse than none — readers trust them and run stale commands. An outdated
README/worklog is a regression to flag, same as an undocumented session.

- **READMEs** (root + per-component). Update the README in the *same change* that changes what it
  describes: bootstrap steps, a component's purpose/sync-wave/values surface, layout, version pins.
  The test: if you can't copy-paste a README command and have it succeed, the README is broken. Sync
  waves listed must match the root app's `values.yaml`. A README wrong but *unrelated* to your
  change → flag it or fix in a separate `docs(readme):` commit, don't bury it.
- **TODO list** lives in **one canonical place** <!-- PROJECT: pick one — a section at the bottom of
  `README.md` (the source repo's choice), a `TODO.md`, an issue tracker, or a project board -->.
  Ship → remove in the same commit. Refine → edit in place, don't duplicate. New → append to the
  right category. **Don't reorganize categories without an explicit ask** — the structure is
  deliberate.
- **Worklogs** — per **Working memory** above.
- **Before proposing "we should add X" / "X is missing" / "follow-up: ship X", grep the docs first**
  (`grep -ri "X" <worklog-dir>/ CLAUDE.md README.md components/`). If the docs say it's done, it's
  done —
  trust the docs over your own model. The user shouldn't have to be the verifier-of-last-resort that
  you read what they already wrote down.

---

## Communication preferences <!-- PROCESS -->

- Concise and technically precise. Skip hedging, flattery, and recap of what was just said.
- Surface trade-offs honestly. If there's a simpler or more idiomatic approach than what was asked,
  say so *before* implementing.
- When proposing a change, include the exact commands to validate it locally.
- Cite OKD/Helm/ArgoCD/cert-manager docs **by version** when version-specific behavior matters.
- Prefer a short correct answer with one follow-up question over a long answer that guessed at
  intent. When you have enough to act, act — don't narrate options you won't pursue.

## Tooling / MCP servers <!-- PROJECT -->

List project-scoped MCP servers and what they're for — e.g. a `kubernetes` server (structured
read-only `kubectl_get`/`describe`/`logs`, preferred over shelling out for inspection — fewer
prompts, structured JSON) and a `github` server (read-only repo access for cross-referencing upstream
issues). State which operations are allowlisted vs. prompt-gated. **Mutations go through the user**,
gated by the guardrails above — `kubectl_apply` and friends are denied by the same rules as `oc
apply`.
