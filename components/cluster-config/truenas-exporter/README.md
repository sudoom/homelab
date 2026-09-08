# truenas-exporter

Scrape path for the `node_exporter` running **on the TrueNAS box**
(`192.168.1.25`). The exporter is not deployed here — it is an Ansible-managed
custom app on the NAS
(`ansible/truenas/roles/truenas-apps/tasks/main.yml`, configured by
`truenas_node_exporter` in `ansible/truenas/group_vars/all.yml`).

What this chart deploys is a **one-container socat forwarder** and the Service /
ServiceMonitor around it.

## Files

| File | Purpose |
|---|---|
| `templates/namespace.yaml` | `truenas-exporter` ns, `openshift.io/cluster-monitoring: "false"` (user workload) |
| `templates/deployment.yaml` | socat, `TCP-LISTEN:9100,fork` → `192.168.1.25:9100` |
| `templates/service.yaml` | Headless Service with a real selector |
| `templates/servicemonitor.yaml` | Scrape config; stamps `instance="truenas"`, drops `pod`/`container` |
| `values.yaml` | Target address/port, image, instance label, scrape interval, resources |

## Why a forwarder pod instead of a selectorless Service + Endpoints

That is the textbook way to scrape an off-cluster target, and **it does not work
on this cluster.** OpenShift GitOps ships `resource.exclusions` on the ArgoCD CR
that excludes both `Endpoints` and `EndpointSlice`:

```yaml
- apiGroups: ["", "discovery.k8s.io"]
  clusters: ["*"]
  kinds: [Endpoints, EndpointSlice]
```

ArgoCD therefore **silently drops** such an object: it never appears in the
Application's resource tree, nothing is applied, and the app still reports
`Synced`/`Healthy`. Confirmed on 2026-09-08 — the first cut of this chart shipped
exactly that pair and the target simply never existed. Both escape hatches are
excluded, so "use an EndpointSlice instead" is not available.

A real Deployment behind a real selector keeps every object here
ArgoCD-managed, and matches how `shelly-exporter` and `mikrotik-exporter`
already reach external devices.

Verify the exclusion is still in force before revisiting:

```bash
oc -n openshift-gitops get cm argocd-cm -o jsonpath='{.data.resource\.exclusions}'
```

## Why socat and not nginx

Prometheus speaks plain HTTP over TCP and needs nothing rewritten, so an L4
forward is the entire job. socat needs no config file, no writable directory and
no privileged port, which makes it trivially compatible with OpenShift's
`restricted-v2` arbitrary UID. An nginx image would need a ConfigMap and
writable temp paths to do strictly less.

## The two things that will bite

**1. The target must be the frontnet address (`192.168.1.25`).**
TrueNAS is also on the 10G storage backnet at `192.168.10.10`, and a pod on the
OVN pod network **cannot route there** — everything reaching the backnet today
does so from the host stack. Pointing this at `.10` gives a silent scrape timeout
with zero inbound SYNs on the NAS, the exact failure that broke the Velero
BackupStorageLocation on 2026-08-28. Pod → frontnet LAN is proven
(`synology-cert-sync` reaches `192.168.1.2` nightly).

**2. The liveness probe deliberately does not reach the NAS.**
It is a TCP probe on socat's own listener. An HTTP probe against `/metrics` would
mark the pod NotReady whenever the NAS is down, dropping it from the Service's
endpoints and making the Prometheus target **vanish** — which is far less visible
than a target that is present and reporting `up == 0`. Keep the pod Ready
whenever socat is alive and let `up` carry the NAS's health.

## Validate

```bash
helm lint components/cluster-config/truenas-exporter/
helm template truenas-exporter components/cluster-config/truenas-exporter/ \
  -f components/cluster-config/truenas-exporter/values.yaml

oc -n truenas-exporter get deploy,svc,endpoints
# metrics should flow once the NAS-side playbook has run:
oc -n truenas-exporter exec deploy/truenas-exporter -- \
  sh -c 'wget -qO- http://127.0.0.1:9100/metrics | head -5'
```

## Dashboard

grafana.com **1860** (Node Exporter Full) is wired in
`components/cluster-config/grafana-config/templates/dashboards.yaml`. It reads
`job` + `instance`; `instance="truenas"` is deliberately the same value the
Shelly plug uses, so power and system metrics for this box share a name.

ZFS pool health, scrub recency, SMART, ARC hit ratio, `zil_commit` rate and NFS
latency are **not** in 1860 — see the TrueNAS TODO in the root `README.md`.

## Why the Service is not headless

`clusterIP: None` would be tidier — a ServiceMonitor scrapes pod endpoints and
never touches the Service IP, so the virtual IP is dead weight. The first cut of
this chart shipped the Service *without* the field, the API server allocated one,
and `spec.clusterIP` is **immutable**:

```
Service "truenas-exporter" is invalid: spec.clusterIPs[0]:
  Invalid value: []string{"None"}: may not change once set (retried 5 times)
```

ArgoCD burned all five retries on it. Converting now would mean deleting and
recreating the Service — a manual mutation for zero functional gain. Same shape
as the `strategy: Recreate` trap in `shelly-exporter`: **when an immutable field
blocks a cosmetic improvement, change the manifest, not the cluster.**
