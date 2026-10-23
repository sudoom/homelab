# Homebox: a home inventory on OKD with its own CNPG Postgres

The hardware facts for this homelab (purchases, invoices, drive history, what sits on the shelf) live as prose in
vault notes. These notes cover picking an inventory tool, deciding where it runs, and deploying it: Homebox on the
cluster, backed by its own CloudNativePG cluster so its records get the backup path the cluster has already proven.

## 2026-10-23 — Snipe-IT or Homebox, cluster or TrueNAS

Snipe-IT was the first idea. Against this cluster it costs more than the problem is worth:

- Database: the official requirements page lists "MySQL 5.7+ or MariaDB"; PostgreSQL is not mentioned. Everything
  here runs on CNPG Postgres with a tested restore path, so Snipe-IT would bring a second engine with its own backup
  job and restore drill.
- Images: the common images serve Apache on port 80, which likely needs `anyuid` or a rebuilt image under
  `restricted-v2` (not tested).
- Its strength is IT-department workflow (check-out to people, licences, depreciation, audits), which a one-person
  homelab does not need.

Homebox (`sysadminsmedia/homebox`, the maintained fork; `hay-kot/homebox` is archived) covers items, serials,
warranties, receipts and locations. The TrueNAS community catalog ships it (`ix-dev/community/homebox`,
app_version `0.27.0-rootless`, uid 568); it has no Snipe-IT.

Cluster or TrueNAS: the first argument for TrueNAS — "an inventory of the cluster's hardware is unreadable when the
cluster is down" — cuts both ways, because TrueNAS is a single box whose drives would be in the inventory too, and a
degraded cluster still serves the app. What actually differed was backup and who applies changes:

| | OKD | TrueNAS |
|---|---|---|
| Backup of app state today | none: the OADP Schedule is paused (README TODO "Scope OADP backups before un-pausing"), only the CNPG clusters are backed up | none: snapshot tasks cover `media`, `immich`, `backup`, `sync`, not `apps/` |
| Applying changes | git push, ArgoCD | `ansible/truenas/playbook.yml`, which needs the vault password interactively |

Decision: OKD. Then the database: Homebox supports PostgreSQL officially (`HBOX_DATABASE_DRIVER=postgres`; its docs
recommend it for larger installs), so the records go to a CNPG cluster and inherit the WAL + base backups to R2,
the daily volume snapshot and the sweep's `ContinuousArchiving` check. Attachments are files, not rows
(`HBOX_STORAGE_CONN_STRING`, local or S3). garage on TrueNAS is S3-compatible, but its `tank/s3` dataset has no
snapshot task and `replication_factor: 1`, so it is not a backup either. Use is "mostly records", so attachments get
a small PVC that is not backed up, accepted knowingly.

## 2026-10-24 — the chart

`components/apps/homebox/`, root-app entry `homebox`, wave 7, namespace `homebox`. Shaped after
`components/apps/immich/` (its own CNPG cluster, not the shared `media-postgres`: a database there would either put
Homebox in the `media` namespace or copy its credentials across, and a media restore would carry Homebox along).

- **App:** `ghcr.io/sysadminsmedia/homebox:0.27.0-rootless@sha256:11ee1008150a7d51a7da6b05f5b3d0e5d4a22eacc39dfef2b9894873c46b4c86`
  (the digest the TrueNAS catalog pins). From `Dockerfile.rootless` at v0.27.0: port 7745, `USER nonroot`,
  `ENTRYPOINT /app/api`, `HBOX_MODE=production`, storage defaults that land files in `/data`, `HEALTHCHECK` on
  `/api/v1/status`. One replica, `Recreate`, PVC `homebox-data` 1Gi `ceph-nvme-block` at `/data`, no pinned UID
  (restricted-v2 injects one). Route `homebox.apps.okd.sudops.pl`, edge TLS on the wildcard cert.
- **Database:** CNPG `homebox-postgres`, 2 instances (a 1-instance cluster blocks every node drain), 2Gi
  `ceph-nvme-block`, `ghcr.io/cloudnative-pg/postgresql:18.6` (the stock image `media-postgres` uses; immich's is
  VectorChord, which Homebox does not need), initdb database and owner `homebox`. The app reads
  `username`/`password`/`dbname` from CNPG's `homebox-postgres-app` Secret; `HBOX_DATABASE_SSL_MODE=require`.
- **Backups:** volumeSnapshot ScheduledBackup 05:00 UTC, 7 days; barman-cloud plugin ObjectStore
  `homebox-postgres-r2` → `s3://psql-backup/` (serverName `homebox-postgres`, so its own path next to immich's),
  base backup 03:30 UTC, 30 days; a WAL-archive PrometheusRule mirrored from immich's.
- **R2 credential:** sealed by the operator from immich's (same bucket), values never printed:

  ```bash
  oc -n immich get secret immich-postgres-r2-creds -o json \
    | jq '{apiVersion:"v1",kind:"Secret",type:.type,data:.data,metadata:{name:"homebox-postgres-r2-creds",namespace:"homebox"}}' \
    | kubeseal --cert components/operators/sealed-secrets/sealed-secrets-pub.pem --format yaml \
    > components/apps/homebox/templates/sealed-homebox-postgres-r2-creds.yaml
  ```

  Checked by metadata only: name/namespace right, keys `ACCESS_KEY_ID,ACCESS_SECRET_KEY`, encrypted lengths 752/792.
  The SealedSecret got `argocd.argoproj.io/sync-wave: "-2"`: immich's sits at the default wave 0, after its Cluster
  (-1), which on a fresh cluster would start WAL archiving before the credential exists.
- **Registration:** `HBOX_OPTIONS_ALLOW_REGISTRATION=true` until the first account exists, then `false`.

Validation:

```bash
C=components/apps/homebox
helm lint $C                                    # 1 chart(s) linted, 0 chart(s) failed
helm template homebox $C -n homebox -f $C/values.yaml > homebox-render.yaml
kubeconform -strict -ignore-missing-schemas -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  homebox-render.yaml
# Summary: 11 resources found in 1 file - Valid: 10, Invalid: 0, Errors: 0, Skipped: 1   (the Route: no schema)
```

The health sweep's CNPG archiving loop (cluster-health skill) needs `homebox:homebox-postgres` added; the skill
file is operator-applied.

## 2026-10-24 — first start: CrashLoopBackOff on a missing API-key pepper

The database came up clean (`homebox-postgres` 2/2, primary `-1`, `ContinuousArchiving=True/ContinuousArchivingSuccess`,
R2 credential unsealed), but the app pod went `CrashLoopBackOff` (exit 2, SCC `restricted-v2`, injected UID
1001040000 — so the rootless image itself was fine):

```
oc -n homebox logs homebox-6b54cf4bb4-wbpst
panic: auth.api_key_pepper must be set to at least 32 bytes; generate with `openssl rand -base64 48` and provide via HBOX_AUTH_API_KEY_PEPPER. Rotating it invalidates all issued API keys
```

v0.27.0 fails fast without it (`backend/app/api/main.go`, `run()`: "Without it, the HMAC keying for stored API key
hashes would degrade to a constant key"). The configuration docs page I had read does not list it; the TrueNAS
catalog app asks the user for it (`HBOX_AUTH_API_KEY_PEPPER` from `values.homebox.api_key_pepper`). It must stay
constant, so it lives in git as a SealedSecret, generated on the operator's side so the value is never printed:

```bash
oc create secret generic homebox-auth -n homebox \
  --from-literal=HBOX_AUTH_API_KEY_PEPPER="$(openssl rand -base64 48)" --dry-run=client -o json \
  | kubeseal --cert components/operators/sealed-secrets/sealed-secrets-pub.pem --format yaml \
  > components/apps/homebox/templates/sealed-homebox-auth.yaml
```

Checked by metadata only (one key, encrypted length 792), given sync wave -2 like the R2 credential, and wired into
the Deployment as `HBOX_AUTH_API_KEY_PEPPER` from `secretKeyRef homebox-auth`.

## 2026-10-24 — running; registration closed

After the pepper commit the first sync operation (pinned to its original revision `593864f`) had to exhaust its five
retries before automated sync started a fresh one at the new revision: `op=Succeeded oprev=5060e22
sync=Synced/Healthy` at 22:40:32Z. The pod ran its goose migrations against `homebox-postgres`
(`successfully migrated database to version: 20260821000000`) and logged `Server is running on :7745`; the Route
`homebox.apps.okd.sudops.pl` is admitted and both ScheduledBackups exist. The operator created the first account,
then `allowRegistration: false` (`HBOX_OPTIONS_ALLOW_REGISTRATION=false`).

Note for the next new app: a first sync whose wave-0 Deployment crashloops pins ArgoCD to that revision through all
its retries (~17 min here), so a fix pushed in the meantime waits for the retries to run out.
