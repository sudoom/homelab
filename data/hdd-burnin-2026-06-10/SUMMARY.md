# HDD burn-in campaign — 2026-06-10

10× HGST Ultrastar 7K6000 **HUS726040ALA610** 4 TB SATA (used datacenter pulls; delivered model is ALA610/512n, not the ALE610 the listing named). Burn-in on **node4's
single internal 3.5" bay**, one drive at a time, full depth (SMART baseline → short
→ long self-test → destructive `badblocks` → post-diff). Procedure + hardened
device-safety gate: `blog/blog-hdd-tier-rollout-draft.md` (2026-06-10 section).

Execution vehicle: `oc exec` into the on-node `smartctl-exporter` pod (has `smartctl`
+ host device access; the external `support-tools` image won't pull on node4).
Self-tests are drive-internal (no etcd-HBA load); only `badblocks` loads the shared
SATA HBA and runs under `ionice -c3` with the node4 etcd-fsync watch.

3 drives go into service (1 per node bay); 7 shelf spares total. **HDD CAMPAIGN COMPLETE 2026-06-12 — all 10/10 PASSED** (long self-test "Completed without error", 0 reallocated/pending/offline/CRC, health PASSED on every drive): 3 in-service (K4KTAEDL/K4KTD40L/K7GEKUBR) + 7 shelf spares (K7GE897L/K7GE89HL/K4KZYB3B/K7GEX0MR/K7GEWZLR/K4KTDL9L/K4KSH3VL). Plus 2 Intel DC SSDs validated+wiped (S3510 480GB boot-spare, S4610 960GB Synology backup — see batch-3 SSD section). In-service HDDs re-seated raw on node5/node6 (K4KTD40L/K7GEKUBR); K4KSH3VL in node4 bay (pull→store raw, then K4KTAEDL re-seats). Next: deferred Ceph HDD-tier OSD install (degraded-window event, Phases 1-5 in blog/blog-hdd-tier-rollout-draft.md).

**Serial caution:** the drives ship with near-identical serials — drive 1 `K4KTAEDL` vs drive 2 `K4KTD40L`. Everything is keyed by WWN to avoid transposition; verify serial+WWN at the destination node before writing it into the OSD device list.

**Decision (2026-06-10): badblocks dropped for the trio.** Long self-test passed clean on all (enterprise TLER drives, behind size=3 Ceph with per-block checksums + scrub + auto-heal). Safety net = SMART degradation alert (`components/cluster-config/smartctl-exporter` PrometheusRule, commit `1dcc709`) + 7 burned-in shelf spares. Install **deferred** — node4's bay is being used to burn in the 7 spares first (user's call).

**Hot-plug works (confirmed 2026-06-10).** Drives can be swapped on node4's bay **live, no reboot** — kernel cleanly saw K4KTAEDL leave (`[sda] DID_BAD_TARGET`) and spare K7GE897L arrive (`ata1 link up 6.0 Gbps → [sdc] attached`); zero cluster disruption (nodes Ready, osd.0 up, ArgoCD clean). So the spare campaign can run **in parallel across all 3 bays** (~days, not weeks) instead of node4-serial. Note: live hot-swaps walk the `/dev/sd*` letter (K7GE897L came up as `sdc`), so the smartctl-exporter static scrape list won't cover mid-swap spares — burn-in uses ad-hoc `oc exec ... smartctl <by-id>`; the exporter list (and alert coverage) re-aligns on the next install-time reboot.

**Wipe DDF FIRST (mandatory at insertion) — not just before OSD.** These used pulls carry **DDF firmware-RAID metadata**; the host auto-assembles a raid0 from it on insertion, and a *broken* array (after a pull) hangs kubelet cAdvisor for 30 s → ~31 **false** Prometheus alerts incl. critical `etcdMembersDown`/`CVO down` (2026-06-10 incident; cluster was healthy throughout — see runbook). So the per-spare flow is now: seat → `mdadm --stop` + `wipefs -a` the DDF (FIRST) → gate → baseline → short → long. **Shelf spares are stored RAW** (no partition/RAID metadata) so re-insertion can't recur the issue and Rook gets clean OSD devices; validated-ness lives in the serial + physical label + this record. Full diagnosis + fix in `blog/blog-hdd-tier-rollout-draft.md`.

| # | Drive serial | wwn- (as burned-in) | Slot node:bay | OSD ID | Pre POH | Realloc | Pending | Verdict |
|---|---|---|---|---|---|---|---|---|
| 1 | K4KTAEDL | wwn-0x5000cca25df55694 | **pulled** (was node4) | - | 43,725 (~5.0 yr) | 0 | 0 | **PASS** — long self-test "Completed without error", 0 new bad sectors. Live-pulled from node4 for spare cycling; labeled + set aside as a validated in-service drive (goes back as an OSD at install). |
| 2 | K4KTD40L | wwn-0x5000cca25df55cf3 | node5:bay1 (in bay) | - | 43,707 (~5.0 yr) | 0 | 0 | **PASS** — long self-test "Completed without error", 0 new bad sectors. Validated; awaiting install. |
| 3 | K7GEKUBR | wwn-0x5000cca269c62bb6 | node6:bay1 (in bay) | - | 43,348 (~4.95 yr) | 0 | 0 | **PASS** — long self-test "Completed without error", 0 new bad sectors. Validated; in node6 bay (awaiting install or pull-for-spare). |
| 4 (spare) | K7GE897L | wwn-0x5000cca269c607f9 | shelf spare (burned in node4) | - | 43,351 (~4.95 yr) | 0 | 0 | **shelf spare PASS** — long self-test "Completed without error", 0 new bad sectors. DDF wiped ✓ (cleared in incident sweep). Store raw + labeled. |
| 5 (spare) | K7GE89HL | wwn-0x5000cca269c60801 | shelf spare (burned in node5) | - | 43,351 (~4.95 yr) | 0 | 0 | **shelf spare PASS** — long self-test "Completed without error", 0 new bad sectors. DDF wiped ✓ (cleared in incident sweep). Store raw + labeled. |
| 6 (spare) | K4KZYB3B | wwn-0x5000cca25df857da | shelf spare (burned in node6) | - | 43,351 (~4.95 yr) | 0 | 0 | **shelf spare PASS** — DDF wiped first ✓ (per the new procedure), long self-test "Completed without error", 0 new bad sectors. Store raw + labeled. |
| 7 (spare) | K7GEX0MR | wwn-0x5000cca269c65202 | shelf spare (burned in node4) | - | 43,350 (~4.95 yr) | 0 | 0 | **shelf spare PASS** — DDF wiped first ✓, long self-test "Completed without error" (POH 43,358), 0 new reallocated/pending/offline/CRC, health PASSED. Store raw + labeled. |
| 8 (spare) | K7GEWZLR | wwn-0x5000cca269c651e2 | shelf spare (burned in node5) | - | 43,350 (~4.95 yr) | 0 | 0 | **shelf spare PASS** — DDF wiped first ✓, long self-test "Completed without error" (POH 43,358), 0 new reallocated/pending/offline/CRC, health PASSED. Store raw + labeled. |
| 9 (spare) | K4KTDL9L | wwn-0x5000cca25df55eae | shelf spare (burned in node6) | - | 43,703 (~4.99 yr) | 0 | 0 | **shelf spare PASS** — DDF wiped first ✓, long self-test "Completed without error" (POH 43,711), 0 new reallocated/pending/offline/CRC, health PASSED. Store raw + labeled. |
| 10 (spare) | K4KSH3VL | wwn-0x5000cca25df4f3d2 | shelf spare (burned in node4) | - | 43,726 (~5.0 yr) | 0 | 0 | **shelf spare PASS** — DDF wiped first ✓, long self-test "Completed without error" (POH 43,733), 0 new reallocated/pending/offline/CRC, health PASSED. Store raw + labeled. |

Verdict legend: `in progress` → `in service` / `shelf spare` / `returned` once the long self-test completes clean (badblocks dropped; SMART alert is the in-service safety net).

## Batch 3 — mixed: last HDD + 2 Intel DC SATA SSDs (2026-06-11)

After batch 2 is pulled, batch 3 runs the **10th/last HDD spare** plus **two used Intel DC SATA SSDs**, across the 3 bays in parallel. Two procedures at once:

| Drive | Model | Purpose | Procedure |
|---|---|---|---|
| Last HDD (10th) | HUS726040ALA610 4TB | Ceph HDD-tier shelf spare | **HDD flow** — DDF-wipe → `assert_burnin_target` → baseline → short → long → diff |
| Intel DC **S3510 480GB** | `INTEL SSDSC2BB480G6` (0.3 DWPD MLC, ~275 TBW, PLP, ~2015) | **boot/etcd spare** | SSD flow + **secure-erase** (gated by `assert_ssd_burnin_target`) |
| Intel D3-**S4610 960GB** | `INTEL SSDSC2KG960G8` (3 DWPD TLC, ~5.5 PBW, PLP, ~2018) | **backup target** (USB box on Synology, Hyper Backup) | SSD flow + **wipe** (gated), Synology formats after |

**SSD-erase hazard — read before seating:** the HDD gate's `ROTA=1` discriminator does NOT protect an SSD op (the boot/etcd disk is also a SATA SSD). Batch-3 SSDs are *written* (secure-erase), so a wrong by-id = boot/etcd disk wiped on a no-drain cluster. Use the **allowlist-driven `assert_ssd_burnin_target`** gate (fail-closed on empty allowlist; paste the seated SSD's WWN in first), NOT the HDD gate. SSD flow = SMART `-x` wear baseline → short → `dd`→/dev/null read pass → `mdadm --stop`+`wipefs` (RAID metadata) → secure-erase (`hdparm`, direct SATA only; unfreeze via hot-replug if `SEC_FROZEN`) → post-erase SMART confirm. Full gate template + flow in `blog/blog-hdd-tier-rollout-draft.md` (2026-06-11 Batch 3 section). Capture SSD SMART as `…-SERIAL-ssd-{baseline,posterase}.txt`.

**Batch-3 SSDs seated 2026-06-11 — wear triage (read-only, both PASSED):**

| SSD | Node:dev | by-id WWN | Serial | POH | Wear | Defects | Verdict |
|---|---|---|---|---|---|---|---|
| S3510 480GB (boot-spare) | node5:sdb | wwn-0x55cd2e414d882542 | BTWA64640719480FGN | 48,796 (~5.6yr) | **Media_Wearout=100, ~6.7 TiB / 275 TBW ≈ 2.4% used** | 0 realloc/pending/CRC/E2E/reserved | **PASS + WIPED** — read pass clean (447 GiB read, 0 I/O err), `blkdiscard`+`wipefs` clean, health PASSED post-wipe. Boot/etcd spare ready (store raw + labeled). |
| S4610 960GB (Synology backup) | node6:sdb | wwn-0x55cd2e415293e3b7 | BTYG01830APB960CGN | 36,783 (~4.2yr) | **Percent_Life_Remaining=100** (20 power-cycles, 15 unsafe-shutdowns) | 0 realloc/pending/CRC/E2E | **PASS + WIPED** — read pass clean (894 GiB read, 0 I/O err), `blkdiscard`+`wipefs` clean, health PASSED post-wipe. Ready for Synology USB-box (Synology formats). |

Boot disks confirmed untouched: node5 `/dev/sda` Toshiba THNSF8 (wwn 500080d910e743a6), node6 `/dev/sda` Toshiba (wwn 500080d910e71bba) — both in the gate denylist; neither SSD WWN collides. No DDF/md auto-assembled on either SSD.

**Wipe method — `blkdiscard`, NOT `hdparm` (2026-06-11 finding):** `hdparm` is **not installed on SCOS** (rc=127 on `oc debug node` chroot — it's a minimal immutable OS; `wipefs`/`lsblk`/`blkdiscard` are present as util-linux, `hdparm` is not). So ATA secure-erase isn't available on-node. Used `blkdiscard -f` (whole-device TRIM) + `wipefs -a` instead — guarded identically (rota=0 + model + exact WWN + not-mounted). Caveat: `DISC-ZERO=0` on these drives (no deterministic-read-zero-after-TRIM guarantee) → this is a **clean-slate-for-reuse** wipe (data unmapped + signatures cleared + NAND background-reclaimed), not a forensic/cryptographic-erase guarantee. Correct for boot-spare + backup reuse; for forensic destruction, pull to a workstation with hdparm. The `assert_ssd_burnin_target` gate's secure-erase step is updated accordingly in the blog draft.

**In-service HDDs re-seated raw on node5/node6 (2026-06-11):** after pulling the wiped SSDs, the in-service drives went back into their bays — K4KTD40L → node5 (`wwn-0x5000cca25df55cf3`), K7GEKUBR → node6 (`wwn-0x5000cca269c62bb6`). **Both still carried metadata** (NOT stored raw after their original burn-in): node5's K4KTD40L re-auto-assembled `md126`/`md127` from a live `ddf_raid_member` superblock (the cAdvisor-hang trap), node6's K7GEKUBR had stale GPT/PMBR. Caught at insertion and wiped (guarded: stop md + `wipefs -a`) **before** any false-alert cascade (firing stayed at baseline 12, no storm). Confirms the rule: **wipe DDF on EVERY insertion, even a previously-validated drive** — "validated" ≠ "stored raw." Both now raw, seated, ready for the deferred OSD install. (node4 bay still running K4KSH3VL's long; its in-service drive K4KTAEDL re-seats after.)
