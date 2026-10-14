# Storage Box usage and access settings in Prometheus

Status: draft 2026-10-14, **not approved**. Follow-up to
`docs/superpowers/specs/2026-10-13-offsite-backup-storage-box-design.md` (Monitoring).

## Why

The box holds the only offsite copy of `tank/immich`, and nothing watches it. Its snapshots keep deleted photos for up
to ten weeks, and they count against the 1 TB. Its access settings can change in the console unseen.

## Decisions

| Decision | Choice | Note |
|---|---|---|
| Chart | `components/cluster-config/hcloud-exporter`, namespace `hcloud-exporter`, sync wave 5 | Agreed. The same wave as the other exporters. |
| Image | `ghcr.io/promhippie/hcloud-exporter`, `tag: "3.30.0@sha256:f1dba83dfd23dc553f05c8693b6a9648d3602ab267b0d81270bbaf07b4ddd3de"` | The digest comes from the research and is re-resolved at build. Renovate's `helm-values` manager replaces version and digest together. Reviewed PR. |
| Collectors | Storage Box only | Every other collector is set `false` explicitly. Agreed. |
| Labels | `id`, `name`, `location` | Never `server` or `username`. Agreed. |
| Token | Read-only. SealedSecret `hcloud-exporter`, key `token`, read through `file://` | Agreed. |
| Email | The critical route, plus one allowlist route | See Email. |

## Design

### Chart

The layout follows `truenas-exporter`, and the SealedSecret follows `mikrotik-exporter`.
- Deployment:
  - 1 replica, `maxSurge: 0`, `automountServiceAccountToken: false`;
  - `runAsNonRoot`, seccomp `RuntimeDefault`, and no `runAsUser`. restricted-v2 assigns the UID, which `runAsNonRoot` needs, because the image's `USER` is a name;
  - `readOnlyRootFilesystem`, `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`;
  - probes on `/healthz` and `/readyz`, port 9501. Both always return 200;
  - requests 10m / 32Mi, limits 100m / 64Mi.
- Environment:
  - `HCLOUD_EXPORTER_TOKEN=file:///etc/hcloud-exporter/token`, the Secret's mount;
  - `HCLOUD_EXPORTER_REQUEST_TIMEOUT=5s`, under the 10 s scrape timeout;
  - `HCLOUD_EXPORTER_COLLECTOR_STORAGEBOXES=true`;
  - `HCLOUD_EXPORTER_STORAGEBOXES_LABELS=id,name,location`;
  - `HCLOUD_EXPORTER_COLLECTOR_{FLOATING_IPS,IMAGES,PRICING,SERVERS,LOAD_BALANCERS,SSH_KEYS,SERVER_METRICS,VOLUMES}=false`.
- Service: ClusterIP, not headless, so the API server's service proxy can read `/metrics`.
- ServiceMonitor: every 60 s, `instance: hcloud-exporter` (with `action: replace` spelled out), and `labeldrop pod|container`. Two Prometheus replicas
  scrape it, about 120 API calls an hour.

### Alerts

PrometheusRule group `hetzner-storagebox`. The placeholders are escaped as in `truenas-exporter`.

| Alert | Expression | for | Severity | Summary |
|---|---|---|---|---|
| `HetznerStorageBoxFilling` | `hcloud_storagebox_general_size / hcloud_storagebox_quota > 0.80` | 1h | warning | `Storage Box {{ $labels.name }} is {{ $value \| humanizePercentage }} full, snapshots included` |
| `HetznerStorageBoxFilling` | same, `> 0.90` | 15m | critical | same |
| `HetznerStorageBoxExposed` | `hcloud_storagebox_samba == 1` (label `setting: samba`), and the same for `webdav` | 15m | critical | `Storage Box {{ $labels.name }}: {{ $labels.setting }} is on` |
| `HetznerStorageBoxAccessClosed` | `hcloud_storagebox_ssh == 0` (label `setting: ssh`), and the same for `external` | 15m | warning | `Storage Box {{ $labels.name }}: {{ $labels.setting }} is off for the main account` |
| `HetznerStorageBoxSnapshotDirHidden` | `hcloud_storagebox_zfs == 0` | 15m | warning | `Storage Box {{ $labels.name }}: snapshot directory hidden` |
| `HetznerStorageBoxExporterDown` | `up{job="hcloud-exporter"} == 0` | 10m | warning | `hcloud-exporter unreachable for 10m` |
| `HetznerStorageBoxApiFailing` | `increase(hcloud_request_failures_total{collector="storagebox"}[30m]) / increase(hcloud_request_duration_seconds_count{collector="storagebox"}[30m]) > 0.1` | 15m | warning | `{{ $value \| humanizePercentage }} of Storage Box API calls failed in 30m` |
| `HetznerStorageBoxUnmonitored` | `absent(hcloud_storagebox_general_size)` | 30m | warning | `No Storage Box reported for 30m` |

- **Fill.** `general_size` is the API's usage with snapshots, and `quota` is the plan size; both HELP strings mislead.
  The two levels share one name, so the inhibit rule mutes 80 % once 90 % fires.
- **Drift.** The expected state is SSH on, external on, Samba off, WebDAV off, snapshot directory on. These are the
  **main account's** settings (Limits). `AccessClosed` therefore means the single-file restore path is shut. A change
  the operator did not make means someone else is in the account.
- **Failures.** On an API error the exporter emits no box series, and `up` stays 1. The ratio ignores one failed call
  in about 60. `absent()` also catches a box that is missing from the list.
- Fill and drift rules carry `keep_firing_for: 30m`, so a short API outage does not resolve them.

### Email and egress

- The critical route emails `Filling` at 90 % and `Exposed`.
- A new allowlist route in `monitoring-config`, `alertname =~ "HetznerStorageBox(Filling|AccessClosed|SnapshotDirHidden)"`,
  emails the warnings. They are actionable when they arrive, and none is standing.
- **Console-only:** `ExporterDown`, `ApiFailing`, `Unmonitored`. The session-start triage sees them. The backstop is
  the upload failing on a full box, which `TrueNASCloudSyncStale` emails. `TrueNASOffsiteReviewDue` is console-only
  as well.
- Egress to `api.hetzner.com:443` is open. The repo has no NetworkPolicy. The cluster has no EgressFirewall or
  AdminNetworkPolicy, and its 68 NetworkPolicies sit in platform namespaces.

## Rollout

1. **Operator**, from the repo root. Prove the token reads the box (safe fields only), then seal it:

   ```bash
   mkdir -p components/cluster-config/hcloud-exporter/templates
   read -rs HCLOUD_TOKEN   # paste the read-only token; nothing is echoed
   printf 'header = "Authorization: Bearer %s"\n' "$HCLOUD_TOKEN" \
     | curl -fsS -K - https://api.hetzner.com/v1/storage_boxes \
     | jq -c '.storage_boxes[] | {id, name, location: .location.name, stats, quota: .storage_box_type.size, access_settings}'
   oc create secret generic hcloud-exporter -n hcloud-exporter \
     --from-literal=token="$HCLOUD_TOKEN" --dry-run=client -o yaml \
     | kubeseal --cert components/operators/sealed-secrets/sealed-secrets-pub.pem -o yaml \
     > components/cluster-config/hcloud-exporter/templates/sealed-hcloud-token.yaml
   unset HCLOUD_TOKEN
   ```

   Check that `id` and `name` hold no account number, and that `access_settings` match the expected state.
2. **Me, in git**, with docs in the same commits:
   - the chart, the rules and the root-app entry;
   - the allowlist route;
   - `TrueNASOffsiteReviewDue`, per Open 1.
3. **ArgoCD** syncs. No step needs a mutating cluster command.

## Verification

- The validation workflow passes, and the sealed file holds `encryptedData.token` only.
- Read-only:

  ```bash
  export KUBECONFIG=~/.kube/config-readonly
  oc -n openshift-gitops get application hcloud-exporter -o jsonpath='{.status.sync.status} {.status.health.status}{"\n"}'
  oc -n hcloud-exporter get pod -o jsonpath='{range .items[*]}{.metadata.annotations.openshift\.io/scc} {.status.phase}{"\n"}{end}'
  oc get --raw /api/v1/namespaces/hcloud-exporter/services/http:hcloud-exporter:9501/proxy/metrics \
    | grep -E '^hcloud_(storagebox_|request_failures_total)'
  ```

  Expected:
  - `Synced Healthy` and `restricted-v2 Running`;
  - 13 box series with labels `id`, `name` and `location` only;
  - the failure counter at 0;
  - `general_size / quota` matching the console's figure.
- **Thanos Ruler evaluates these rules**, not Prometheus. Rule health is read there; `ALERTS` on Prometheus returns
  `[]`. The readonly SA cannot reach the ruler. As in the parent rollout, this needs the break-glass kubeconfig and
  the operator's go-ahead:

  ```bash
  KUBECONFIG=~/.kube/config-breakglass oc -n openshift-user-workload-monitoring exec thanos-ruler-user-workload-0 -c thanos-ruler -- \
    wget -qO- 'http://localhost:10902/api/v1/rules?type=alert' | jq -c '.data.groups[] | select(.name=="hetzner-storagebox") | .rules[] | {name, health, state}'
  ```

  Expected: ten rules, all `ok` and `inactive`.

## Docs

- A new chart README.
- `truenas-exporter`'s "not yet monitored" lines.
- The parent spec's Monitoring bullet.
- The blog draft.
- `README.md`'s wave-5 diagram and layout list. `truenas-exporter` is missing there too; that fix is a separate commit.

## Limits

- **Sub-account settings are invisible.** The exporter calls `StorageBox.All` only, so it reads the box's access
  settings, not the upload sub-account's own. `TrueNASCloudSyncStale` still catches a broken upload.
- **No snapshot plan and no snapshot count**, only `snapshot_size` in bytes.
- **No success metric.** A failure looks like missing data.

## Open

1. **`TrueNASOffsiteReviewDue`, the owner's choice.**
   - (a) Replace it with the 80 % rule. That rule reads the box itself, snapshots included. It follows a rescale, and it is emailed.
   - (b) Keep both, with the dataset rule as an API-independent planning trigger.

   **Recommended: (a).** The dataset rule counts data that is never uploaded.
2. **Whether the main account's SSH and external settings gate sub-accounts.** Hetzner's docs do not say, so the
   premise that turning them off breaks the upload is unconfirmed.
3. **Whether `stats.size` equals data plus snapshots.** Checked on the first scrape.

## Out of scope

- Sub-account and snapshot-plan monitoring.
- `locked`, `active` and `protection` alerts.
- A dashboard.
