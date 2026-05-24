# synology-cert-sync

Daily CronJob that pushes the LE-issued `*.homelab.sudops.pl` wildcard
cert from cert-manager into the Synology DSM certificate store.

Phase 3 of the `homelab.sudops.pl` rollout — see
`blog/blog-homelab-sudops-zone-draft.md`.

## How it works

1. Init container `mirror-tls` runs `oc extract` to pull the
   `homelab-wildcard-tls` Secret from the `cert-manager` namespace into
   an emptyDir. Cross-ns access is gated by a `Role` +
   `RoleBinding` in `cert-manager` ns (see `templates/rbac.yaml`).
2. Main container `sync` runs `sync.sh` from a ConfigMap:
   - openssl-fingerprints the in-cluster cert vs the cert DSM is currently
     serving on `https://<DSM_HOST>:5001`.
   - If equal → no-op, exits 0.
   - If different → logs into DSM via the `SYNO.API.Auth` endpoint,
     multipart-POSTs cert + key + chain to `SYNO.Core.Certificate.import`
     with `as_default=true`, logs out.
3. DSM applies the new cert; affected services (Web Station, File Station
   over HTTPS, etc.) pick it up automatically.

The cert-manager `Certificate` for `*.homelab.sudops.pl` lives in the
`cert-manager-config` chart (shipped in commit `a49a8d2`, valid until
`2026-08-22`). LE renews 30d before expiry; this CronJob runs daily
so it catches the renewal within 24h.

## First-time setup

The DSM credentials are not in the repo. After deploying the chart, seal
them once on the operator workstation:

```bash
oc -n synology-cert-sync create secret generic dsm-credentials \
  --from-literal=username='<dsm-user>' \
  --from-literal=password='<dsm-password>' \
  --dry-run=client -o yaml | \
kubeseal --controller-namespace sealed-secrets --format yaml \
  > components/cluster-config/synology-cert-sync/templates/sealed-dsm-credentials.yaml
```

Commit the sealed blob. The sealed-secrets controller in the cluster
decrypts to a regular Secret named `dsm-credentials`; the CronJob
references its `username` + `password` keys via `secretKeyRef`.

## DSM user setup (pre-seal)

DSM 7.x doesn't have per-section admin delegation for Certificate
management — the API endpoint requires admin scope. The pattern used
here: a dedicated DSM user in the `administrators` group.

1. Synology DSM → **Control Panel** → **User & Group** → **Create**
2. Fill in name/password
3. **Join Groups** step → check `administrators`
4. Disable 2FA on this account (the CronJob can't do interactive 2FA)
5. Optional: limit login to specific IPs via Control Panel → Security →
   Account → Allow / Block List

## Rotation

- **Cert rotation**: fully automatic. cert-manager renews via DNS-01;
  the next CronJob run picks up the new cert and pushes to DSM.
- **DSM credential rotation**: re-run the `kubeseal` command in
  "First-time setup" with the new password, commit, push. The
  sealed-secrets controller rolls the underlying Secret in place; the
  next CronJob run uses the new creds.

## Files

| File | Purpose |
|---|---|
| `templates/namespace.yaml` | `synology-cert-sync` namespace |
| `templates/rbac.yaml` | SA + cross-ns Role/RoleBinding for the cert Secret |
| `templates/sealed-dsm-credentials.yaml` | DSM creds — replace placeholder with `kubeseal` output |
| `templates/configmap-script.yaml` | the `sync.sh` script (mounted into the main container) |
| `templates/cronjob.yaml` | the schedule + init-container + main-container spec |

## Manual run

To trigger a sync immediately (e.g., after rotating creds):

```bash
oc -n synology-cert-sync create job --from=cronjob/synology-cert-sync \
  cert-sync-manual-$(date +%s)
oc -n synology-cert-sync logs job/cert-sync-manual-<timestamp> -c sync -f
```

## Validation

```bash
helm lint components/cluster-config/synology-cert-sync/
helm template synology-cert-sync components/cluster-config/synology-cert-sync/ \
  -n synology-cert-sync \
  -f components/cluster-config/synology-cert-sync/values.yaml
```
