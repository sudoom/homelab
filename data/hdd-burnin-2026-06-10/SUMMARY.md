# HDD burn-in campaign — 2026-06-10

10× HGST Ultrastar 7K6000 **HUS726040ALA610** 4 TB SATA (used datacenter pulls; delivered model is ALA610/512n, not the ALE610 the listing named). Burn-in on **node4's
single internal 3.5" bay**, one drive at a time, full depth (SMART baseline → short
→ long self-test → destructive `badblocks` → post-diff). Procedure + hardened
device-safety gate: `blog/blog-hdd-tier-rollout-draft.md` (2026-06-10 section).

Execution vehicle: `oc exec` into the on-node `smartctl-exporter` pod (has `smartctl`
+ host device access; the external `support-tools` image won't pull on node4).
Self-tests are drive-internal (no etcd-HBA load); only `badblocks` loads the shared
SATA HBA and runs under `ionice -c3` with the node4 etcd-fsync watch.

3 drives go into service (1 per node bay); 7 are burned-in shelf spares.

**Serial caution:** the drives ship with near-identical serials — drive 1 `K4KTAEDL` vs drive 2 `K4KTD40L`. Everything is keyed by WWN to avoid transposition; verify serial+WWN at the destination node before writing it into the OSD device list.

**Decision (2026-06-10): badblocks dropped for the trio.** Long self-test passed clean on all (enterprise TLER drives, behind size=3 Ceph with per-block checksums + scrub + auto-heal). Safety net = SMART degradation alert (`components/cluster-config/smartctl-exporter` PrometheusRule, commit `1dcc709`) + 7 burned-in shelf spares. Install **deferred** — node4's bay is being used to burn in the 7 spares first (user's call).

**Hot-plug works (confirmed 2026-06-10).** Drives can be swapped on node4's bay **live, no reboot** — kernel cleanly saw K4KTAEDL leave (`[sda] DID_BAD_TARGET`) and spare K7GE897L arrive (`ata1 link up 6.0 Gbps → [sdc] attached`); zero cluster disruption (nodes Ready, osd.0 up, ArgoCD clean). So the spare campaign can run **in parallel across all 3 bays** (~days, not weeks) instead of node4-serial. Note: live hot-swaps walk the `/dev/sd*` letter (K7GE897L came up as `sdc`), so the smartctl-exporter static scrape list won't cover mid-swap spares — burn-in uses ad-hoc `oc exec ... smartctl <by-id>`; the exporter list (and alert coverage) re-aligns on the next install-time reboot.

**Wipe-before-OSD:** these used datacenter pulls carry leftover metadata — K4KTAEDL had a stale RAID0 superblock the host auto-assembled as `md126` (failed harmlessly on pull); the spares show leftover partitions. Before any drive becomes a Ceph OSD, zap it (`mdadm --zero-superblock` + `wipefs -a` + `sgdisk --zap-all`); Rook usually handles this but the md superblocks are worth an explicit wipe to avoid auto-assembly surprises.

| # | Drive serial | wwn- (as burned-in) | Slot node:bay | OSD ID | Pre POH | Realloc | Pending | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | K4KTAEDL | wwn-0x5000cca25df55694 | **pulled** (was node4) | - | 43,725 (~5.0 yr) | 0 | 0 | **PASS** — long self-test "Completed without error", 0 new bad sectors. Live-pulled from node4 for spare cycling; labeled + set aside as a validated in-service drive (goes back as an OSD at install). |
| 2 | K4KTD40L | wwn-0x5000cca25df55cf3 | node5:bay1 (in bay) | - | 43,707 (~5.0 yr) | 0 | 0 | **PASS** — long self-test "Completed without error", 0 new bad sectors. Validated; awaiting install. |
| 3 | K7GEKUBR | wwn-0x5000cca269c62bb6 | node6:bay1 (in bay) | - | 43,348 (~4.95 yr) | 0 | 0 | **in progress** — gate ✓, baseline clean, short ✓, long self-test running (ETA 23:29Z 2026-06-10) |
| 4 (spare) | K7GE897L | wwn-0x5000cca269c607f9 | node4:bay (spare burn-in) | - | 43,351 (~4.95 yr) | 0 | 0 | **in progress** — gate ✓, baseline clean, short→long chained (live hot-swap, no reboot) |

Verdict legend: `in progress` → `in service` / `shelf spare` / `returned` once the long self-test completes clean (badblocks dropped; SMART alert is the in-service safety net).
