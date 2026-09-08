# truenas-exporter

Scrape wiring for the `node_exporter` running **on the TrueNAS box**
(`192.168.1.25`). This chart deploys **no workload** — it is three objects that
let user-workload Prometheus reach an off-cluster target.

The exporter itself is not here. It is an Ansible-managed custom app on the NAS:
`ansible/truenas/roles/truenas-apps/tasks/main.yml`, configured by
`truenas_node_exporter` in `ansible/truenas/group_vars/all.yml`.

## Files

| File | Purpose |
|---|---|
| `templates/namespace.yaml` | `truenas-exporter` ns, `openshift.io/cluster-monitoring: "false"` (this is a user workload) |
| `templates/service-endpoints.yaml` | Selectorless `Service` + hand-written `Endpoints` pointing at the NAS IP |
| `templates/servicemonitor.yaml` | Scrape config; stamps `instance="truenas"` |
| `values.yaml` | Target address/port, instance label, scrape interval |

## The two things that will bite

**1. The target address must be the frontnet one (`192.168.1.25`).**
TrueNAS is also on the 10G storage backnet at `192.168.10.10`, and a pod on the
OVN pod network **cannot route there**. Everything that reaches the backnet today
does so from the host stack (Ceph is `network.provider: host`; the NFS CSI pods
are `hostNetwork`). Pointing this at `.10` gives a silent scrape timeout with
zero inbound SYNs on the NAS — the exact failure that broke the Velero
BackupStorageLocation on 2026-08-28.

**2. `helm lint` warns that `v1 Endpoints` is deprecated. Ignore it.**
This cluster's user-workload Prometheus has `spec.serviceDiscoveryRole` unset, so
prometheus-operator uses its default `Endpoints` service-discovery role, which
watches the **Endpoints** API. Mirroring only runs Endpoints → EndpointSlice,
never the reverse, so "modernising" this into an `EndpointSlice` makes the target
vanish **silently**: the ServiceMonitor stays valid and ArgoCD stays
Synced+Healthy while the series simply stop.

Re-check before ever switching:

```bash
oc -n openshift-user-workload-monitoring get prometheus user-workload \
  -o jsonpath='{.spec.serviceDiscoveryRole}'
```

Empty or `Endpoints` → keep this chart as-is. `EndpointSlice` → the two objects
can collapse into one.

## Why not an in-cluster exporter

`shelly-exporter` and `mikrotik-exporter` both run the exporter as a pod here and
reach out to the device. That shape does not work for the NAS: ARC, ZIL, per-disk
SMART and NFS server stats only exist **on the box**. Hence an agent there and a
bare scrape target here.

## Validate

```bash
helm lint components/cluster-config/truenas-exporter/
helm template truenas-exporter components/cluster-config/truenas-exporter/ \
  -f components/cluster-config/truenas-exporter/values.yaml

# target should be UP once the NAS-side playbook has run
oc -n truenas-exporter get endpoints truenas-exporter
oc get --raw "/api/v1/namespaces/openshift-user-workload-monitoring/services/http:prometheus-user-workload:9090/proxy/api/v1/targets?state=active" \
  | python3 -c 'import json,sys;[print(t["labels"],t["health"]) for t in json.load(sys.stdin)["data"]["activeTargets"] if "truenas" in t["labels"].get("job","")]'
```

## Dashboard

grafana.com **1860** (Node Exporter Full) is wired in
`components/cluster-config/grafana-config/templates/dashboards.yaml`. It reads
`job` + `instance`; `instance="truenas"` is deliberately the same value the
Shelly plug uses, so power and system metrics for this box share a name.

ZFS/SMART/scrub/NFS panels are **not** in 1860 and are still to be built — see
the TrueNAS TODO in the root `README.md`.
