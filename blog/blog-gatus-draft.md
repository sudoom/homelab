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
- **Network gear:** TCP probes against the mktxp/RouterOS API port (`tcp://192.168.1.1:8728` for the router and `tcp://192.168.1.220:8728` for the switch). Originally drafted as ICMP — that didn't survive contact with OpenShift's `restricted-v2` SCC, see "Rollout findings" below. Both devices already have `tcp/8728` open for the mktxp scrape, so reusing it as a liveness probe is free.
- **DNS:** UDP probe to pi-hole at 192.168.1.12. Tagged for replacement (technitium migration is queued), but until then it's load-bearing for cluster.local resolution from external machines, and seeing it red the moment it stops being authoritative is worth the line.

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

## Rollout findings

Three things broke between "values.yaml looked right" and "every endpoint green," all worth writing down because the next time I add a Gatus probe I'll forget at least one.

### ICMP doesn't work on `restricted-v2` SCC

First-pass config used `icmp://192.168.1.1` and `icmp://192.168.1.220` for the Mikrotik gear. Gatus reported every probe as failed with no useful error in the logs — "down" with `[CONNECTED] == false`.

Root cause: Gatus's ICMP probe uses `golang.org/x/net/icmp`, which needs `CAP_NET_RAW` to open the raw socket. OpenShift's `restricted-v2` SCC (default for any user-created namespace, including `gatus`) drops every Linux capability and disallows requesting them back. The pod runs but the syscall is denied — silent failure rather than an error message that points anywhere useful.

Fix: TCP probes to a port that's already open. Both devices have `tcp/8728` open for the mktxp Prometheus scrape, so:

```yaml
url: tcp://192.168.1.1:8728
conditions:
  - "[CONNECTED] == true"
```

Doesn't tell you whether RouterOS is healthy at the application layer — just that the API socket is accepting connections. For a "is the network gear reachable from the cluster" check, that's what we want anyway.

The alternative — running Gatus with a non-default SCC or a `SecurityContextConstraints` exception for `CAP_NET_RAW` — is more invasive than the value of literal ICMP for these probes. If we ever want true ICMP from the cluster, blackbox_exporter with the right SCC is the cleaner answer.

### `grafana-grafana.apps...` is not the route

Initial draft had `https://grafana-grafana.apps.okd.sudops.pl` for the Grafana endpoint — a guess based on the "service-name service-name" Argo pattern. The actual route is `grafana.apps.okd.sudops.pl` (created by the Grafana CR with an explicit short name).

Lesson, slightly embarrassing in retrospect: always `oc get route -A | grep <app>` before writing the URL. Five seconds of verification beats a red endpoint at first paint.

### The ingress canary doesn't speak the wildcard cert

`canary-openshift-ingress-canary.apps.okd.sudops.pl` is the openshift-router self-canary. It runs with `tls.termination: passthrough` and serves its own self-signed cert — *not* the cert-manager wildcard that every other `*.apps...` route uses. The first config had `[CERTIFICATE_EXPIRATION] > 168h` on it, which evaluated against the canary's self-signed cert and produced a meaningless number.

Fix: `client.insecure: true` (skip cert verification) and drop the cert-expiry condition. The platform-level cert-expiry check belongs on the API server endpoint (`api.okd.sudops.pl:6443`), which uses the actual cert-manager-issued cert. Kept that one.

### Final state

After the three fixes (commit `1229d65` for the endpoints, prior commit for the chart):

```
2026-05-01 11:10:06 endpoint=external/github                        success=true
2026-05-01 11:10:06 endpoint=external/sudops-blog                   success=true
2026-05-01 11:10:07 endpoint=platform/okd-api                       success=true
2026-05-01 11:10:07 endpoint=platform/okd-ingress                   success=true
2026-05-01 11:10:08 endpoint=cluster-apps/argocd                    success=true
2026-05-01 11:10:08 endpoint=cluster-apps/grafana                   success=true
2026-05-01 11:10:09 endpoint=cluster-apps/ceph-dashboard            success=true
2026-05-01 11:10:09 endpoint=network/mikrotik-router                success=true
2026-05-01 11:10:10 endpoint=network/mikrotik-switch                success=true
2026-05-01 11:10:10 endpoint=network/pihole-dns                     success=true
```

All ten endpoints green. Cert-expiry placeholders rendered as actual remaining-time numbers (months, not parse errors). Pod is running with the OpenShift-assigned random UID; PVC bound on `ceph-nvme-block` and writes to SQLite are working.

## UI bump: v5.16.0 → v5.35.0

After first paint on `v5.16.0` the dashboard rendered the classic groups-of-pills view (one row per endpoint, group headers stacked above). Compared side-by-side with the upstream demo at `status.twin.sh`, the demo showed a card-based "Health Dashboard" with a search box and Filter/Sort dropdowns — visibly nicer for a 10-endpoint board, and *much* nicer once it grows.

That UI is just the default in newer Gatus. The relevant config keys (`ui.dashboard-heading`, `ui.dashboard-subheading`) and the layout itself landed in **v5.32.0**. We were sitting on `v5.16.0` because that was current when the chart was first authored — no other reason.

Diff:

```diff
 image:
   repository: ghcr.io/twin/gatus
-  tag: v5.16.0
+  tag: v5.35.0
```

No config-shape changes between v5.16 and v5.35 for the keys we use (`endpoints[*]`, `[STATUS]`, `[CERTIFICATE_EXPIRATION]`, `[CONNECTED]`, `storage.type: sqlite`). Drop-in replacement; pod rolls, history persists in the Ceph PVC, the new UI paints.

Renovate will keep this current going forward — once the chart is in tree, future bumps come in as labeled PRs rather than us spotting "we're 19 minor versions behind" again.

## External probes red — DNS hang on search-domain permutations (2026-05-01)

After a few hours the dashboard was steady except for `external/github` and `external/sudops-blog`, both red, both showing ~10 s response time (gatus' default per-endpoint timeout). Other groups (`cluster-apps`, `platform`, `network`) all green at single-digit ms. Initial reaction was "external link broken upstream" — wrong.

From the gatus pod's host node (`node4`):

```
curl https://github.com → http=200 t_total=0.290s t_connect=0.048s
curl https://sudops.pl  → http=200 t_total=0.089s t_connect=0.021s
```

Internet works. From a fresh test pod in the **same `gatus` namespace** (so same pod-network egress + same DNS):

```
curl https://github.com → http=200 t_total=6.291s t_connect=6.050s
curl https://sudops.pl  → http=200 t_total=6.100s t_connect=6.019s
```

`t_connect` ≈ 6 s — that's not TCP RTT, that's resolver latency. The pod sees the cluster DNS search list plus the host-inherited `okd.sudops.pl` plus `ndots:5`. For `github.com` (1 dot) the resolver tries every search-domain permutation before the bare name; the `github.com.okd.sudops.pl` permutation goes CoreDNS → host resolv.conf → pi-hole → NXDOMAIN, and that's where the seconds go. Same root cause as the existing TODO to drop `okd.sudops.pl` from the node-side DNS search list — it just surfaced as a per-pod symptom because Gatus is the only workload doing real-time external-name resolution every 30 s.

Fix in the gatus deployment template:

```yaml
spec:
  template:
    spec:
      dnsConfig:
        options:
          - { name: ndots, value: "1" }
```

`ndots:1` tells the resolver "any name with at least 1 dot is FQDN-ish, query directly first." `github.com` has 1 dot → matches → no search-domain walk → fast. The cluster-internal endpoints (`grafana.grafana.svc.cluster.local`-style or in-namespace `gatus.svc`) are unaffected because they're either fully qualified or single-label internal lookups that the in-cluster CoreDNS handles directly.

Per-pod workaround until the global node-side search-list cleanup happens. Not a layered/parallel fix — both will live; the pod-level setting is robustness against any future case where the node leak comes back.

## Open follow-ups

- **Alerting**: deferred. Gatus has webhook/Discord/Slack/email backends; once we decide on a notification channel (probably Discord for homelab), wire it via a SealedSecret holding the webhook URL and add `alerts:` blocks to the per-endpoint config.
- **Auth on the dashboard**: also deferred. Gatus supports basic auth and OIDC out of the box. For now the Route is unauthenticated — homelab is internal-ish, but eventually OIDC against the cluster's identity provider would be cleaner than a shared password.
- **Endpoint coverage**: today's list is the obvious stuff. As apps come online (Immich, media stack post-migration), each gets a line in `values.yaml` under the right group.
- **Grafana panel/dashboard**: Gatus exposes `/metrics` in Prometheus format with `metrics: true` in the config. Could scrape it via a `ServiceMonitor` and have the same data as Grafana panels — useful if we want longer-term retention than Gatus's SQLite handles. Park until there's a clear use case beyond what the Gatus dashboard already shows.
