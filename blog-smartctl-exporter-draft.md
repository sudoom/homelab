# NVMe SMART metrics on OKD with prometheus-community/smartctl_exporter

Working notes for adding `smartctl_exporter` as a DaemonSet to the cluster, scraped by OpenShift's user-workload monitoring stack and surfaced through Grafana via Thanos.

The motivation is concrete: the storage cluster is mid-swap (PNY CS1030 → Samsung PM9A1, see `blog-rook-ceph-draft.md`), and ad-hoc `oc debug node/<n> -- chroot /host nvme smart-log /dev/nvme0n1` captures aren't a substitute for a continuous wear-rate signal. With consumer-grade NVMe and Ceph's typical 5–10× write amplification, a 600 TBW drive can burn through endurance in weeks under sustained load. I want a Prometheus series that surfaces `smartctl_device_percentage_used` rate-of-change *before* the next drive starts throwing media errors. The new Samsung PM9A1s arriving for node5/node6 are also mid-life (the one in node4 was 18% used at insertion); knowing the t=0 SMART per drive matters even more here.

## Component layout

```
components/cluster-config/smartctl-exporter/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── namespace.yaml          # smartctl-exporter ns, cluster-monitoring=false
    ├── serviceaccount.yaml
    ├── scc-rolebinding.yaml    # binds SA to system:openshift:scc:privileged
    ├── daemonset.yaml          # privileged, hostPath:/dev, runAsUser=0
    ├── service.yaml            # headless, port 9633
    └── servicemonitor.yaml     # node label from __meta_kubernetes_pod_node_name
```

Image: `quay.io/prometheuscommunity/smartctl-exporter:v0.14.0`. Sync wave 5 (alongside `monitoring-config` and `grafana-config`).

## Why a DaemonSet (and why privileged)

- **DaemonSet** because SMART data is per-node-per-device. One Pod per node maps cleanly onto one NVMe drive per node in the current 3-node layout.
- **Privileged** because reading NVMe SMART requires raw block-device access. The exporter shells out to `smartctl --json` which needs `SYS_ADMIN` and access to `/dev/nvme*`. Could narrow to `--cap-add=SYS_RAWIO,SYS_ADMIN` later, but on OpenShift `restricted-v2` denies hostPath anyway, so the SCC binding is needed regardless. Doing the simple thing: `privileged: true` + `system:openshift:scc:privileged` rolebinding.
- **hostPath:/dev (read-only)** rather than mounting just `/dev/nvme0n1`: lets the exporter scan all SMART-capable devices without per-node config drift if the hardware layout changes. Read-only mount, so no risk of accidental writes.

## Why user-workload monitoring (and what changed)

OpenShift's default `prometheus-k8s` (in `openshift-monitoring`) only scrapes ServiceMonitors with the `openshift.io/cluster-monitoring=true` namespace label. Putting that label on the exporter namespace would work but would drag the workload into the cluster-monitoring stack — not the right boundary.

The supported path is **user-workload monitoring (UWM)**: a separate Prometheus instance in `openshift-user-workload-monitoring` that scrapes ServiceMonitors / PodMonitors / PrometheusRules in user namespaces. Enabled with `enableUserWorkload: true` in `cluster-monitoring-config`. UWM Prometheus's metrics flow through `thanos-querier.openshift-monitoring.svc:9091`, which Grafana already uses as its primary datasource (see `components/cluster-config/grafana-config/templates/grafana.yaml`). So once UWM is enabled, the smartctl metrics show up in Grafana with no datasource changes.

Diff against live monitoring-config (read-only `oc diff` before commit):

```
+    enableUserWorkload: true
```

Plus a new `user-workload-monitoring-config` ConfigMap in `openshift-user-workload-monitoring` (namespace already exists since 27 d ago — likely auto-created by an earlier OKD reconcile loop). Intra-app sync-wave `"1"` on that ConfigMap so it lands after the cluster-monitoring-config flip.

UWM Prometheus PVC: `ceph-nvme-block`, 10 GiB, 15 d retention. Sized small because SMART metrics are low-cardinality (handful of series per drive, scrape every 60 s) — the bulk of UWM volume will be whatever future user-namespace exporters push in.

## Scrape interval

60 s. SMART counters update on the order of seconds-to-minutes inside the drive controller; sub-minute scraping is just noise. The relevant signals are slow-moving:

- `smartctl_device_percentage_used` (wear)
- `smartctl_device_data_units_written_total` (write counter, derive rate)
- `smartctl_device_temperature_current_celsius`
- `smartctl_device_media_errors_total`
- `smartctl_device_critical_warning`

For the wear-rate panel — the point of the whole exercise — a 24 h rate window is what we want, so 60 s scrape leaves plenty of resolution.

## Validation workflow (per CLAUDE.md)

```bash
helm lint components/cluster-config/smartctl-exporter/
helm template smartctl-exporter components/cluster-config/smartctl-exporter/ \
  -f components/cluster-config/smartctl-exporter/values.yaml
helm template smartctl-exporter components/cluster-config/smartctl-exporter/ | \
  kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
helm template ... | oc diff -f -
```

All clean on first pass. The `oc diff` for `monitoring-config` showed only the `enableUserWorkload: true` line and the new UWM ConfigMap; for `smartctl-exporter` the diff is namespace-doesn't-exist-yet (expected — ArgoCD `CreateNamespace=true`).

## Post-deploy verification (TODO once deployed)

```bash
# DaemonSet rolled out
oc -n smartctl-exporter get ds smartctl-exporter

# Each node has a Pod
oc -n smartctl-exporter get pods -o wide

# Metrics endpoint reachable from inside the cluster
oc -n smartctl-exporter port-forward svc/smartctl-exporter 9633:9633
curl -s localhost:9633/metrics | grep smartctl_device | head -20

# UWM Prometheus is scraping it
oc -n openshift-user-workload-monitoring port-forward svc/prometheus-user-workload 9091:9091
# Then in browser: http://localhost:9091/targets — look for the smartctl-exporter scrape job

# Thanos sees it
# Grafana → Explore → query: smartctl_device_percentage_used
```

## Open follow-ups

- **Grafana dashboard**: deferred. Once metrics are flowing, pick a community dashboard ID (the prometheus-community/smartctl_exporter project README links one) and add it to `grafana-config/templates/dashboards.yaml` alongside the existing Ceph/k8s dashboards.
- **Wear-rate alert**: when do we want to be paged? Probably `rate(smartctl_device_data_units_written_total[24h]) * 86400 > <some TBW/day budget>`. Park until we have a few weeks of baseline data to set the threshold from.
- **Per-drive labels**: the ServiceMonitor relabels `__meta_kubernetes_pod_node_name` to `node`, but if a node ever has multiple NVMe drives we'll need a `device` label too. Not a problem today (one NVMe per node).

## 2026-05-01 — Adding OS disks to the scrape set

Initial scope was the Ceph OSD device only (`/dev/nvme0n1`) — that's the failure mode I cared about because consumer NVMe wear was pathological on the PNYs. But the OS disks (`/dev/sda` on all three nodes) get hammered by control-plane writes, container runtime, kubelet state, log buffering, and they're the same generic consumer-SSD class. No reason to leave them blind.

One-line change in `components/cluster-config/smartctl-exporter/values.yaml`:

```yaml
devices:
  - /dev/nvme0n1
  - /dev/sda
```

The DaemonSet already runs privileged with `/dev` mounted, so no RBAC or security-context change is needed — only the `--smartctl.device=...` arg list grows. `oc diff` confirmed exactly that:

```
       - args:
         - --web.listen-address=:9633
         - --smartctl.device=/dev/nvme0n1
+        - --smartctl.device=/dev/sda
```

Why explicit list instead of `smartctl --scan` auto-discovery: the explicit list keeps the per-node scrape set predictable and makes "what are we monitoring" a values question, not a runtime question. If a future node has a different OS disk path, that's a values change — not a silent gap or a noisy add.

The "node-exporter already exposes this" assumption is wrong. OKD's bundled `node-exporter` exports `node_disk_*` — kernel-level IO counters: read bytes, write bytes, queue depth, IO time — but does **not** enable the `smartctl` collector or the textfile pattern. SMART health (`percentage_used`, `data_units_written`, `temperature_celsius`, `media_errors`) only comes from `smartctl-exporter`. Easy to conflate because both sets of metrics show up under "disk" panels in Grafana.
