# shelly-exporter

Scrapes Shelly Gen 2/3 plug power telemetry into the cluster's Prometheus
stack via `prometheus-community/json_exporter`.

## Why this shape (vs. a dedicated Shelly exporter)

Gen 3-specific exporter projects on GitHub are immature (single-developer,
0-2 stars, no tagged releases). `prometheus-community/json_exporter` is
stable, versioned, and a perfect fit for "scrape one JSON endpoint and
extract numeric fields" — which is exactly what the Gen 2/3 RPC API
(`/rpc/Switch.GetStatus?id=0`) offers.

The multi-target probe pattern means a single `json_exporter` Deployment
handles N plugs — each ServiceMonitor endpoint passes a different
`target=<rpcUrl>` query param.

## Metrics emitted

For each plug listed in `values.yaml`'s `plugs:` entries:

| Metric | Type | Source field |
|---|---|---|
| `shelly_power_watts{instance=…}` | gauge | `.apower` |
| `shelly_voltage_volts{instance=…}` | gauge | `.voltage` |
| `shelly_current_amperes{instance=…}` | gauge | `.current` |
| `shelly_energy_total_wh{instance=…}` | counter | `.aenergy.total` |
| `shelly_temperature_celsius{instance=…}` | gauge | `.temperature.tC` |

`shelly_energy_total_wh` resets on plug reboot — it's a per-boot counter,
not lifetime energy. Use `rate(…[5m]) * 12` to get watt-equivalent if needed
(though `shelly_power_watts` is the direct read).

## Adding a plug

Append to `values.yaml`:

```yaml
plugs:
  - instance: node6
    rpcUrl: http://192.168.1.50/rpc/Switch.GetStatus?id=0
  - instance: node4
    rpcUrl: http://192.168.1.78/rpc/Switch.GetStatus?id=0  # example
```

Each entry's `instance` becomes the metric's `instance` label.

**Currently monitored** (`values.yaml`): `node6` = `192.168.1.50` (single node),
`rack` = `192.168.1.77` (whole-homelab feed upstream of the PDU — the meaningful
denominator for cluster-wide power-lever decisions; ~1/3 of it is any one node),
`truenas` = `192.168.1.55` (the NAS box, added 2026-08-25).

`node6` and `truenas` are **sub-meters** of `rack` when their plugs sit downstream
of the rack feed — the dashboard's `$instance` variable is multi-select, so it shows
them as separate series rather than summing, but don't hand-add the numbers.

Adding a plug is a `values.yaml` edit only: the ServiceMonitor ranges over `plugs`,
and the Grafana dashboard's `$instance` variable is populated by
`label_values(shelly_power_watts, instance)` — so a new plug appears in the
dropdown with no dashboard change. This holds only for Gen 2/3 plugs sharing the
`/rpc/Switch.GetStatus?id=0` shape; a Gen 1 plug (`/status`, `.meters[0].power`)
would need its own `json_exporter` module in `templates/configmap.yaml`.

## Files

| File | Purpose |
|---|---|
| `templates/namespace.yaml` | `shelly-exporter` namespace (UWM scrape, not platform Prometheus) |
| `templates/serviceaccount.yaml` | SA for the Deployment |
| `templates/configmap.yaml` | json_exporter config — JSONPath -> metric mapping |
| `templates/deployment.yaml` | Single replica running `json_exporter --config.file` |
| `templates/service.yaml` | Headless Service exposing the metrics port |
| `templates/servicemonitor.yaml` | One endpoint per plug; uses `params.target` for multi-target |

## Validation

```bash
helm lint components/cluster-config/shelly-exporter/
helm template shelly-exporter components/cluster-config/shelly-exporter/ \
  -n shelly-exporter -f components/cluster-config/shelly-exporter/values.yaml
```

To smoke-test the scrape after sync — from any pod with curl:

```bash
oc -n shelly-exporter exec deploy/shelly-exporter -- \
  wget -qO- 'http://localhost:7979/probe?target=http://192.168.1.50/rpc/Switch.GetStatus?id=0'
```

Should return Prometheus exposition format with the five metrics.
