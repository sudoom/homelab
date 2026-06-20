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
