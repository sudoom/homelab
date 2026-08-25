# Synology DS418 → TrueNAS SCALE — build, migration, cutover

Working notes for standing up the DIY TrueNAS box and moving three volumes off the
Synology (and one off CephFS) onto it. Chronological, appended as the work happens.

Upstream planning that this draft executes against:

- vault `_memory/chats/homelab/2026-06-22-syno-truenas-migration-plan.md` — the migration plan
- vault `Runbooks/TrueNAS SCALE — NAS setup and best practices.md` — the setup runbook
  (**`status: DRAFT`, `last_tested: null`** — this build is its first execution, so every
  prescribed command is simultaneously the plan and the thing being validated)
- vault `Infrastructure/Homelab/NAS build.md` — the hardware BOM
- vault `Runbooks/Ceph-safe shutdown — power event.md` — the NUT-triggered shutdown path

## 2026-08-25 — read-in, and the decisions that are one-way doors

The replacement **Supermicro X11SCH-F** landed. Context: the original X11SCA-F was confirmed
dead 2026-07-30 (CPU-core VRM / platform power sequencing — three separate Coffee Lake CPUs
all no-POST with 12.2 V present at the EPS), refunded in full by eBay. The Xeon E-2146G was
exonerated by that same three-CPU test. TrueNAS **25.10.6 Goldeye Community** is installed and running on the new board
(dashboard confirmed 2026-08-25: hostname `truenas`, Xeon E-2146G @ 3.50 GHz / 12 threads,
all 12 cores ~35-38 °C at idle, **31.3 GiB total available reported as ECC**).

### Parts status as of today

| Part | Status |
|---|---|
| Supermicro X11SCH-F (C246, mATX) | on hand, running |
| Xeon E-2146G (6C/12T, 80 W) | on hand, bench-verified genuine |
| Samsung 2× 16 GB DDR4-2666 ECC UDIMM (M391A2K43BB1) | **installed** — dashboard reports 31.3 GiB "(ECC)" |
| Mellanox ConnectX-4 MRT0D 2×25G + 3 m Extralink SFP+ DAC | **on hand** |
| Lanberg SC01-5204-12B 4U chassis + 6× HGST 4 TB | **on hand** |
| Intel DC S3510 480 GB (boot) | on hand |
| be quiet! Pure Power 13 M 550 W | on hand |
| CyberPower CP1600EPFCLCD UPS | **NOT on hand** — gates the migration, see below |

### Decisions taken today

**Vdev drives: 6× HGST 4 TB.** The notes contradicted each other — the 2026-06-22 migration
plan called for mixing in 3 ex-Ceph pulls "so it isn't a pure age-cohort", while the NAS-build
and rack notes said plainly "6× HGST + cold spares". The mix branch is not a drive-selection
preference: those 3 drives are **`osd.3–5` and are in service right now**, backing
`cephfs-bulk-hdd` (media `/data`, 4 Ti) *and* the RGW-on-HDD data pool (Loki chunks). CLAUDE.md's
own note says the HDD tier *keeps* earning via RGW after the media move — it is not being
decommissioned. Taking those drives would gate pool creation behind a full Ceph HDD teardown:
CRUSH rule change, RGW data pool move, CephFS recreate needing the manual
`ceph fs new … --force`. Weeks, not days. **Resolved: 6× HGST; the Ceph HDD tier is untouched.**

**Encryption: none.** One-way door at dataset creation. Rejected because it interacts badly
with the recorded NUT unattended-shutdown design — an encrypted pool needing a key at import
does not come back cleanly after a power event unless key escrow is solved in the same breath.
Media is re-downloadable; the genuinely valuable ~2 TB gets its confidentiality from the
offsite borg/restic repo instead.

**Pool topology (carried from the plan, unchanged):** one pool, single 6-wide RAIDZ2 vdev,
~14.5 TiB usable, 2 bays left deliberately free as `zfs send | recv` runway (a RAIDZ vdev's
drive count can never shrink, so fewer-bigger is rebuild-only). `ashift=12` confirmed at
creation (immutable), LZ4 always on, `atime` off, dedup off. No SLOG, no L2ARC, no LACP.

### The UPS is not optional, and it moves a gate

The setup runbook's own phase order puts **NUT (Phase 7) before migration (Phase 9)**, and the
whole recorded power design has TrueNAS as **NUT master for the rack**. Steps 19–20 of the
migration make TrueNAS a hard dependency for live-serving Immich and Jellyfin, in a
**non-hot-swap, no-backplane chassis** where any drive swap is a full power-down.

So the gate is not "NUT waits for the UPS" — it is **the irreversible cutovers wait for the
UPS**. Split accordingly:

- **Proceed now, UPS-independent:** everything through pool → datasets → shares → snapshots /
  scrub / SMART → hardening, plus the non-disruptive bulk pre-stage from the Synology (source
  stays read-only and intact).
- **Hold for the UPS:** the Immich library cutover and the media `/data` reflip.

`keepers` (50 Gi) is the cheap rehearsal and can go early — it proves the whole
StorageClass + PVC-delete + data-placement pattern on a volume nobody misses.

### Gaps found in the existing plan

Surfaced by an adversarial completeness pass over the vault notes + repo. Recording them here
because each is a real hole, not a style note:

1. **The Synology's daily 03:00 USB Copy job for Immich loses its source.** It is explicitly the
   local "oops/deletion" leg of 3-2-1 — incremental, delete-source OFF, so files deleted on the
   source are *retained* on the exFAT USB SSD. The moment the library moves, that job has
   nothing to copy, and nothing in the notes designs a TrueNAS replacement. ZFS snapshots on
   `<pool>/immich` are **not** a substitute — same pool, and Golden Rule 2 says snapshots are
   not backups.
2. **No DS418 audit exists.** No `/etc/exports` inventory, no `synopkg list` / Package Center
   audit, no SMB/AFP/iSCSI/Time Machine share list, no user/permission dump, and — most
   practically — **no used-vs-free capacity figure**. The plan reaches "wipe the Synology's
   drives" with no inventory gate upstream. A Phase-A0 audit is required before any bulk copy.
3. **From pool creation until the offsite leg exists, the pool is copy #1 with no configured
   copy #2**, spanning the irreversible cutovers. The runbook's Phase 6 "Replication / off-box
   — *the actual backup*" row was dropped. The cheap fix the notes already name: point
   replication at the Synology while it is still in service.
4. **The Ceph-safe-shutdown script's CONFIG block is wrong for this cluster.** It names
   `node1-3` at `192.168.1.4–.6` and `CEPH_NS=openshift-storage`; the real cluster is
   node4/5/6 at `192.168.1.7–.9`, Ceph in `rook-ceph`, toolbox `deploy/rook-ceph-tools`. As
   written it would cordon nothing, find no toolbox, skip `noout`, and power the nodes off
   ungracefully — the exact outcome it exists to prevent. **Fix before the UPS lands.**
5. **No `VolumeSnapshotClass` for `nfs.csi.k8s.io`**, so OADP/Velero CSI snapshots of NFS-backed
   PVCs fail (`PartiallyFailed`). Moving media `/data` onto NFS adds a *third* PVC to that blind
   spot. Options recorded: ship a VolumeSnapshotClass, or set `snapshotVolumes: false` for those
   PVCs.
6. **`<pool>/apps` is never created** in either dataset layout, yet the NUT tooling is specified
   to live at `/mnt/<pool>/apps/nut/` (deliberately on the pool, because `/root` and `/etc` do
   not survive TrueNAS updates).
7. **`tank/backups` vs `tank/backup` is a name collision, not a complement.** The runbook's
   `backups` = "targets for other machines' backups", no offsite policy; the migration plan's
   `backup` = 128k/zstd/frequent snapshots/**offsite YES**. One keystroke apart, different
   purposes. A machine-backup tree accidentally inheriting the offsite policy is a 2 TB borg
   repo that quietly is not 2 TB any more.
8. **`csi-driver-nfs` version drift.** `Chart.yaml` requests 4.13.4, the untracked `Chart.lock`
   pins 4.11.0, the vendored tarball is 4.11.0. Local `helm template` therefore renders
   something different from what ArgoCD pulls fresh at sync — resolve and commit the lock
   *before* editing this chart during a migration.

### Certificate / DNS path — already built, needs porting not designing

Verified live rather than assumed:

```
$ oc get certificate -A -o jsonpath=…
cert-manager/homelab-wildcard  dns=["*.homelab.sudops.pl","homelab.sudops.pl"]  secret=homelab-wildcard-tls

$ oc -n cert-manager get secret homelab-wildcard-tls -o jsonpath='{.data.tls\.crt}' | base64 -d | openssl x509 -noout -subject -ext subjectAltName -enddate
subject=CN=*.homelab.sudops.pl
X509v3 Subject Alternative Name:
    DNS:*.homelab.sudops.pl, DNS:homelab.sudops.pl
notAfter=Oct 21 11:24:57 2026 GMT
```

So `truenas.homelab.sudops.pl` is covered with **zero new cert-manager work**. The delivery
mechanism is a port of the shipped `components/cluster-config/synology-cert-sync/` chart — daily
CronJob, cross-namespace RBAC on the Secret, fingerprint-gated so it no-ops until LE renews,
replaces the cert *by id* so service bindings survive. Swap the DSM API calls for TrueNAS
middleware calls. **Open:** which API generation 25.10 Goldeye exposes — SCALE has been moving
from REST v2.0 to a JSON-RPC websocket API, so `certificate.create` +
`system.general.update{ui_certificate}` is the right *shape* but not yet the right transport.

DNS is `ansible/technitium/group_vars/all.yml` → `homelab_records`, code-only via the role
(never the Technitium or TrueNAS web UI).

### OADP as the CephFS→NFS move mechanism — considered, rejected for the bulk move

Raised as an option. Velero's `velero.io/change-storage-class` ConfigMap genuinely is the
sanctioned way to change a PVC's backend, since `storageClassName` is immutable. Rejected for
the media move on capacity grounds:

- The `daily` Schedule has been **`paused: true` since 2026-06-08** (the Loki-WAL-fills-Ceph
  incident), with an open TODO to ship `excludedNamespaces` before un-pausing.
- Velero's data mover targets **RGW, which lives on the same 3 HDD OSDs as the CephFS EC pool**.
  Live figures today: 13.54 TB raw total, 6.27 TB used, **7.27 TB available**. Staging ~1.5 TiB
  of media through RGW means ×3 replication ≈ 4.5 TiB raw, landing on the same spindles as the
  source. That is structurally the same failure shape as the incident that paused the schedule.

A copy Job mounting both PVCs (both RWX) and rsync'ing directly is less machinery and stages
nothing. **Where OADP does earn its place: un-pause it *after* the migration, once TrueNAS
exists as a proper off-cluster BSL** — which retires the "backing up to the same disks" problem
that made the pause necessary in the first place.

### Still blocked on operator input

- NFS VLAN concrete numbers: VLAN ID, subnet, TrueNAS address, per-node addresses on
  `enp1s0f1np1`, CRS317 port, access-vs-trunk. **Nothing in any note assigns any of these** —
  the Homelab IP plan has no TrueNAS row and the Port Access Plan still lists the Synology on
  the CCR2004's `ether1-2`.
- TrueNAS management address on VLAN 5, and whether it inherits `192.168.1.2` when the Synology
  is sold or takes a fresh address permanently. This is what `synology-cert-sync`'s replacement,
  the Technitium `nas` record, and Gatus all key off.
- Pool name. Both runbooks say `tank`; the Ceph-safe-shutdown script hardcodes `/mnt/pool/…` in
  its body while writing `/mnt/<pool>/` in its prose. **Not cosmetic** — it is baked into the
  NUT shutdown command stored in the TrueNAS config DB, into every dataset path, and into the
  `nfs-csi` StorageClass `share` parameter, **which is immutable**.
- The DS418 audit numbers (gap 2 above), specifically used-vs-free, which decides whether the
  ~7 TiB Synology bulk and the ~1.5 TiB CephFS `/data` are distinct or overlapping bodies of
  data. Distinct puts ~10.3 TiB against an ~11.6 TiB working ceiling (80 % of 14.5 TiB) before
  any growth or snapshot reserve.

## 2026-08-25 (later) — pre-pool hardware verification

Ran the runbook's pre-pool checks against the live box. All four open unknowns from the
read-in closed, and one unexpected finding.

### ECC is genuinely active, not merely present

The distinction matters and is worth stating once: the TrueNAS dashboard's "(ECC)" label and
`dmidecode`'s `Error Correction Type: Single-bit ECC` both only prove **ECC-type DIMMs are
installed**. Neither proves the memory controller is *running* in ECC mode and reporting
corrections. The proof is EDAC registering a memory controller:

```
root@truenas[~]# ls /sys/devices/system/edac/mc/
mc0  power  subsystem  uevent
root@truenas[~]# grep . /sys/devices/system/edac/mc/mc0/{ce_count,ue_count}
/sys/devices/system/edac/mc/mc0/ce_count:0
/sys/devices/system/edac/mc/mc0/ue_count:0
```

`mc0` present = ECC active. Zero correctable and zero uncorrectable errors. Both
`M391A2K43BB1-CTD` sticks seen, 2 of 4 slots populated. **The runbook's hard gate is cleared.**

### Boot device resolved — it is the S3510

An open unknown in the notes was whether the running install sat on the intended Intel DC
S3510 or on the test NVMe:

```
root@truenas[~]# zpool status boot-pool
  pool: boot-pool
 state: ONLINE
        NAME        STATE     READ WRITE CKSUM
        boot-pool   ONLINE       0     0     0
          sdg3      ONLINE       0     0     0
```

`sdg` = `INTEL SSDSC2BB480G6`, 447.1 G, `ROTA=0`, WWN `0x55cd2e414d882542`. `SSDSC2BB…G6` is
the DC S3510 480 GB. It is on the intended device — no reinstall needed.

### All 8 SATA ports enumerate; 7 populated, 1 free

```
[    1.581618] ata1: SATA link up 6.0 Gbps
[    1.581638] ata7: SATA link down
[    1.581658] ata4: SATA link up 6.0 Gbps
[    1.581702] ata5: SATA link up 6.0 Gbps
[    1.581722] ata3: SATA link up 6.0 Gbps
[    1.581739] ata2: SATA link up 6.0 Gbps
[    1.581758] ata6: SATA link up 6.0 Gbps
[    1.581774] ata8: SATA link up 6.0 Gbps
```

Seven links up = 6 HDD + 1 boot SSD; one free port. Confirms the no-HBA decision empirically
rather than by datasheet.

### Unexpected: the 6 HGST drives are already two cohorts

| Serial | WWN | Cohort |
|---|---|---|
| K7GE89HL | `0x5000cca269c60801` | A |
| K7GEX0MR | `0x5000cca269c65202` | A |
| K7GE897L | `0x5000cca269c607f9` | A |
| K7GEWZLR | `0x5000cca269c651e2` | A |
| K4KSH3VL | `0x5000cca25df4f3d2` | **B** |
| K4KTDL9L | `0x5000cca25df55eae` | **B** |

HGST allocates WWNs sequentially, so `269c6…` and `25df…` are different production runs —
a 4 + 2 split. This matters because the *entire* motivation for the 2026-06-22 plan's
"mix in 3 ex-Ceph pulls" idea was avoiding a pure age-cohort. **The 6× HGST set is already
not one.** Suggestive rather than proven — `Power_On_Hours` from the SMART baseline is what
settles it — but it removes the last argument for touching `osd.3–5`.

### DDF superblocks: check before writing anything

`HUS726040ALA610` is the same model family CLAUDE.md documents as carrying **DDF
firmware-RAID superblocks** on used datacenter pulls. On the cluster those auto-assembled an
md raid0 on insertion, and a broken array hung kernel disk-stats long enough to wedge
kubelet's cAdvisor → ~31 false alerts including **critical** `etcdMembersDown` and
`ClusterVersionOperatorDown`. Different box, identical superblocks.

Read-only check first (`-n` is a dry run — reports signatures, touches nothing):

```bash
cat /proc/mdstat
mdadm --examine --scan
for d in sda sdb sdc sdd sde sdf; do echo "== $d"; wipefs -n /dev/$d; done
```

If DDF appears: `mdadm --stop /dev/md*`, then `wipefs -a` on the affected drives, **then**
burn-in. Wiping after a burn-in that ran against an auto-assembled array proves nothing.

### Burn-in

`badblocks` needs **`-b 4096` on >2 TB drives** or it aborts with "Value too large for defined
data type". Run all six in parallel under tmux so an SSH drop does not kill it.

```bash
tmux new -s burnin

# baseline FIRST — this is the comparison point, and it is unrecoverable afterwards
for d in sda sdb sdc sdd sde sdf; do smartctl -a /dev/$d > /root/smart-baseline-$d.txt; done
grep -HE "Power_On_Hours|Reallocated_Sector|Current_Pending|Offline_Uncorrect|Reported_Uncorrect" \
  /root/smart-baseline-*.txt

# destructive write test — single random pattern ~15 h; drop -t random for the
# full 4-pattern sweep (~60 h) if the stronger test is wanted on used pulls
for d in sda sdb sdc sdd sde sdf; do
  badblocks -wsv -b 4096 -c 32768 -t random -o /root/bb-$d.log /dev/$d &
done
```

Then SMART long tests and a delta against the baseline. **Any growth in
`Reallocated_Sector_Ct`, `Current_Pending_Sector` or `Offline_Uncorrectable` means the bin,
not the pool** — with used pulls that is the entire point.

The UPS shipping window is the right time to spend on this: it is the one multi-day job on
the critical path that costs nothing but wall-clock.
