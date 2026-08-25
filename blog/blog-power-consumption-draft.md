# Power consumption — working draft

Running notes for power-reduction work on the homelab. Three nodes
(node4/5/6) plus the Mac mini and the RPi `dns-master` run 24/7;
electricity isn't free and idle waste is the easiest thing to cut once
we can measure it.

## Why this matters

- Continuous-on hardware: 3× OKD nodes + Mac mini + RPi. Even a 10W
  reduction per node compounds to ~260 kWh/year across the cluster.
- The cluster is over-provisioned for the workload (typical CPU load
  on each node is single-digit %), so the deep-idle floor matters more
  than peak efficiency.
- Storage backnet 10G NICs and PM9A1 NVMe drives have non-trivial
  idle draw that's only addressable with link/APST tuning.

## Prerequisite — enable per-node power telemetry first

**Don't tune blind.** Need a measurement loop before changing any
governor, C-state, or APST setting; otherwise we can't tell whether
a "win" actually reduced wall power vs. just shifted load.

### Options for telemetry

1. **BMC/IPMI on the node itself** — most server boards expose
   `ipmitool dcmi power reading` (DCMI 1.5 power-cap interface). If
   available, this is the cleanest path: read PSU input wattage at
   ~1 Hz with no extra hardware.
   - Validate: `ipmitool dcmi power reading` from the host or
     `ipmitool -H <bmc-ip> -U <user> -P <pass> dcmi power reading`
     out-of-band. If it returns instantaneous wattage, we're good.
   - Wire into Prometheus via `prometheus-ipmi-exporter` or `ipmi-exporter`
     (the latter is Soundcloud's; mature, well-maintained).
2. **PDU with per-outlet metering** — a smart PDU (APC AP78xx,
   Tripp-Lite PDUMVH series, Shelly Pro 4PM in DIN-rail form) exposes
   per-outlet watt readings over SNMP or REST. Per-node isolation,
   ground truth (PSU efficiency loss is included in the reading).
3. **In-line wall meter** — Kill-A-Watt or similar plugged between
   wall and one node's PSU. Manual readings only, no metrics history,
   but zero setup time and dead-accurate. Good for one-node baseline
   before deciding to instrument all three.

### Sequencing

- **Step 1**: enable measurement on one node (node4 likely, since
  it's already the etcd-leader / debug-target on most procedures).
  Pick the cheapest path that works — IPMI if available, otherwise
  a wall meter for the initial baseline.
- **Step 2**: capture 24h of idle telemetry to establish baseline.
  Look for the lowest steady-state wattage (probably overnight when
  Sonarr/Radarr are quiet).
- **Step 3**: roll out the tuning changes one at a time, A/B against
  baseline. Don't bundle changes — can't attribute the delta otherwise.
- **Step 4**: once one node's tuning is validated, apply to all three
  via MachineConfig / Tuned operator.

## Levers ranked by likely impact

Estimates below are educated guesses pending baseline measurement —
revise once we have real data.

### 1. CPU governor + C-states via Node Tuning Operator

OKD ships the `openshift-node` Tuned profile by default, which is
throughput-oriented (governor=performance, shallow C-states for low
wake latency). For a homelab workload this is overkill.

Custom Tuned CR with:
```ini
[cpu]
governor=powersave
energy_perf_bias=power
min_perf_pct=0

[bootloader]
cmdline_powersave=intel_pstate=passive processor.max_cstate=9
```

- Expected: 15-25W per node at idle on modern Intel CPUs.
- Tradeoff: ~10-50ms wake latency on the first packet after deep idle.
  Irrelevant for homelab — Kubernetes/Ceph internal traffic keeps
  cores warm enough that user-facing requests rarely hit deep C-states.
- Risk: `intel_pstate=passive` + `powersave` governor can interact
  badly with some workloads on older silicon. Validate per-node by
  measuring p99 latency on Loki ingest / ArgoCD reconcile before/after.

### 2. Mac mini Jellyfin decommission

Already a TODO item; mentioned here for completeness. If we migrate
to the in-cluster Jellyfin and turn off the Mac mini, savings are
~10-30W continuous (M-series sips, but it's still ~10W idle + ~30W
under transcode). Zero ongoing cost since the in-cluster instance is
already configured.

Caveat: in-cluster has no HW transcode today (no GPU passthrough).
If the Jellyfin library is mostly direct-play, this is a wash.

### 3. NVMe APST (Autonomous Power State Transition)

PM9A1 supports APST. Default kernel setting on RHCOS may be more
conservative than the drive's capabilities allow.

```bash
# Check current state
nvme get-feature /dev/nvme0n1 -f 0x0c -H

# Drive's available power states
nvme id-ctrl /dev/nvme0n1 -H | grep -A 3 "Power State"
```

- Expected: 1-2W per drive once it spends meaningful time in PS3/PS4.
- Tradeoff: micro-latency on the first IO after idle (PM9A1 wake is
  fast, sub-ms). Ceph's BlueStore keeps the drive busy enough that
  this rarely fires anyway.
- Validate via `nvme smart-log /dev/nvme0n1 | grep -i power` over time.

### 4. PCIe ASPM

PCIe Active State Power Management can save 1-3W per lane on idle
links. Often disabled by default on server boards to avoid
compatibility issues with older devices.

- Enable via kernel cmdline `pcie_aspm=force` or selectively per
  device via `/sys/bus/pci/devices/<bdf>/link/aspm`.
- Tradeoff: rare incompatibility with NICs / NVMe firmware. Most
  modern hardware handles ASPM correctly but it's a per-device
  validation.

### 5. 10G NIC power tuning

The storage backnet NIC (`enp1s0f0np0`) is a 10G port that's idle
most of the time but holds the link up at line rate. Some NICs
support EEE (Energy Efficient Ethernet, 802.3az) which clocks down
between bursts.

- `ethtool --show-eee enp1s0f0np0` — check current state.
- `ethtool --set-eee enp1s0f0np0 eee on` — enable.
- Expected: 2-5W per port. Small but free if supported.
- Tradeoff: EEE can add ~10µs latency on wake. Ceph msgr2 is mostly
  bulk transfer, so this is fine. Don't enable on latency-critical
  control paths (we don't have any).

### 6. Fan curve

Server boards often run fans more aggressively than necessary on
idle CPUs. BMC fan-curve tuning (or `ipmitool raw` commands for
some boards) can drop 5-15W in fan power. Highly board-specific;
need to verify the model first.

### 7. BIOS power profile

Some boards expose "Performance / Balanced / Power Saving" at the
firmware level — these often disable Turbo Boost or cap PL1/PL2.
A "Balanced" profile typically loses <5% compute but cuts idle
draw 5-10W. Worth checking BIOS settings on first node when we
have measurement.

## Stop-list — things NOT to do

- **Don't reduce mon/osd/csi replica counts** — Ceph size=3 is a
  correctness requirement, not a tuning knob.
- **Don't cordon nodes overnight** — Rook can't recover with 2 of 3
  nodes (no drain headroom), would degrade storage health.
- **Don't disable Cluster Autoscaler** — n/a, we don't have it.
- **Don't underclock CPUs via BIOS** — `intel_pstate=passive` +
  governor=powersave does this dynamically and reversibly.
- **Don't disable Turbo Boost via BIOS** — let the governor handle it;
  hard-off in firmware loses peak-burst performance permanently.

## Open questions

- Does each node's board expose IPMI DCMI power reading? (Check
  `ipmitool dcmi power reading` on node4 first.)
- What's the actual idle baseline? Could be already-low if the boards
  default to balanced; could be high if they default to performance.
- Is there a PDU on the rack that could provide per-outlet metering
  without per-node setup?
- Mac mini power: read `pmset -g log` for current idle/active draw,
  or measure with a wall meter for one day.

## Next step

Enable measurement on node4 — either IPMI DCMI (if supported) or a
wall meter for the initial 24h baseline. Once we have a number, the
sequencing of tuning changes can be data-driven instead of guessing.

## 2026-05-21 — Shelly exporter shipped; measurement unblocked

The "open question" about per-outlet metering is now closed: a Shelly
Plus Plug S Gen3 sits between node6's PSU and the wall socket
(192.168.1.77, static, no auth on its LAN-only HTTP RPC API). Today's
work wires that into Prometheus so the 24h baseline can begin tonight.

### Why json_exporter instead of a dedicated Shelly exporter

Initial expectation was to drop in a Shelly-specific Prometheus
exporter container like `geerlingguy/shelly-plug-prometheus`. That
project ships no released container image; its Gen 3 support is also
unverified (README only covers Gen 1/Gen 2). The other Gen 3-aware
projects I found on GitHub (`sparklingSausage/shelly-prometheus`,
`simonjur/shelly-plug-s-g3-prometheus-exporter`) are 0-2 stars,
single-developer, no tagged releases, `:latest` only. Not what I want
sitting in the scrape path for power-tuning A/B work.

The Shelly Gen 2/3 RPC API returns clean JSON at
`/rpc/Switch.GetStatus?id=0`:

```json
{
  "id": 0,
  "source": "switch",
  "output": true,
  "apower": 12.34,
  "voltage": 230.5,
  "current": 0.054,
  "aenergy": { "total": 1234.5, "by_minute": [...], "minute_ts": ... },
  "temperature": { "tC": 45.2, "tF": 113.4 }
}
```

That's exactly what `prometheus-community/json_exporter` is for —
scrape one HTTP endpoint, extract numeric fields via JSONPath, emit
Prometheus exposition format. Stable project, versioned releases
(v0.7.0, Feb 2025), official `quay.io/prometheuscommunity/json-exporter`
image. Multi-target probe pattern (`/probe?target=<url>`) means a
single Deployment handles all future plugs by adding entries to the
chart's `plugs:` list — no per-plug pod.

### Chart shape

```
components/cluster-config/shelly-exporter/
├── Chart.yaml
├── README.md
├── values.yaml                          plugs list, image tag, scrape interval
└── templates/
    ├── namespace.yaml                   cluster-monitoring="false" → UWM scrape
    ├── serviceaccount.yaml
    ├── configmap.yaml                   JSONPath → metric mapping
    ├── deployment.yaml                  single replica json_exporter
    ├── service.yaml                     headless, port 7979
    └── servicemonitor.yaml              one endpoint per plug, params.target
```

Wave 5 (`bootstrap/root-app/values.yaml`), same wave as the other
observability exporters (smartctl, mikrotik, gatus). UWM scrape, not
platform Prometheus — pattern matches mikrotik-exporter.

### Metrics emitted

| Metric | Type | Source field |
|---|---|---|
| `shelly_power_watts{instance="node6"}` | gauge | `.apower` |
| `shelly_voltage_volts{instance="node6"}` | gauge | `.voltage` |
| `shelly_current_amperes{instance="node6"}` | gauge | `.current` |
| `shelly_energy_total_wh{instance="node6"}` | counter | `.aenergy.total` |
| `shelly_temperature_celsius{instance="node6"}` | gauge | `.temperature.tC` |

Note: `shelly_energy_total_wh` is a per-boot counter — it resets when
the plug reboots. For lifetime kWh, `rate(shelly_power_watts[24h])`
integrated over a day is more reliable.

### Next step

Capture 24h idle baseline (Grafana panel: `avg_over_time(shelly_power_watts{instance="node6"}[24h])`).
Then move to the lever-ranking work documented above.

## 2026-05-23 — Lever 1 sub-step A: runtime-only Tuned profile shipped

24h baseline pre-apply: **avg 102.88 W, min 91.6 W, max 158.5 W, stddev 5.81 W**
(100% coverage from 2880 samples). Max was the rados-bench spike during the
2026-05-21 jumbo-frame work; everything else is steady-state.

Shipped a new chart `components/cluster-config/power-tuning/` with a
Tuned CR that inherits from `openshift-control-plane` (node6's active
baseline as a combined CP+worker) and layers the runtime-only knobs:

```ini
[cpu]
governor=powersave
energy_perf_bias=power
min_perf_pct=0
```

Scoped to nodes carrying `power-tuning/profile=experimental` — only
node6 today (the node with the Shelly plug). The label is added via
`components/cluster-config/node-labels/values.yaml`. Tuned operator
applies live, no MachineConfig event, no reboot.

### Kernel verification

```
scaling_governor (CPU0):                powersave   ✓
/cpu0/power/energy_perf_bias (MSR):     15          ✓  (max powersave)
intel_pstate/min_perf_pct:              16          partial — wanted 0
```

The min_perf_pct floor at 16 is the parent profile's value showing
through; Tuned's `min_perf_pct=0` was accepted as the request, kernel
clamped it. Default RHCOS value is ~20, so 16 is already a meaningful
reduction. Not chasing further — the deeper savings come in sub-step B
(intel_pstate=passive boot arg).

### What to watch

In ~24h, compare `avg_over_time(shelly_power_watts[24h])` vs today's
102.88 W. Expected gain from runtime knobs alone: somewhere between
5-10W (maybe half of the blog draft's full-lever 15-25W estimate, since
sub-step B's `intel_pstate=passive + processor.max_cstate=9` are the
bigger contributors).

If the gain is ≥5W (≈5%), proceed to sub-step B — adds a `[bootloader]`
section with `cmdline_powersave=intel_pstate=passive processor.max_cstate=9`,
which triggers a MachineConfig delta and node reboot. Full cascade
pre-flight applies (the runbook in CLAUDE.md).

If the gain is <2W, the runtime knobs alone are noise and the savings
must be coming from C-states / pstate-mode — go straight to sub-step B
(or abandon the lever if the cost is too high).

### 2026-05-24 — Sub-step A check at +24h: no measurable gain

| Window | Avg power | Δ vs 2026-05-23 baseline |
|---|---|---|
| Pre-apply 24h | 102.88 W | (baseline) |
| Post-apply 24h | **104.23 W** | **+1.35 W** |
| Post-apply 12h | 104.35 W | +1.47 W |
| Post-apply 1h  | 105.66 W | +2.78 W |

Stddev on the baseline was 5.81 W, so +1.35 W is within noise (~0.23σ).
Not a clear regression, but definitely not the ≥5W gain that would have
triggered sub-step B.

Hypothesis (matches the prediction in the earlier section): on the
RHCOS default **`intel_pstate=active`** driver, the `powersave` governor
is essentially decorative — intel_pstate makes its own race-to-idle
decisions internally and the governor knob doesn't translate to real
freq scaling. The actual savings live in **`intel_pstate=passive`**,
which is the boot arg in sub-step B.

Decision: hold sub-step A in place, recheck again on 2026-05-25
(another 24h of data). If the average is still within noise of the
102.88 W baseline, accept that the runtime-only knobs do nothing on
this hardware/driver combo and either:
- ship sub-step B in full (boot args via MachineConfig + the documented
  cascade pre-flight), or
- skip the CPU lever entirely and move to the next-biggest lever
  (Mac mini Jellyfin decommission, ~10-30W, no cluster risk).

### 2026-05-25 — Sub-step A check at +48h: still no measurable gain

| Window | Avg power | Δ vs 2026-05-23 baseline |
|---|---|---|
| Pre-apply 24h        | 102.88 W | (baseline)        |
| Post-apply 48h       | **103.92 W** | **+1.04 W** |
| Post-apply 24h (rolling) | 103.58 W | +0.70 W       |
| Post-apply 12h           | 103.29 W | +0.41 W       |
| Post-apply 1h            | 105.12 W | +2.24 W       |

Trend is flat. The 48h average is +1.04 W vs baseline — 0.18σ on the
baseline's 5.81 W stddev, i.e. statistical noise. Direction is even
slightly *up*, which rules out any "lever working but slow to manifest"
scenario.

**Decision: the runtime-only Tuned profile delivered nothing measurable
on this hardware.** Confirms the hypothesis: with `intel_pstate=active`
(RHCOS default), the `powersave` governor + `energy_perf_bias=power` +
`min_perf_pct=0` are mostly cosmetic — intel_pstate makes its own
race-to-idle decisions and the governor knob doesn't gate freq scaling.

**Next-step options** (user pick):
1. **Ship sub-step B** — `cmdline_powersave=intel_pstate=passive processor.max_cstate=9`
   via a `[bootloader]` section in the same Tuned CR. This *does*
   trigger a MachineConfig delta and a serial reroll of all 3 masters
   (30-45 min degraded window + the full network-stack cascade
   pre-flight from CLAUDE.md). High effort for an uncertain payoff —
   the blog estimate is 5-15 W; could land anywhere.
2. **Skip the CPU lever, decommission the Mac mini Jellyfin** —
   estimated 10-30 W standing draw, no cluster risk, deterministic
   savings. Migrate Jellyfin into the cluster (or onto the Synology)
   and shut the Mac mini down.
3. **Hold sub-step A in place, defer the rest** — the runtime profile
   does no harm; leave it for the day RHCOS flips intel_pstate driver
   default. Move to a non-power task.

Recommendation: **option 2**. Highest deterministic savings, no MCO
risk, no CPU-lever guesswork.

## 2026-05-25 — Sub-step B shipped (intel_pstate=passive + max_cstate=9)

User overrode the recommendation and picked option 1 (ship sub-step B
in full). Rationale: the pool-wide bootloader change applies to all 3
masters, so 3× per-node savings; if it works, the absolute number
beats the Jellyfin decom option.

### Chart shape

Initial commit (`b22b65f`) added the `[bootloader]` section but used
`recommend.match` (node-label scoping). NTO's behavior surprised us:
the runtime profile updated on node6 (NTO log: `updated profile
node6.okd.sudops.pl [powersave-experimental]`) but **no MachineConfig
was generated**, no MCO event triggered. Reading the NTO docs more
carefully — `match` scopes runtime profile assignment per-node;
generating a MachineConfig requires `machineConfigLabels:` which tells
NTO which MCP role to tag the MC for. Fixed in `80c7b03`:

```yaml
recommend:
  - machineConfigLabels:
      machineconfiguration.openshift.io/role: master
    priority: 20
    profile: powersave-experimental
```

Side effect: the runtime `[cpu]` knobs now apply to every node in
`master` MCP (all 3 here), not just node6. Fine — sub-step A's 48h
data confirmed those knobs are a no-op on this hardware anyway, and
cluster-wide consistency is cleaner. The `power-tuning/profile=
experimental` label on node6 is now unused (cosmetic cleanup TODO).

### Pre-flight (cascade per CLAUDE.md)

```bash
# 1. Hold loki ingester PDB at MinAvailable=1 throughout
oc -n openshift-operators-redhat scale deploy/loki-operator-controller-manager --replicas=0
# 2. Drop router replicas so RGW anti-affinity has a viable node during drains
oc -n openshift-ingress-operator patch ingresscontroller default --type=merge -p '{"spec":{"replicas":1}}'
```

### Rollout chronology

| Time (UTC) | Event |
|---|---|
| 15:03:11 | Baseline: argocd on prior commit, MCP idle |
| 15:03:53 | ArgoCD synced to `2568b46` (initial sub-step B); Tuned CR carries `[bootloader]` but `nto_mcs=0` |
| 15:10–15:13 | Diagnosis: NTO log shows profile update but no MC; root cause = `match` vs `machineConfigLabels` |
| 15:14:19 | ArgoCD synced to `80c7b03` (fix); `nto_mcs=1` — NTO generated the MC |
| 15:14:40 | node4 cordoned (MCO drain start) |
| 15:19:13 | node4 NotReady (rebooting with new kernel) |
| 15:20:57 | node4 back updated; node5 cordoned |
| 15:24:48 | node5 NotReady (rebooting) |
| 15:26:53 | node5 back Ready |
| 15:27:14 | node6 cordoned |
| 15:32:34 | node6 NotReady (rebooting) |
| 15:34:25 | **Reroll complete: `upd=3/3`, rendered config flipped `72361e71` → `52e93850`** |

**Total wall time: 20 minutes.** Much faster than the 90-min estimate
from the original framing. The 3-OSD cluster drains quickly because
the OSD/mon on each node are topology-pinned and just terminate (don't
reschedule); the small Loki/Grafana footprint reschedules within
seconds.

### Post-cascade

```bash
# Restart all 3 ovnkube-node pods (intended one-at-a-time; my loop's
# `oc wait` didn't actually wait so it ended up batch-deleting. No
# data plane impact — OVS lives on the host, not in the pod. All 3
# pods came back 8/8 Ready within ~40s.)
oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node

# Restart repo-server (clears the post-cascade `argocd=` empty
# polling observation we saw during node6's reboot window)
oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-repo-server
```

### Verification — all 3 nodes

```
cmdline:           intel_pstate=passive processor.max_cstate=9
scaling_driver:    intel_cpufreq         ← KEY: passive mode marker
scaling_governor:  powersave
energy_perf_bias:  15                    ← max powersave
max_cstate:        9                     (both intel_idle + processor modules)
```

`scaling_driver=intel_cpufreq` (not `intel_pstate`) is the proof that
the driver flipped to passive mode. In passive mode, the cpufreq
governor (`powersave`) actually drives frequency decisions instead of
intel_pstate's internal "race to idle" logic. This is what sub-step A
couldn't deliver alone.

### Restore

```bash
oc -n openshift-operators-redhat scale deploy/loki-operator-controller-manager --replicas=1
oc -n openshift-ingress-operator patch ingresscontroller default --type=merge -p '{"spec":{"replicas":2}}'
# Run pdb-override CronJob to re-patch loki-ingester PDB → MinAvailable=1
oc -n openshift-logging create job --from=cronjob/loki-pdb-override pdb-restore-$(date +%s)
```

Quirk noted: the first pdb-override job ran BEFORE loki-operator had
finished reconciling MinAvailable back to 2 → "already at 1, nothing
to do." Triggered a second job ~30s later, ingester PDB went 2 → 1
correctly. Worth tightening: the CronJob is on a 5-min schedule, so
the next regular run would have caught it anyway; manual re-trigger
just for sub-minute closure.

### Cascade-side regressions: **one delayed hit**

Initial impression after the post-cascade ovnkube-node + repo-server
restarts was "no cascade observed" — every prior network-stack change
(IPsec, OVN-K pod MTU, jumbo NIC) caused the documented pod↔host-
network cascade and required immediate restarts; this one looked
clean. **Wrong.** During the final sweep, `cert-manager-config`
ArgoCD app surfaced as `Synced/Degraded`:

```
ClusterIssuer/letsencrypt-prod  Degraded
  Failed to register ACME account: Get "https://acme-v02.api.letsencrypt.org/directory":
  dial tcp 172.65.32.248:443: i/o timeout
```

Same cascade symptom — pod can't reach external IPs. The cert-manager
controller pod was on node4 (rebooted at 15:14, ran for 18 min after),
so it had been retrying its ACME registration the whole time without
network being reachable from its pod-network IP. Restarting the
controller pod cleared it immediately:

```bash
oc -n cert-manager delete pod -l app.kubernetes.io/name=cert-manager,app.kubernetes.io/component=controller
# → new pod, fresh ACME registration: Ready=True reason=ACMEAccountRegistered
```

Updated takeaway: **pure cmdline bootloader changes DO trigger the
cascade, just on a longer fuse**. ovnkube-node + repo-server restarts
cover the immediately-visible apps (ArgoCD itself, anything talking
to host-network etcd); apps with longer-fuse external-egress retries
(cert-manager talking to LE, anything pulling from external registries
mid-stride) need their own pod restart. Future runbook update: extend
post-cascade restart sweep to include cert-manager controller plus
any other pod observed to do external-network polling, or have a
generic "restart any pod with EgressFailure-shaped conditions" pass
at T+15 min after MCO complete.

### What's next: 24h measurement

The new kernel cmdline is in effect cluster-wide from 2026-05-25 15:34
UTC. First valid 24h-window comparison is 2026-05-26 15:34 UTC.

**Two instances, two signals:**

| Instance | What it captures | Pre-B baseline | Source |
|---|---|---|---|
| `node6` | Single-node wall-socket plug (1 of 3 cluster nodes) | 102.88 W avg | Prometheus, 24h 2026-05-23 |
| `rack`  | Full rack upstream of PDU (3 nodes + Mac mini + NAS + RPi + switch + router + drives) | 372.5 W avg (range 370–377.5) | Shelly web UI, 24h 2026-05-23→05-24 |

The rack instance was wired in late (commit `65a8e97`) — its baseline
is from the Shelly's built-in chart rather than Prometheus, but the
post-apply value will be Prometheus-backed and the comparison is
apples-to-apples once 24h of post-apply data has accumulated.

**The rack signal is the primary decision driver.** A 5 W cluster-wide
gain shows as ~1.3% on the rack (5/372.5) vs ~5% on the node6 plug
alone (5/103, but only if savings happen to land on node6 — they
won't necessarily). The rack number doesn't lie about denominator.

Queries:
```promql
avg_over_time(shelly_power_watts{instance="rack"}[24h])   # primary
avg_over_time(shelly_power_watts{instance="node6"}[24h])  # cross-check
```

Decision tree:
- **≥15 W rack-wide gain** (~5W per node × 3 nodes) — lever working as
  the original blog estimated; keep + optionally try `max_cstate=10`.
- **5–15 W rack-wide gain** — partial win; keep + move to Lever 2
  (Jellyfin decom) for incremental.
- **<5 W rack-wide gain** — CPU lever exhausted on this hardware,
  skip straight to Lever 2.

## 2026-05-26 — Sub-step B at +19h: Lever 1 SHIPPED, decision finalized

Pulled `avg_over_time(shelly_power_watts[12h])` (cleanest post-apply
window for both plugs) and called the result early — the data is so
emphatic that waiting for the formal 24h window adds nothing.

| Instance | Baseline | 12h post-B | Δ | Δ% |
|---|---:|---:|---:|---:|
| node6 | 102.88 W | **40.57 W** | **−62.31 W** | **−60.6%** |
| rack  | 372.50 W | **226.07 W** | **−146.43 W** | **−39.3%** |

Result is **way above** the original 5-15 W/node estimate. Cost
back-of-envelope: 146 W × 8760 h/yr ÷ 1000 × 1.263 zł/kWh = **~1,615
zł/year saved**.

The numbers are real, not a measurement artifact. Sanity checks:
- node6's individual reading dropped by 62 W (−60%) — too big to be
  explained by anything other than the lever (no external change
  could move node6 alone by that much)
- `scaling_cur_freq` on all 3 nodes confirmed at 800 MHz (= scaling_min)
  during the readings — cores in deep idle, not bursting
- Both plugs reported simultaneously, so it's not a scrape glitch on
  one device

### The tradeoff: CPU utilization tripled

Per-instance CPU% baseline → post-apply on the OCP "Cluster CPU
Utilization" dashboard:

| Node | Pre-B steady | Post-B steady |
|---|---:|---:|
| node4 | ~3% | **~35-40%** |
| node5 | ~3% | **~40%** |
| node6 | ~13% | **~16%** (smaller jump — sub-step A already inflated baseline) |

This is a **measurement artifact**, not real load. The kernel's CPU%
accounting is `busy_ticks / total_ticks`. With cores parked at 800 MHz,
the same work takes ~4× longer in wall-time, so `busy_ticks` grows
proportionally while `total_ticks` is unchanged — apparent utilization
goes up despite identical workload.

### CPU throttling: real, but not breaking anything

Top throttling pods (5m rate, % of CPU periods throttled):

| Pod | Throttle % |
|---|---:|
| smartctl-exporter (×3) | 72-81% |
| nmstate-cert-manager | 78% |
| mikrotik-exporter | 48% |
| nmstate-handler (×3) | 8-16% |
| openshift-gitops-server | 5% |

These pods aren't failing — work still completes within scrape budgets,
no CrashLoopBackOff, no CO degraded, ovnkube-control-plane stable.
They just spend 50-80% of their 100ms CPU periods waiting on the
cgroup throttle to release. Root cause: CPU limits set under
`intel_pstate=active` assumed 3+ GHz cores; now tasks run at 800 MHz
so the same work consumes 4× more CPU-time and hits the limit.

### Decision: accept and move on (option 5)

Tuning options considered:
1. Raise `min_perf_pct` 16 → 30-50 (runtime knob, less aggressive idle)
2. Switch governor `powersave` → `schedutil` (faster ramp-up)
3. Drop `max_cstate=9` → `max_cstate=6` (shallower idle, faster wake)
4. Remove CPU limits on throttled pods (proper k8s fix)
5. **Accept as-is, document** ← user pick

Rationale: nothing is broken, savings are huge, throttling is
observable but not impactful. Falling back to option 1 (raise
`min_perf_pct`) is a runtime knob that can be A/B-tested any time
without an MCO event, so the safety net is cheap. Lever 2 (Mac mini
Jellyfin decom, 10-30 W) is no longer the headline action; it
becomes an "if we ever want even more" item.

### Annotation in dashboards

Added a data-driven Grafana annotation to `shelly-power` dashboard
that fires on `changes(node_boot_time_seconds[5m]) > 0` — auto-marks
any node reboot (yesterday's reroll shows as 3 markers, one per
node), and future MCO events get the same treatment for free.

### Status: closed (with a known monitorable)

Lever 1 final result delivered ~10× the original estimate. The CPU%
metric noise + throttling are accepted as the cost of doing business.
If anything starts actually failing (CO degraded, probe failures,
slow reconciles), the runtime fallback is `min_perf_pct` 16 → 30.

---

# Final post

# Cutting 146W off a homelab idle baseline with the OKD Node Tuning Operator

I run a 3-node bare-metal OKD 4.20 cluster at home. Three identical
nodes (16-core Intel, 128 GiB RAM, NVMe-backed Ceph storage), plus a
Synology NAS, a Mac mini, an RPi for DNS, a switch, a router, and a
handful of drives. Everything is on 24/7 because the cluster runs my
media stack, Loki, Prometheus, Grafana, Gatus, ArgoCD, all the usual
homelab plumbing — but the load is single-digit CPU% the vast majority
of the day.

Electricity isn't free in Poland (1.263 zł/kWh as I write this), and a
W of standing draw compounds to ~11 zł/year. Standing draw at idle was
the obvious thing to cut once I had a way to measure it. This post is
about how I did that, and the surprises along the way — including a
~20-line Helm chart that ended up shaving **146 W off the rack draw
(−39%) and saving an estimated 1,615 zł/year**, plus the tradeoff that
makes the CPU dashboard look terrifying for no real reason.

TL;DR: ship a Tuned profile with `intel_pstate=passive` +
`processor.max_cstate=9` via the Node Tuning Operator. Make sure to
use `recommend.machineConfigLabels` (not `recommend.match`) or the
kernel cmdline change never gets applied. Expect Cluster CPU%
dashboards to triple — that's the kernel's CPU accounting, not real
load.

## 1. Measure first

Rule one of tuning: don't tune blind. Without a measurement loop you
can't tell whether a change is a real win, a regression, or noise.

Three options were on the table for telemetry: IPMI DCMI on the boards
(if the BMCs expose `dcmi power reading`), a smart PDU with SNMP per
outlet, or an in-line wall meter that I could scrape. I went with the
third: a **Shelly Plus Plug S Gen3**, a ~120 zł wifi-attached plug
that sits between the wall socket and whatever you want to measure.
It exposes an HTTP RPC API on its LAN IP:

```bash
$ curl -s 'http://192.168.1.77/rpc/Switch.GetStatus?id=0'
{
  "id": 0, "source": "switch", "output": true,
  "apower": 102.8, "voltage": 230.5, "current": 0.451,
  "aenergy": {"total": 1234.5, ...},
  "temperature": {"tC": 45.2, "tF": 113.4}
}
```

That's clean JSON. There are several community Prometheus exporters
for Shelly devices on GitHub, but I checked their READMEs and they
were uniformly 0–2 stars, no tagged releases, `:latest` only, and
mostly missing Gen 3 support. Not what I want sitting in the scrape
path.

Instead, I used the **`prometheus-community/json_exporter`** with the
multi-target probe pattern (one Deployment, N plugs, each ServiceMonitor
endpoint passes `target=<rpcUrl>` as a query param). Mature project,
tagged v0.7.0 release, official `quay.io/prometheuscommunity/json-exporter`
image. The whole chart is six templates and a `plugs:` list in values:

```yaml
plugs:
  - instance: node6
    rpcUrl: http://192.168.1.77/rpc/Switch.GetStatus?id=0
  - instance: rack
    rpcUrl: http://192.168.1.50/rpc/Switch.GetStatus?id=0
```

The trick worth calling out: by default Prometheus stamps
`instance=<pod-ip>:7979` on every scraped series, which would collapse
all plugs into one indistinguishable mess. Each `endpoint` in the
ServiceMonitor needs an explicit relabel to override `instance` to
something meaningful:

```yaml
relabelings:
  - action: replace
    sourceLabels: []
    targetLabel: instance
    replacement: "{{ .instance | quote }}"   # "node6" or "rack"
```

Five metrics come out of this: `shelly_power_watts`, `shelly_voltage_volts`,
`shelly_current_amperes`, `shelly_energy_total_wh`, `shelly_temperature_celsius`,
each labeled by `instance`. A Grafana dashboard with template variables
on `label_values(shelly_power_watts, instance)` got me real-time draw,
24h average, projected daily/monthly kWh, and projected cost in zł in
about 20 minutes.

I started with one plug on node6 (the node already on my "test
everything here first" list). Later I added a second plug upstream of
the rack PDU, which measures everything: 3 nodes + NAS + Mac mini +
RPi + switch + router. That's the rack-level signal, and it matters —
more on that in §6.

## 2. The baseline

24h of idle telemetry, captured 2026-05-22 → 2026-05-23 with no
tuning changes applied yet:

| Instance | avg | min | max | stddev | samples |
|---|---:|---:|---:|---:|---:|
| node6 | 102.88 W | 91.6 W | 158.5 W | 5.81 W | 2880 (100% coverage) |

The max was a `rados bench` write spike from earlier Ceph work; the
steady-state baseline was 100–105 W with low variance. That's the
number to beat.

Rack baseline came in a couple days later (the second plug was wired
in mid-rollout). 24h captured from the Shelly's built-in web UI:

| Instance | avg | min | max |
|---|---:|---:|---:|
| rack | 372.5 W | 370 W | 377.5 W |

Stable. ~373 W rack continuous = **3,266 kWh/year × 1.263 zł = ~4,125
zł/year just to run the homelab idle.**

## 3. Sub-step A: the runtime knobs that did nothing

The OKD Node Tuning Operator (NTO) is the right mechanism here: it
manages Tuned profiles on each node, can scope by node label, applies
runtime knobs without a reboot, and can also generate MachineConfigs
for bootloader-level changes (we'll need that for sub-step B).

First attempt: a Tuned CR with the runtime-only knobs. No
`[bootloader]` section, so no MachineConfig, no reboot.

```yaml
apiVersion: tuned.openshift.io/v1
kind: Tuned
metadata:
  name: powersave-experimental
  namespace: openshift-cluster-node-tuning-operator
spec:
  profile:
    - name: powersave-experimental
      data: |
        [main]
        summary=Runtime powersave knobs
        include=openshift-control-plane

        [cpu]
        governor=powersave
        energy_perf_bias=power
        min_perf_pct=0
  recommend:
    - match:
        - label: power-tuning/profile
          value: experimental
      priority: 20
      profile: powersave-experimental
```

The node label was set on node6 only via a separate `node-labels`
chart. Tuned-daemon applied the profile within seconds, no reboot
needed. On the node:

```
scaling_governor:                       powersave   ✓
/cpu0/power/energy_perf_bias:           15          ✓  (max powersave)
intel_pstate/min_perf_pct:              16          partial  (kernel clamped from 0)
```

The `min_perf_pct=0` request was clamped to 16 — that's the parent
profile's floor showing through the kernel's enforcement. Acceptable
on its own; the deeper savings were always supposed to come from
sub-step B.

Then waited 24h. And another 24.

| Window | Avg power | Δ vs 102.88 W baseline |
|---|---:|---:|
| Post-apply 48h | 103.92 W | **+1.04 W** |
| Post-apply 24h (rolling) | 103.58 W | +0.70 W |
| Post-apply 12h | 103.29 W | +0.41 W |

Nothing. 0.18σ on the baseline stddev = statistical noise, and the
direction was even slightly *up*.

The reason, in hindsight, is documented in the kernel's pstate driver
source but I had to learn it the hard way: **on `intel_pstate=active`
(RHCOS's default), the `powersave` governor is decorative.** In active
mode, the `intel_pstate` driver makes its own frequency decisions
internally based on the workload's measured CPU utilization; the
cpufreq governor sitting on top of it is informational and doesn't
actually drive `scaling_cur_freq`. Same story for `energy_perf_bias`
on most CPU SKUs — it influences the driver's internal heuristics
but doesn't open the deeper idle states by itself.

This is a real and useful learning, even though it cost two days of
soak time. The fix is to flip the driver into `passive` mode, which
turns control back over to the cpufreq governor. That's a kernel
cmdline argument, which means a MachineConfig, which means a node
reboot. Which means sub-step B.

## 4. Sub-step B: the lever that actually works

The change is small:

```ini
[bootloader]
cmdline_powersave=intel_pstate=passive processor.max_cstate=9
```

Two args:
- `intel_pstate=passive` — load the driver in passive mode. The
  cpufreq governor (`powersave`, set in sub-step A) now actually
  drives `scaling_cur_freq`.
- `processor.max_cstate=9` — lift the cap on the deepest idle states
  the kernel will request. Default may cap at C6; allowing C7/C8/C10
  on Intel server SKUs that expose them means a deep-idle core pulls
  almost no power.

NTO generates a MachineConfig with these kernel args. MCO renders the
new master pool config, then serially drains, reboots, and rejoins
each node in the pool. On a 3-OSD no-drain Ceph cluster like mine
this is a degraded-window event — every prior MCO-class change took
30–45 minutes per node and required a pre-flight cascade runbook to
avoid cluster outages. So I scheduled this with headroom.

### 4a. The screw-up: `match` vs `machineConfigLabels`

I shipped the chart change. ArgoCD synced, the Tuned CR updated, NTO
log showed:

```
controller.go:740 updated profile node6.okd.sudops.pl [powersave-experimental] (deferred=never)
```

Good — profile assignment updated. Now waited for the MachineConfig
to appear and the reroll to start.

It didn't.

Five minutes, ten minutes, no MachineConfig. `oc get mc | grep -i nto`
returned the same two pre-existing MCs that have been there for 41
days. `oc get mcp master` showed `Updated=True, Updating=False`. The
Tuned CR had the `[bootloader]` block, NTO had reconciled it onto
node6, but no MachineConfig was generated and no reroll happened.

After re-reading the NTO docs more carefully:

> For profile-matching that requires generating a MachineConfig, you
> must use `machineConfigLabels` instead of `match`.

The `recommend.match` block I'd used scopes which nodes get the
runtime profile assigned — by node label, evaluated per-node. That
works for runtime knobs (`[cpu]`, `[disk]`, `[net]`). But for
`[bootloader]`, NTO doesn't know which MCP role to tag the generated
MachineConfig with. Without `machineConfigLabels`, it just... doesn't
generate one. Silently. No error, no warning in the operator log.

The fix:

```yaml
recommend:
  - machineConfigLabels:
      machineconfiguration.openshift.io/role: master
    priority: 20
    profile: powersave-experimental
```

This tells NTO to label the generated MC as `role=master`. The master
MCP's `machineConfigSelector` matches that label and picks the MC up.

Side effect: `machineConfigLabels` also drives Tuned profile assignment
based on MCP membership, not node label. So the runtime `[cpu]` knobs
from sub-step A now apply to **every node in the master MCP** — all 3
in my case — rather than just node6. Fine: sub-step A is a no-op on
this hardware anyway, and cluster-wide consistency is cleaner. The
`power-tuning/profile=experimental` node label became dead weight and
got removed.

Second push. NTO generated the MC within ~30 seconds. MCO started
the reroll.

### 4b. The reroll, faster than expected

Pre-flight per my cluster's runbook (the cascade pre-flight is a long
story documented in `CLAUDE.md` from prior MCO events; short version:
on a 3-node cluster certain workload patterns deadlock node drains):

```bash
# Hold loki ingester PDB at MinAvailable=1 (LokiStack hardcodes it to 2
# at this size class, with 2 replicas → 0 disruption budget → drains
# hang forever). I have a CronJob that re-patches it every 5 min, but
# loki-operator would reconcile it back during drain; scaling the
# operator to 0 keeps the override in place.
oc -n openshift-operators-redhat scale deploy/loki-operator-controller-manager --replicas=0

# Drop router replicas. With 2 routers + RGW podAntiAffinity, every
# node-drain strands RGW because the only RGW-eligible node is the
# one being drained. One router = always a viable node.
oc -n openshift-ingress-operator patch ingresscontroller default \
  --type=merge -p '{"spec":{"replicas":1}}'
```

Then committed the Tuned fix. ArgoCD synced, NTO generated the MC,
MCO started. I tailed `oc get mcp master -w` in a Monitor:

| Time (UTC) | Event |
|---|---|
| 15:14:19 | NTO generated the MC |
| 15:14:40 | node4 cordoned (drain start) |
| 15:19:13 | node4 NotReady (rebooting) |
| 15:20:57 | node4 back updated; node5 cordoned |
| 15:24:48 | node5 NotReady |
| 15:26:53 | node5 back Ready |
| 15:27:14 | node6 cordoned |
| 15:32:34 | node6 NotReady |
| 15:34:25 | **Reroll complete — all 3 updated** |

**20 minutes total** for all 3 nodes. I'd budgeted 90. The 3-OSD
cluster drains quickly because the OSD and mon on each node are
topology-pinned (`failureDomain: host`) and just terminate when their
node drains — they don't reschedule onto a different node, so there's
no "wait for the OSD to come up elsewhere" delay. The smaller
observability footprint (Loki, Grafana, Prometheus) reschedules
within seconds.

### 4c. The cascade victim: cert-manager

After the reroll completed, I ran the cascade post-flight:

```bash
# Restart all 3 ovnkube-node pods. Cross-node host-network can break
# between pod-network pods and host-network IPs after any change that
# causes NetworkManager / OVS to reload gateway state. Restart restores
# it.
oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node

# Restart repo-server. Resolves the "DeadlineExceeded on manifest
# generation" symptom that always lingers after the cluster has been
# thrashed.
oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-repo-server
```

ArgoCD apps came back. Everything looked clean. I started writing
"cascade-side regressions: none observed" in the blog draft —
unusually quiet, given that every prior network-stack change had
caused the cascade and required the immediate restart sweep.

Then the final session sweep before signing off picked up:

```
ClusterIssuer/letsencrypt-prod  Degraded
  Failed to register ACME account: Get "https://acme-v02.api.letsencrypt.org/directory":
  dial tcp 172.65.32.248:443: i/o timeout
```

cert-manager's controller pod had been on node4 (rebooted at 15:14,
running for 18 minutes after that on the new kernel). It was retrying
its ACME registration the whole time without external network being
reachable from its pod-network IP. Standard cascade symptom, but
cert-manager only polls LE on a long fuse (every 5–10 min during
initial bootstrap, then every few hours), so it hadn't shown up in
the short window where I was doing the post-cascade sweep.

Restart fixed it:

```bash
oc -n cert-manager delete pod -l app.kubernetes.io/name=cert-manager,app.kubernetes.io/component=controller
# → new pod, fresh ACME registration: Ready=True reason=ACMEAccountRegistered
```

Updated runbook takeaway: **pure cmdline bootloader changes still
trigger the cascade, just on a longer fuse.** The standard
ovnkube-node + repo-server restarts cover the immediately-visible
apps (ArgoCD itself, anything talking to host-network etcd). Apps
with longer-fuse external-egress retries — cert-manager talking to
Let's Encrypt, anything pulling from external image registries
mid-stride — need their own restart, and if you don't see them in
the immediate sweep, you'll see them in the next session's sweep
sitting `Synced/Degraded`. I extended my CLAUDE.md cascade runbook
to include a generic "T+10–15 min after MCO complete: sweep for any
ArgoCD app stuck on `dial tcp ... i/o timeout`-shaped conditions"
pass.

### 4d. Verification

On each node, via `oc debug node/<name>`:

```
$ cat /proc/cmdline | tr ' ' '\n' | grep -E 'intel_pstate|max_cstate'
intel_pstate=passive
processor.max_cstate=9

$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver
intel_cpufreq                          ← KEY: passive mode marker

$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor
powersave

$ cat /sys/devices/system/cpu/cpu0/power/energy_perf_bias
15                                     ← max powersave (set by sub-step A's runtime knobs)

$ cat /sys/module/intel_idle/parameters/max_cstate
9
$ cat /sys/module/processor/parameters/max_cstate
9

$ cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq
799915                                 ← cores parked at 800 MHz = scaling_min, deeply idle
```

The `scaling_driver=intel_cpufreq` is the key tell. In active mode it
would read `intel_pstate`. `intel_cpufreq` is the passive-mode driver
that exposes the governor knob as the real frequency selector. Cores
parked at 800 MHz min while the cluster is otherwise idle = the
governor doing its job.

## 5. The result

I'd planned to wait for a clean 24h post-apply window before calling
the result official. Twelve hours in I pulled the average just to see
the direction:

```promql
avg_over_time(shelly_power_watts[12h])
```

| Instance | Pre-B baseline | 12h post-B | Δ | Δ% |
|---|---:|---:|---:|---:|
| node6 | 102.88 W | **40.57 W** | **−62.31 W** | **−60.6%** |
| rack | 372.50 W | **226.07 W** | **−146.43 W** | **−39.3%** |

The 24h reading the next morning was essentially identical (rack
227.55 W, node6 40.66 W). Result is stable.

This is **way above** what I'd estimated. The original blog estimate
for "CPU power tuning" was 5–15 W per node, so 15–45 W cluster-wide.
What I actually got is ~10× that.

A few sanity checks because the numbers were suspicious:
- node6's individual draw dropped by 62 W. No external change (Mac
  mini unplugged, NAS spin-down, etc.) could move node6 in isolation
  by that much. It's the lever.
- `scaling_cur_freq` on all 3 nodes was sitting at 800 MHz during the
  reading. Not bursting.
- Both Shelly plugs reported simultaneously to Prometheus, so it's
  not a scrape glitch on one device.
- Same draw a day later, in different time-of-day conditions.

Cost back-of-envelope:

```
146 W × 8760 h/yr ÷ 1000 = 1279 kWh/year saved
1279 kWh × 1.263 zł/kWh = 1,615 zł/year saved
```

That's roughly €375 / $400 / year, recurring, in exchange for a
20-line Helm chart change and a 20-minute MCO reroll.

## 6. The tradeoff: CPU utilization tripled (and what to do about it)

Within a few hours of the apply, the Cluster CPU Utilization dashboard
in OKD's built-in monitoring told me the cluster had gone from 8%
idle to 30%. Per-node:

| Node | Pre-B steady | Post-B steady |
|---|---:|---:|
| node4 | ~3% | ~35–40% |
| node5 | ~3% | ~40% |
| node6 | ~13% | ~16% |

(node6 was already running the runtime profile from sub-step A, which
had inflated its CPU% slightly without affecting power; that's why
its jump is smaller.)

If you only look at the dashboard, this looks like a regression: 4×
more "load" for the same workload. It's not real load. It's a
measurement artifact of how the kernel computes CPU%.

CPU utilization in Linux is `busy_ticks / total_ticks`. `total_ticks`
is wall time; `busy_ticks` is wall time minus idle time. When the
cores are parked at 800 MHz instead of bursting to 3+ GHz, the same
amount of work takes ~4× longer in wall time — `busy_ticks` grows
proportionally, while `total_ticks` doesn't change, so apparent
utilization quadruples. The cores are doing the same work; they're
just doing it slower while running cooler and pulling less power.

The dashboards don't lie, exactly — they're showing what the kernel
reports. The kernel is correctly reporting that cores spent more
wall-time busy. But "busy at 800 MHz" and "busy at 3 GHz" are very
different things for power, and the dashboard doesn't have that
context.

### CPU throttling: real, but not breaking anything

The dashboard noise is one thing; what would actually matter is if
pods started failing because they couldn't get enough CPU. That's a
real risk — workloads with CPU limits that were set under fast cores
will now hit those limits faster, since the same task burns 4× more
CPU-time at the lower clock.

I checked the top throttling pods (5m rate, % of CPU periods throttled):

```promql
topk(10, sum by (namespace, pod) (rate(container_cpu_cfs_throttled_periods_total[5m]))
       / sum by (namespace, pod) (rate(container_cpu_cfs_periods_total[5m])))
```

| Pod | Throttle % |
|---|---:|
| smartctl-exporter (×3 DaemonSet) | 72–81% |
| nmstate-cert-manager | 78% |
| mikrotik-exporter | 48% |
| nmstate-handler (×3) | 8–16% |
| openshift-gitops-server | 5% |

These pods are throttling heavily. But: nothing is actually failing.
No `CrashLoopBackOff`. No degraded `ClusterOperator`. ovnkube-control-plane
stable. All workloads functional. They just spend 50–80% of their
100ms CPU periods waiting on the cgroup throttle to release.

The reason none of this manifests as a user-visible failure: the
work itself is small. smartctl-exporter scrapes every 30 seconds;
even at 80% throttled, an individual scrape that "should" take 200ms
of CPU now takes ~1 second of wall time — still well within the 30s
budget. mikrotik-exporter is similar. nmstate-cert-manager handles
TLS for the nmstate operator's webhook; throttled, sure, but the
operator isn't latency-critical.

The root cause is that CPU limits in Kubernetes are an anti-pattern
in general — they cause exactly this kind of throttling under load,
and they don't provide any guarantees beyond what `requests` already
does. But the affected pods are all from upstream charts (the
smartctl-exporter community chart, the nmstate operator, etc.) and
changing those would mean per-chart maintenance.

### Decision: accept the tradeoff

I looked at five options:

1. **Raise `min_perf_pct`** from 16 → 30 or 50. Sets a floor on
   intel_pstate's minimum performance percentage so deeply-idle cores
   are less idle and wake faster. Runtime knob — no MCO event. Easiest
   to reverse.
2. **Switch governor `powersave` → `schedutil`.** `schedutil` uses the
   scheduler's load signal to ramp frequency up faster. Smaller power
   savings, less throttling.
3. **Drop `max_cstate=9` → `max_cstate=6`.** Allow only shallow idle
   states. Wake latency drops from ~100µs to ~5µs at the cost of C7+
   residency. MCO event required.
4. **Remove CPU limits on the throttled pods.** Correct k8s answer,
   but means per-chart edits to vendored upstream charts.
5. **Accept as-is.** Nothing is broken; savings are huge.

I went with **option 5**. Net evaluation: a few observability pods
are mathematically throttled but functionally fine, vs ~1,600 zł/year
in real savings. The CPU% dashboard noise is annoying but I know
what's causing it. If anything *actually* starts failing, option 1
is a 1-line Helm-values change and a runtime push — no reboot, no
risk.

I also added a data-driven Grafana annotation to the `shelly-power`
dashboard:

```json
"annotations": {
  "list": [{
    "name": "Node reboots (MCO events)",
    "datasource": { "type": "prometheus", "uid": "${datasource}" },
    "enable": true,
    "iconColor": "rgb(255, 96, 96)",
    "target": {
      "expr": "changes(node_boot_time_seconds[5m]) > 0",
      "queryType": "", "refId": "Anno", "step": "1m"
    },
    "titleFormat": "Node reboot",
    "tagKeys": "instance",
    "textFormat": "{{instance}}"
  }]
}
```

It fires on `changes(node_boot_time_seconds[5m]) > 0`, which means any
node reboot — yesterday's reroll shows as 3 vertical markers on the
power chart, one per node. Every future MCO event auto-annotates the
same way. Cheap and durable.

## 7. What I'd do differently

A few things in retrospect:

- **Read the NTO `recommend` docs before assuming `match` does what
  you want.** The silent failure mode (profile assigned, no MC
  generated, no log line indicating anything is wrong) cost me ~15
  minutes of "why isn't the reroll happening". `machineConfigLabels`
  is the right field for bootloader changes; `match` is for runtime-
  only profiles.
- **Sub-step A taught me something even though it did nothing.** The
  48h of "no measurable change" was useful — it confirmed the
  hypothesis that the governor knob alone is decorative on
  `intel_pstate=active`, and that the real lever is the driver-mode
  flip. If I'd skipped sub-step A and gone straight to B, I'd have
  bundled two changes and been unable to attribute the result.
- **Wait for the long-fuse cascade victims.** The cert-manager hit
  was 18 minutes post-reroll, well after the standard post-cascade
  restarts. Worth adding a T+15 min "check for `dial tcp ... i/o
  timeout`-shaped conditions" sweep to the runbook. Done.
- **Add the rack-level plug earlier.** I only added it after sub-step
  B was already applied. The node6-only plug captures ~1/3 of total
  draw, which is fine for relative measurement but undersells the
  absolute number — if I'd had the rack plug from day 1, the
  decision-tree thresholds would have been calibrated against the
  rack signal from the start, and "what's the actual cost savings"
  would have been answerable on day 1 instead of after 24h of
  Prometheus-backed rack data.
- **Don't expect the dashboards to make sense.** CPU% accounting is
  load-time-relative, not work-relative. Frequency-scaled cores break
  the assumption every utilization metric is built on. The dashboards
  aren't lying; they're just not measuring what intuition expects.

## 8. What's next

Lever 1 is closed. The original blog draft had three more levers
queued:

- **Mac mini Jellyfin decommission** (estimated 10–30 W). Was the
  recommended fallback if Lever 1 underdelivered. Now demoted to
  "incremental if motivated" — Lever 1 over-delivered enough that
  this isn't on the critical path.
- **NVMe APST tuning** (1–2 W per drive). Still queued; PM9A1 supports
  it, default kernel state may not be using deep PS states.
- **PCIe ASPM + 10G NIC EEE.** Couple of watts each, free if supported.

But honestly, after a 39% rack-wide reduction, the marginal value of
these is small. The new baseline (227 W rack) is roughly where I'd
hoped to end up after all four levers. The remaining levers stay
queued as low-priority hygiene items.

The chart, dashboard JSON, and the cascade runbook update are all in
the [homelab GitOps repo](https://github.com/sudoom/homelab) under
`components/cluster-config/power-tuning/`,
`components/cluster-config/grafana-config/files/shelly-power.json`,
and `CLAUDE.md` respectively.

## 2026-08-25 — third plug: the TrueNAS box

The TrueNAS NAS (Supermicro X11SCH-F / Xeon E-2146G / 6× HGST 4 TB) came up on its
own Shelly plug at `192.168.1.55`. Adding it to telemetry turned out to be a
two-line change, which is the point of how this chart was built back in May:

```yaml
# components/cluster-config/shelly-exporter/values.yaml
  - instance: truenas
    rpcUrl: http://192.168.1.55/rpc/Switch.GetStatus?id=0
```

Nothing else moved. The `ServiceMonitor` template already `range`s over `.Values.plugs`,
so a new entry becomes a new scrape endpoint; and the Grafana dashboard
(`components/cluster-config/grafana-config/files/shelly-power.json`) drives every panel
off `instance=~"$instance"` where `$instance` is a query variable of
`label_values(shelly_power_watts, instance)`. A new plug therefore shows up in the
dropdown on its own, with no dashboard edit. Worth recording as a design that paid off —
the alternative (hardcoded per-plug panels) would have meant touching 10 panels.

Validation:

```
$ helm lint components/cluster-config/shelly-exporter/
1 chart(s) linted, 0 chart(s) failed

$ helm template shelly-exporter components/cluster-config/shelly-exporter/ | grep -A1 'target:'
        target:
          - "http://192.168.1.50/rpc/Switch.GetStatus?id=0"
        target:
          - "http://192.168.1.77/rpc/Switch.GetStatus?id=0"
        target:
          - "http://192.168.1.55/rpc/Switch.GetStatus?id=0"

$ ... | kubeconform -strict -ignore-missing-schemas ...   # exit 0
```

**Generation confirmed** (the one risk in this change — the `json_exporter` module is shared
across all plugs, so a Gen 1 plug on `/status` / `.meters[0].power` would have returned no
data rather than failing loudly):

```
$ curl -s http://192.168.1.55/rpc/Shelly.GetDeviceInfo
{"name":null,"id":"shellyplugsg3-d885ac16f888","mac":"D885AC16F888","slot":0,
 "model":"S3PL-00112EU","gen":3,"fw_id":"20260710-101146/2.0.0-g87fbfa4","ver":"2.0.0",
 "app":"PlugSG3","auth_en":false,...}
```

`gen: 3`, `app: PlugSG3` — same family as the other two, so the shared module applies.

Sync verified end to end:

```
$ oc -n openshift-gitops get application shelly-exporter -o jsonpath='{.status.sync.status} {.status.health.status} rev={.status.sync.revision}'
Synced Healthy rev=ae7accc...

$ oc -n shelly-exporter get servicemonitor shelly-exporter -o jsonpath='{range .spec.endpoints[*]}{.params.target[0]}{"\n"}{end}'
http://192.168.1.50/rpc/Switch.GetStatus?id=0
http://192.168.1.77/rpc/Switch.GetStatus?id=0
http://192.168.1.55/rpc/Switch.GetStatus?id=0
```

**Two baselines worth capturing while the box is still empty**, because they answer a
question the README's power section has been carrying as an assumption:

1. **Idle, pre-pool** — board + CPU + boot SSD, no spinning drives loaded.
2. **Idle, 6 HDDs spun up** — after the pool exists.

The delta is the real cost of the 3.5" tier. README's "Power (~15–30 W for 3× 3.5" HDD) is
the only real argument for NVMe-only-compact nodes" is an estimate; this measures it, at 6
drives instead of 3. It also feeds the Synology-vs-TrueNAS comparison — the DS418 it
replaces has 4 bays and its own draw, so the migration's true power delta is
`truenas − ds418`, not `truenas` alone. Capture the DS418 figure before it is sold.
