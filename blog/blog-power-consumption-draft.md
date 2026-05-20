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
