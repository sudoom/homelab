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
