# Immich on OKD — deploy notes

Self-hosted photo/video library on the 3-node OKD cluster. Official OCI Helm chart
wrapped in `components/apps/immich/`, with a dedicated VectorChord CNPG Postgres,
chart-bundled Valkey, CPU-only ML, library on Synology NFS, DB on Ceph NVMe-RBD.
Live at https://immich.apps.okd.sudops.pl since 2026-06-20.

## Pre-deploy de-risk (the research that paid off)

Two unknowns were worth nailing before flipping `enabled:true`:

**1. The vchord `CREATE EXTENSION` bootstrap under CNPG.** I'd assumed CNPG's
`bootstrap.initdb.postInitApplicationSQL` runs as the non-superuser app owner — which
would make `CREATE EXTENSION vchord` (a not-trusted, superuser-only extension) fail.
That assumption was **wrong**: all three CNPG postInit hooks run as the **postgres
superuser**; they differ only by target DB (`postInitSQL`→postgres, `postInitTemplateSQL`
→template1, `postInitApplicationSQL`→the app DB). So `postInitApplicationSQL` is exactly
right — superuser privilege AND it lands in the immich DB. Immich's own startup
migrations re-run `CREATE EXTENSION IF NOT EXISTS` as a no-op, so the non-superuser
immich role works. **No `managed.roles: superuser` needed** (the common shortcut in
gists, but unnecessary and a footgun). The `tensorchord/cloudnative-vectorchord` README
example uses `postInitSQL` — that's the subtle bug (creates the extension in the
`postgres` DB, never reaching the app DB). Ordering: `vector` before `vchord`, `cube`
before `earthdistance` (or CASCADE). `shared_preload_libraries: [vchord.so]` must be set
(it is) so the lib is loaded before the extension is created.

**2. restricted-v2 SCC fit.** The official chart ships no securityContext; the plan was a
values overlay (no custom SCC). This is where the research was *almost* right — see
gotcha 1 below.

## Deploy gotchas (both hit live, both fixed)

**Gotcha 1 — restricted-v2 rejects `fsGroup: 0`.** The SCC overlay set `fsGroup: 0` +
`runAsGroup: 0` (to match OKD's primary GID 0 for the NFS library). restricted-v2
refused every pod: `.spec.securityContext.fsGroup: Invalid value: []int64{0}: 0 is not
an allowed group`. restricted-v2 wants fsGroup from the namespace's allocated
supplemental-groups range, NOT 0 — so "fsGroup:0" and "no custom SCC" are mutually
exclusive. Fix: **drop the GID-0 pins**, keep only `runAsNonRoot: true` +
`fsGroupChangePolicy: OnRootMismatch` + the container hardening (allowPrivilegeEscalation
false, drop ALL caps, seccompProfile RuntimeDefault), and let OpenShift inject the
UID/fsGroup. The NFS write under the random UID then Just Worked — no EACCES (the
nfs-csi provisioned subdir was writable enough), so the NFS-perms worry never bit.

**Gotcha 2 — sync-wave deadlock.** First scaffold had the CNPG Cluster + library PVC at
`sync-wave: "1"`, but the chart's Deployments are at the default wave **0** and reference
the CNPG-generated `immich-postgres-app` secret (for DB_PASSWORD) + the `immich-library`
PVC. So ArgoCD applied wave 0 first, the pods failed (`secret "immich-postgres-app" not
found`, `pvc "immich-library" not found`), the Deployments hit their progress deadline,
the sync failed and retried — and **never advanced to wave 1**, so the Cluster + PVC were
never created. Classic inverted-dependency deadlock. Fix: **negative waves** — namespace
`-3`, library PVC `-2`, CNPG Cluster `-1` (ArgoCD waits on its health gate → the secret
exists), Deployments `0`, ScheduledBackup `1`. After ArgoCD's retry picked up the new
order: PVC bound, CNPG bootstrapped (initdb + extensions, `Cluster in healthy state`),
the `immich-postgres-app` secret appeared, valkey/ML/server came up, server logged
`Immich Server is listening on …:2283 [v2.6.3]` + `Machine learning server became
healthy`. (Debug note: the app's `operationState` showed a *stale* failing op for a
while; the controller logs — `waiting for healthy state of …/Cluster/immich-postgres` —
were the truth that it had recovered.)

## Final shape

- `immich-server` + `immich-machine-learning` (CPU-only) + `immich-valkey` (bundled) +
  `immich-postgres` (CNPG, 1 instance, vchord 18-1.1.1) — all `1/1`.
- Library: `immich-library` PVC, **nfs-csi RWX 500Gi**, Retain, Prune=false.
- DB: `immich-postgres-1` PVC, **ceph-nvme-block 10Gi**; daily volumeSnapshot (on-cluster).
- Route: `immich.apps.okd.sudops.pl`, edge TLS on the wildcard cert.
- First access → Immich's admin-account setup wizard.

## Open follow-ups

- **DB offsite**: ScheduledBackup is on-cluster RBD snapshot only — add barman→RGW or
  pg_dump→NAS so Postgres rides the offsite pipeline (files already do via the NAS).
- **ML cache → PVC** (currently emptyDir → re-downloads models on restart).
- **NVMe thumbnails** overlay if NFS thumb-grid latency is felt (server-only RWO).
- **vchord upgrades**: a tensorchord operand-tag bump needs a one-off superuser
  `ALTER EXTENSION vchord UPDATE` + `REINDEX INDEX face_index; clip_index;`.
- **No LTS**: pin the image; read release notes (DB-migration / VectorChord-floor) before
  any bump; keep server + ML on the same tag.

## 2026-06-20 (cont.) — pre-import prep: storage template, NVMe thumbnails, more gotchas

Before bulk-importing the existing library, three changes (all set BEFORE import so
assets land right the first time): pin the storage template, move thumbnails to NVMe,
bump ML/server memory. Two more chart gotchas surfaced.

**Storage template — declarative.** `immich.configuration.storageTemplate` renders a
`{release}-immich-config` ConfigMap, auto-mounted as `IMMICH_CONFIG_FILE`. Placement
matters: in chart 0.12.0 `configuration`/`configurationKind` live under the subchart's
`immich.immich` block (sibling of `persistence`), NOT the subchart top level — my first
try put it one level too high and it silently rendered nothing. The `{{y}}` template
braces render LITERALLY (the chart doesn't `tpl` the config block, so no Helm escaping).
Config-file = those keys are READ-ONLY in the admin UI (per-key), which is the
GitOps-correct trade. Set enabled BEFORE import to avoid the heavy Storage Template
Migration job over NFS.

**Thumbnails on NVMe.** Immich v2.x has a first-class `THUMB_LOCATION` env — no fragile
nested mount needed. Set `THUMB_LOCATION=/thumbs` (server only; ML works over HTTP and
never reads thumbs, valkey needs nothing) and side-mount an RWO `ceph-nvme-block` PVC at
`/thumbs`. The library mounts at `/data` (NOT `/usr/src/app/upload`), controller/container
ids are `main`/`main` (not `server`).

**Gotcha A — RollingUpdate→Recreate SSA conflict.** RWO + the chart's default
RollingUpdate deadlocks (Multi-Attach), so the server needs `strategy: Recreate`. But
server-side apply REFUSED the change: `spec.strategy.rollingUpdate: Forbidden: may not be
specified when strategy type is 'Recreate'` — the live Deployment (born RollingUpdate)
carried a defaulted `rollingUpdate` block that SSA wouldn't clear on the type flip, so
the sync failed 5×. Fix: delete the live `immich-server` Deployment once; ArgoCD recreates
it Recreate-native (no stale field). (Future-proofing: a fresh object born Recreate never
hits this.)

**Gotcha B — bjw-s auto-create thumbs PVC was wrong.** `persistence.thumbs` with
`type: persistentVolumeClaim` + `storageClass` rendered a PVC named `immich-server` with
NO storageClass (would never bind). Fix: template my own `templates/thumbs-pvc.yaml`
(`immich-thumbs`, ceph-nvme-block RWO 40Gi, sync-wave -2) and mount via
`persistence.thumbs.existingClaim: immich-thumbs` — same pattern as the library PVC.
The stray auto-created `immich-server` PVC was then pruned by ArgoCD.

**Result:** server `1/1` on the Recreate spec, mounts `/config /data /thumbs`,
`immich-thumbs` Bound on NVMe, storage template config-managed, app Synced/Healthy.
ML limit 4Gi→10Gi + server 8Gi for the import. Import itself: immich-go (managed upload,
storage template applies) from a workstation against the Route — operator-run.

## 2026-06-26 — bump to v2.7.5 + make Immich Renovate-trackable

Bumped the app `v2.6.3 → v2.7.5` (latest **stable**; `v3.0.0` is RC-only with major
breaking changes — OAuth/API/env + forward-only DB migrations — and wants a newer chart,
so it's a deliberate manual event after a verified DB backup, not a Renovate merge). The
chart stays `immich-charts 0.12.0` (still the latest chart; its `appVersion` is `v2.6.3`,
but app version is decoupled from chart version — you override `image.tag`, the chart
doesn't enforce it). `helm template` confirms `ghcr.io/immich-app/immich-{server,machine-learning}:v2.7.5`.

### The Renovate-tracking gap (and a repo-wide audit)

Immich's app tag was **invisible to Renovate**: we pinned a bare `tag: v2.6.3` with no
co-located `repository:`, and the `helm-values` manager needs BOTH to resolve a datasource.
Fix: set `image.repository` explicitly (`ghcr.io/immich-app/immich-server` /
`…/immich-machine-learning`, == the chart defaults, zero behaviour change) next to the tag.
Now Renovate tracks them.

Ran a verified repo-wide audit (4 parallel auditors classifying all 51 version pins +
an adversarial Opus verifier cross-checked against the open-PR ground truth). Findings:

- Every other component image is already tracked (full `repo:tag` strings, or co-located
  `repository`+`tag`). Intentionally-ignored sets stay ignored: rook/ceph (`enabled:false`
  packageRules), OLM `channel:` subscriptions (not a Renovate mechanism), `bootstrap/**`.
- **A second untracked CNPG image** — `components/apps/cnpg-clusters/values.yaml`
  `imageName: ghcr.io/cloudnative-pg/postgresql:18` (key is `imageName`, not `image`, so
  `helm-values` skips it). But `:18` is a rolling major tag → the only thing Renovate could
  offer is Postgres **19** (a migration event). So *not tracking it is correct* — it's a
  supervised image, same class as ceph.
- **A dead config rule:** the media/keepers patch-automerge rule uses
  `matchPaths: ["media/**","keepers/**"]`, but the real paths are `components/apps/media/**`
  → it matches **zero files**, so media patch PRs have never actually auto-merged (they sit
  open — e.g. #146 sonarr, #139 jellyfin). `matchPaths` is also deprecated (→ `matchFileNames`).
  Operator chose to **enable it**: repointed to `matchFileNames: [components/apps/{media,keepers}/**]`
  and removed the 3 dead `kubernetes` fileMatch globs (`media/.+`, `keepers/.+`, `ai/.+` — no such
  root dirs). Media/keepers **patch** bumps now self-merge; everything else stays a reviewed PR.

### renovate.json changes

Two packageRules added: (1) **group** `immich-server` + `immich-machine-learning` (`groupName: immich`)
— they MUST bump together or the app breaks; reviewed, not automerged. (2) **disable** both CNPG
operand images (`cloudnative-vectorchord` + `cloudnative-pg/postgresql`) — supervised, a major tag
bump is a DB migration (+ vchord needs an in-DB `ALTER EXTENSION`). Same gate shape as the ceph rule.

**Ordering note:** v2.6.3→v2.7.5 is same-major, low-risk, but still runs forward DB migrations on
first start. Library wasn't imported yet (operator-confirmed) so the DB was disposable — bump was
free. Roll confirmed clean: ArgoCD OutOfSync→Synced, server Progressing→Ready on v2.7.5 (migration
succeeded, not crashlooping), ML also v2.7.5.

**DB offsite backup — already covered (operator clarification):** Immich ships an automatic
database backup (`pg_dumpall`, default daily, keeps 14) that writes a `.sql.gz` to
`<library>/backups/`. Our library PVC is on **Synology NFS**, which rides the existing
NAS→cloud/offsite 3-2-1 — so the Immich DB lands offsite alongside the photo files, no separate
`pg_dump`/barman CronJob. (Restore caveat: needs the `cloudnative-vectorchord` operand image for the
vchord extension.) This downgrades the README "CNPG no offsite backup" item — only `media-postgres`
(servarr config, largely re-creatable) remains, now low-priority.

## 2026-06-27 — the NVMe-thumbnails dead end (it can't be done) + a CPU HPA for the server

Two asks today: finish the NVMe-thumbnails move from 2026-06-20, and add autoscaling to
`immich-server`. The first one turned into a clean retraction — the whole premise was wrong.
(Context: earlier today I also bumped the app to **v2.7.5** and made it Renovate-trackable —
see the 2026-06-26 section above.)

### `THUMB_LOCATION` is not a real Immich env var

The 2026-06-20 plan leaned on `THUMB_LOCATION=/thumbs` as a "first-class" env to relocate
thumbnails onto an NVMe RBD PVC. **It isn't one.** Checked against
`docs.immich.app/install/environment-variables` — there is no `THUMB_LOCATION` (nor any
per-folder location override). Immich writes thumbnails to `<media-location>/thumbs`
**unconditionally**; `media-location` is `/data` on v2.x by default with no override knob.

So the dedicated `immich-thumbs` `ceph-nvme-block` PVC, side-mounted at `/thumbs`, **sat
empty** — the operator noticed it had zero usage. The thumbs had been landing in
`/data/thumbs` on the NFS library the entire time. The env var did nothing; the mount just
shadowed an unused path.

### The nested-mount fix, and why it crashlooped

If Immich insists on `/data/thumbs`, the next idea was to **nest-mount** the RWO RBD PVC at
exactly `/data/thumbs` — overlay just that subdirectory of the NFS `/data` mount. This is a
legitimate kernel trick: `/data` (NFS) and `/data/thumbs` (RBD) are independent mounts, and
the kernel routes path lookups by **longest-prefix-match** — NFS owns `/data/*` except
`/data/thumbs`, which RBD owns. On paper it works.

In practice it **crashlooped the server**. Immich's startup runs "system mount folder
checks" (`StorageService.verifyReadAccess`): it reads a `.immich` marker in each media
folder, including `/data/thumbs/.immich`. On the **empty** freshly-provisioned RBD mount
that file doesn't exist → `ENOENT` → the microservices worker exits `1` →
`CrashLoopBackOff`. The integrity guard that protects against a half-mounted library is
exactly what an empty overlay trips.

### Removing thumbs didn't recover it — an SSA list-merge footgun

Reverting (drop the thumbs mount entirely, back to NFS-only) **did not** immediately fix it,
which was the nasty part. Server-side apply had **accumulated** two thumbs `volumeMounts`
across the iterations — `/thumbs` from the original 06-20 deploy plus `/data/thumbs` from the
nested-mount change — rather than replacing one with the other (SSA merges lists by key, it
doesn't treat my manifest as the full set). Removing the thumbs *volume* then left a
**dangling volumeMount** referencing a volume that no longer existed:

```
Deployment.apps "immich-server" is invalid:
spec.template.spec.containers[0].volumeMounts[2].name: Not found: thumbs
```

ArgoCD's apply got stuck retrying that invalid object, so the **crashing pod never got
replaced** — the corrected manifest was committed but couldn't land. Resolution: **delete
the `immich-server` Deployment** so ArgoCD recreated it **clean** from the rendered manifest
(ConfigMap + NFS library only, no thumbs cruft). The `immich-thumbs` PVC was pruned.

### Lesson: don't chase NVMe-for-thumbs on Immich

It can't relocate thumbnails — there's no env, the media-location default is fixed, and the
nested-mount workaround collides head-on with the folder-integrity check **and** the SSA
list-merge accumulation. That's a triple footgun for a marginal win (NFS thumb-grid latency
was never actually a felt problem). **Thumbs stay on the NFS library default.** Removed the
"NVMe thumbnails" follow-up from the open list.

### The actual win today: a CPU HPA on `immich-server`

With the server now carrying **no RWO volume** — only the RWX NFS library + a ConfigMap — it
can finally run multi-replica. Changes:

- **`HorizontalPodAutoscaler`** (`autoscaling/v2`) for `immich-server`: `minReplicas: 1`,
  `maxReplicas: 2`, target **75% average CPU**.
- **Strategy `Recreate` → `RollingUpdate`** — the Recreate constraint only existed because
  of the RWO thumbs PVC (Multi-Attach). No RWO volume → rolling is safe again, and the HPA
  needs it to add a replica without tearing the old one down first.
- **root-app `ignoreDifferences`** now includes the Deployment's `.spec.replicas`, so
  ArgoCD `selfHeal` doesn't fight the HPA over the replica count (the classic
  HPA-vs-GitOps drift).

Verified the HPA actually reads CPU — it reported **2918%**, which looks absurd until you
remember it's **request-relative**: the server's CPU request is only **250m**, so any real
work blows past 75% and scaling is effectively **binary** (1 → max almost immediately under
load). It does scale.

**Anti-affinity gap.** The HPA initially stacked both server replicas onto **one node**. The
existing `immich-server ↔ immich-machine-learning` anti-affinity keeps server *away from ML*
but says nothing about **server-from-server**, so two servers happily co-located. Added a
**soft (`ScheduleAnyway`) hostname `topologySpreadConstraint`** to prefer spreading replicas
across nodes.

**maxReplicas 3 → 2.** Capped at 2 because the cluster is memory-tight and each
`immich-server` runs **~5 GiB during import**. Three concurrent servers risked memory
pressure for no real throughput gain on this workload. min1/max2 is the right envelope here.

## v3 migration plan — Immich v2.7.5 → v3.0.1, chart 0.12.0 → 0.13.1

*Drafted 2026-07-05. Supervised, hand-done, backup-gated. This is NOT a Renovate merge — Renovate refs #150 (app v3 major) and #151 (chart 0.13 breaking schema) both stay HOLD/NOT-APPROVE. This section supersedes the "v3.0.0 is RC-only" note earlier in this draft.*

All paths are `components/apps/immich/` unless stated. Baseline: wrapper Chart.yaml `version: 1.0.0`, dep `oci://ghcr.io/immich-app/immich-charts/immich` **0.12.0**; server + ML pinned `v2.7.5`; dedicated CNPG `immich-postgres` on `ghcr.io/tensorchord/cloudnative-vectorchord:18-1.1.1`; root-app sync wave 7.

### 0. HARD PREREQUISITE — a verified, restorable DB backup (GATE #1)

**Do not touch the image tag or chart version until this gate is green.** v3's DB schema migration is **forward-only and effectively irreversible** — Immich has no down-migrations, official position "do not downgrade below 1.133.0 once migrated." The *only* rollback from a bad v3 start is restore-from-backup, so the backup posture must be *proven* first. Per the 2026-07-03 briefing the **R2 barman-cloud base backup has been failing** — that layer is unverified = blocker.

Three layers + gate criteria:
1. **On-cluster RBD volumeSnapshot** (`immich-postgres-daily`, class `ceph-rbd-snapshot`, 04:30 UTC, 7d) — verify a recent one is `completed`.
2. **Immich built-in `pg_dumpall` → NFS → NAS** (`<library>/backups/*.sql.gz`, daily, keeps 14) — verify a recent non-empty dump on the NAS. Restore needs the `cloudnative-vectorchord` operand image.
3. **R2 barman-cloud base** (`immich-postgres-r2`, method plugin) — **currently failing; fix as prep.**

**R2 triage (the gate blocker) — native sidecar, verify via bucket + sidecar logs, NOT CNPG status:**
- **pod→external egress** first (most likely, given cluster history): a node-outage OVN egress cascade silently kills R2 archiving; if a node power-cycled, restart all 3 `ovnkube-node` (user-run) + check WAL PVC free space (long outage → WAL-fill → CNPG safe-mode deadlock).
- **checksum env** still on the ObjectStore (`AWS_REQUEST/RESPONSE_CHECKSUM_*=when_required`, `AWS_REGION=auto`) — boto3≥1.36 `XAmzContentSHA256Mismatch` otherwise.
- **creds/endpoint** — `immich-postgres-r2-creds` valid, `…r2.cloudflarestorage.com` reachable.
- Read the `immich-postgres-1` barman sidecar log for the actual error class before guessing.

**Gate exit (all must hold before Section 3):** at least one of {NFS dump, R2 base} confirmed **restorable** (not just "the job ran"); **a restore rehearsal done at least once** into a throwaway vchord CNPG cluster + Immich starts clean against it; R2 either fixed or explicitly accepted with layers 1+2 proven.

### 1. Compatibility review

**vchord operand — NO change for v3.** v3 accepts vchord `>=0.3,<2.0`; our **1.1.1 is in range** → stay on `18-1.1.1`, do NOT jump to 2.x. We already run VectorChord on 2.7.5 (>v1.133.0) so **no pgvecto.rs→VectorChord and no v1.133 stepping stones** — go **2.7.5 → 3.0.x directly**. Same operand image → **no `ALTER EXTENSION vchord UPDATE`, no `REINDEX` this migration**. Keep pgvector (vchord depends on it); `shared_preload_libraries: vchord.so` already set. *(Deferred, NOT this migration: on a future operand-tag bump that changes the vchord `.so`, run superuser `ALTER EXTENSION vchord UPDATE; REINDEX INDEX face_index; REINDEX INDEX clip_index;` — REINDEXes appear to hang on a large library, normal; `postInitApplicationSQL` won't auto-run it on an existing cluster.)*

**Chart 0.13's CNPG "Database-CRD/imageVolume-extensions" model — does NOT conflict. Decision: keep the external DB; the chart never touches Postgres.** Verified on main: the official chart has **no DB dependency** (only `bjw-s common` 5.0.1) and **no postgres/cnpg/Cluster/Database template** — Immich is wired to the external DB purely via env (`DB_HOSTNAME`/`DB_USERNAME`/`DB_DATABASE_NAME`/`DB_PASSWORD`), exactly what our `controllers.main.containers.main.env` already does. PR #267 is a docs/example recommendation, not chart-applied resources. Nothing in the chart can mutate our `immich-postgres` Cluster/extensions → no adoption, no "bundled DB to disable" (there never was one).

**Values-schema remap 0.12 → 0.13 (PR #382) — a real breaking change to the chart's own values.** 0.13.0 added a JSON schema that rejects configs 0.12.0 silently ignored. **Confirmed break:** `persistence.library` no longer accepts `globalMounts` → the library mount must move under the **server component's** persistence block (our `immich.immich.persistence.library.existingClaim: immich-library` must be re-shaped + survive the move). **Uncertain — the full #382 field diff wasn't renderable; MANDATORY: diff live values vs `charts/immich/values.yaml` @ the 0.13.1 tag + run schema validation. Don't assume only `library` moved.** (appVersion map: 0.12.0→v2.6.3; 0.13.0/0.13.1→v3.0.0; we pin the image explicitly so appVersion is informational.)

### 2. Change set

Two independent workstreams applied together (0.13 is the matching chart for app v3); neither hands the chart control of Postgres.
- **2a. Coupled bump:** `Chart.yaml` dep `0.12.0`→`0.13.1` (`helm dependency update` + commit `Chart.lock`); `immich.controllers.main.containers.main.image.tag` and `immich.machine-learning.controllers.main.containers.main.image.tag` `v2.7.5`→`v3.0.1` (keep both `repository:` explicit for Renovate).
- **2b. values schema remap (#382):** re-shape `persistence.library` per 0.13; re-validate `immich.immich.immich.configuration.storageTemplate`, `defaultPodOptions` (securityContext, dnsConfig ndots:2), `strategy: RollingUpdate`, anti-affinity/topologySpread, both securityContext blocks (bjw-s common 5.x may have moved a passthrough key). **Diff against the 0.13.1 tag's values first.**
- **2c. v3 env audit:** confirm `DB_VECTOR_EXTENSION=pgvecto.rs` is absent (now a hard error; we use vchord = N/A but grep the render + admin UI). Audit for the 3 removed ML preload/timeout envs (`IMMICH_MACHINE_LEARNING_PING_TIMEOUT`, `MACHINE_LEARNING_PRELOAD__CLIP`, `MACHINE_LEARNING_PRELOAD__FACIAL_RECOGNITION`) — we don't set them, confirm admin UI too. OIDC breaks N/A (no OAuth configured — confirm none enabled out-of-band). ML needs x86-64-v2 + NumPy 2.4+ — trivially met.
- **2d. vchord SQL — NO change** (same operand, in-range). `postInitApplicationSQL` untouched (only runs on fresh bootstrap).
- **No sync-wave changes** (namespace -3 → PVC/ObjectStore -2 → Cluster -1 → Deployments 0 → ScheduledBackups +1 stays — the Gotcha-2 deadlock ordering).

### 3. Sequence (Gate #1 must be green first)

1. **Pre-cut backup+verify:** fresh on-demand base on all working layers; take an **explicit CNPG volumeSnapshot immediately before** + record its name (primary rollback artifact); confirm the NFS dump is current. Don't proceed without a restore-verified pre-migration copy.
2. **Maintenance window:** announce downtime; optionally scale `immich-server`/`machine-learning` to 0 so the schema migration runs from a controlled cold start (avoids HPA adding a 2nd replica racing the same forward-only migration).
3. **Local render + review:** `helm dependency update` → `helm lint` → `helm template …` → `kubeconform -strict` (+ validate against the 0.13 chart's JSON values schema) → `helm template … | oc diff -f -`. **Scrutinize the library volumeMount delta** (where #382 lands) and confirm no stray `thumbs` mount reappears (2026-06-27 SSA list-merge footgun → if it does, delete the `immich-server` Deployment for a clean ArgoCD recreate).
4. **Apply on `master`** (coupled: Chart.yaml + Chart.lock + values remap + both tags), push → ArgoCD syncs (fresh OCI subchart pulled at sync time → watch the *rendered* result, not just local).
5. **Run/confirm DB migrations:** new `immich-server` runs forward-only migrations on first start (album owner→`album_user`, timeline/asset fields). Watch logs to completion; do NOT interrupt or roll back mid-migration.
6. **Verify:** `immich-postgres` stays Healthy; server+ML Running, no crashloop; vchord loads (no VectorChord version-validation crash — #18960 class; 1.1.1 passes the `>=0.3<2.0` range); Route serves.
7. **Smoke test:** web login; library browses (thumbs off NFS `/data/thumbs`); a small ML job (search/face) responds; upload one asset + confirm storage-template placement; then update the mobile app (v3 removed old editor features — update client after server).
8. **Post-cut:** confirm HPA behavior, next scheduled backups fire on v3, un-scale if scaled to 0.

### 4. Rollback (forward-only DB → restore, not revert)

- **Primary:** restore the pre-migration CNPG volumeSnapshot (step 3.1) into `immich-postgres` (vchord operand image), then revert the git commit (dep→0.12.0, Chart.lock, values, tags→v2.7.5) so ArgoCD redeploys the old render against the restored DB.
- **Secondary:** restore from the NFS `pg_dumpall` or the R2 base (whichever is verified) into a vchord-capable cluster, then revert git.
- **Keep on hand during the window:** the old rendered chart output (`helm template` of the pre-bump state → scratchpad) + the named pre-migration DB snapshot.
- **Do NOT** start v2.7.5 against a DB v3 already migrated — restore to pre-v3 state first.

### 5. Risks + open questions

- **R2 backup failing** — biggest risk; if unfixable, migrate only on layers 1+2, restore-rehearsed first. The gate.
- **0.13 values-schema full diff unknown** *(uncertain — #382 field list thin)* — only the `library`/`globalMounts` removal confirmed; diff + schema-validate, don't assume.
- **v3.0.1 changelog thin** *(uncertain)* — treated as a bugfix over 3.0.0's breaking set; re-read release notes before applying if any surface.
- **SSA list-merge dangling volumeMount** — if `oc diff` shows a stray `thumbs` mount / `volumeMounts[N].name: Not found`, delete the `immich-server` Deployment for a clean recreate (2026-06-27 precedent).
- **PSA baseline vs restricted** (pre-existing, not v3): namespace PSA labels are `baseline`; the securityContext is a restricted-v2-shaped overlay but enforcement is baseline. Not a v3 regression; no action here.
- **HPA racing the migration** — mitigated by scaling server to 0 at start.
- **R2 schedule comment drift** (cosmetic cleanup while in the file): live is `0 0 3` = 03:00 UTC; a stray template comment says "03:30."
- **Out of scope:** ML cache `emptyDir`→PVC stays a separate queued follow-up.

### 6. Effort / scheduling

- **Prep (R2 triage + backup verify + first restore rehearsal):** ~1.5–3h, the real work; do as its own session ahead of the cut (= Gate #1).
- **Values reshape + render/diff:** ~1–1.5h (the 0.13 schema diff is the unknown; iterate against kubeconform + the chart JSON schema).
- **Migration window:** ~30–60 min apply + auto-migration + verify, + 20–30 min smoke test. **Total supervised window ~2h with 2h+ headroom**, prep done beforehand, quiet hours. One-way migration = no rushing step 5.

Files touched: `Chart.yaml`, `Chart.lock`, `values.yaml` (tags + 0.13 reshape). No template/sync-wave changes; `templates/cnpg-cluster.yaml` untouched (same operand, no vchord ALTER this round).

### 2026-07-05 — prep DONE + validated; cutover DEFERRED (backup gate open)

Ran the prep locally (chart pull + values reshape + validate) and it de-risks the cutover
significantly — **the reshape fear was overblown:**

- **0.13.0's "breaking" #382 is just the *addition* of `values.schema.json`.** The chart's Go
  templates are byte-identical 0.12.0 ↔ 0.13.1, and **our `values.yaml` was already
  schema-conformant** — we set `immich.persistence.library.existingClaim` (accepted) and never used
  the now-rejected `globalMounts`. So **NO structural reshape is needed.** The entire cutover diff is:
  `Chart.yaml` dep `0.12.0 → 0.13.1` + the two image tags (`immich-server`, `immich-machine-learning`)
  `v2.7.5 → v3.0.1`. That's it.
- **Validated clean:** `helm dependency update` pulled `immich-charts:0.13.1` fine; `helm lint` 0 fail;
  `helm template` clean (rendered tags = v3.0.1, all customizations preserved); `kubeconform -strict`
  18/18 valid (Route skipped); v3 env audit clean (no `DB_VECTOR_EXTENSION`/pgvecto.rs, no removed ML
  preload envs); vchord 1.1.1 in-range → no operand bump / no `ALTER EXTENSION`.
- **immich chart `Chart.lock` + `charts/*.tgz` are gitignored** (unlike Rook) → a cutover commit shows
  only `Chart.yaml` + `values.yaml`; ArgoCD re-pulls 0.13.1 fresh keyed off `Chart.yaml`. Local render
  used the matching 0.13.1 tgz, so **local render == what ArgoCD deploys** (no stale-subchart trap).

**Why deferred (not done 2026-07-05):** the backup gate isn't closed — **a restore rehearsal has
never run for immich-postgres**, and a `completed` Backup CR proves the *write* path, not
restorability. v3's schema migration is forward-only, so the only rollback is restore-from-backup;
cutting over on unverified backups (hours after the same-day OSD_FULL storage incident, on the same
Ceph the DB+backups live on) stacks avoidable risk. Prep reverted → tree clean.

**Next-session cutover checklist (gate is genuinely small now):**
1. **Restore rehearsal** — restore immich-postgres into a throwaway recovery Cluster from the
   volumeSnapshot (and ideally the R2 base+WAL); confirm Immich schema/row counts. Closes Gate #1.
2. Confirm the **07-06 03:00 R2 daily** completed green (the InvalidPart fix's first unattended run).
3. Take a **named pre-V3 CNPG volumeSnapshot** (`immich-postgres-preV3-<ts>`) immediately before.
4. Scale `immich-server` + `machine-learning` to 0.
5. Bump `Chart.yaml` dep → 0.13.1 + both tags → v3.0.1; `oc diff` (expect only the tag deltas);
   commit + push (**point of no easy return**).
6. Watch the forward-only DB migration in the server logs → verify (vchord loads, Route serves,
   ContinuousArchiving True) → smoke test (login/library/ML/mobile).

### 2026-07-06 — Gate #1 CLOSED: R2 restore rehearsal passed

Checklist items 1–2 done this morning: (1) **restore rehearsal PASSED** — immich-postgres restored
end-to-end from the R2 base (`20260706T030001`, first post-InvalidPart-fix uncompressed base) + WAL
replay into a throwaway vchord cluster, ~2.5 min, exact row/size parity (1987 assets / 2 users /
147 MB), vchord index queryable, live archive provably untouched (full write-up:
`blog/blog-cnpg-draft.md` 2026-07-06; manifest: `tests/immich-postgres-restore-drill.yaml`);
(2) the **07-06 03:00 R2 daily completed unattended** (03:00:07Z). Proceeding with checklist
steps 3–6 (pre-V3 snapshot → scale to 0 → bump+push → watch migration) — cutover chronicle below.

### 2026-07-06 — v3 CUTOVER DONE (v2.7.5 → v3.0.1, chart 0.12.0 → 0.13.1)

Executed the same morning the gate closed, per plan. Chronicle:

1. **Pre-V3 snapshot:** on-demand `Backup` CR `immich-postgres-prev3-20260706`
   (method volumeSnapshot) → `completed` in seconds. Old `helm template` render saved to
   scratchpad. (Today's 03:00 R2 base `20260706T030001` + continuous WAL = the PITR layer,
   restore-verified by the morning's drill.)
2. **The bump** (commit `2c44971`): `Chart.yaml` dep `0.12.0→0.13.1` + both image tags
   `v2.7.5→v3.0.1` + comment refresh. Validation: `helm dependency update` (0.13.1 pulled
   clean), lint 0 fail, kubeconform 18/18, render-diff vs pre-V3 = chart labels + server/ML
   images + **one unplanned-but-benign extra: 0.13.1 bumps the pinned Valkey `9.1-alpine`
   digest** (same tag; disposable queue). `oc diff` live: the same 3 image deltas, **no stray
   `thumbs` mount** (the 2026-06-27 SSA footgun didn't reappear), no library-mount churn.
3. **Deviation from plan step "scale to 0":** skipped deliberately. All three Deployments
   render `replicas: 1`, so ArgoCD selfHeal makes a manual scale-to-0 non-sticky — and the
   race (selfHeal restoring replicas with the OLD cached render before the repo refresh)
   could restart v2 mid-window. RollingUpdate overlap (old v2 serving while the v3 surge pod
   migrates) was accepted instead: migrations take exclusive locks, 2-user instance, quiet
   hours. Deterministic beats theoretically-cleaner.
4. **Push → `argocd.argoproj.io/refresh=normal` annotation → sync Running** at `2c44971`
   within ~30 s. v3 images pulled ~1.5 min.
5. **Migration: 8 seconds.** `Running migrations` 10:22:04Z → `Immich Server is listening on
   http://[::1]:2283 [v3.0.1]` 10:22:12Z → `Adding 3.0.1 to upgrade history` 10:23:07Z.
   No errors, no interference from the outgoing v2 pod.
6. **Verify:** rollout watcher reported v3 Ready + old pod gone; ML on v3; CNPG
   `Cluster in healthy state`, `ContinuousArchiving=True` throughout; Route
   `GET /api/server/version` → `{"major":3,"minor":0,"patch":1}`. **HPA scaled server to 2
   during startup** (CPU spike tripped the 75% target) — post-migration second v3 pod is
   safe; expected to settle back to 1 after the downscale stabilization window.

**Remaining human smoke test (operator):** web login, library browse (thumbs off NFS), an ML
job (search/face), one upload + storage-template placement, **then update the mobile apps**
(v3 removed old editor features — client after server). Watch tonight's scheduled backups
(03:00 R2 base, 04:30 snapshot) fire on v3.

**Rollback posture (unused, for the record):** restore `immich-postgres-prev3-20260706` into
immich-postgres + revert `2c44971`; secondary = R2 PITR to pre-10:22Z (drill-verified) or the
NFS pg_dumpall. Do NOT start v2.7.5 against the migrated DB.

Renovate #150 (v3 images) + #151 (chart 0.13.1) should auto-close/obsolete now that master
carries both versions.

## 2026-10-11 — multi-user design: a `family` account, partner sharing, a cluster group

The question was whether the picture in my head is the right shape: every phone backs up to its own
account, and one shared `family` folder is readable by everyone. Checked against the v3.3.1 docs and
the v3.2.0 / v3.3.0 release notes rather than from memory:

```bash
gh api 'repos/immich-app/immich/contents/docs/docs/features/partner-sharing.md?ref=v3.3.1' --jq .content | base64 -d
gh api 'repos/immich-app/immich/contents/docs/docs/features/sharing.md?ref=v3.3.1' --jq .content | base64 -d
gh api 'repos/immich-app/immich/contents/docs/docs/administration/user-management.mdx?ref=v3.3.1' --jq .content | base64 -d
gh api 'repos/immich-app/immich/contents/docs/docs/features/libraries.md?ref=v3.3.1' --jq .content | base64 -d
gh release view v3.2.0 -R immich-app/immich --json body --jq .body   # cluster groups
gh release view v3.3.0 -R immich-app/immich --json body --jq .body   # people sharing
gh api 'repos/immich-app/immich/contents/server/src/schema/tables/album-asset.table.ts?ref=v3.3.1' --jq .content | base64 -d
```

What those say, as far as it drives the design:

- Access is granted per account, never per folder. The on-disk tree (`library/<storage label>/…`)
  only records who uploaded. The label applies to new uploads; applying it to existing assets needs
  the Storage Migration job.
- Partner sharing shares the *entire* library, one way: view and download, all metadata including
  GPS, and the right to put those assets into one's own albums and share links. It does not carry
  albums, favourites, or people and face data. Archived assets are not shared. "Show in timeline" is
  a per-partner switch. Duplicates are detected per user only, so a photo held by two accounts shows
  twice.
- A shared album has editors and viewers; members add their own assets. Album membership is a row in
  `album_asset` (albumId, assetId) — adding a partner's photo to an album copies nothing.
- An external library belongs to one user and leaves the files where they are.
- Deleting a user removes their library after 7 days by default.
- Cluster group (v3.2.0): trusted users on the instance join a group so people are recognised across
  the assets they share. As shipped it required resetting facial recognition for every member, which
  drops names and birth dates. v3.3.0 added sharing a person with a group member (directional, both
  can edit name and birth date) and cross-user merging, described as the way to avoid the reset.

### Decided

- **Accounts:** mine (admin, as today, label `Vadzim`), my wife's, and `family` — a normal non-admin
  account that is logged in on no phone. More accounts (our son, maybe others) are undecided and do
  not change anything: a new account gets one extra share from `family`.
- **What `family` holds:** the old archive (plain folders on a Synology share) plus whatever is later
  uploaded from a PC while logged in as `family`. Phone photos stay in the personal accounts.
- **Who sees it:** `family` partner-shares its whole library, one way, with every personal account,
  each with "show in timeline" on. Nobody shares back to `family`. This replaces the June plan of one
  "Family" album: the library share picks up later uploads with no further step. Write access is
  simply the `family` password, kept to the two of us.
- **Between the personal accounts:** left open on purpose. It is a per-person switch that moves no
  files. Suggested start: share both ways with "show in timeline" off.
- **Duplicates rule:** phone photos are never uploaded into `family`; they are shared by reference
  (albums or the library share). `family` uploads are for what no phone backs up — archive, camera
  cards, scans, photos other people send.
- **Faces:** go for the cluster group (me, wife, `family`) and people sharing, tried on about 20 test
  photos before the archive import. Reason for doing it early: a forced reset costs 8 names today and
  would cost hundreds after the archive is named. Fallback is separate People per account, which
  means searching the archive by person only while logged in as `family`.

### Ruled out

- **No `family` account** (archive into my own account, partner-shared): People and search in one
  place, but the archive would be mine alone to organise and would mix into `library/Vadzim/`.
- **External library** on its own TrueNAS dataset: keeps the folders browsable outside Immich, but it
  is a second dataset to back up, belongs to one user anyway, and loses Immich-side metadata whenever
  a file is moved.

### Rollout

Stage 1 needs neither the UPS nor OVH and is all in the web UI: record the 8 named people, create the
two accounts with storage labels set before any upload, share `family` out, upload ~20 photos as
`family` from a separate browser profile, confirm from my wife's account that she sees them and
cannot delete, form the cluster group, check People and search from my account and note whether a
reset was forced, share one person, decide.

Stage 2 (confirmed 2026-10-11) waits for the library to be on TrueNAS with the OVH job running, except
for its first two steps, which only read: measure the archive on the Synology (never measured; bounded at < ~2.2 TiB on 2026-08-29),
compare it by checksum against the personal libraries and build an exclude list, import as `family`
with immich-go v0.32.0 (`upload from-folder`, albums from folder names, API key created in the
`family` account) — dry run, one small folder, then the rest — and check asset count against file
count. Importing before the move would write a second copy of the archive onto the DS418 and make
the move copy it again with Immich stopped.

For the backup design this means the archive lands inside the Immich library, so the OVH task covers
it without being named; the share on the DS418 stays as the untouched original until the box is
sold; and the sell gate gains "a restore from OVH that includes `library/family/` was checked".

### Same day — stage 1 reported working; stage 2 prep

The operator ran stage 1 in the web UI and reported it working, then asked to go on to stage 2.
Whether joining the cluster group forced a facial-recognition reset was not reported; record it here
when known.

Prep done from the MacBook Air: `brew install immich-go` -> `immich-go version:0.32.0` (the Immich v3
release; nothing was installed on this machine before). Checked against the v0.32.0 docs
(`docs/commands/upload.md`, `docs/installation.md`, `docs/configuration.md`):

- `immich-go upload from-folder` with `--dry-run`, `--folder-as-album FOLDER|PATH|NONE`,
  `--album-path-joiner`, `--on-errors stop|continue|N`, `--concurrent-tasks`, `--log-file`.
- The default `--ban-file` list already drops Synology junk (`@eaDir/`, `SYNOFILE_THUMB_*.*`).
- `--pause-immich-jobs` defaults to `true` and then needs `--admin-api-key` (an admin-linked key with
  `job.create` and `job.read`). Dry runs use `--pause-immich-jobs=false`.
- API key permissions per account: `asset.read`, `asset.statistics`, `asset.update`, `asset.upload`,
  `asset.copy`, `asset.delete`, `asset.download`, `album.create`, `album.read`, `albumAsset.create`,
  `server.about`, `stack.create`, `tag.asset`, `tag.create`, `user.read`.
- Keys stay out of chat, shell history and git: immich-go reads `immich-go.toml` from the current
  directory (`[upload]` table: `server`, `api-key`, `admin-api-key`), so one directory per account
  under `~/immich-import/`, files mode 600, and the commands carry no secret.

Order from here: mount the archive share on the Mac, measure it (size, file count, extensions), dry-run
against `family` and against each personal account to size the overlap, and only then decide when the
real import runs. The import writes to the library; the measuring and the dry runs do not.

## 2026-10-11 — stage 2, before any upload: sorting the archive

The order of the day changed twice. The old single-account library was deleted on purpose, the
library moved to TrueNAS, and a nightly copy to the Synology went live
(`blog/blog-truenas-migration-draft.md`, `blog/blog-offsite-backup-draft.md`). The condition for
the import — a backup that exists first — is met. The operator then asked for one more thing
before uploading anything: separate what is a photo or video from what is not, to review the rest
by hand and to avoid importing piles of duplicates.

The personal-account keys I had asked for turned out to be unnecessary. They were for checking
the archive against photos already in those accounts, and those accounts are now empty. Only the
`family` key exists, in `~/immich-import/family/immich-go.toml`, outside the repo; `immich-go`
reads it with `--config ./immich-go.toml` (its `--help` names `./immich-go.yaml` as the default,
the docs name `.toml`, so I pass the file explicitly).

A dry run on one small folder first: 67 assets found, 82.4 MB, 0 errors, and the file counts on
TrueNAS unchanged afterwards (145 in `library/`, 3 in `upload/`) — the log says "Dry-run mode
enabled. No changes will be made to the server."

### Inventory (read-only walk of the share over SMB)

One line per file — path, size, mtime, extension — into `~/immich-import/inventory/`, then sorted
by what Immich v3.3.1 accepts (`docs/features/supported-formats.md` at that tag):

| group | files | size |
|---|---|---|
| videos Immich accepts | 2,178 | 251.4 GiB |
| photos Immich accepts | 49,693 | 85.9 GiB |
| archives (one Google Takeout `.tgz`, two zips) | 3 | 49.4 GiB |
| video Immich cannot take (`.vob`, DVD) | 5 | 4.2 GiB |
| files that belong to a photo (15,280 Takeout `.json`, plus `.aae`, `.xmp`, `.thm`) | 15,329 | 0.01 GiB |
| everything else (`.pdf`, `.db`, `.exe`, `.xml`, …) | 48 | 0.02 GiB |
| **total** | **67,256** | **390.9 GiB** |

That is 47 GiB more than this morning's 343.5 GiB: the operator added a folder in between.

### Duplicates, as far as names and sizes can tell

- 13,141 media files (69.5 GiB) have the same name and the same size as a file somewhere else in
  the archive. Not hashed: confirming it would mean reading 209 GiB over SMB, and Immich rejects a
  second identical file per account by checksum anyway.
- Almost all of it is one thing: the Google Photos export is there three times — an extracted
  folder with its `.json` files (14,115 media), a second folder without them (13,776 media), and
  the `.tgz`. The two folders share 11,745 files by name and size; 2,031 (4.2 GiB) are only in
  the second, 2,370 (2.8 GiB) only in the first.
- Both zips match their extracted folders (169 entries vs 169 files; 230 vs 224, the difference
  being directory entries).
- Outside the Takeout copies, 561 of 23,980 media files also sit in one of them.

What names and sizes cannot see is the same picture saved as a different file (resized, re-saved
by a messenger, an edited copy). Those are the duplicates that would show in the timeline, and
they are a job for Immich's duplicate utility after the import, not for a pre-check.

Review lists left for the operator in `~/immich-import/inventory/`: `review-other.tsv`,
`review-video-immich-cannot-take.tsv`, `review-archives.tsv`, `review-same-name-and-size.tsv`.
Nothing on the share was changed.

## 2026-10-12 — the archive checked by content, not by name

Two things from the evening before. The operator asked for the files that are neither photo nor
video to be moved aside, and for the Google `.tgz` to be compared with the two extracted copies
"by content — it should match" before anything is skipped.

### Moves and one conversion (the only changes made to the share)

- 48 non-media files moved from `photo/photo/…` to `photo/docs_to_review/…`, keeping their
  relative paths. A rename on the same share, so no copy; each checked for size at the
  destination and absence at the source. List kept outside the repo.
- Five `.vob` files turned out to be one 1 h 30 min home video (MPEG-2 720×576 PAL, 4:3,
  interlaced, AC-3). "Remove vob" could have meant delete, and the share has no recycle bin, so I
  asked; the answer was to convert. `brew install ffmpeg` (9.0.2), then:

  ```bash
  ffmpeg -fflags +genpts -i "concat:VTS_01_1.VOB|VTS_01_2.VOB|VTS_01_3.VOB|VTS_01_4.VOB|VTS_01_5.VOB" \
    -map 0:v:0 -map 0:a:0 -vf "bwdif=mode=send_frame:parity=tff,scale=768:576:flags=lanczos,setsar=1" \
    -c:v libx264 -preset medium -crf 18 -pix_fmt yuv420p -c:a aac -b:a 192k \
    -af "aresample=async=1:first_pts=0" -movflags +faststart out.mp4
  ```

  135,892 frames, 5,435.68 s in and out, 3.20 GiB against 4.2 GiB; a full decode of the result
  reported nothing, three sampled frames looked right, and the source had one damaged B-frame
  that the decoder concealed. Copied next to the originals and compared by sha1. The originals
  are untouched; the recording date is unknown (the files carry their copy date).

### The checksum run

`sha1` of every member of the `.tgz` (streamed once with Python's `tarfile`), of every file in the
two extracted Google folders, and of one folder pair that shared 792 names and sizes. sha1
because it is what Immich uses to refuse a duplicate, so "equal here" is "the same asset there".
188.3 GiB read over SMB in 8 h 36 min — the DS418 manages about three small files a second, and
for the first three hours a full-tree `immich-go` dry run was competing for the link. I stopped
that dry run: it reads every file completely, and a quarter of the way in it had already shown
the one thing it could (13,687 warnings that the Takeout's `.json` files are ignored in
`from-folder` mode).

| question | answer |
|---|---|
| is the extracted Takeout folder the `.tgz`? | 29,392 of 29,396 members identical at the same path, none different. Three of the other four exist under another name; the fourth is the index page that had just been moved to `docs_to_review` |
| what does the second Google folder add? | of 13,776 files, 12,778 (44.0 GiB) are byte-identical to something in the export; 998 (3.4 GiB) are not |
| is the 792-file pair really the same? | all 792 identical (24.5 GiB); 56 small files exist on one side only |

Name-and-size matching had put the second folder's surplus at 2,031 files; content puts it at
998, because about a thousand files there are export files under different names. The 16 "read
errors" in the run are the 16 files moved away after the inventory was taken.

So the `.tgz` and both zips can be skipped, the Takeout folder goes through
`immich-go upload from-google-photos` (its `--help` accepts a folder as well as the zips), and the
second folder can be imported as a plain folder, where the server will turn away all but 998.
