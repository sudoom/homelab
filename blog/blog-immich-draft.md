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
