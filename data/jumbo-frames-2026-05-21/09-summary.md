# Jumbo frames (MTU 9000) on storage backnet — 2026-05-21

## Pre-flight
- NIC: enp1s0f0np0, max-mtu=9978 (Mellanox/Broadcom 10G) on all 3 nodes
- MikroTik: sfp-sfpplus2/4/6 raised from l2mtu=1584 → 9214
- Cluster: HEALTH_OK at start, no client load other than baseline writes

## Pre-MTU (MTU 1500)
- rados bench 4M write, t=16, 60s: **92.5 MB/s** avg
  - Stddev 178.9 (max 852 MB/s, min 0 MB/s — extremely bursty)
  - Avg latency 692 ms
- rados bench 4M seq read, t=16: 1647 MB/s (mostly cached)
- OSD commit_lat: 9/9/9 ms across the three OSDs

## Post-MTU (MTU 9000)
- rados bench 4M write, t=16, 60s: **129.4 MB/s** avg
  - Stddev 147.3 (max 836 MB/s, min 0 MB/s — still bursty, less so)
  - Avg latency 494 ms
- rados bench 4M seq read, t=16: 1724 MB/s
- OSD commit_lat: 8/6/9 ms (one OSD improved 9→6)

## Delta
- Write throughput: **+40%** (92.5 → 129.4 MB/s)
- Write latency: **-29%** (692 → 494 ms)
- Write stddev: -18% (less bursty, fewer 0 MB/s troughs)
- Read throughput: +5% (mostly cached, not a meaningful comparison)
- OSD commit latency: 1 of 3 OSDs improved -33%; others unchanged

## End-to-end jumbo verification
- ping -M do -s 8972 192.168.10.3: 0% loss, RTT 0.115/0.149/0.194 ms
  (8972-byte payload + 20 IP + 8 ICMP = 9000-byte L3 packets, DF set)

## Cluster health
- HEALTH_OK throughout — NNCP applied in-place by nmstate handler,
  no daemon restart, no OSD flap.

## Why bigger than predicted (5-15% was the bet)
The pre-MTU write profile (stddev 178.9, frequent 0 MB/s troughs)
suggests the bottleneck wasn't drive throughput — it was the
replication-amplified write path stalling under packet-rate
pressure. At MTU 1500, every 4M client write becomes ~2.7k packets
to ship to replicas (12 MB after 3x size); at MTU 9000, ~450
packets — 6× fewer. Smaller per-packet kernel overhead + less
softirq pressure on Ceph daemons → fewer ack stalls → write side
stops hitting 0 MB/s troughs as often.

The OSD that didn't move (osd.2 stayed at 9ms commit_lat) may be
the local-write OSD whose latency is purely BlueStore-bound; the
ones that improved are bound by network ack from the replicas.

---

## Update — second post-MTU run after pod-network recovery

The first post-MTU bench (129.4 MB/s) hit an unusually clean OSD state
(osd.1 commit_lat 6 ms vs typical 9 ms). It also overlapped with the
pod-network-to-host-network cascade that broke etcd-operator + ArgoCD
repo-server in parallel — though those run on the pod network and
shouldn't have affected an in-cluster `rados bench` directly, the
timing was suspicious.

Re-ran the exact same bench after recovering the pod-network
(restart of ovnkube-node ×3 + repo-server):

- HEALTH state: WARN (BLUESTORE_SLOW_OP_ALERT on osd.1 then osd.0)
- OSD perf: 8/11/8 ms at start, 11/13/8 ms by end of bench
- **rados bench write: 101.5 MB/s** (avg lat 631 ms, stddev 147.6)

So the **honest gain is ~+10% over the pre-MTU baseline**, not +40%.
The cluster's BlueStore latency variability (8-13 ms range, with
intermittent slow alerts on whichever OSD happens to be compacting)
is large enough that single 60s benchmarks are noisy.

What's still genuinely true:
- End-to-end MTU 9000 verified via DF-ping at 8972-byte payload
- Stddev / max-latency improvements appear robust across runs
- The architectural reasoning (6× fewer packets) is sound
- For larger / sustained workloads (RGW puts, future CephFS bulk),
  the gain should materialize more clearly

What was wrong in the original writeup:
- "+40%" was a single lucky measurement
- The "+1 OSD improved from 9→6 ms" was a transient state, not a
  jumbo-attributable change — the same OSD now reads 11-13 ms
- Headline figure should be more conservative: "+10-15% under
  typical state, dependent on BlueStore latency variability"

This is also a reminder to take multiple benchmark samples on this
cluster, not just one — the 8-13 ms commit_lat noise floor makes
single runs untrustworthy. Two or three runs separated by a few
minutes would have caught the inflated number.
