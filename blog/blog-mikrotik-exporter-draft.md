# Mikrotik metrics in Grafana — `mktxp` on OKD

Working notes from shipping `akpw/mktxp` as an ArgoCD-managed Helm chart on the 3-node OKD homelab. The end state is a single Deployment in namespace `mikrotik-exporter`, scraping the home router and a downstream RouterOS switch over the API on `tcp/8728`, exposing Prometheus metrics on `:49090`, picked up by UWM Prometheus via a ServiceMonitor, and graphed by Grafana dashboard 13679.

## Why mktxp

The cluster already has a Mikrotik switch and router on the management VLAN (192.168.1.0/24). They were unmonitored — Ceph fio benchmarks during the PNY → PM9A1 swap kept raising the question "is the back-net bottlenecked?" without a way to look at switch byte counters and queue stats over time. SNMP would work but reading byte counters per port is the easy half; PoE state, DHCP lease count, wireless RSSI, IPv6 neighbor cache — all easier through the RouterOS API.

[`akpw/mktxp`](https://github.com/akpw/mktxp) talks to the API directly. One container, one Python process, one Prometheus endpoint. Fits.

## Chart layout

Standard pattern for this repo:

```
components/cluster-config/mikrotik-exporter/
├── Chart.yaml
├── values.yaml
├── examples/
│   └── mktxp.conf.example          # template the operator fills in + seals
├── README.md                        # chart-local prereqs (RouterOS-side + sealing)
└── templates/
    ├── namespace.yaml               # opted out of platform monitoring; UWM scrapes it
    ├── serviceaccount.yaml
    ├── configmap.yaml               # _mktxp.conf (system settings)
    ├── deployment.yaml              # 1 replica, mounts ConfigMap + Secret
    ├── service.yaml                 # headless, port 49090
    ├── servicemonitor.yaml          # 30s scrape, /metrics
    └── sealed-mktxp-config.yaml     # SealedSecret holding the per-device creds
```

Two files in the container's config directory:
- `_mktxp.conf` — global mktxp settings (timeouts, parallel mode). Lives in a ConfigMap because nothing here is secret.
- `mktxp.conf` — per-device entries, including credentials. Lives in a `SealedSecret` (`mktxp-config`) created via `kubeseal` out-of-band.

Wire-up: the `Deployment`'s container has two `volumeMount`s with `subPath` so each file lands as a single file (not a directory), both `readOnly: true`. ServiceMonitor is plain HTTP — UWM scrapes it because the namespace is labeled `openshift.io/cluster-monitoring=false`.

## Things that bit me — keep notes

A clean Helm chart is the easy part. Four separate failures showed up between "synced" and "running 1/1":

### 1. Image tag has no `v` prefix

Initial `values.yaml` had `tag: v1.2.17` to match the git release tag. Pod went to `ImagePullBackOff` with:

```
manifest unknown ... reading manifest v1.2.17 in ghcr.io/akpw/mktxp
```

GHCR publishes tags without the leading `v` — the canonical pull is `ghcr.io/akpw/mktxp:1.2.17`. The package page lists the full tag set: `latest`, `1`, `1.2`, `1.2.17`, etc. Quoted the tag in YAML (`tag: "1.2.17"`) so Renovate doesn't try to coerce it into a number.

### 2. The image uses `CMD`, not `ENTRYPOINT`

After fixing the tag, the pod went to `CreateContainerError`:

```
container create failed: executable file `export` not found in $PATH
```

I had `args: [export]` in the deployment spec, expecting `ENTRYPOINT ["mktxp"]` to give us `mktxp export`. The image actually uses `CMD ["mktxp", "export"]` — and Kubernetes' `args` *replaces* `CMD` entirely when no `command` is set. Result: kubelet tried to exec `export` directly.

Fix: pin both explicitly.

```yaml
command: [mktxp]
args: [export]
```

This pattern is generally safer for any image you don't fully control — set `command` so a CMD/ENTRYPOINT change upstream can't quietly change what your pod runs.

### 3. OpenShift random UID + `~` expansion

Pod next went to `CrashLoopBackOff`:

```python
PermissionError: [Errno 13] Permission denied: '/mktxp/mktxp.conf'
```

But the volume mount is at `/home/mktxp/mktxp/mktxp.conf`. Why is mktxp looking at `/mktxp/`?

Tracing back: mktxp's config code resolves the user-config dir as `~/mktxp/`. In the upstream image, the Dockerfile does `USER mktxp` (uid 1000, `HOME=/home/mktxp`) and `~` expands correctly. But OpenShift's restricted-v2 SCC ignores the image's `USER` and assigns a random UID from the namespace's UID range — so the runtime user has no `/etc/passwd` entry, `HOME` is unset, and Python's `os.path.expanduser("~")` falls back to `/`.

`~/mktxp/mktxp.conf` then resolves to `/mktxp/mktxp.conf` — which exists in the image as a directory (the upstream Dockerfile does `WORKDIR /mktxp` + `COPY . .` of the source tree). That directory is root-owned. mktxp tries to bootstrap a default config by writing into it. EACCES.

Fix: pin `HOME` via env.

```yaml
env:
  - name: HOME
    value: /home/mktxp
```

That's it. `~` now resolves to `/home/mktxp`, the existing volume-mounted file is found, and mktxp skips the bootstrap path. No `runAsUser` override needed (which would fail SCC admission anyway).

This is a recurring class-of-bug for OpenShift: any tool that does `~/...` lookups instead of reading `XDG_CONFIG_HOME` will break under random UIDs. The fix is always the same: set `HOME` explicitly.

### 4. The pi-hole DNS deadlock came back mid-rollout

While Argo was iterating on the chart fixes, I hit the same regression covered in `blog-pihole-cluster-local-draft.md`: `openshift-gitops-repo-server` happens to be scheduled on **node6**, which is the node that gets per-client REFUSED from pi-hole under load. Argo logged:

```
Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = failed to list refs:
dial tcp: lookup github.com on 172.30.0.10:53: server misbehaving
```

The deadlock is self-feeding: repo-server retries `git ls-remote` once a second; combined with everything else node6 looks up, that's enough to keep node6 over pi-hole's 1000-q/min rate-limit window. Pi-hole keeps responding REFUSED → Argo can't resolve `github.com` → the rollout stalls on whichever commit got through during a momentary clear window.

Cross-reference with `blog-pihole-cluster-local-draft.md` for the underlying analysis. The acute fix is to bounce the repo-server pod so it reschedules off node6; the durable fix is the planned pi-hole → technitium migration. I rode it out this session — the rate-limit window cleared on its own once retry pressure dropped.

## What `mktxp.conf` looks like for two devices

```ini
[home-router]
    enabled = True
    hostname = 192.168.1.1
    port = 8728
    username = mktxp
    password = <REDACTED>
    use_ssl = False
    # ... plus per-collector booleans
    use_comments_over_names = True

[home-switch]
    enabled = True
    hostname = 192.168.1.220
    port = 8728
    username = mktxp
    password = <REDACTED>
    use_ssl = False
    # disable router-only collectors so the exporter doesn't
    # waste RPCs on empty tables
    dhcp = False
    pool = False
    route = False
    wireless = False
    # ...
    use_comments_over_names = True

[default]
    enabled = False
```

Block name = `routerboard_name` label on every metric, so `home-router` and `home-switch` get filterable separately in Grafana. The `[default]` block is mktxp's "reset all per-entry defaults" sentinel — leaving it `enabled = False` keeps it from being scraped as a phantom third device.

`fetch_routers_in_parallel = True` in `_mktxp.conf` lets the two scrapes run concurrently — at 30s scrape interval and ~5s socket timeout each, serial mode would risk overrunning the interval if the switch goes silent.

## RouterOS-side prereqs

Per device:

```routeros
/ip service set api address=192.168.1.0/24 disabled=no port=8728
/user group add name=prometheus policy=read,api,test,winbox
/user add name=mktxp group=prometheus password="<LONG_RANDOM>" comment="prometheus / mktxp"
```

The `read,api,test,winbox` policy is the minimum that mktxp's RPCs need. `test` is for the keepalive, `winbox` is for some metric paths that route through the Winbox protocol layer internally. No `write`, no `policy`, no `sniff` — read-only.

If the device has firewall rules on the management interface, `tcp/8728` from the cluster nodes (`192.168.1.7-9`) needs to be allowed.

Everything's documented inline in the chart README so the next person setting this up doesn't have to dig.

## Verification, end to end

```bash
# Pod up
oc -n mikrotik-exporter get pods                       # 1/1 Running
oc -n mikrotik-exporter logs deploy/mikrotik-exporter  # one 'scraping...' line per [entry]

# UWM scrape target healthy
oc -n openshift-user-workload-monitoring exec prometheus-user-workload-0 -c prometheus -- \
  wget -qO- 'localhost:9090/api/v1/targets?scrapePool=serviceMonitor/mikrotik-exporter/mikrotik-exporter/0'
# → health: up

# A real metric is flowing
oc -n openshift-user-workload-monitoring exec prometheus-user-workload-0 -c prometheus -- \
  wget -qO- 'localhost:9090/api/v1/label/__name__/values' | jq '.data[] | select(startswith("mktxp_"))'
# → mktxp_active_users_info, mktxp_collection_time_total, mktxp_dhcp_lease_*, ...
```

Grafana dashboard 13679 is provisioned by `grafana-config` and bound to the `Prometheus` datasource via the chart-level helper. It shows up under "MikroTik / mktxp" in the Grafana UI immediately after sync.

## Open items

- **Enable the RouterOS API on the switch.** Day-one rollout had only the router configured; the switch logged `Connection refused` once per scrape until its API was enabled. Pure operator-side action, not a chart change.
- **Disable `poe = True` on routers without PoE.** The home router is non-PoE; mktxp logs `'no such command prefix' executing command b'/interface/ethernet/poe/print'` once per scrape until the flag is flipped in the sealed config. Also pure operator-side.
- **Cosmetic migration warnings.** mktxp 1.2.17 wants to rewrite `mktxp.conf` on first run to migrate `use_comments_over_names → interface_name_format` and add new feature keys. The mount is `readOnly: true`, so it logs `[Errno 30] Read-only file system` and uses an in-memory translation. Functional; ignore. To silence: regenerate `mktxp.conf` from a fresh `mktxp config init` dump and re-seal.
- **TLS on the API.** mktxp supports `api-ssl` on `tcp/8729` once a cert is imported into RouterOS. The whole management VLAN is on a switch we own and the API user is read-only, so the cleartext exposure is small — but it's a hardening pass worth doing the next time the cert-manager → RouterOS path becomes interesting.

## Why I bothered with all of this

Three weeks of fio runs against Ceph generated lots of "is the network in the way?" follow-ups. Without `node_network_*` on the switch side it's all guessing. Now there's a graphable answer. The PoE / wireless / DHCP signals are bonus — and turn out to be useful for the upcoming pi-hole → technitium migration, where the switch is going to be the most stable observability point as boxes get swapped in and out.

Total session time: ~1 hour of chart writing, ~30 min of debug-and-fix on the four issues above. Cheaper than I'd guessed.
