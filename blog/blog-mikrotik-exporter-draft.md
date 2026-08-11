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

---

## 2026-08-10 — first real payoff: why the switch fans sit at 8.5k RPM

**Question that started it:** the CRS317's Health panel showed `fan1-speed 8580 RPM` / `fan2-speed
8430 RPM` with `cpu-temperature 37 C`. Why are the fans screaming when the CPU is cold?

The whole diagnosis was answered from `mktxp` series in UWM Prometheus, without touching the
switch. That is the payoff this chart was built for, so it belongs here.

### The Health panel, as observed

```
cpu-temperature  = 37 C          fan-state       = ok
fan1-speed       = 8580 RPM      psu1-state      = ok
fan2-speed       = 8430 RPM      psu2-state      = fail
sfp-temperature  = 69 C

Health > Settings:  Fan Full Speed Temp 65 | Fan Target Temp 58
                    Fan Min Speed Percent 1 | Fan Control Interval 00:00:30
```

`sfp-temperature 69` is above `fan-full-speed-temp 65`, so the controller is doing exactly what it
is configured to do. RouterOS drives the fan curve off the **hottest** monitored sensor (CPU / PHY /
SWITCH / SFP), not off `cpu-temperature` — so 37 C on the CPU is irrelevant. Worth noting: **65 is
the maximum value RouterOS accepts** for `fan-full-speed-temp`, so this is stock, and "just raise
the threshold" is not an available move.

### Which cage is hot — answered by `mktxp_interface_sfp_info`

Only one module on the switch reports DDM at all:

```promql
mktxp_interface_sfp_temperature{routerboard_name="home-switch"}
  → {name="Mac mini"} 68
```

`mktxp_interface_sfp_info` names it outright:

| Port comment          | Vendor      | Part            | Connector               |
|---|---|---|---|
| **Mac mini**          | MikroTik    | **S+RJ10**      | **RJ45**                |
| Reserved (Node 4 sto) | MikroTik    | XS+DA0001       | copper-pigtail (DAC)    |
| Reserved (Node 5 sto) | MikroTik    | XS+DA0001       | copper-pigtail (DAC)    |
| Reserved (Node 6 sto) | EXTRALINK   | EX.2275         | copper-pigtail (DAC)    |
| sfp-sfpplus1          | Ubiquiti    | DAC-SFP10-0.5M  | no-separable-connector  |

The `S+RJ10` is MikroTik's 10GBASE-T copper RJ45 transceiver — the one module class that dissipates
real power (single-digit watts vs. ~0.1 W for a passive DAC). The other four are all passive DACs,
which is also why only one temperature series exists: **a passive DAC has no DDM, so it reports no
temperature.** The absence of four series is not a scrape gap; it is the expected shape.

So: one active copper module heats the cage area, the board sensor next to it reads 69 C, and the
fan controller pins the fans. The three Ceph backnet links are DACs and contribute ~nothing.

### It is not new, and the firmware upgrade did not cause it

The obvious suspicion was the 2026-08-07 firmware upgrade (the same reboot that caused the
`br-ex.forwarding` outage — see `blog/blog-ovn-brex-forwarding-outage-draft.md`). The 15-day
retention window covers both sides of that boundary, and it refutes the idea outright:

```
sfp DDM temp, daily:  69 67 68 67 71 70 68 69 70 70 72 69 70 70 69
15d min/max:          64 C … 73 C
fan1 15d min/max:     4335 … 8595 RPM
```

No step change on 08-07 — the module has been sitting in the mid-to-high 60s for the entire window.
The fan swing is **diurnal**: the module straddles the 65 C threshold, dipping just under it in the
coolest hours (min 64 C → fans drop to 4335 RPM) and sitting above it the rest of the day (→ pinned
~8580). "The fans got loud" is ambient temperature moving a distribution that was always centred on
the threshold, not an event.

Incidental confirmation of the 08-07 outage: both series have a **hole at 08-07 ~14:23Z**, the
scrape blackout during the pod-egress break. The monitoring gap and the incident share a timestamp —
the same trap documented in the `br-ex` writeup.

### `psu2-state: fail` — a separate, non-thermal finding

`mktxp_system_psu2_state{routerboard_name="home-switch"}` reads `0` for **all 15 days**, and the
operator confirmed the cause: the second power cord is simply not plugged in. Worth being precise
about why the panel can't tell you that itself — the RouterOS field (`mtxrHlPowerSupplyState`) is a
boolean with no "absent" state, so "no mains on inlet 2" and "PSU is dead hardware" both render as
`fail`. The log discriminates (`PSU2 power input not detected` vs `PSU2 removed from the slot`); the
Health panel does not.

I briefly floated that an unpowered PSU might be reducing chassis airflow and thus *contributing* to
the SFP temp. The data kills that: `psu2_state` has been `0` across the entire window while the
module temperature stayed flat, so there is no before/after to attribute anything to. No source was
found either way on whether MikroTik PSUs contribute airflow — dropping the theory rather than
carrying it as folklore.

What remains true is the boring part: **this switch is single-corded, and it is the only path for
the Ceph storage backnet.** Given that a 3m40s link flap on it cost a 5-hour cluster-wide outage on
08-07, that is the finding worth acting on — not the fan noise.

### Conclusions

- Fans are **correct, not faulty**. The controller is saturated because a 10GBASE-T copper module
  parks the cage sensor above the maximum-permitted full-speed threshold.
- The lever that actually works is **removing the heat**: relocate/replace the `S+RJ10`, or improve
  ambient/airflow. Raising the threshold is both unavailable (65 is the ceiling) and wrong — the
  curve is already 11 C above `fan-target-temp` (58), meaning heat input exceeds what the fans can
  remove at 100%. Muting that signal is how you get an unplanned thermal event on the switch that
  carries the storage backnet.
- The Noctua NF-A4x20 swap costed in the vault is the wrong trade here: the vault's own note says it
  *raises* switch temperature ~3 C and to skip it under heavy SFP+ load. Quieter, hotter.
- **Gaps this exposed:** `mktxp` exports no `sfp-temperature` board sensor (only per-module DDM), and
  there are **zero PrometheusRules** for any mktxp metric — the chart ships a ServiceMonitor and
  dashboards but nothing that fires. Both queued in the README.

### 2026-08-11 follow-up — the port is also flapping, and heatsinks won't fix it

Two follow-ups to the above: an unprompted finding, and an evaluation of the obvious fix.

#### The `S+RJ10` port flaps, and the rate tracks temperature

`mktxp_link_downs_total` for the Mac mini port shows **266 link-down events over the 15-day
window** — by far the worst port on the switch:

```
link-down events per port, 15d:
  Mac mini      266        <- the S+RJ10
  ether1         62
  TrueNAS         7
  (Node 4/5/6 sto: zero)   <- the Ceph backnet DACs are clean
```

These are not a sleeping Mac. The port was **UP 99.93 % of the window**, so 266 events across
~15 minutes of total downtime is ~3.4 s each — PHY retraining, not a host powering down. Error
counters are all zero (`rx_error`, `tx_error`, `rx_drop` = 0), so nothing is being corrupted; the
link just re-negotiates.

Binning flap counts by module temperature:

```
mean flaps/2h, module >= 69 C : 3.24   (n=36)
mean flaps/2h, module <  69 C : 0.60   (n=47)
```

A 5.4x skew, and it holds *within* the last four days as well as across the whole window — the
drops cluster at 69-70 C and mostly vanish at 67-68 C. Temperature-dependent retraining is what a
thermally marginal 10GBASE-T link looks like.

**Two caveats I can't resolve from switch-side data.** The flap rate fell off sharply around
08-06/08-07 — roughly *eight hours before* the firmware reboot, so the upgrade doesn't explain it;
something changed at the Mac end or in the cabling. And correlation isn't causation: a marginal
cable would also flap more when warm. 10GBASE-T is unusually sensitive to cable category and length,
so the cable is a live alternative hypothesis.

#### The link is using 2.4 % of its rate

```
Mac mini port, 15d:   peak rx 241.3 Mbit/s | peak tx 77.0 Mbit/s
                      p99 rx  28.4 Mbit/s | avg rx 1.4 Mbit/s
```

Peak is 2.4 % of 10 Gbps. Gigabit would carry the observed peak with 4x headroom. Worth stating
plainly because it reframes every option below: the switch is burning ~2.7 W and its entire fan
budget to run a link whose measured ceiling fits comfortably in 1 Gbps.

#### Port position is already optimal

`mktxp_interface_default_name_info` puts the `S+RJ10` on **`sfp-sfpplus12`**, with `sfp-sfpplus11`
and `sfp-sfpplus13` both empty. MikroTik's guidance is not to seat these in adjacent ports — already
satisfied. **Relocating it within the chassis is not a lever**, which rules out the cheapest
physical option before spending anything.

#### Heatsinks: right mechanism, wrong magnitude

The barrel is genuinely convection-limited — forced air over the protruding nose measured **~15 C**
on a CRS317 + S+RJ10 (a taped-on 40 mm fan). So the nose *is* a real thermal path. But fins add
surface area, not air velocity, and area is the weak lever in still air. Measured passive clip-on
results:

| Source | Result |
|---|---|
| gilesthomas (charted, same module) | **3.5 C** |
| MikroTik forum, CRS326 | ~0-1 C |
| MikroTik forum, **CRS317 + S+RJ10r2 @ 71 C** | **null — heatsinks fitted, fans still ~8000 RPM** |

The "58 -> 42 C" figures on AliExpress-style wiki pages are content-farm fabrications; ignore them.

**Size the gap against our own numbers:** median DDM 69 C, and 64 C is empirically where the fans
drop (to 4335 RPM). So the median needs ~5 C and the 72 C days need ~8 C just to get *off* the
threshold; reaching `fan-target-temp` 58 needs ~11 C. Derating the 3.5 C reference for our ΔT regime
lands ~2-3 C. Not in the required class — and the one published test on this exact switch and module
is a null result.

There's also a feedback trap: cool it to 64 C, the fans drop to ~4335 RPM, thermal resistance rises,
and it drifts back to 65. Only an intervention with margin well past 11 C escapes that loop.

**Blast radius argues against it too.** Fitting clip-ons means reaching into a live front panel
directly beside the three Ceph backnet DACs. A fumbled DAC is a backnet flap, and the last one of
those cost a ~5 h cluster-wide outage.

#### The rate lever, and why it isn't a RouterOS change

Power scales with negotiated rate: **2.7 W at 10GBASE-T** (MikroTik's own figure) vs well under 1 W
at 1000BASE-T. Traffic volume is irrelevant — link-up dominates, which matches the flat 15-day
temperature trend.

But it **cannot be done switch-side**. MikroTik states verbatim for the `S+RJ10` that *"forced link
speeds and configurable link speed advertisements are not supported."* So capping has to happen at
the Mac (Settings -> Network -> Ethernet -> Details -> Hardware -> Configure Manually -> Speed), and
that disables autonegotiation, which the module wants. Reversible, but a non-zero chance of dropping
the link — and 1000BASE-T mandates autoneg by standard, so "manual 1G" behaviour here is genuinely
uncertain. Test it when a dropped link is cheap, not remotely.

#### Not a safety issue

`sfp-shutdown-temperature` is **95 C**. At 69 C, flat for 15 days, this is noise and (possibly) link
churn — not a risk of thermal shutdown. **"Do nothing" is a legitimate option** and worth naming as
such rather than defaulting to action.

#### The one measurement that settles it

Disable the Mac port for ~30 min and watch `sfp-temperature` + fan RPM:

```routeros
/interface ethernet disable sfp-sfpplus12     # then re-enable
```

That bounds the payoff of *every* module-side option — heatsink, fan, rate cap — at zero cost. If
killing the module's 2.7 W entirely doesn't take the fans off full speed, nothing done to that module
will. Caveat: a soft disable may not fully power down the PHY, so a positive result is definitive and
a null one is inconclusive.
