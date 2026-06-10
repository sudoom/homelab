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

| # | Drive serial | wwn- (as burned-in) | Slot node:bay | OSD ID | Pre POH | Realloc | Pending | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | K4KTAEDL | wwn-0x5000cca25df55694 | node4:bay1 (in bay) | - | 43,725 (~5.0 yr) | 0 | 0 | **long ✓** — gate ✓, baseline clean, short ✓, Extended self-test "Completed without error", post-long diff 0 new bad sectors. Awaiting badblocks (gated). |
| 2 | K4KTD40L | wwn-0x5000cca25df55cf3 | node5:bay1 (in bay) | - | 43,707 (~5.0 yr) | 0 | 0 | **long ✓** — gate ✓, baseline clean, short ✓, Extended self-test "Completed without error", post-long diff 0 new bad sectors. Awaiting install (badblocks dropped — see alert safety net). |
| 3 | K7GEKUBR | wwn-0x5000cca269c62bb6 | node6:bay1 (in bay) | - | 43,348 (~4.95 yr) | 0 | 0 | **in progress** — gate ✓, baseline clean, short ✓, long self-test running (ETA 23:29Z 2026-06-10) |

Verdict legend: `in progress` → `in service` / `shelf spare` / `returned` once long + badblocks complete and the post-diff is clean.
