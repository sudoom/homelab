# Gatus on OKD: a single uptime view for the homelab

The homelab grew enough surface area to need a uptime dashboard. Grafana with Prometheus has all the data in principle — `up{}`, blackbox probes, ingress 5xx — but stitching together "is the cluster API reachable from outside? is the blog SSL still valid? is the Mikrotik router responding to ICMP? is pi-hole still answering DNS?" into a single glanceable view is its own piece of work. Gatus does that out of the box.

## Why Gatus over alternatives

Quick survey before picking:

- **Uptime Kuma**: closest competitor, more polished UI, has its own bundled SQLite. Minus: config is UI-driven, not GitOps-friendly. Editing endpoints means clicking around the dashboard, not changing a YAML file in git.
- **Statping / StatPing-NG**: looked promising, but development pace concerns and historical CVE patterns made me skip.
- **Prometheus blackbox + Grafana panels**: I already have this for some endpoints. It's powerful but verbose — every endpoint is three things (a `Probe`, a `ServiceMonitor` if needed, a Grafana panel). Gatus is one YAML block per endpoint.
- **Gatus**: YAML config, dead simple endpoint definitions, supports HTTP / TCP / ICMP / DNS / TLS-cert-expiry checks natively, has a built-in dashboard, and runs as a single Go binary. Config-as-code, one Deployment, one PVC.

Gatus won on "least daemons that need to coexist with everything else."

## Chart layout

`components/cluster-config/gatus/` follows the same pattern as the other recent fresh charts (`mikrotik-exporter`, `smartctl-exporter`):

```
components/cluster-config/gatus/
├── Chart.yaml
├── values.yaml
└── templates/
    ├── namespace.yaml
    ├── serviceaccount.yaml
    ├── configmap.yaml      # Gatus config rendered from values.config
    ├── pvc.yaml             # 5Gi ceph-nvme-block, RWO
    ├── deployment.yaml
    ├── service.yaml         # ClusterIP
    └── route.yaml           # edge-TLS Route at gatus.apps.okd.sudops.pl
```

Wave 5 in `bootstrap/root-app/values.yaml` (alongside the other monitoring components — `grafana-config`, `monitoring-config`, `smartctl-exporter`, `mikrotik-exporter`).

The Gatus config itself lives in `values.yaml` under the `config:` key and is `toYaml | indent 4`'d into a ConfigMap. That means the source of truth for "what is Gatus monitoring" is one Helm values file, not a runtime UI state. Add an endpoint, commit, Argo syncs, the deployment rolls (the deployment template has a `checksum/config` annotation so the pod actually restarts on config change).

## Persistence: SQLite on Ceph

Gatus supports `memory`, `sqlite`, and `postgres` storage backends. For a homelab, SQLite on a Ceph RBD PVC is the right call:

- **Memory** loses history on restart — defeats half the point of an uptime dashboard.
- **Postgres** is overkill (and we don't have CNPG-managed Postgres yet at the time of writing).
- **SQLite on RBD** gets durability from Ceph's 3-way replication for free, no extra moving parts.

PVC: `5Gi`, `ReadWriteOnce`, `ceph-nvme-block`. Gatus's history table is small (single-digit MB after months of data with sub-100 endpoints) but 5Gi is the smallest size where I don't have to think about it again.

## Endpoint set: what's monitored

Curated to "things I'd want to know are down at 02:00":

- **External / internet path:** `https://github.com` (sanity check — if this is down from inside the cluster, something at the egress is broken), `https://sudops.pl` (the blog itself, including a TLS expiry check `[CERTIFICATE_EXPIRATION] > 168h` — paged a week before expiry).
- **OKD platform:** `api.okd.sudops.pl:6443/healthz` and the ingress canary route. Both with `[CERTIFICATE_EXPIRATION] > 168h` to catch cert-manager regressions early.
- **Cluster apps:** ArgoCD, Grafana, Ceph dashboard. These are the three I actually open day-to-day.
- **Network gear:** ICMP to the Mikrotik router (192.168.1.1) and switch (192.168.1.220). If either drops, half the cluster ops are about to be painful.
- **DNS:** UDP probe to pi-hole at 192.168.1.12. Tagged for replacement (technetium migration is queued), but until then it's load-bearing for cluster.local resolution from external machines, and seeing it red the moment it stops being authoritative is worth the line.

The cert-expiry checks are the one thing I'd flag as non-obvious — Gatus's `[CERTIFICATE_EXPIRATION]` placeholder evaluates against the leaf cert presented during the HTTPS handshake. `> 168h` (one week) gives a comfortable lead on cert-manager renewal failures before the cert actually expires.

## OpenShift random UID handling

The `ghcr.io/twin/gatus` image is built on a distroless base and runs as `nonroot`. OpenShift's `restricted-v2` SCC will assign a random UID inside that container; the image needs to be UID-agnostic.

Two failure modes to watch for here, both common with images that weren't designed for arbitrary UIDs:

1. **Config read failure** — if the configmap mount comes through with `0644` and the Gatus binary can't read it as a non-`nonroot` UID. Not a problem for Gatus because the configmap is world-readable by default.
2. **Data dir write failure** — the SQLite write to `/data/data.db` needs the random UID to own (or have group access to) `/data`. The PVC mount with default `fsGroup` (auto-assigned by OpenShift) gets group ownership matching the pod's UID range, so writes work.

I'm leaving the validation observation here as a placeholder until rollout — historically Gatus just works on OpenShift, but I want to confirm before declaring victory.

## Route + TLS

`gatus.apps.okd.sudops.pl`, edge termination, `Redirect` on plain HTTP. The wildcard `*.apps.okd.sudops.pl` cert from cert-manager (DNS-01 via Cloudflare, Let's Encrypt prod) covers it automatically — no per-app Certificate resource needed.

## Validation

Pre-commit:

```bash
$ helm lint components/cluster-config/gatus/
1 chart(s) linted, 0 chart(s) failed

$ helm template gatus components/cluster-config/gatus/ -n gatus \
    -f components/cluster-config/gatus/values.yaml | \
  kubeconform -strict -ignore-missing-schemas \
    -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
                              <- silent, all kinds OK
```

Post-deploy verification (to fill in once the rollout completes):

- Pod running with the random UID.
- PVC bound to a Ceph RBD volume.
- Dashboard reachable at `https://gatus.apps.okd.sudops.pl`.
- All endpoint groups (external, platform, cluster-apps, network) showing green at first paint.
- The cert-expiry condition rendering an actual remaining-time number, not a parse error.

## Open follow-ups

- **Alerting**: deferred. Gatus has webhook/Discord/Slack/email backends; once we decide on a notification channel (probably Discord for homelab), wire it via a SealedSecret holding the webhook URL and add `alerts:` blocks to the per-endpoint config.
- **Auth on the dashboard**: also deferred. Gatus supports basic auth and OIDC out of the box. For now the Route is unauthenticated — homelab is internal-ish, but eventually OIDC against the cluster's identity provider would be cleaner than a shared password.
- **Endpoint coverage**: today's list is the obvious stuff. As apps come online (Immich, media stack post-migration), each gets a line in `values.yaml` under the right group.
- **Grafana panel/dashboard**: Gatus exposes `/metrics` in Prometheus format with `metrics: true` in the config. Could scrape it via a `ServiceMonitor` and have the same data as Grafana panels — useful if we want longer-term retention than Gatus's SQLite handles. Park until there's a clear use case beyond what the Gatus dashboard already shows.
