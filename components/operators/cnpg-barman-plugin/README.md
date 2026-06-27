# cnpg-barman-plugin

CloudNativePG **Barman Cloud Plugin** (CNPG-I sidecar) — the forward path for
object-store backups now that in-tree `spec.backup.barmanObjectStore` is
deprecated (CNPG 1.26) and **removed in CNPG 1.30**.

- **Sync wave:** `3` (root-app) — after cert-manager + CNPG operator (wave 1),
  before the consumer clusters that declare `ObjectStore` CRs (cnpg-clusters at
  wave 5, immich at wave 7).
- **Namespace:** `cnpg-system` (the existing OLM-managed CNPG namespace; the
  manifest does not create it).
- **Requires cert-manager** — the manifest ships a self-signed `Issuer` +
  `Certificate`s for the plugin's gRPC mTLS to the CNPG operator.
- **Installs:** the `objectstores.barmancloud.cnpg.io` CRD + the plugin
  controller `Deployment` + RBAC.

## What it enables

A cluster opts in by adding a `plugins:` entry referencing an `ObjectStore` CR:

```yaml
spec:
  plugins:
    - name: barman-cloud.cloudnative-pg.io
      isWALArchiver: true
      parameters:
        barmanObjectName: <objectstore-name>
```

In this repo the consumers are `media-postgres` (components/apps/cnpg-clusters)
and `immich-postgres` (components/apps/immich), both backing up to **Cloudflare
R2** (see those charts' `values.yaml` `backup.objectStore` blocks). The R2
specifics (endpoint, the boto3≥1.36 checksum env fix, at-rest-only encryption)
live in each `ObjectStore` CR.

## Files

| File | Purpose |
|---|---|
| `templates/plugin.yaml` | Upstream install manifest, vendored verbatim @ v0.13.0 |
| `Chart.yaml` | `appVersion` pins the vendored version |
| `values.yaml` | none (static manifest); bump instructions only |

## Bumping (supervised)

Renovate is disabled for `ghcr.io/cloudnative-pg/plugin-barman-cloud` — bumping
re-vendors the whole manifest and must be checked against the running CNPG
minor. Re-download the release `manifest.yaml` into `templates/`, bump
`Chart.yaml` `appVersion`, **re-apply the OpenShift securityContext patch**
(delete the controller container's `runAsUser: 10001` + `runAsGroup: 10001` —
they're outside cnpg-system's restricted-v2 UID range and forbid the pod; see
the marked comment in `plugin.yaml`), `helm template … | oc diff`, then sync the
operator app before touching the clusters.
