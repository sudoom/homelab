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
