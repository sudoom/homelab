# HDD burn-in campaign — 2026-06-10

10× HGST Ultrastar 7K6000 4 TB SATA (used datacenter pulls). Burn-in on **node4's
single internal 3.5" bay**, one drive at a time, full depth (SMART baseline → short
→ long self-test → destructive `badblocks` → post-diff). Procedure + hardened
device-safety gate: `blog/blog-hdd-tier-rollout-draft.md` (2026-06-10 section).

Execution vehicle: `oc exec` into the on-node `smartctl-exporter` pod (has `smartctl`
+ host device access; the external `support-tools` image won't pull on node4).
Self-tests are drive-internal (no etcd-HBA load); only `badblocks` loads the shared
SATA HBA and runs under `ionice -c3` with the node4 etcd-fsync watch.

3 drives go into service (1 per node bay); 7 are burned-in shelf spares.

| # | Drive serial | wwn- (as burned-in) | Slot node:bay | OSD ID | Pre POH | Realloc | Pending | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | K4KTAEDL | wwn-0x5000cca25df55694 | node4:bay1 (planned) | - | 43,725 (~5.0 yr) | 0 | 0 | **in progress** — gate ✓, baseline clean, short ✓, long self-test running (ETA 21:29Z 2026-06-10) |

Verdict legend: `in progress` → `in service` / `shelf spare` / `returned` once long + badblocks complete and the post-diff is clean.
