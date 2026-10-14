# hcloud-exporter

[promhippie/hcloud_exporter](https://github.com/promhippie/hcloud_exporter) **3.30.0**, with the **Storage Box
collector only**, for the Hetzner Storage Box that holds the only offsite copy of `tank/immich` (the offsite Cloud
Sync task in `ansible/truenas`). It exports the box's usage with snapshots, its plan size and the main account's
access settings. Design record: `blog/blog-offsite-backup-draft.md` ("2026-10-14 — the box itself in Prometheus").

## Files

| File | Purpose |
|---|---|
| `templates/namespace.yaml` | `hcloud-exporter` ns, `openshift.io/cluster-monitoring: "false"` (user workload) |
| `templates/deployment.yaml` | The exporter under restricted-v2; token read from the mounted Secret; every collector but Storage Box off |
| `templates/service.yaml` | ClusterIP Service, port `http` 9501. Not headless, so `/metrics` is readable through the API server's service proxy |
| `templates/servicemonitor.yaml` | Scrape every 60 s; stamps `instance="hcloud-exporter"`, drops `pod`/`container` |
| `templates/sealed-hcloud-token.yaml` | SealedSecret `hcloud-exporter`, key `token`: a **read-only** API token of the Hetzner Console project that owns the box |
| `values.yaml` | Image (tag + digest), port, scrape interval, instance label, resources |

## What it exports

13 series per box, labelled `id`, `name` and `location` and nothing else:
`hcloud_storagebox_{active,locked,general_size,data_size,snapshot_size,quota,external,samba,ssh,webdav,zfs,protection,created}`.

- **`general_size` is usage with snapshots** (the API's `stats.size`) and **`quota` is the plan size**
  (`storage_box_type.size`). Both HELP strings say otherwise. Fill = `general_size / quota`.
- **Never add `server` or `username` to `HCLOUD_EXPORTER_STORAGEBOXES_LABELS`.** Both carry the account number.
  `id` and `name` were checked for it when the token was made, before sealing (2026-10-14).
- **A failed API call looks like missing data.** The exporter then emits no box series while `/metrics` answers
  200, so `up` stays 1. Its health is `hcloud_request_failures_total{collector="storagebox"}` against
  `hcloud_request_duration_seconds_count{collector="storagebox"}`, which counts every call, failed or not
  (`pkg/exporter/storagebox.go` at v3.30.0), plus `absent()`.
- The access settings are the **main account's**. The upload sub-account's own settings are not in the API call
  the exporter makes.

## Rotating the token

Make a new **read-only** token in the Hetzner Console project that owns the box. From the repo root:

```bash
read -rs HCLOUD_TOKEN   # paste the token; nothing is echoed
oc create secret generic hcloud-exporter -n hcloud-exporter \
  --from-literal=token="$HCLOUD_TOKEN" --dry-run=client -o yaml \
  | kubeseal --cert components/operators/sealed-secrets/sealed-secrets-pub.pem -o yaml \
  > components/cluster-config/hcloud-exporter/templates/sealed-hcloud-token.yaml
unset HCLOUD_TOKEN
```

Commit and push. The pod template carries a checksum of the sealed file, so ArgoCD rolls the pod; the exporter
reads the token only at start. `file://` is read verbatim, so the token must not end in a newline (`read -rs`
strips it). Revoke the old token once `hcloud_request_failures_total` stays at 0 on the new pod.

## Validate

```bash
helm lint components/cluster-config/hcloud-exporter/
helm template hcloud-exporter components/cluster-config/hcloud-exporter/ -n hcloud-exporter \
  -f components/cluster-config/hcloud-exporter/values.yaml
export KUBECONFIG=~/.kube/config-readonly
oc -n hcloud-exporter get pod -o jsonpath='{range .items[*]}{.metadata.annotations.openshift\.io/scc} {.status.phase}{"\n"}{end}'
oc get --raw /api/v1/namespaces/hcloud-exporter/services/http:hcloud-exporter:9501/proxy/metrics \
  | grep -c '^hcloud_storagebox_'    # 13 per box
```
