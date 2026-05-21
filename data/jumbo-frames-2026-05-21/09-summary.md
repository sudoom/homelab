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
