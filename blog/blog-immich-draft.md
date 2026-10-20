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

The operator's answers closed the open points for the upload itself: everything still in
`photo/photo` goes into the `family` library, including the two folders I had flagged, and there
are to be no albums — timeline only. For the plain folders that is `--folder-as-album=NONE`. For
the Takeout it should mean `--sync-albums=false` as well, but Google's own albums are not the same
thing as folder names, so that one gets asked before the run. The home video's year and what
happens to its `.vob` originals are not decided. Nothing has been uploaded yet.

## 2026-10-12 — stage 2, first upload: one camera-roll folder

The first real upload, kept as small as the archive allows so that every file could be checked
afterwards. By the inventory the smallest top-level folder is `102APPLE`: 67 JPEGs,
86,411,730 bytes, no subfolders. Its dry run on 2026-10-11 had reported 67 to upload and no
errors, and the folder had not changed since.

Baseline first: sha1 of the 67 source files (list kept outside the repo), and file counts in the
dataset on TrueNAS — `library/Family` 141, `thumbs` 300, `upload` 3.

```bash
cd ~/immich-import/family
immich-go upload from-folder --config ./immich-go.toml --no-ui --on-errors continue \
  --folder-as-album NONE --log-file ./upload-102APPLE.log /Volumes/photo/photo/102APPLE
```

Eight seconds (17:26:16Z to 17:26:24Z), exit 0, "uploaded successfully: 67 (82.4 MB)", errors 0.

| check | result |
|---|---|
| `library/Family` file count | 141 → 208 |
| the 67 new files against the 67 sources, by sha1 | 67 identical, 0 missing, 0 extra |
| where the storage template filed them | `library/Family/2017/2017-07-17` (9), `2017-07-18` (58) |
| `upload/` afterwards | 3, as before — nothing left waiting |
| thumbnails | 300 → 436 within about three minutes |
| the same command again with `--dry-run` | "server has duplicate: 67", nothing to upload |

Three things worth keeping:

- **One `ERR` line that is not an error.** At the end of a run immich-go sends a "resume" for the
  `thumbnailGeneration` job, even with `pause-immich-jobs = false` in the config. The `family`
  key is not an admin key, so the server answers `403 Forbidden`. Nothing had been paused, so
  nothing needed resuming, and the thumbnail count shows the job running.
- **`find -mmin` finds nothing after an upload.** Immich keeps each file's original modification
  time, so the new files look years old. `find -cmin` (inode change time) is the one that works.
- **The CPU autoscaler reacted.** `immich-server` went from 1 to 2 replicas while the thumbnails
  were generated; both pods Ready, CPU back at 3% of the request afterwards. Expected, and a
  reason not to read a second server pod during an import as a problem.

The second dry run also counts "metadata updated: 67". Read from the v0.32.0 source afterwards
(`app/upload/run.go`, case `SameOnServer`): for a file the server already has, immich-go records
that event and re-applies album membership, nothing else. With no albums a real re-run writes
nothing.

### Deleting a photo, then importing the same folder again

The operator's question after seeing the photos in the UI: if a couple are deleted from the
`family` account, are they gone from disk, and does a repeat import skip the identical ones and
bring back only the deleted ones? Checked in the source of both sides at the versions in use
rather than answered from memory.

- **Delete is trash first.** The file stays where it is on disk until the trash is emptied or its
  retention passes (Immich's default is 30 days; the chart does not set it, and I cannot read
  the admin setting). Only then are the original and its thumbnails removed.
- **A trashed photo still counts as present.** Server v3.3.1,
  `server/src/services/asset-media.service.ts`: an upload whose checksum matches an existing row
  is answered `DUPLICATE`, and the bulk check reports `isTrashed` for it — it is neither stored
  again nor restored. immich-go v0.32.0 lists trashed assets as well (`immich/metadata.go` adds a
  `TrashedAfter` query) and matches by checksum, so it reports "server has duplicate" and does
  not even try.
- **So a deleted photo comes back only after it is permanently gone.** Before that a repeat
  import skips it, and it then disappears for good when the trash expires.

The consequence for this archive, which holds the same bytes in more than one folder: a photo
deleted *and* purged from the trash is re-imported by the next folder that contains a copy.
Culling belongs after the last folder is in, or the trash stays un-emptied until then.

**Tried the same evening.** The operator removed two of the 67 photos, and I repeated the dry
run and the count on TrueNAS at 17:35Z:

```
uploaded successfully              :       2  (1.6 MB)
server has duplicate               :      65  (80.8 MB)
library/Family 206 files | under 2017: 65 | thumbs 432
```

The two files were already gone from the dataset (208 → 206, four thumbnails with them), and by
sha1 the two missing files are exactly the two the dry run wants to upload (1,688,917 bytes).
That is the "permanently gone" case, not the trash case: the server's public settings say trash
is on with 30 days (`/api/server/features` → `trash: true`, `/api/server/config` →
`trashDays: 30`), so a plain delete would have left the files in place. The trash case therefore
stays read from source, not tested.

A side note from the same listing: the `.immich` marker file in every top-level folder had a
change time of 17:26:54Z, with no upload touching those folders. That is the second
`immich-server` pod starting under the autoscaler — the server rewrites the markers when it
checks write access at start-up. By 17:35Z the deployment was back to one pod.

Deletion from the live dataset is also not deletion everywhere: the dataset's daily snapshots
keep a file for 30 days, and the nightly copy to the Synology is `COPY` mode on purpose, so
anything that was present at a 05:00 run stays in `photo/backups/immich`.

One sample, so no estimate for the rest yet: 67 files and 82 MB in 8 s, including start-up and
reading from the DS418 over SMB with the default 10 concurrent tasks.

## 2026-10-15 — stage 2, step 1: the small folders, and immich-go's "upgrade" rule

The import plan, agreed with the operator the same morning: the camera and phone folders first, smallest
first, then the Google export through `from-google-photos`, then the second Google folder, which is mostly
byte-identical to the export. Every folder gets a full sha1 check afterwards (the operator's call: "just to
fully close"). Step 1 was seven folders of 0.9 to 2.6 GiB plus the seven loose files in the share root.

### The checker

A small driver (kept outside the repo, next to the import logs) runs one folder at a time:

1. index the `family` account's files on TrueNAS, `library/Family` plus `upload/<user id>`, hashing only paths
   it has not seen (`ssh … 'cd /mnt/tank/immich && xargs -0 sha1sum -z'`);
2. upload the folder (`caffeinate -i immich-go upload from-folder … --folder-as-album NONE`);
3. wait until nothing on the dataset changes for a minute;
4. index again, sha1 every source file the upload log names, and match each one to its last event: an upload
   must appear among the new server files, a duplicate must already be there, and nothing may appear on the
   server without a source or disappear from it.

Loose root files go in with `--recursive=false` on the share root. A dry run first showed exactly the seven
files and the three archives skipped as "useless file".

### What the first photographer's folder showed

One folder is a photographer's delivery: 78 shots, each as a normal JPEG of about 2 MB, most also as a
print-size version of about 12 MB in a subfolder, and 15 as a third edit in another. immich-go 0.32.0 reported
46 "server asset upgraded" and stopped on four `CopyAsset … 400 Bad Request` errors. The source explains both
(`app/upload/advice.go`, `app/upload/run.go` at tag v0.32.0):

- After the checksum check, immich-go looks for a server asset with the **same file name and a capture time
  within ±5 s**. A bigger local file "upgrades" it: upload the new file, `PUT /api/assets/copy` to carry albums
  and favourites over, then `DeleteAssets(…, force=true)`. **Force means no trash**: the smaller asset is gone
  from Immich at once. A smaller local file is skipped instead ("bigger size … exists").
- With the default 10 concurrent uploads, two versions sent at the same moment do not see each other. The
  folder ended with 42 shots holding only the print version, 32 holding print and normal, one holding all three
  and three holding one of the smaller ones: the result depended on timing.
- The four 400s were the copy step failing on an asset that was itself only seconds old. The delete never ran,
  so both versions stayed. The same race left four files the storage template could not move out of `upload/`
  (`duplicate key value violates unique constraint "UQ_newPath"`).

Across the archive the 10-11 dry run had counted 7,842 such replacements and about 2,200 skips, so the rule
decides about ten thousand files. Put to the operator as a choice — keep immich-go's rule with one upload at a
time, or de-duplicate by checksum only and review near-duplicates in Immich — they chose to keep every distinct
file.

### immich-go, checksum-only

A one-change build from the v0.32.0 tag (`f7d19fc`): in `ShouldUpload`, after the checksum lookup, return
"not on server" instead of falling through to the name match.

```bash
git clone --depth 1 --branch v0.32.0 https://github.com/simulot/immich-go.git
# patch app/upload/advice.go (8 lines), then, outside the sandbox (its proxy breaks Go's TLS check):
GOCACHE=… GOMODCACHE=… go build -trimpath \
  -ldflags "-X github.com/simulot/immich-go/app.Version=0.32.0-checksum-only" -o immich-go-cs .
```

`go vet` clean; the package has no tests upstream. The real test was a dry run of the photographer's folder
against the server as it stood:

| build | upload | replace | skip for a bigger copy | already on server |
|---|---|---|---|---|
| stock 0.32.0 | 47 | 1 | 9 | 112 |
| checksum-only | 57 | 0 | 0 | 112 |

57 = the 46 force-deleted versions plus the 11 skipped ones. The real re-run uploaded those 57 and the check
found all 169 source files on the server.

### Step 1 result

| folder (kind) | source files checked | uploaded | already there / local duplicate | problems |
|---|---|---|---|---|
| a family-history export (2024) | 176 | 171 | 0 / 5 | 0 |
| the photographer's delivery | 169 | 112 + 57 (re-run) | — | 0 |
| a family-history export (2023) | 224 | 220 + 1 (retry) | 0 / 3 | 0 |
| iPad camera roll | 356 | 355 | 0 / 1 | 0 |
| iPhone camera roll | 434 | 434 | 0 | 0 |
| two iPhone `1xxAPPLE` folders | 509, 470 | 509, 468 + 1 (retry) | 0 / 1 | 0 |
| loose files in the root | 7 | 7 | 0 | 0 |

The `family` library went from 208 files to 2,543 media files.

Things the checker turned up on the way, none of them a loss:

- **Two transient upload failures.** `write: broken pipe` to the ingress VIP at 11:22:52 (a reused keep-alive
  connection, most likely; the autoscaler started a second server pod a few seconds later) and one
  `502 Bad Gateway` at 11:45:28 with nothing in either server pod's log and no scaling event. The driver now
  re-runs a failed folder once: with checksum-only de-duplication the re-run uploads only what is missing, and its
  log names every source file, so verifying the re-run covers the whole folder.
- **Sidecars Immich writes itself.** 172 `.xmp` files appeared with no source. They hold a capture time immich-go
  took from the file name, for files without EXIF dates (`IMG_20200105_174314.jpg` →
  `<exif:DateTimeOriginal>2020-01-05T17:43:14.000+01:00`). The checker now lists them as notes.
- **Three `.AAE` files** (iOS edit instructions) were skipped as unknown; the photos they belong to are in.
- **Seven files are still in `upload/`**: two from before today, four from the race above, one more from step 1.
  Immich serves them from there; the Storage Template Migration job moves them at the end of the import.

### Same day — what the "bigger copies" in two large folders are, and a rule for the Google steps

The 10-11 dry run had two big camera folders down for 3,830 and 2,497 "upgrades". Before importing them, the
operator asked what the smaller copies actually are. Matching each bigger file to the smaller one with the
same name and a capture time within ±5 s, read with `sips -g pixelWidth -g pixelHeight -g model -g creation`,
on 150 random pairs per folder:

| | folder 1 (3,830) | folder 2 (2,497) |
|---|---|---|
| smaller copy comes from one of the two Google Photos folders | 150 / 150 | 150 / 150 |
| same pixel dimensions | 150 / 150 | 149 / 150 |
| smaller ÷ bigger file size, median | 0.60 | 0.57 |

Same camera, same timestamp, same resolution, about 60 % of the bytes: Google's re-encoded copies of the camera
originals, not separate edits. A local comparison page (thumbnails plus 1:1 crops from the centre) let the
operator look before deciding. Name-only matching had first produced pairs from different cameras, so the date
check matters.

Decision: for the two Google steps only, skip a local file when the server already holds a **bigger** asset
with the same name and capture time; never delete anything. The camera folders go first, so the originals are
in place when their Google copies arrive. The patched build gained a switch for it (`IMMICH_GO_SKIP_SMALLER=1`);
without it the build stays checksum-only.

The first test of the switch skipped nothing. `--log-level DEBUG` showed why:

```
Immich asset: FileName=IMG_1005.JPG Capture date=2014-01-13 15:54:41.433 +0100 CET FileSize=1593562
upload asset: file.OriginalFileName=IMG_1005.JPG file.FileSize=835942 file.CaptureDate=2014-01-13 14:54:41
```

An EXIF time has no zone. Immich takes it as UTC and immich-go as the Mac's local time, so the same photo reads
an hour apart and upstream's ±5 s comparison misses it (upstream has the same gap). The patched comparison
accepts a difference of a whole zone offset — any multiple of 15 minutes up to 14 h — within ±5 s. Retested on
three real pairs: the originals were uploaded for real (they belong to a later step anyway), then their Google
copies dry-run against the server — default mode uploads all three, the switch skips all three with "same
name … but with bigger size … exists on the server".

## 2026-10-15 — stage 2, step 2: the first large camera folder, and the 502s explained

The largest family folder so far: 5,957 photos and videos (29 GiB), including the converted home video, which
has no recording date and therefore sorts to its conversion date until the operator sets one in Immich.

```
12:47:04 upload: rc=1 in 1171s; uploaded successfully 5943, discarded local duplicate 13, server error 1
13:06:15 upload (retry): rc=0 in 533s; uploaded successfully 1, server has duplicate 5956
13:23:06 verify: 5957 source files sha1-checked; server has duplicate 5956, uploaded successfully 1; problems 0
```

About 25 MB/s for the upload itself, then 16 minutes to read every source file back over SMB for the sha1 check.

The one error was a third transient (`502 Bad Gateway` at 12:38:31), and this time the namespace events lined
up with it:

```
Readiness probe failed: Get "http://10.130.0.199:2283/api/server/ping": context deadline exceeded
Liveness probe failed:  Get "http://10.130.0.199:2283/api/server/ping": context deadline exceeded
```

The upstream chart (0.13.4, `templates/server.yaml`) gives `immich-server` liveness and readiness probes on
`/api/server/ping` with `timeoutSeconds: 1`, `periodSeconds: 10`, `failureThreshold: 3`. Each server pod also
runs Immich's background jobs, and during an import the thumbnail and face-detection work keeps it busy enough to
miss a one-second ping. Three misses take the pod out of the Service for about 30 s, and an upload routed to it
in that window gets a 502 from the router. There is no CPU limit on the container, so this is load, not
throttling. Fix, between steps: `timeoutSeconds: 5` on both probes in `components/apps/immich/values.yaml`
(the chart merges `server:` values over its defaults, so only the two fields change; rendered diff two lines,
`helm lint` and kubeconform clean). The import's single retry per folder had already covered all three errors.

## 2026-10-15 — stage 2, step 3: the second camera folder

4,154 photos and videos (29 GiB), the first step on the 5 s probes. The three originals uploaded early for the
skip-rule test were found as server duplicates.

```
13:54:01 upload: rc=1 in 1060s; uploaded successfully 4147, server has duplicate 3, discarded local duplicate 2, server error 2
14:11:45 upload (retry): rc=0 in 594s; uploaded successfully 2, server has duplicate 4152
14:23:02 verify: 4154 source files sha1-checked; server has duplicate 4152, uploaded successfully 2; problems 0
```

No readiness or liveness failure since the probe change, so the two errors (`502 Bad Gateway` at 13:38:49,
`EOF` mid-request at 13:46:07) are something else, with nothing in either server pod's log. Most likely the
usual race between a Node.js server closing an idle keep-alive connection after 5 s and the router reusing it
for a POST; about one upload in seven thousand, covered by the retry. The same server logs show a few
machine-learning calls failing with `write EPIPE` (face detection, CLIP) while the ML pod itself stayed up with no
errors: those photos miss faces or smart search until the "Missing" runs of both jobs at the end of the import.
The `family` library now holds 12,962 files on TrueNAS, counting Immich's own sidecars.

## 2026-10-15 — stage 2, step 4: the third large folder, and what the retry pass really does

4,172 photos and videos (73 GiB, 283 of them videos), plus 15 `.AAE` edit sidecars and 2 Finder `.DS_Store`
files that immich-go skips by design. The `.AAE` files are the Photos app's edit recipes; Immich cannot read
them, so the 15 photos they belong to arrive as their unedited originals and the sidecars stay on the share.

```
16:16:07 upload: rc=1 in 2584s; uploaded successfully 4154, metadata updated 354, server has duplicate 1, discarded local duplicate 11, server error 7
16:47:07 upload (retry): rc=0 in 1214s; uploaded successfully 6, metadata updated 4166, server has duplicate 4166
17:18:09 verify: 4172 source files sha1-checked; server has duplicate 4166, uploaded successfully 6; problems 0
```

Seven transient errors this time, six `EOF` and one `502 Bad Gateway`, in clusters (15:36 ×2, 16:09 ×2,
16:10 ×3, Warsaw time). Checked against each: both server pods Ready since they started (no Ready transition,
0 restarts), no probe or Unhealthy event in the namespace, nothing in either server log at those seconds, and
the last router reload at 13:33:55Z, when the HPA added a second server pod, 2.5 minutes before the first
cluster. So not this morning's probe problem; the same keep-alive races as step 3 (the router closing an idle
client connection as immich-go reuses it → `EOF`; Node.js closing an idle backend connection after 5 s as the
router reuses it → `502`). Neither Go nor HAProxy retries a POST or PUT on its own. About 0.4 % of uploads,
higher than step 3, probably because large videos leave some of the ten connections idle between requests.

One of the seven was a metadata update (`PUT /api/assets/<id>` after a successful upload). I first assumed
the retry pass would skip that file as a duplicate and never re-send the update, which would leave a wrong date
that the sha1 check cannot see. The retry log says otherwise:

```
16:28:44 INF server has duplicate file=…/2016/02.2016/IMG_1043.PNG
16:28:44 INF metadata updated file=…/2016/02.2016/IMG_1043.PNG
```

immich-go re-applies its metadata to every server duplicate (4,166 duplicates, 4,166 metadata updates), so the
retry pass covers both kinds of failure and a client-side retry patch would only save the ~20-minute second
pass. Not patched; to re-check before the Google steps what the skip-smaller path applies to the server's bigger
copy.

(Corrected 2026-10-16: wrong. "metadata updated" after "server has duplicate" is a bookkeeping label with no API
call behind it, and the retry did not re-send the PUT. See the 2026-10-16 code-check section below.)

Left over in `upload/` after the 5-minute settle: 3 JPGs the storage template had not moved (unique files, sha1
present nowhere else, so counted as present; the close-out Storage Template Migration job is the fix) and 26
`.xmp` sidecars. The server log has about 30 `Error reading exif data (/data/upload/…): File not found` warnings
for assets that had already moved to `library/`. The sidecar for one of them, `2c84….PNG.xmp`, is among the 26
left in `upload/`. It looks like the sidecar-write and metadata re-read that follow immich-go's metadata update
raced the move and used the old path. Not traced further. The `family` library now holds 17,464 files on
TrueNAS, counting sidecars.

## 2026-10-15 — stage 2, step 5: the fourth large folder

4,489 photos and videos (37 GiB). One of its subfolders is a byte-for-byte copy of a subfolder imported in
step 4, and those 792 files came back as server duplicates, as the checksum-only rule intends.

```
17:45:15 upload: rc=1 in 864s; uploaded successfully 3688, metadata updated 804, server has duplicate 793, discarded local duplicate 7, server error 1
18:03:03 upload (retry): rc=0 in 656s; uploaded successfully 1, metadata updated 4488, server has duplicate 4488
18:26:12 verify: 4489 source files sha1-checked; server has duplicate 4488, uploaded successfully 1; problems 0
```

The one error was a `502 Bad Gateway` at 15:35:31Z. The HPA had added a second server pod at 15:31:27Z
(Ready 15:31:57Z, router reload 15:31:58Z), and in step 4 the first errors also came about three minutes after a
scale-up, so I checked the pattern: step 4's later cluster (14:09–14:10Z) had no scale event or reload anywhere
near it. No correlation; same transient class as before.

A photographer's set in this folder was edited in ACDSee, which keeps each unedited original in an
`[Originals]` subfolder and writes a `NAME.JPG.xmp` next to it with its develop settings
(`acdsee:image_edited False`, no date, rating or GPS). immich-go logged all 20 as `discovered sidecar` and
attached them to the originals; Immich did not keep them as files (the only new `.xmp` files on TrueNAS are
four it wrote itself). Edited and original versions differ in bytes, so both went in as separate photos, in line
with the keep-every-distinct-file rule; the Duplicates review at the end is where they get culled. The other
skips: 10 `.THM` thumbnails next to camera `.MPG`/`.AVI` clips (immich-go: unknown file), 4 `.DS_Store`.

3 more files (two JPGs, one `.3gp`) stayed in `upload/` after the settle, for the close-out Storage Template
Migration job. The `family` library now holds 21,157 files on TrueNAS, counting sidecars; 21,196 source files
verified so far across steps 0–5.

## 2026-10-15 — stage 2, step 6: the last local folder, and a renamed copy inside it

2,797 files (68 GiB): 1,398 loose iPhone files (HEIC, MOV, JPG, PNG), a one-photo subfolder, and a subfolder
`test` with another 1,398 files named `YYYYMMDD_HHMMSS_NNNN.ext`. Its size multiset matched the loose files
exactly, so before uploading anything I hashed both sides in full:

```
test files 1398; identical to a top-level file 1398; not found 0
distinct top-level sha1 1394
```

`test` is a renamed copy. Uploaded together, each photo would still land once (checksum de-duplication), but the
name Immich keeps would depend on which of two parallel uploads finished first. That matters for the Google
steps: the skip-smaller rule matches by same name, so a photo stored as `20211130_104642_1092.mov` would not
match its Google copy `IMG_1092.MOV`, and the re-encode would come in as an extra asset. The operator chose to
skip the folder. `imp.py run` got a `--ban PATTERN` option that passes immich-go's `--ban-file`, and a dry run
confirmed the effect before the real one: immich-go logs `discovered banned file file=vadim_backup:test
reason=banned folder` once and never reads the folder, and the extra pattern is appended to the default ban list
(`.DS_Store`, `@eaDir/`, …) rather than replacing it.

```
19:43:08 upload: rc=1 in 1063s; uploaded successfully 1386, server has duplicate 8, discarded local duplicate 3, server error 2
20:01:48 upload (retry): rc=0 in 660s; uploaded successfully 2, metadata updated 1397, server has duplicate 1397
20:17:16 verify: 1399 source files sha1-checked; server has duplicate 1397, uploaded successfully 2; problems 0
```

One of the two errors was new: `400 Bad Request` with `io: read/write on closed pipe` on a 71 MB iPhone clip,
meaning the other end answered and closed while the body was still streaming. Nothing in either server pod's
log (Immich does not log 4xx), and `ffprobe` showed an ordinary 10.5 s HEVC clip with valid creation dates, the
same shape as its neighbours. The retry uploaded it, so it was transient, not the file. 191 of the MOVs are Live
Photo motion parts paired by name with a HEIC/JPG; 30 of them were still in `upload/` after the settle, along
with 2 HEICs, for the close-out Storage Template Migration job. The `family` library now holds 22,545 files on
TrueNAS; 22,595 source files verified across steps 0–6, all local folders done.

## 2026-10-16 — before the Takeout: the job-load alerts, and no CPU cap

Step 6 left Immich a backlog of thumbnail, metadata and video jobs for 312 videos. From 17:36Z on 2026-10-15 both
`immich-server` pods ran at about 7.1–7.3 cores each, node4 and node6 reached about 15.6 of their 16 threads, and
`ExtremelyHighIndividualControlPlaneCPU` (×2), `HighOverallControlPlaneCPU`, `NodeSystemSaturation` (×2) and
`PrometheusMissingRuleEvaluations` (×2) fired. All three nodes are control plane, so the job workers were competing
with etcd and the API server. The server container has a memory limit (8Gi) but no CPU limit.

By the next morning the queue had drained and every one of those alerts was gone from Alertmanager. Read through the
metrics API under the readonly SA:

```bash
oc get --raw /apis/metrics.k8s.io/v1beta1/namespaces/immich/pods   # immich-server 5m CPU, one replica
oc get --raw /apis/metrics.k8s.io/v1beta1/nodes                    # node4 5.1, node5 3.1, node6 7.3 cores
oc -n immich get hpa                                                # cpu: 1%/75%, replicas 1
```

No pod restarted and no upload failed because of it. The Takeout is the largest step left, so the question was whether
to limit Immich before it. Three options:

1. A CPU limit of 4 cores on the server container (at most 8 across the HPA's 2 replicas). The API and the job
   workers share that one container, so a throttled pod would also slow the uploads.
2. Lower job concurrency in the Immich admin settings. That alone does not bound video conversion: one ffmpeg job
   uses as many threads as Immich's ffmpeg `threads` setting allows, and its default lets ffmpeg take them all.
3. Leave it as is.

The operator chose 3. The alerts were warnings, they cleared on their own and nothing failed.

## 2026-10-16 — v3.3.3 before the Takeout, and a schema-drift warning that was a startup race

The operator merged Renovate's #200 (server and machine-learning `v3.3.1` → `v3.3.3`: a people-query speed-up and a
mobile fix) before the Takeout step, so that step runs on the version the import finishes on. ArgoCD rolled it at
10:29Z; both pods were ready on v3.3.3 within two minutes with no restarts.

The new server logged a schema-drift warning once at startup:

```
10:29:16 [Microservices:DatabaseService] No schema drift detected
10:29:19 [Api:DatabaseService] Detected schema drift ...
           - The index "geodata_places"."idx_geodata_places_name" is missing and needs to be created
           - ... idx_geodata_places_admin2_name, idx_geodata_places_admin1_name, idx_geodata_places_alternate_names
           - The constraint "geodata_places"."geodata_places_pkey" (primary-key) is missing and needs to be created
10:29:20 [Microservices:MapRepository] Starting geodata import
10:29:59 [Microservices:MapRepository] Geodata import completed
```

It was a race between the two workers in the pod, not drift. The image carries a newer geodata date file, so the
microservices worker re-imports the reverse-geocoding table. In v3.3.3's `server/src/repositories/map.repository.ts`
that import replaces `geodata_places` with a copy made `LIKE geodata_places INCLUDING ALL EXCLUDING INDEXES`
(lines 304–310), loads it, and only then adds back the primary key and the four name indexes (lines 419–437). The
API worker ran its drift check inside that window, and the five objects it named are exactly the five that step
recreates. The microservices worker had checked three seconds earlier, before the swap, and found nothing. The
import completed 40 s later. The operator confirmed it afterwards (an exec, so operator-run):

```
$ oc -n immich exec deploy/immich-server -- immich-admin schema-check
Migrations are up to date

No schema drift detected
```

## 2026-10-16 — the Takeout code check: what immich-go writes onto photos already on the server

Before the Takeout step I had immich-go v0.32.0's source read, with our patch applied (tag v0.32.0, commit
f7d19fc), for everything `upload from-google-photos` can do to an asset that is already on the server. Paths
below are in that tree.

**"metadata updated" on a duplicate is only a label.** The `SameOnServer` branch (`app/upload/run.go:387-393`)
records `DiscardedServerDuplicate` and `ProcessedMetadataUpdated` in the tracker and then calls
`manageAssetAlbums`, and that is all. The only `PUT /assets/{id}` is in `uploadAsset`, after a fresh upload, and
it is gated:

```go
if a.FromApplication != nil && ar.Status != immich.StatusDuplicate {
    a.UseMetadata(a.FromApplication)
    _, err := uc.client.Immich.UpdateAsset(ctx, a.ID, immich.UpdAssetField{
        Description: a.Description, Latitude: a.Latitude, Longitude: a.Longitude,
        Rating: a.Rating, DateTimeOriginal: a.CaptureDate,
    })
```

So the step 4 conclusion above was wrong. The one failed PUT in steps 0–6 (all 22 upload logs: 1 `updateAsset`
error, plus 4 `CopyAsset` errors from the stock-binary run on the first folder) was IMG_1043.PNG, and the retry
did not re-send it. In `from-folder`, `FromApplication` is only set from an immich-go JSON sidecar, iCloud
metadata, or, for a file with no EXIF date, the date `--date-from-name` (default true) parses from the name or
path (`adapters/folder/run.go:325-395`). That PNG has no date in its name, so `TakeTimeFromPath`
(`internal/filenames/namesdate.go:16`) fell back to the whole path, and its regex reads `2016/02.2016/IMG_1043.PNG`
as 2016-02-20 16:00 (checked with the same regex: groups `2016`, `02`, `20`, `16`). The lost PUT would have set
that artefact, not a real date. The same parse did go through for every other EXIF-less file in folders named
`YYYY/MM.YYYY`, which is something to look at in the close-out review.

For the Takeout the gate matters more: there, `FromApplication` is the Google JSON (date, GPS, description) for
every file. If that PUT fails on a transient error the upload has already happened, so the retry pass sees a
server duplicate and the JSON metadata never arrives. The sha1 verification cannot see it.

**What reaches an existing asset**, with or without `IMMICH_GO_SKIP_SMALLER=1`:

- Album membership, with `--sync-albums` (default true): `PUT /albums/{id}/assets` or `POST /albums`. It only
  adds, and it extends any existing Immich album with the same title.
- A stack. `series.Group` runs in every adapter (`cmdFromGooglePhotos.go:151`, and `app/upload/upload.go:171`
  for `from-folder`). It groups images with the same radical and capture time; a group that is not RAW+JPEG,
  HEIC+JPEG or a burst becomes `GroupByOther` (`internal/groups/series/series.go:66`), which no filter or flag
  un-groups, and `handleGroup` stacks it (`run.go:322-338`). An asset's ID is the existing server ID when it is a
  duplicate or skipped as smaller, so a Takeout original that is already on the server gets stacked with its new
  `-edited` copy. The cover is index 0 of an unstable sort over map-ordered input, so which photo shows on the
  timeline is effectively random. Steps 0–6 created no stacks: the only "stack" lines in the 22 logs are the three
  flag defaults, and the "stacked" event logs at the same level as "server has duplicate".
- Nothing else: delete, trash, replace, copy and visibility changes are unreachable in the patched build, and
  tags (`--takeout-tag`, `--people-tag`) go only on new uploads (`run.go:568-575`). `--overwrite` is a no-op
  with the patch.

Also from the read: `--include-archived=false` does nothing (the filter at `googlephotos.go:515` tests a field the
Google adapter never sets); trashed Takeout items are dropped by default; partner-shared items are imported by
default as the uploader's own; `--pause-immich-jobs` would pause five job queues even under `--dry-run`, but our
config sets it false (`--pause-immich-jobs=false origin=config file` in every log), so the only job call is the
harmless resume that answers 403.

## 2026-10-16 — step 7 dry run: the Google Takeout

Decisions for the Takeout, made by the operator after the code check: no stacking (patched out), no albums
(`--sync-albums=false`), `--takeout-tag=true` (it lands only on assets this run creates, so it marks exactly what
came from Google), `--people-tag=false`, and a retry on the metadata PUT. Partner sharing was moot: none of the
15,280 JSON files has a `fromPartnerSharing` key. The build is `0.32.0-homelab.4`: the homelab.3 patch plus two
`app/upload/run.go` changes, the stacking block replaced by an INFO line `group not stacked (homelab build)`
listing the files, and `UpdateAsset` retried up to three times (3 s, then 6 s) before the error is recorded. The
module cache was gone, so it was rebuilt from `proxy.golang.org`; inside the sandbox Go failed every download
with `x509: OSStatus -26276` (it uses the macOS trust store), outside it `go mod verify` reported all modules
verified. Upstream's tests for `internal/groups/...` and `adapters/googlePhotos` pass; `app/upload` has none.

```bash
IMMICH_GO_SKIP_SMALLER=1 immich-go-cs upload from-google-photos --config ./immich-go.toml --no-ui \
  --on-errors continue --sync-albums=false --takeout-tag=true --people-tag=false --dry-run \
  --log-file dry-takeout.log /Volumes/photo/photo/Takeout
```

55 minutes over SMB (13:10–14:05), exit 0. 14,115 media files, 45.9 GB (13,638 images, 477 videos), 14,112 of
them matched to a JSON. By each file's final event:

| outcome | files |
|---|---|
| would upload | 6,212 (12.1 GB, 123 videos) |
| skipped: a bigger same-name, same-moment copy is on the server | 7,626 |
| server has the same bytes | 245 |
| local duplicate (same bytes twice in the Takeout, e.g. `MOV00001(1).3gp`) | 28 |
| no matching JSON, not imported | 3 |
| trashed in Google, not imported (`--include-trashed=false`) | 1 |

The skip reason reads e.g. `An asset with the same name:"DSC00006.JPG" and date:"2007-04-10 15:23:55" but with
bigger size:59.7 KB exists on the server. No need to upload.` — it is logged as "metadata updated", so the run
summary's `metadata updated: 14097` mixes these skips with the PUT that follows every new upload. The only `ERR`
was the usual `403` on the `thumbnailGeneration` resume.

18 groups would have been stacked by upstream: `(1)` copies of the same photo, Google's `image(N).jpg` series
within one second, and one original + `(1)` + `-измененный` (Russian "edited") trio. With the patch they stay
separate assets and the log lists them for review.

The three files without a JSON are all `NAME(1).JPG` next to a `NAME.JPG` with one JSON between them, and `file`
says every one is `Apple QuickTime movie`: Live Photo motion clips Google exported under the still's name. Two
have the sha1 of a `.mov` already in the library from the local folders; the third (a 3 s clip from 2018-09-17)
is on the server only as its still. The trashed file is not on the server either.

`imp.py` gained `--google` (same flow, `from-google-photos` with the flags above) and, in `verify`, two accounted
outcomes instead of problems: "not imported: no matching JSON" and "not imported: filtered (trashed)", each listed
in the notes with whether its sha1 is on the server. Anything else without a final event still stops the run.

## 2026-10-16 — stage 2, step 7: the Takeout is in

The operator kept the one trashed item, so the run added `--include-trashed=true` (the dry run had shown it is the
only trashed entry; nothing marks it trashed on upload, so it lands on the timeline with its Google date and GPS).

```
14:40:23 index pre-20261016-144022: 22545 files (73 in upload/), 0 newly hashed
15:46:51 upload Takeout: rc=0 in 3987s; ... uploaded successfully 6215, metadata updated 14091, server has duplicate 245,
         discarded local duplicate 29, associated metadata 14112, missing metadata 3, tagged 6215
15:55:09 index after-Takeout: 34983 files (80 in upload/), 12440 newly hashed
16:45:20 verify Takeout: 14115 source files sha1-checked; uploaded successfully 6215, discarded local duplicate 29,
         bigger copy already on server 7623, server has duplicate 245, not imported: no matching JSON 3,
         server-written .xmp 5711; server +12438 -0 files; problems 2
```

No upload error at all, so no retry pass and no metadata-PUT retry fired (`grep -c 'retrying (homelab build)'` = 0).
Against the dry run: two more uploads, one more local duplicate and three fewer skips. The skip index also holds
assets uploaded earlier in the same run and the input order comes from map iteration, so a few same-name,
same-moment pairs resolve differently from run to run; every file still lands in one accounted outcome. The kept
photo is at `library/Family/2020/2020-01-29/`. Of the 12,440 new paths, 6,217 are media (5,841 `.jpg`, 251 `.png`,
86 `.mov`, 17 `.mp4`, 11 `.avi`, 10 `.3gp`, 1 `.gif`: the 6,215 uploads plus two older `upload/` leftovers the
template moved) and 6,221 are `.xmp` sidecars Immich wrote for the assets whose date or GPS the PUT set (5,712
distinct contents; photos sharing a date and place get byte-identical sidecars).

The two "problems" were `upload/…/<uuid>.jpg.xmp_exiftool_tmp` and `…JPG.xmp_exiftool_tmp`, written at 15:17 and
15:35 and still there an hour later, with no final `.xmp` beside them and their assets already moved to `library/`:
exiftool's sidecar write cut off by the storage-template move, the same race as step 4's orphaned sidecars. The
database holds the date and GPS either way. What the run left in `upload/` is 6 `.xmp` and these 2 temp files, no
media. Left for the close-out with the other `upload/` leftovers.

The Immich job load this time: the machine-learning pod at ~3.3 cores, the two server pods at 0.1–0.2 cores each
once the upload ended, nodes at 6.7 / 3.9 / 0.8 cores, against step 6's two and a half hours at ~99 % on node4 and
node6 under the powersave cap. Archive total: 36,710 source files sha1-verified across steps 0–7; TrueNAS holds
34,983 files for the `family` user, sidecars included. Left: the second Google folder (step 8) and the close-out.

## 2026-10-16 — stage 2, step 8: the second Google folder, and the import is finished

The last folder is a Google Photos web download, plain files with no JSON, so it went through `from-folder` with the
skip-smaller rule like the camera folders. The dry run (16:52–17:19) found 13,776 media files, 47.4 GB, and would
upload 1,592 (30.0 GB). The triage of 2026-10-12 had said this folder adds 998 files by content, so I matched each
would-be upload against `inventory/hashes.tsv` (a sha1 for every file on the share and every member of the `.tgz`):

| would upload | files | size |
|---|---|---|
| among the triage's "only in this folder" files | 615 | 2.7 GiB |
| same bytes as a Takeout file step 7 skipped as the smaller copy | 977 | 27.4 GiB |

The other 383 of the 998 were already in the library (381, from before the archive import) or duplicated inside the
folder (2). The 977 are 631 `.jpg`, 229 `.mov` and 117 `.mp4`. 631 carry a different name from their Takeout twin
(`IMG_0124 (1).JPG`), so the same-name rule cannot see them; the other 346 have the same name but `from-folder`
reads no capture date for them (the Takeout took its dates from the JSON), so `sameMoment` is false. I offered to
skip them with a sha1 list built from step 7's skipped files; the operator chose to upload all 1,592 and clean up
with Immich's Review duplicates, which compares by content and so will pair each re-encode with its original.

```
17:27:04 index pre-20261016-172702: 34983 files (80 in upload/), 0 newly hashed
17:58:48 upload dwn: rc=0 in 1903s; ... uploaded successfully 1592, metadata updated 12184, server has duplicate 5906,
         discarded local duplicate 2
18:01:47 index after-dwn: 36575 files (28 in upload/), 1708 newly hashed
18:47:39 verify dwn: 13776 source files sha1-checked; uploaded successfully 1592, server has duplicate 5906,
         bigger copy already on server 6276, discarded local duplicate 2; server +1592 -0 files; problems 0
18:47:39 ALL DONE: dwn
```

Exactly the dry run's numbers, no upload error, no PUT retry. No sidecars this time: `from-folder` sends no
application metadata for files that have EXIF dates, so Immich has nothing to export, and the server grew by exactly
1,592 files. The storage template also cleared 52 of the earlier `upload/` leftovers (80 → 28).

A side question from the Synology copy: `library/` holds `Family/`, `Vadzim/` and `5693963b-6338-…/`. Immich names a
user's folder after their storage label and falls back to the user ID; the third folder is the second personal
account, which never got a label (2 files). Fix in the admin UI (Users → edit → storage label), then the Storage
Template Migration job; the Synology copy is COPY-mode, so the old ID folder stays there.

The import is complete: 50,486 source files sha1-verified across steps 0–8, 36,575 files on TrueNAS for `family`.
What remains is the close-out list in the README TODO.

## 2026-10-19 — close-out, part 1: the totals

A fresh index of the `family` files on TrueNAS, then every per-folder source report (`verify/src-*.tsv`, 17 of them,
re-runs included) checked against it. Step 0's 67 files predate the reports, so they were re-hashed from the share.

```
imp.py index final-20261019
15:43:42 index final-20261019: 36575 files (8 in upload/), 20 newly hashed
```

On TrueNAS for `family`: 36,575 files = 29,683 media files (230.8 GiB, every one a distinct sha1), 6,890 `.xmp`
sidecars and the 2 `*.xmp_exiftool_tmp` orphans from step 7. The 20 newly hashed files are moves, not new content:
20 media files that step 8 left in `upload/` have since been filed into their date folders by the storage template,
with the same sha1s. `upload/` now holds only six `.xmp` sidecars and the two `_tmp` files.

Source side, by distinct path (a later run of a folder overrides an earlier one):

| outcome | source files |
|---|---|
| already on the server byte for byte | 27,114 |
| uploaded (steps 1–8) | 9,354 |
| uploaded (step 0) | 65 |
| skipped, a bigger same-name copy is on the server | 12,922 |
| skipped as smaller by step 7, the same bytes uploaded by step 8 | 977 |
| duplicated inside a folder | 37 |
| Live Photo clip with no JSON (2 already on the server as `.mov`, 1 not) | 3 |
| deleted on purpose in the 2026-10-12 delete test (`IMG_8183.JPG`, `IMG_8204.JPG`) | 2 |
| **total** | **50,474** |

Every source file that was on the server when its folder was checked is still there: 0 went missing between
2026-10-15 and today. The two delete-test photos are still absent, as intended.

Correction: the running total I kept from 2026-10-15 to 2026-10-16 said 50,486. It was a sum of per-step figures and
was 12 too high; the "steps 1–6, 22,595" figure was really steps 0–6 and is 22,583. The recount by distinct path
above is the number of record. I did not find which re-run the 12 came from.

The server also holds 143 media files with no source in the archive (0.63 GiB of `.jpg`, 139 under
`2024/2024-01-01` and 4 under `2000/2000-01-01`). All 143 are in `index-baseline`, taken before step 1: they are the
photos the `family` account already had (141 in `library/Family` before step 0 on 2026-10-12, plus 2 that arrived in
`upload/` before 2026-10-15). 63 share a name with an archive file but not its bytes, so the Duplicates review is
where they meet their twins, if they are re-encodes.

Source sha1s on the server (29,540) plus those 143 equal the server's 29,683 media files exactly.

## 2026-10-20 — close-out, part 2: storage labels, the migration, and the eight files in `upload/`

The operator set the second personal account's storage label and ran Administration → Jobs → Storage Template
Migration. Its two files moved from `library/5693963b-…/` to the label's folder; the ID-named folder is gone. A fresh
`family` index afterwards (`index after-migration-20261020`) read 36,575 files with 0 re-hashed, so the job moved
nothing for `family`, and the eight files in `upload/` (six `.xmp`, two `*.xmp_exiftool_tmp`, all written 15:17–15:38
on 2026-10-16 during step 7) stayed where they were.

Whether those six `.xmp` are live sidecars in the wrong place or orphans is a database question. Reads, run by the
operator (pods/exec is not open to the readonly SA). Two traps on the way, both mine:

- `psql -d immich` alone fails `Peer authentication failed for user "1000980000"`: the pod runs under OpenShift's
  random UID and CNPG maps that UID to `postgres`, so it needs `-U postgres`. Already written down in
  `blog/blog-cnpg-draft.md`; I had not read it first.
- The UUID in an upload filename is NOT the asset ID. Immich names the uploaded file with a fresh random UUID; a
  query by those UUIDs as `asset.id` returned nothing because no such assets exist, not because the sidecars are
  orphans.

The query that answers it, plus a control to show the pattern can match:

```
oc -n immich exec immich-postgres-1 -c postgres -- psql -U postgres -d immich -At -F ' | ' -c \
  "select a.id, a.\"originalPath\", f.path from asset a left join asset_file f on f.\"assetId\" = a.id
   and f.type = 'sidecar' where a.\"originalPath\" ~ '/upload/' or f.path ~ '/upload/'"
(no rows)

... -c "select (select count(*) from asset), (select min(\"originalPath\") from asset),
        (select count(*) from asset_file where type = 'sidecar'), (select min(path) from asset_file where type = 'sidecar')"
29688 | /data/library/<label>/… | 6884 | /data/library/Family/…​.jpg.xmp
```

Paths are stored as `/data/library/…`, so anything left in `upload/` would read `/data/upload/…` and match. Nothing
does. The counts close against TrueNAS exactly:

| | database | TrueNAS |
|---|---|---|
| assets | 29,688 | 29,683 `family` media + 3 + 2 in the two personal accounts |
| sidecars | 6,884 | 6,884 `.xmp` in `library/Family` (+ 6 in `upload/`) |

So the six `.xmp` in `upload/` are orphans: Immich wrote them to the upload path while the storage template was
moving the asset, then recorded the sidecar at the asset's new path. The two `_tmp` files are exiftool's temporary
files from the same race and were never recorded at all. None of the eight is referenced.

The operator chose to delete them. `truenas_admin` cannot: the files belong to UID 1000980000 (the pod's UID, mode
644 in 755 directories) and `sudo` on the box wants a password. So the delete ran inside the pod, as the files' owner
(`oc -n immich exec deploy/immich-server -- sh -c 'cd /data/upload/<family-uid> && rm -v …'`, eight `removed` lines).
Afterwards `upload/` holds 0 files and `index after-orphans-20261020` reads 36,567: exactly those eight gone,
nothing new, nothing changed.
