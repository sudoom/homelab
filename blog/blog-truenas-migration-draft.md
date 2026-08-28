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

## 2026-08-25 (evening) — network decision reversed, and a chart drift caught on the way

### NFS goes on the Ceph backnet, not a dedicated VLAN

The 2026-06-22 plan said NFS traffic would go on a **new dedicated VLAN** on the nodes' spare
10G port `enp1s0f1np1`, "explicitly NOT the Ceph backnet (VLAN 10), to preserve the backnet's
'no other hosts' invariant". **Reversed today, deliberately.**

I had drafted a VLAN 15 / `192.168.15.0/24` proposal (VLAN 20 was unavailable — it is IoT in
the vault's VLAN plan). The operator pushed back: use the backnet for the 10G SFP+ and
frontnet for management. That is the better call, for a reason I had under-weighted:

- **It eliminates the most dangerous step in the migration.** A dedicated VLAN needs
  `enp1s0f1np1` brought up on all three nodes — an nmstate enactment, which is precisely the
  `br-ex.forwarding` cascade trigger documented in CLAUDE.md's network pre-flight. On the
  backnet the nodes **already** hold `192.168.10.2/3/4` on `enp1s0f0np0`, so the mount is
  on-link. **No NNCP change at all.**
- **The bandwidth objection does not survive contact with the numbers.** The bulk migration
  reads from the Synology, which is **1G-attached** — capped ~118 MB/s, under 10 % of a 10G
  backnet. Ceph replication and, more importantly, OSD heartbeats keep ample headroom. The
  "no other hosts" invariant was guarding against congestion the source link makes impossible.

Settled addressing:

| | |
|---|---|
| TrueNAS NFS | `192.168.10.5` — clear of nodes (`.2-.4`), `ceph-shim` (`.16-.18`), and **outside the `192.168.10.128/25` Multus pod range** |
| TrueNAS mgmt | `192.168.1.25` on onboard 1G, VLAN 5 — pinned by a **MikroTik DHCP reservation**, not a TrueNAS static (see the 19:30 section) |
| MTU | **9000**, and raise that CRS317 port's L2MTU to 9214 to match the three node-storage ports. TCP MSS negotiation would hide a 1500/9000 mismatch — it would "work" while silently losing jumbo on the one link that most benefits |
| Pool | `tank` |

**Accepted costs, recorded so they are not rediscovered as surprises:**

1. **Ceph and the NAS now share a failure domain.** A backnet incident takes out both at once.
   Two in the last two months: node6's NIC came back `DOWN` after a reboot (2026-07-25), and
   the 10G switch firmware upgrade flapped every node's link (2026-08-07). During those, the
   NAS stops being an independent fallback.
2. **TrueNAS holds an interface on frontnet *and* backnet**, bridging two otherwise-isolated
   segments. It does not route by default — do not enable `ip_forward` on it.
3. The spare `enp1s0f1np1` on each node stays unused. That is fine; it remains runway.

### Shipped: additive TrueNAS StorageClasses, gated off

`components/storage/nfs-csi/` now renders `nfs-truenas-media` and `nfs-truenas-immich`
alongside the existing `nfs-csi`, behind `truenas.enabled` (default `false`) — the same
inert-until-enabled gating precedent as the CNPG R2 work.

**Additive, not a mutation of `nfs-csi`.** StorageClass `parameters` and `reclaimPolicy` are
immutable, and a PVC's `storageClassName` is immutable too — so a backend migration is a
delete+recreate of both, never an edit. Keeping both classes live for the whole overlap means
rollback is "point the PVC back", not "re-edit a class". `reclaimPolicy: Retain` matches
`nfs-csi` and `cephfs-hdd`: deleting a PVC must never destroy data.

### Caught on the way in: csi-driver-nfs version drift

CLAUDE.md warns about exactly this shape and it was live here:

```
Chart.yaml   → csi-driver-nfs 4.13.4
Chart.lock   → 4.11.0        (gitignored, so not reviewable)
charts/*.tgz → 4.11.0        (stale vendored tarball)
```

So a local `helm template` rendered **4.11.0** while ArgoCD, which runs `helm dependency
update` fresh at sync time, deployed **4.13.4**. Confirmed against the cluster:

```
$ oc -n nfs-csi get pods -o jsonpath='…{.image}…' | sort -u
registry.k8s.io/sig-storage/nfsplugin:v4.13.4
```

Harmless in itself — 4.13.4 is what `Chart.yaml` asked for and it is Synced + Healthy. But it
means **every local diff review of this chart was reviewing fiction**, which is not acceptable
now that media and Immich are about to depend on it. That is the same mechanism as the
2026-06-12 Rook v1.20 CSI outage: an unreviewed subchart version reaching the cluster because
the local render disagreed with the deployed one.

Fixed the same way Rook was: `helm dependency update` (pulls the real 4.13.4 tarball,
regenerates the lock), then un-gitignore `components/storage/nfs-csi/Chart.lock` so the
deployed subchart version is pinned and reviewable. Local render now matches live.

```
$ helm template nfs-csi components/storage/nfs-csi/ --set truenas.enabled=true | grep nfsplugin
          image: "registry.k8s.io/sig-storage/nfsplugin:v4.13.4"
$ … | kubeconform -strict -ignore-missing-schemas …   # exit 0
```

Net cluster change: **zero**. ArgoCD was already running 4.13.4; the repo now says so.

### Burn-in: tmux does not work in the TrueNAS web shell

`tmux new -s burnin` exited instantly and leaked terminal capability responses into zsh
(`1;2c`, `0;276;0c`, `10;rgb:ffff/ffff/ffff` → `zsh: command not found: 1`). Those are DA1 and
OSC-11 *replies* — the signature of tmux querying a terminal that cannot answer, i.e. the
web-UI shell rather than a real SSH pty.

TrueNAS SCALE is systemd-based, so transient units are the better tool anyway — no TTY
needed, survives disconnect, real exit status afterwards:

```bash
for d in sda sdb sdc sdd sde sdf; do
  systemd-run --unit=burnin-$d \
    badblocks -wsv -b 4096 -c 32768 -t random -o /root/bb-$d.log /dev/$d
done
systemctl list-units 'burnin-*'
journalctl -u burnin-sda -f
```

`--collect` deliberately omitted so failed units persist for inspection.

> **Correction (2026-08-27):** `-t random` did **not** survive into the running
> process — see the 08-27 entry below. What actually ran is the block above
> minus `-t random`, i.e. the 4-pattern default. The ~61 h ETA computed on
> 08-26 is correct *because of* that; had `-t random` applied, it would have
> been one pattern and ~15 h.

## 2026-08-25 (late) — config-as-code: why `midclt`, not REST, not Terraform

Burn-in is running (all six drives, full 4-pattern `badblocks`, ~70 h), so the
useful work is the configuration layer. The question was simply "Ansible or
Terraform?" and the answer turned on one fact neither option advertises.

### The finding that decided it

TrueNAS has two management APIs, and the older one is on a clock:

| API | Status on 25.10 | Reachable from `ansible.builtin.uri`? |
|---|---|---|
| REST `/api/v2.0/` | **Deprecated in 25.04, REMOVED in TrueNAS 26** | Yes |
| JSON-RPC 2.0 over WebSocket | Current | **No** — `uri` is HTTP-only |

Verified empirically on the box before designing anything:

```
$ curl -sk -o /dev/null -w 'v2.0  -> %{http_code}\n' https://localhost/api/v2.0/system/info
v2.0  -> 401
$ curl -sk -o /dev/null -w 'current -> %{http_code}\n' https://localhost/api/current/system/info
current -> 404
```

`401` means present-but-unauthenticated; `404` means the path shape is not used.
So REST **works today**. But iX's own docs say *"The TrueNAS REST API was
deprecated in TrueNAS 25.04. Full removal of the REST API is planned for
TrueNAS 26"*, TrueNAS 26 is already at **BETA.3**, and from 25.10.1 the box
raises a **daily alert** every time REST is used. Its 25.10 coverage is also
already incomplete — the OpenAPI spec has no ZFS snapshot endpoints at all.

That kills the obvious approach. Copying `roles/technitium-config` verbatim —
`ansible.builtin.uri` against a documented REST surface — would have been a
half-hour job, and would have been a scheduled rewrite at the next major
upgrade, on a box that is about to become a hard dependency for live Immich and
Jellyfin.

### What was chosen: `midclt` over SSH

`midclt` is the middleware's local CLI, talking to the same method surface over
a UNIX socket — it is what the web UI drives. Properties that matter here:

- **Indifferent to the HTTP→WebSocket transition.** Code written now still works
  after the 26 upgrade.
- **Stays inside the all-builtin invariant.** Verified: the entire topic uses
  only `ansible.builtin.{command,assert,set_fact,debug}`.
- **No API key at all.** It authenticates as root on the box, so **SSH access is
  the credential**. The vault shrinks to SMTP settings only.
- **Honest change reporting**, which the technitium precedent does not have:
  `ansible.builtin.uri` hardcodes `changed = False` unless `dest:` is used, so
  every API task in `technitium-config` reports `ok` forever whether or not it
  mutated anything. `command` + explicit conditionals gives a real play recap,
  which is what makes drift visible under a code-only culture.

Rejected, with reasons:

- **`ansible.builtin.uri` + REST** — the tempting copy-paste. Expiry date.
- **Terraform** — the field is eight single-maintainer providers with no iX
  involvement. The most capable (`PjSalty/truenas`, the only one covering
  NUT) is a 4-month-old repo modelling pool creation as an opaque
  `topology_json` blob that names disks as raw `sda`/`sdb` — on a box whose boot
  device is also SATA, against a repo rule of never `/dev/sdX`, always by-id.
  The most-downloaded (`dariusbakunas`, 44k) is archived and REST-only. And it
  would add a state file to a repo with no Terraform, i.e. a second place for
  drift to live next to a NAS whose live state `midclt` can just read.
- **`arensb.truenas` collection** — fails the all-builtin invariant first, but
  fails on merit too: no pool module, no replication module, and open 25.10
  breakage. Mechanically it is a wrapper around `midclt` on the target — so this
  approach is the same transport minus the broken wrappers.
- **`config.save` as the source of truth** — that is DR, not IaC. A SQLite DB in
  a tar: not diffable, not reviewable, not partially applicable, and restoring
  reboots the box. With `secretseed: true` it decrypts every stored credential
  and can never live in this repo; without it, every password silently resets.
  It also does not carry the pool. Scheduled off-box artifact, not source of truth.

### Shipped: `ansible/truenas/`

Mirrors `ansible/technitium/` in shape — same three-playbook split, same
per-topic `.gitignore` + `vars/vault.yml.example`, same README structure.

```
ansible/truenas/
├── inventory.yml            # host truenas @ 192.168.1.25, truenas_admin, NO become
├── group_vars/all.yml       # ALL declarative inputs
├── vars/vault.yml.example   # SMTP only — no api key exists in this topic
├── playbook.yml             # full convergence (needs vault)
├── check.yml                # read-only state report (NO vault)
└── roles/
    ├── truenas-storage/     # assert pool, converge datasets
    ├── truenas-system/      # timezone, NTP, alert email
    ├── truenas-shares/      # NFS exports + service
    └── truenas-tasks/       # scrub, SMART, periodic snapshots
```

The middleware is a **CRUD API, not a declarative one**, which dictated the
task shapes. Two namespace shapes exist: *singletons* (`<ns>.config` +
`<ns>.update`) that genuinely no-op on re-assert, and *collections*
(`<ns>.query` + `.create`/`.update`/`.delete`) whose identity is an integer id
with no natural key — so a blind re-run would happily stack duplicate NFS
exports. Every collection task therefore queries first and matches on a natural
key we choose (dataset path, export path, pool id).

**The pool is asserted, never created.** `pool.create` is the most dangerous
method on the box: re-run against an existing name it errors, and re-run against
wiped disks it would silently build a new empty pool where the old one was. The
storage role fails loudly if `tank` is absent and tells the operator to create
it by hand. Deliberately not automated even behind a guard — the research could
not confirm that `pool.create`'s name-collision validator fires *before*
`format_disks`, and "probably validates first" is not a bet worth taking with
six drives of data behind it.

`ashift` appears nowhere in the role: it is a per-vdev, create-time-only ZFS
value that cannot be changed afterwards under any circumstance. Representing it
as desired state would be a lie. It is recorded in the README as a property of
the creation event instead.

### Gaps recorded rather than papered over

- **NFS exports ship without `maproot`/`mapall`.** The two current consumers
  write with different UID shapes — Immich under OpenShift's injected random
  namespace UID, the servarr apps as PUID/PGID 0 — and both work against DSM
  today. Reproducing both needs deliberate mapping plus dataset ACLs, which
  depends on users/groups converging first (the middleware resolves `maproot`
  via `user.get_user_obj` at validation time). Users are out of scope for now,
  so **each write shape must be tested before a cutover window, not inside one.**
- **`keepers` was initially missed** from the dataset list despite being a live
  50 Gi NFS consumer (`keepers/keepers-data-pvc`). Added.
- **`tank/backups` vs `tank/backup`** resolved by having no `backups` at all —
  the two source notes used names one keystroke apart for different purposes
  (machine-backup targets vs the offsite-replicated tree), and a machine-backup
  tree inheriting the offsite policy is a borg repo that quietly is not the size
  you think.
- **`tank/apps` added** — the NUT tooling has to live on the pool because
  `/root` and `/etc` do not survive TrueNAS updates. Neither source dataset
  layout had it.
- **Network config is out of scope.** Automating the network of a box you reach
  *over* that network is how you lock yourself out, and TrueNAS's
  commit-then-confirm rollback does not survive an Ansible run whose connection
  has already dropped.
- **SSH hardening is out of scope.** `ssh.update` restarts sshd — the transport
  the run depends on. 25.10 also has no `rootlogin` parameter (stale blog posts
  still cite one); root login is per-user via `user.update`. `check.yml` reports
  the state instead of enforcing it.

Validation:

```
$ ansible-playbook -i inventory.yml playbook.yml --syntax-check   # clean
$ ansible-playbook -i inventory.yml check.yml    --syntax-check   # clean
$ grep -rhoE "[a-z_]+\.[a-z_]+\.[a-z_]+:" ansible/truenas/ | grep -v '^ansible\.builtin\.'
(empty — all-builtin invariant holds)
```

Nothing has been run against the box yet: the pool does not exist until burn-in
finishes, and `truenas-storage` will correctly refuse to proceed until it does.

## 2026-08-25 (19:30) — why the 10G interface would not take an IP

Symptom: setting an IPv4 address on `enp2s0f0np0` "does not apply properly" — the
UI accepts it, `midclt call interface.update` returns the updated record, and the
address never appears in `ip -br a`.

### It was not the MTU

That was my first hypothesis and it was wrong. `interface.query` shows the live
kernel MTU already at 9000 while the desired value is unset:

```
enp2s0f0np0    dhcp=True  desired=-  live=-  mtu=None->9000
```

Jumbo had applied and survived. Only the address failed.

### The actual cause: TrueNAS's interface DB is authoritative AND exclusive

`/var/log/middlewared.log`, one commit cycle:

```
18:13:24 InterfaceService.configure()  Configuring interface 'enp2s0f0np0'
18:13:24 InterfaceService.configure()  enp2s0f0np0: adding 192.168.10.10/255.255.255.0
18:13:24 InterfaceService.sync()       Interfaces in database: enp2s0f0np0
18:13:24 InterfaceService.unconfigure() Unconfiguring interface 'eno1'
18:13:24 InterfaceService.unconfigure() Unconfiguring interface 'eno2'
18:13:24 InterfaceService.unconfigure() Unconfiguring interface 'enp2s0f1np1'
18:14:24 InterfaceService.sync()       Interfaces in database: NONE
18:14:24 InterfaceService.unconfigure() Unconfiguring interface 'enp2s0f0np0'
18:14:25 RouteService.sync()  ERROR  Failed adding 192.168.1.1 as default gateway:
                                     NetlinkError(101, 'Network is unreachable')
```

Read the third line: **`Interfaces in database: enp2s0f0np0`** — exactly one. Any
interface NOT in TrueNAS's config database is **unconfigured on every apply**.
`eno1` came up via DHCP at install time and was never committed, so it exists
only as a `dhclient` lease. So the sequence is:

1. `commit` applies the 10G address **and tears down `eno1`**,
2. the default gateway (`192.168.1.1`, reachable only via `eno1`) becomes
   unreachable — hence the `NetlinkError(101)`,
3. connectivity validation fails, and at **exactly +60 s** the rollback timer
   fires and wipes everything back to `Interfaces in database: NONE`.

`interface.checkin` returned `null` (success) but could not save it: by the time
it ran, the network it was meant to validate had already been dismantled. The
same mechanism explains the earlier UI attempts.

Confirmed by querying the box directly — after the rollbacks, **nothing** is
managed and the working default route belongs to dhclient, not TrueNAS:

```
eno1           dhcp=True  desired=-  live=['192.168.1.25']  mtu=None->1500
eno2           dhcp=True  desired=-  live=-                 mtu=None->1500
enp2s0f0np0    dhcp=True  desired=-  live=-                 mtu=None->9000
enp2s0f1np1    dhcp=True  desired=-  live=-                 mtu=None->1500
gw4 = (unset)   ns1 = (unset)   domain = local
```

### The fix, and the trap inside the fix

`eno1` must be **in the database** before any commit touches the 10G port.

The obvious move — give `eno1` a static address — contains its own trap: changing
the management IP in the same commit drops the SSH session mid-apply, so
`interface.checkin` never runs and the whole thing rolls back at +60 s. The
failure looks identical to the original bug.

Chosen instead (2026-08-25): **a MikroTik DHCP reservation pinning `eno1` to
`192.168.1.25`**, and telling TrueNAS to manage the interface *as DHCP*. That
puts `eno1` in the database (so it stops being torn down) without ever changing
the address, so the session survives the apply and the check-in lands. The
address is pinned at the router, which is where reservations belong anyway.

Also worth recording: the management address had already drifted `.67 → .25`
between two screenshots during this session. An unpinned mgmt IP would have
broken the cert-sync CronJob and the Technitium `nas` record later.

## 2026-08-25 (20:00) — the ansible role, validated against the real box

Three corrections that only surfaced by running it rather than reasoning about it.

**1. `become` was unnecessary, and would have hung the playbook.** I had written
`ansible_become: true` on the assumption that `midclt` needs root. It does not:

```
$ sudo -n true
sudo: a password is required          <-- would have hung every run

$ id
uid=950(truenas_admin) gid=950(truenas_admin) groups=950(truenas_admin),544(builtin_administrators)

$ for m in interface.query pool.query pool.dataset.query sharing.nfs.query \
           system.general.config service.query; do
    printf "%-26s " "$m"; midclt call $m >/dev/null 2>&1 && echo OK || echo DENIED
  done
interface.query            OK
pool.query                 OK
pool.dataset.query         OK
sharing.nfs.query          OK
system.general.config      OK
service.query              OK
```

Membership in **`builtin_administrators` (gid 544)** is what authorises the
middleware socket. So the whole topic runs **unprivileged** — no `become`, no
become-password in the vault, no sudo prompt. Recorded in `inventory.yml` with a
warning not to "fix" a future permission error by adding `become`: if a method is
refused, the account's ROLE is the thing to look at.

**2. The SSH key is `id_rsa`, not `vadz_key`.** The Technitium topic uses
`vadz_key`; the TrueNAS admin account was set up with a different key. Copying the
inventory verbatim produced `Permission denied (publickey)`.

**3. Two Jinja bugs in `check.yml`, both caught only by execution.**

```
'>' not supported between instances of 'int' and 'str'
```
`|` binds tighter than `>`, so `x | length > 0 | ternary('PRESENT','ABSENT')`
parses as `length > ('PRESENT')`. Needs explicit parens.

```
object of type 'dict' has no attribute 'healthy'
```
`ternary` evaluates **both** branches eagerly, so `_pool.healthy` was evaluated
even when the pool was absent and `_pool` was `{}`. Jinja's inline `if/else` is
lazy; `ternary` is not. Both `--syntax-check` and `helm lint`-style static checks
pass straight over these — only running it finds them.

Result, against the live box:

```
$ ansible-playbook -i inventory.yml check.yml
TASK [Report]
ok: [truenas] => {
    "msg": [
        "version   : TrueNAS-25.10.6",
        "pool      : ABSENT - create it by hand first, see README",
        "datasets  : (none)",
        "nfs       : (none)"
    ]
}
PLAY RECAP
truenas : ok=5  changed=0  unreachable=0  failed=0
```

`changed=0`, and the pool guard correctly refuses with the right instruction.
The transport, the unprivileged `midclt` path and the JSON parsing are all
validated — before the pool exists, which is the right time to find out.

Burn-in still running: all six units `active running`.

## 2026-08-25 (20:15) — storage network live, and the last failure was the switch

After the interface-database fix landed, the address stuck past the rollback
window but `ping 192.168.10.2` still failed:

```
From 192.168.10.10 icmp_seq=1 Destination Host Unreachable
```

That wording matters. On a **directly-attached** subnet, "Destination Host
Unreachable" sourced from *your own address* is not a routing failure — it is
the local kernel reporting that **ARP got no reply**. Confirmed:

```
$ ip neigh show dev enp2s0f0np0
192.168.10.2 FAILED

$ ip -s link show enp2s0f0np0
RX:  bytes packets errors dropped  missed   mcast
    220472    1016      0       0       0    1016     <-- ALL RX is multicast
TX:  bytes packets errors dropped carrier collsns
    111158     442      0       0       0       0

$ ethtool enp2s0f0np0 | grep -iE "speed|link detected"
Speed: 10000Mb/s
Link detected: yes
```

**Zero unicast received, 1016 of 1016 RX packets multicast.** A healthy 10G link
hearing broadcast chatter from *some* VLAN while being invisible to the nodes —
the signature of a port sitting in the wrong VLAN (broadcast noise from frontnet
rather than silence from a dead link). Nothing left to fix on TrueNAS; it was the
CRS317 port's VLAN membership plus its `l2mtu`, neither of which had been set for
this new port. The three node-storage ports had been done back on 2026-05-21.

Useful trick for finding which physical port a DAC landed in, without tracing
cables: look the MAC up in the switch's bridge host table.

```
/interface/bridge/host/print where mac-address=E8:EB:D3:10:76:CE
```

After the switch-side fix — VLAN 10 untagged + `pvid=10` + `l2mtu=9214`, matching
the node ports:

```
$ for n in 2 3 4; do ping -c2 -W2 -q 192.168.10.$n; ping -c2 -W2 -q -M do -s 8972 192.168.10.$n; done
node@192.168.10.2   std=0% packet loss   jumbo9000=0% packet loss
node@192.168.10.3   std=0% packet loss   jumbo9000=0% packet loss
node@192.168.10.4   std=0% packet loss   jumbo9000=0% packet loss

$ ip neigh show dev enp2s0f0np0
192.168.10.2 lladdr ec:0d:9a:75:a5:d8 REACHABLE
192.168.10.3 lladdr ec:0d:9a:75:a6:88 REACHABLE
192.168.10.4 lladdr ec:0d:9a:75:a6:e0 REACHABLE
```

`-M do -s 8972` is the test that matters and it is worth insisting on: 8972 bytes
of payload plus 28 of header is exactly a 9000-byte frame, and `-M do` sets DF so
no hop is allowed to fragment it. Without it, standard pings pass on a 1500-byte
path and the jumbo misconfiguration only surfaces later as NFS silently
black-holing large writes — mid-migration, on 7 TiB.

**The storage network path is done.** TrueNAS `192.168.10.10/24` on the Ceph
backnet, MTU 9000, all three nodes reachable at both frame sizes. Repo updated:
`components/storage/nfs-csi/values.yaml` now points at `.10` (the earlier `.5`
was a plan, `.10` is what exists).

### Running total of what this evening actually cost

Three separate faults stacked on one symptom ("the IP won't apply"), and only the
last one was where anyone would have looked first:

1. **`eno1` not in the interface database** → every commit tore down management
   and the default gateway → connectivity validation failed → +60 s rollback.
   Fixed by making `eno1` a managed DHCP record (no address change, so the SSH
   session survived to run `checkin`) plus a MikroTik reservation pinning `.25`.
2. **MTU was never the problem** — it had applied and persisted at the kernel
   level the whole time. I suspected it first and was wrong.
3. **The CRS317 port was in the wrong VLAN with a default `l2mtu`.**

The lesson worth keeping: `interface.update` returning the updated record proves
only that the *desired config* was stored. The `state` sub-object is the live
kernel, and when the two disagree the middleware log is the only place the reason
appears — none of it surfaces as an error from `commit` or `checkin`, both of
which returned `null` (success) throughout.

### Address allocation — and a collision I proposed and did not catch

`192.168.1.13` is **allocated to `dns-slave`**, confirmed by the operator
2026-08-25. It has been earmarked there since the Technitium migration:
`ansible/technitium/inventory.yml` carries a commented `dns-slave` stub with
`ansible_host: 192.168.1.13`, and `blog-technitium-dns-migration-draft.md`
references it in three places.

I proposed `.13` for the TrueNAS management address earlier the same day, having
already read that inventory file in the same session. The collision never
happened only because DHCP moved the box's lease `.67 -> .25` and we pinned `.25`
at the router instead — luck, not diligence. Recording it because the fix is
mechanical: **check `ansible/*/inventory.yml` before proposing any LAN address**,
since that is where reservations actually live; the vault's IP-plan table stops
at `.12` and calls everything above it "Reserved DHCP", which is no longer true.

Frontnet allocations as they actually stand:

| IP | Host |
|---|---|
| .1 | Gateway (MikroTik CCR2004) |
| .2 | Synology DS418 (until sold) |
| .3 | Mac mini |
| .4–.6 | old node1-3 |
| .7–.9 | node4/5/6 |
| .10–.11 | reserved, future node7-8 |
| .12 | dns-master (Technitium primary) |
| **.13** | **dns-slave** — RPi 3B+, not yet built |
| **.25** | **truenas** — MikroTik DHCP reservation |

Two doc-drift items fixed in `blog-technitium-dns-migration-draft.md` while
confirming this: the secondary's IP was still recorded as *"TBD (likely
192.168.1.13)"*, and the hardware was still described as an **RPi Zero 2W** in
three places — superseded 2026-08-19 in favour of an RPi 3B+ (the Zero 2W has no
Ethernet at all, 512 MB, and a ~2026-12-04 ship date on what is currently a
single point of failure).

Naming note: the operator called it `dns-slave`; the repo consistently uses
`dns-slave`, which is both the modern DNS term and what Technitium's own UI
calls the zone type. Keeping `dns-slave` in code unless told otherwise.

## 2026-08-26 — burn-in at ~19 h: the ZCAV curve says the drives are fine

TrueNAS's per-disk I/O graph for `sda` (HUS726040ALA610, serial K7GE89HL) over
the first 19 hours:

| Pass | Window | Duration |
|---|---|---|
| Pattern 1 write | 17:45 → 01:30 | ~7.75 h |
| Pattern 1 read | 01:30 → 09:00 | ~7.5 h |
| Pattern 2 write | 09:00 → in progress | — |

Each pass starts at **191 MiB/s** and declines smoothly to **~100 MiB/s**. That
is the **ZCAV** curve — zoned constant angular velocity. Outer tracks hold more
sectors per revolution than inner ones, so sequential throughput falls roughly
by half as the head walks inward. It is the expected shape for a healthy
spinning disk, and 191 MiB/s is at spec for a 4 TB 7200 rpm SATA drive.

**What matters is what is NOT in the trace.** On a drive with latent defects you
see sawtooth dips where reads are retried, sudden cliffs, or plateaus where the
drive stalls. There are none. The write and read passes trace the *same* curve,
so there is no asymmetric weakness either — a drive that writes fine and reads
badly (or vice versa) shows two different shapes.

For a 5-year-old datacenter pull at 43,361 power-on hours, that is about as good
as the mechanics can look.

### Revised ETA, measured rather than estimated

One full pattern (write + read) ≈ **15.25 h**. `badblocks -w` runs four patterns
(`0xaa`, `0x55`, `0xff`, `0x00`), so 8 half-passes ≈ **61 h** total — close to
the ~70 h originally guessed, now measured from the machine instead. Started
2026-08-25 17:45, so it completes **early Friday 28 Aug**. At the time of the
graph it was ~19 h in, on half-pass 3 of 8: **~31 % done**.

All six units confirmed `active`:

```
$ systemctl list-units 'burnin-*'
sda active | sdb active | sdc active | sdd active | sde active | sdf active
```

Note the progress percentages badblocks writes to stderr land in journald, which
`truenas_admin` cannot read without sudo — so the TrueNAS disk graph is actually
the better instrument here, and it shows pass boundaries the text output would
not make obvious at a glance.

**Still to do when it finishes:** SMART long test on all six, then diff against
the baselines captured before the run (`/root/smart-baseline-*.txt`). Any growth
in `Reallocated_Sector_Ct`, `Current_Pending_Sector` or `Offline_Uncorrectable`
against the zeros recorded on 2026-08-25 means that drive does not go in the
pool. Only then is `truenas-storage`'s pool assert satisfiable.

## 2026-08-27 — measuring badblocks progress without root, and a dropped flag

At ~40 h in, the `sda` disk graph showed **six** completed sawteeth and a seventh
starting — alternating write (magenta) and read (blue), each tracing the same
191 → 100 MiB/s ZCAV curve as on day one. Still no dips, cliffs or plateaus on
any pass.

Six sawteeth is the interesting number. A single-pattern run (`-t random`) is
**two** half-passes. Six means the flag was not in effect.

### Confirming it

`systemctl status` prints the real cgroup command line, and that needs no
privilege:

```
$ systemctl status burnin-sda --no-pager -l | tail -3
     CGroup: /system.slice/burnin-sda.service
             └─10144 /sbin/badblocks -wsv -b 4096 -c 32768 -o /root/bb-sda.log /dev/sda
```

No `-t random`. **`systemd-run` did not eat it** — that was my first theory and
it is wrong: `-w`, `-s`, `-v`, `-b`, `-c` and `-o` all survived, and if
`systemd-run` were permuting options past the command name it would have
rejected `-w` outright (it has no such option). systemd's `getopt_long` optstring
carries a leading `+`, which disables permutation precisely so a wrapped
command's own flags pass through untouched. The flag was therefore lost in the
shell, before `systemd-run` was invoked — most plausibly while fixing the
missing `;` before `done` in the original paste.

**Consequence: the drives get a better burn-in than specified.** Four
solid/alternating patterns (`0xaa`, `0x55`, `0xff`, `0x00`) exercise every bit
cell in both states; one random pattern does not. The cost is wall-clock only,
~58 h against ~15 h, and it was 78 % spent by the time anyone noticed. Nothing
to decide.

### The measurement that actually answers "how far along?"

Everything badblocks emits about progress on this box is root-only: the `-o`
logfile lands in `/root`, the stderr percentages go to journald (`truenas_admin`
is in neither `adm` nor `systemd-journal`), and `/proc/<pid>/io` belongs to root.
`sudo` wants a password, and the box is Ansible-managed code-only, so
interactive escalation is not the move.

But `/proc/diskstats` and `/sys/block/<d>/size` are both world-readable, and
their ratio is an exact pass count:

```bash
SZ=$(cat /sys/block/sda/size)
for d in sda sdb sdc sdd sde sdf; do
  awk -v d=$d -v sz=$SZ '$3==d {printf "%s rd=%.2f wr=%.2f\n", d, $6/sz, $10/sz}' /proc/diskstats
done
```

`$6` is sectors read, `$10` sectors written, both in 512 B units — the same unit
as `/sys/block/*/size`, so the division is unitless and needs no scaling. On a
raw unpooled disk badblocks is the only writer, so the counters are clean.

```
dev  rd_pass  wr_pass
sda  3.00  3.19      sdd  3.00  3.15
sdb  3.00  3.43      sde  3.00  3.23
sdc  3.00  3.25      sdf  3.00  3.27
```

Exactly three read passes everywhere and a fraction over three writes: the run
is inside **W4**, the final write pass, with only **R4** after it. `rd_pass`
being 3.00 on all six — not 2.97, not 3.04 — is itself a small proof that
nothing is being retried.

### Final ETA, integrating the curve instead of averaging it

Averaging the ZCAV curve flatters the remainder, because the 81 % of W4 still
outstanding is the *slow* inner-LBA part. With throughput linear in LBA,
`v(x) = 190 − 90x` MiB/s, pass time is `S·∫dx/v(x)`:

- full pass: `S·(1/90)·ln(190/100)` = 7.56 h (measured: 7.29 h — close enough)
- rest of W4 (x = 0.19 → 1): 6.4 h
- R4 in full: 7.6 h

**≈ 14.0 h remaining**, so all six complete **Friday 28 Aug, ~02:45–03:15**
(sdd trailing, sdb leading). Unchanged from the 08-26 estimate, now confirmed
from the kernel's own counters rather than read off a graph.

**Lesson worth keeping:** when a long-running job's own progress output is
locked behind privilege you have deliberately not granted yourself, look for a
kernel counter that is world-readable instead. `/proc/diskstats` answered a
question the process's logfile, journal and `/proc/<pid>/io` all refused to.

## 2026-08-28 — burn-in done; and TrueNAS 25.10 deleted SMART out from under the role

Eight sawteeth, then flat. All four `badblocks` patterns complete.

```
$ systemctl list-units 'burnin-*' --all
(empty)

dev  rd_pass  wr_pass
sda  4.00  4.00      sdd  4.00  4.00
sdb  4.00  4.00      sde  4.00  4.00
sdc  4.00  4.00      sdf  4.00  4.00
```

Two independent confirmations. `--collect` was deliberately omitted when the
units were created, so a **failed** transient unit would still be sitting there
in `failed` state — an empty list is the success signal, not an absence of
information. And `rd=4.00 wr=4.00` exactly, on all six: four write passes, four
read passes, no fractional overshoot from retried I/O.

48 full-surface traversals across six 4 TB drives. ~87 TB written and verified,
zero anomalies in the throughput trace.

One thing I am **not** claiming: that this proves a clean surface. I am not
certain `badblocks` exits non-zero merely for *finding* bad blocks (as opposed
to failing to run), so "no failed units" is weaker evidence than it looks. The
bad-block lists in `/root/bb-*.log` are root-only. SMART is the real verdict.

### Which is where the day went sideways

The plan said "SMART long test on all six, diff against the baselines". That
step does not exist on this platform any more.

```
$ midclt call smart.test.query
Method does not exist
$ midclt call core.get_methods | grep -i smart
(nothing)
$ systemctl list-units '*smart*' --all
(empty)
$ midclt call disk.query | jq '.[0] | keys' | grep -i smart
(nothing)
$ smartctl -H /dev/sda
Smartctl open device: /dev/sda failed: Permission denied
```

No `smart.*` namespace, no smartd unit, no smartd process, no SMART fields on
the disk record. Not a permissions artefact either — `disk.wipe` *is* in the
method list, so this account is not being filtered down.

That is a big claim (a whole subsystem removed), and I had already been wrong
once this week by trusting a truncated source, so I checked upstream rather
than my own probing. It holds: **TrueNAS 25.10 "Goldeye" removed SMART test
scheduling — UI and API both.** smartmontools stays installed, existing
schedules are rewritten as **cron tasks** on upgrade, and the suggested
replacements are user-managed cron or the Scrutiny app.

**We are a fresh install, so nothing was migrated. Nothing tests these drives
and nothing reads the results. There is no default.**

### What this broke in code I had already written

`roles/truenas-tasks/` called `smart.test.query` and `smart.test.create`. It
would have hard-failed the first time the operator ran `playbook.yml` — caught
here only because the burn-in finishing sent me looking for the SMART step.

Worse, `group_vars/all.yml` already had:

```yaml
truenas_smart_short_cron: "0 3 * * 0"
truenas_smart_long_cron:  "0 4 1 * *"
```

…as **cron strings**, which the role never read — it built `schedule:` dicts
instead. So the variables were dead *and* the code was dead, in opposite
directions, and neither `--syntax-check` nor a lint pass can see either.

### The replacement

Three `cronjob.create` entries, which is the same mechanism upstream migrates
to. Idempotency key is `description`, because middleware identity is an integer
id.

| Job | Schedule | stdout | Purpose |
|---|---|---|---|
| SMART short, all disks | Sun 03:00 | hidden | quick weekly check |
| SMART long, all disks | 1st 04:00 | hidden | full surface monthly |
| SMART health report | daily 07:00 | **mailed** | reads results, mails only on trouble |

The third job is the one that matters. `smartctl -t` only *starts* a test; the
result lands hours later, and with smartd gone nothing would ever look at it.
Scheduling tests without scheduling a reader is how you get a drive that has
been failing its self-test for a month in silence.

It stays quiet by design — TrueNAS only mails a cron job whose stdout is
non-empty, so healthy runs produce no mail at all:

```sh
for d in $(smartctl --scan | cut -d" " -f1); do
  smartctl -H -l selftest "$d" >/dev/null 2>&1; rc=$?
  [ $((rc & 152)) -ne 0 ] && echo "SMART ALERT $d rc=$rc"
done; true
```

**Why 152 and not "any non-zero".** smartctl's exit status is a bitmask. 152 =
8 (disk failing now) + 16 (prefail attribute below threshold now) + 128 (a
self-test logged an error). Deliberately excluded: 32 ("attribute was below
threshold **in the past**") and 64 ("errors present in the ATA error log").
These are 43,000-hour datacenter pulls — both bits are plausibly set from a
previous life, and a daily mail that always fires is a daily mail you learn to
delete unread. Alert fatigue is the failure mode being designed against, not
disk failure.

Verified by substituting a fake `smartctl`:

```
FAKE_RC=0   -> (silent)
FAKE_RC=64  -> (silent)      # historical log noise, correctly ignored
FAKE_RC=8   -> SMART ALERT /dev/sda rc=8
               SMART ALERT /dev/sdb rc=8
```

`cut -d" " -f1` rather than `awk '{print $1}'` is not stylistic: the command is
a single-quoted YAML scalar that gets JSON-encoded into a `midclt` argv, and
keeping single quotes out of it removes an entire class of escaping bug. Same
lesson as the `synology-cert-sync` f-string earlier this week, applied before
it bit rather than after. All three commands are `sh -n` clean.

### Still operator-run

`smartctl` needs root; `truenas_admin`'s sudo wants a password; the box is
code-only. So the post-burn-in verification — long test on all six, then diff
against `/root/smart-baseline-*.txt` — is the operator's to run. The cron jobs
above make it the *last* time that is true: from then on the schedule and the
reader are both in git.

### The verdict: six for six

```
== sda .. sdf  (identical on all six)
  5 Reallocated_Sector_Ct   0x0033   100   100   005    Pre-fail  Always  -  0
197 Current_Pending_Sector  0x0022   100   100   000    Old_age   Always  -  0
198 Offline_Uncorrectable   0x0008   100   100   000    Old_age   Offline -  0
```

Zero, zero, zero — on every drive. `WORST` is 100 as well, so none of these ever
dipped even transiently.

**The baseline diff turned out to be unnecessary, and provably so.**
`Reallocated_Sector_Ct` is a *monotonic* counter: it only grows. Reading 0 today
mathematically requires it to have been 0 on 2026-08-25. Zero is the floor, so
there is nothing a diff could reveal. Worth remembering as a general shortcut —
for a monotonic counter, a current reading at the floor makes the baseline
comparison redundant.

The other two are *not* monotonic (pending sectors can clear), so in principle
one could have spiked and resolved mid-run. But any sector permanently remapped
would appear in `Reallocated`, and that is 0; and a weak sector *recovered* by
being rewritten is exactly what a destructive write test is for. Conclusion
either way: **no sector on any of the six was remapped across ~87 TB of
writes**, on 43,000-hour datacenter pulls. Better than I expected.

## 2026-08-28 (cont.) — the pool gate

`truenas-storage` asserts the pool and never creates it, so the genesis event is
a manual step. The README said "Storage → Create Pool in the UI". Replaced with
a committed script, for a reason that only became visible while writing it.

`disk.query` gives a clean picture:

```
sda..sdf  HUS726040ALA610     4001 GB  pool=None
sdg       INTEL_SSDSC2BB480G6  480 GB  pool=None
$ midclt call boot.get_disks
["sdg"]
```

**The boot device is also SATA.** So the obvious move — read the disk list once,
paste `["sda"..."sdf"]` into a `pool.create` payload — is a latent trap: SATA
enumeration is not stable across reboots, and a list captured today can name the
boot disk tomorrow. That is the same hazard the root `CLAUDE.md` documents for
HDD bay installs, where the new drive took `sda` on node4 but `sdb` on node5/6.

So `bootstrap-pool.sh` re-derives the member set **at execution time** and
gates, fail-closed, on: model matches, disk not already in a pool, disk not in
`boot.get_disks`, count is exactly 6, and no pool exists yet. Verified in both
directions — the happy path prints the payload and changes nothing without
`--create`, and forcing a mismatch aborts with exit 1:

```
$ TRUENAS_DISK_COUNT=7 ./bootstrap-pool.sh ; echo $?
GATE FAILED:
  expected 7 disks, matched 6: ['sda', ..., 'sdf']
1

$ TRUENAS_DISK_MODEL=INTEL_SSDSC2BB480G6 TRUENAS_DISK_COUNT=1 ./bootstrap-pool.sh
GATE FAILED:
  expected 1 disks, matched 0: []
```

That second case is the useful one: aiming the gate directly at the **boot
SSD's own model** yields zero candidates, because `boot.get_disks` removed it
before the count check ever ran. The layers are independent, which is the point
of having more than one.

### A schema correction

Reading `pool.create`'s schema rather than assuming its shape turned up that
**`ashift` is not a parameter**. Accepted keys are `name`, `encryption`,
`topology`, `allow_duplicate_serials` and the dedup/checksum/encryption options
— nothing else. ZFS derives ashift from the disks' reported sector size.

The README had said "Confirm `ashift=12` at creation; it is immutable", which
implied it was settable there. It is immutable *and* not requestable: the only
option is to verify afterwards, and a wrong value means rebuilding the pool is
the sole remedy. Corrected, and `bootstrap-pool.sh` runs `zpool get ashift` as
part of its post-create verification for exactly that reason.

## 2026-08-28 (cont.) — why RAIDZ2 and not dRAID2

Asked at the only moment it can be asked: vdev geometry is immutable, and the
pool had not been created yet.

Prior art first — **`draid` appears nowhere** in this repo or the vault, zero
grep hits. So this was a genuinely open question rather than a re-litigation.

### Taking the dRAID case seriously

The chassis is **non-hot-swap with no backplane**: any drive swap is a full
power-down. dRAID's distributed spare rebuilds automatically, with no human
present and no hardware touched. That is a direct answer to a real operational
pain here, and it deserved better than a reflex "dRAID is for big arrays".

It fails on its own arithmetic.

dRAID distributes rebuild across **redundancy groups**, so the speedup is
roughly children / group width:

| children | group (D+P) | groups | speedup |
|---|---|---|---|
| **6** | **5** | **1.00** | **1.00×** |
| 12 | 10 | 1.10 | 1.10× |
| 30 | 10 | 2.80 | 2.80× |
| 90 | 10 | 8.60 | 8.60× |

At 6 children with a 5-wide group there is **exactly one group**. There is
nothing to distribute across, so the distributed spare — the entire feature —
returns nothing. The non-hot-swap argument was the whole case for dRAID, and it
evaluates to 1.00×.

### What it would have cost to find that out later

| | raidz2 6-wide | draid2:3d:6c:1s |
|---|---|---|
| Usable | **16.00 TB** / 14.55 TiB | 12.00 TB / 10.91 TiB |
| At 80% ceiling | **11.64 TiB** | 8.73 TiB |
| Parity overhead | 33.3% | 40.0% |
| Rebuild speedup | 1× | 1.00× |
| 4 KiB block on disk | 12 KiB | 20 KiB |
| 128 KiB block | 192 KiB (×1.50) | 220 KiB (×1.72) |
| Expandable later | **yes** | no |

- **The 25% capacity loss is two effects stacking.** A distributed spare drops
  effective children 6→5 *and* narrows the data stripe 4→3, so parity overhead
  climbs 33.3%→40.0% at the same time. `media` alone holds a 4 TiB quota today;
  8.73 TiB at the 80% ceiling is tight before immich/backup/keepers land.
- **The padding is real I/O, not bookkeeping.** From `module/zfs/vdev_draid.c`:
  *"dRAID always allocates a full stripe width. Any extra sectors due this
  padding are zero filled and written to disk."* Contrast `vdev_raidz.c`, where
  skip sectors are issued `ZIO_FLAG_NODATA | ZIO_FLAG_OPTIONAL`. TrueNAS
  accordingly floors dRAID datasets at 128 K recordsize — exactly where
  `backup`, `apps`, `personal` and `work` sit. Zero headroom.
- **It would waste the two free bays.** OpenZFS 2.3 added RAIDZ expansion, and
  `raidz_expansion` is live on this box (`zfs-2.3.4-1`, confirmed via
  `zpool upgrade -v`). `zpool-attach(8)` documents it for RAID-Z only and never
  mentions draid. RAIDZ2 can grow 6→7→8 in place; dRAID cannot, ever. The bays
  were reserved as `zfs send | recv` runway — expansion gives them a second,
  cheaper use.
- **Vendor guidance is unanimous and we are far under it.** TrueNAS: "fewer than
  10 disks … RAIDZ is strongly recommended". Klara: "<20 spindles … limited
  benefits". The TrueNAS dRAID primer targets arrays ">100" disks.

### The consistency check that settles it

dRAID's distributed spare is the same bet as a hot spare — and that was already
rejected, deliberately, on 2026-05-29: *"NOT a hot spare — hot spare burns a bay
and idle power for marginal benefit when RAIDZ2 already tolerates 2 failures."*
dRAID prices the identical bet worse: 25% of the pool instead of one bay.
Adopting it would have silently reversed a decision that had already been made
with its reasons written down.

`draid2:4d:6c:0s` (dRAID, no spare) was checked too and is strictly dominated:
identical capacity and fault tolerance to raidz2, minus variable stripe width,
minus the expansion path, plus the padding tax. Worth noting only because it is
what a bare `zpool create tank draid2 <6 disks>` produces by default — the
`data` parameter defaults to `N-P-S`.

**Verdict: RAIDZ2 6-wide stands. `bootstrap-pool.sh` needs no change.**

### Doc hygiene found on the way

The vault's `wiki/concepts/RAIDZ2.md` still described the **dead 4-wide layout**
("4× HGST 4 TB in RAIDZ2 = 8 TB usable"), superseded by the 6-wide re-scope on
2026-06-22 and never updated in the two months since. Corrected, with the dRAID
reasoning added, plus a decision note at
`_memory/chats/homelab/2026-08-28-raidz2-vs-draid2.md`.

## 2026-08-28 (cont.) — `tank` is up, and a `midclt` job-method trap

```
>>> creating pool 'tank' (destructive, one-shot)
8180

>>> verifying
cannot open 'tank': no such pool
```

That `8180` is not an error code — it is a **job id**, and it is the whole bug.

`pool.create` is a **job method**. A plain `midclt call pool.create …` enqueues
the job, prints its id and returns *immediately*; the pool is then built
asynchronously. My verification block ran microseconds later and correctly
reported that no pool existed yet. The run looked like a failure while actually
succeeding.

```
$ midclt call core.get_jobs '[["id","=",8180]]'
method   : pool.create
state    : SUCCESS
progress : 100  Setting pool options
$ midclt call pool.query
[('tank', 'ONLINE')]
```

Fix is one flag — `midclt call -job pool.create …` blocks until the job reaches
SUCCESS/FAILED and propagates a real exit status. Worth internalising as a
general `midclt` rule: **anything long-running is a job method, and job methods
need `-job` or every check you write afterwards races them.** The failure mode
is nasty precisely because it is silent-and-inverted — it reports failure on
success, which invites exactly the wrong follow-up action (re-running a
destructive create).

The gate is what made that safe. On the re-run it refuses:

```
$ ./bootstrap-pool.sh ; echo $?
GATE FAILED:
  a pool already exists: ['tank']
1
```

A destructive one-shot cannot be idempotent by re-execution, so it is idempotent
by *refusal* — which is the property that mattered in the one situation where a
confusing error message tempted a second run.

### Final state

```
  pool: tank
 state: ONLINE
	NAME          STATE     READ WRITE CKSUM
	tank          ONLINE       0     0     0
	  raidz2-0    ONLINE       0     0     0
	    41e7a725-…  ONLINE     0     0     0     (x6)
errors: No known data errors

$ zpool get -H -o value ashift tank
12
$ zfs list -o name,used,avail tank
tank  1.92G  14.4T
```

**`ashift=12`** — the immutable one, correct. **14.4 TiB available**, against the
14.55 TiB predicted from `(N−P)×X`; the delta is ZFS's ~1% reserved slop.

One nice detail: `zpool status` lists members as **GPT partition UUIDs**, not
`sdX`. TrueNAS partitions each disk and references the partition UUID, so the
enumeration instability that justified the whole gate does not apply to the pool
once it exists — only to the moment of creation, which is exactly where the gate
sits.

## 2026-08-28 (cont.) — two bugs that a green `--check` was hiding

First real run was `ansible-playbook … --check`. Recap: `ok=18 changed=0
skipped=11`. Everything skipped, nothing to do, looks converged.

It was not converged. The box at that moment had **one** dataset (`tank` itself),
zero NFS shares, zero cron jobs and zero snapshot tasks.

### Bug 1 — `--check` is structurally blind here

`ansible.builtin.command` **does not support check mode**. Every mutation in this
playbook is a `midclt` command call, so under `--check` Ansible skips all of them
*regardless of their `when:`*. The query tasks ran only because they carry
`check_mode: false`.

The trap is that **a when-false skip and a check-mode skip render identically**:

```
skipping: [truenas] => (item=tank/media)
```

There is no way to tell "already exists" from "cannot evaluate" by reading it.
`changed=0` did not mean converged; it meant *unanswerable*. Confirmed against
the box rather than inferred:

```
datasets    : 1 ['tank']
nfs shares  : 0 []
cron jobs   : 0 []
snap tasks  : 0 []
```

17 missing objects, reported as zero.

Fix: a `post_tasks` drift report. The *query* facts are trustworthy under
`--check`, and `debug` does support check mode, so the block turns those facts
into the answer `--check` should have produced — identical output in both modes:

```yaml
datasets_missing:       [tank/media, tank/immich, tank/keepers, ...]   # 8
nfs_exports_missing:    [/mnt/tank/media, /mnt/tank/immich, ...]       # 3
snapshot_tasks_missing: [tank/media, tank/immich, tank/backup]         # 3
cron_jobs_missing:      [SMART short…, SMART long…, SMART health…]     # 3
scrub_schedule_drift:   true
```

### Bug 2 — TrueNAS creates its own scrub task, so ours never applied

The one row that was *not* empty:

```
scrub tasks : 1 [1]
id=1 pool=1 threshold=35 enabled=True desc=''
  schedule: {"minute":"00","hour":"00","dom":"*","month":"*","dow":"7"}
```

**`pool.create` auto-creates a scrub task** — weekly Sunday 00:00, empty
description. The role's condition was `when: pool_id not in existing_scrub_pools`,
and pool 1 was in that list, so it would skip **forever**. The monthly-03:00
schedule declared in `group_vars` was never going to land. Git says one thing,
the box does another, and nothing reports the gap.

That is the same failure class as the dead `truenas_smart_*_cron` variables and
the removed `smart.*` API, three for three this week: **declared intent that
never executes.** Create-if-missing is not idempotence when something else also
creates the object.

Fixed by making it create-**or**-update (`pool.scrub.update` on drift).

**The padding trap inside the fix.** TrueNAS stores cron fields zero-padded —
`"00"`, not `"0"`. Comparing that against a declared `"0"`/`"3"` would report
drift on every run and re-issue the update forever: idempotence lost in the
opposite direction. Both sides are normalized with
`regex_replace('^0+(?=[0-9])', '')`, which strips leading zeros only when a digit
follows, leaving `*` and `7` alone. Verified across all three shapes:

```
live = TrueNAS default (Sun 00:00)      -> DRIFT=True    (converges)
live = after update, padded  "03"/"01"  -> DRIFT=False   (quiet)
live = after update, unpadded "3"/"1"   -> DRIFT=False   (quiet)
```

Converges once, then stays silent whichever way TrueNAS chooses to store it.

### The pattern

Three bugs in this topic now, all the same shape: **configuration declared in git
that never reaches the box**, each invisible to `--syntax-check`, `helm lint`, and
— as of today — to `--check` as well. The lesson is not "test more"; it is that
*absence of a reported change is not evidence of convergence* unless the tool can
actually evaluate the thing. Verify against the box.

## 2026-08-28 (cont.) — the apply landed; the drift report cried wolf

Full apply: 8 datasets, 3 NTP servers, 3 NFS exports, NFS enabled+started, the
scrub reconcile, 3 snapshot tasks, 3 SMART cron jobs. `changed=8, failed=0`.

Verified independently on the box rather than trusting the recap:

```
datasets   : 9  (tank + 8 children)
nfs shares : 3      cron jobs : 3      snap tasks : 3
scrub      : hour=3 dom=1 dow=*  desc='Monthly scrub (managed by ansible/truenas)'
nfs service: state=RUNNING enable=True
```

The scrub reconcile worked — TrueNAS's weekly Sunday-midnight default is now the
declared monthly 03:00. Note it stored the fields **unpadded** (`"0"`,`"3"`,`"1"`),
one of the three shapes the normalizer was tested against, so the next run
compares equal and stays quiet.

### But the drift report said everything was still missing

```
datasets_missing:    [tank/apps, tank/media, tank/work, ...]   # all 8
nfs_exports_missing: [/mnt/tank/media, ...]                    # all 3
scrub_schedule_drift: true
```

…printed immediately after successfully creating all of it.

The report consumed the facts captured by the roles' **query** tasks — which run
*before* their create tasks. So it reported pre-run state. Correct under
`--check` (nothing changes, so pre-state == current state), badly wrong after an
apply.

Ironic failure: the block added *this morning* to fix a misleading `--check` was
itself misleading in the opposite direction. Yesterday's fix, today's bug. The
common root is the same one all week — **reporting state that was never
re-verified against the box.**

### Fixed by re-reading, which makes it worth more than before

The post_tasks now re-query the five collections after the roles have run, and
the block means the right thing in both modes:

- `--check` → nothing was applied, so it is the **to-do list**.
- apply → everything was applied, so it is a **convergence proof**, and every
  list must be empty.

And since it is now a post-condition rather than a preview, it can assert:

```yaml
- name: Assert the box converged
  ansible.builtin.assert:
    that:
      - _drift.datasets_missing | length == 0
      # … and the rest
    fail_msg: "Apply finished but the box did not converge."
  when: not ansible_check_mode
```

A silent partial apply is precisely what this topic keeps producing, so it now
fails loudly instead. Validated against the live post-apply state: all five
deltas empty, `CONVERGED`.

### One more Jinja trap, caught before it ran

The first draft of the scrub signature was:

```jinja
{{ _cur.schedule is defined | ternary(<build sig>, []) }}
```

Two bugs in nine tokens, both already hit earlier this week:

1. **Precedence** — `|` binds tighter than `is`, so this parses as
   `_cur.schedule is (defined | ternary(...))`, which is not the test intended.
2. **Eagerness** — `ternary` evaluates *both* branches, so the sig-building
   branch would run even when `schedule` is undefined.

Replaced with an inline conditional, which is lazy and has no precedence trap:

```jinja
{{ (<build sig>) if (_cur.schedule is defined) else [] }}
```

`grep -c ternary` across the topic now returns zero. Worth making a standing
rule here: **no `ternary` in this repo's Ansible** — the lazy `if/else`
expression is never worse and removes both failure modes at once.

## 2026-08-28 (cont.) — idempotent, and the assert extended to recordsize

Re-run: `ok=25 changed=0 skipped=12 failed=0`, all five deltas empty,
`Converged: every declared dataset, export, snapshot task, cron job and the
scrub schedule are live.`

That is the *meaningful* `changed=0` — the one backed by a post-apply re-read of
the box, as opposed to this morning's, which was produced by a tool that could
not evaluate anything.

### The gap in the assert

It covered datasets, exports, snapshot tasks, cron jobs and the scrub schedule.
It did **not** cover NTP, timezone, mail, NFS service state, or **recordsize**.

recordsize is the one that mattered. From `group_vars`: *"recordsize applies to
NEW WRITES ONLY, so it must be right before data lands. This is the one chance
to get it right per dataset."* An unverified one-shot property, on a pool that
is about to receive several TiB, is exactly the shape of thing this week kept
punishing. Checked live:

```
tank/apps        recordsize=128K  compression=LZ4
tank/backup      recordsize=128K  compression=ZSTD
tank/immich      recordsize=1M    compression=LZ4
tank/keepers     recordsize=1M    compression=LZ4
tank/media       recordsize=1M    compression=LZ4
tank/personal    recordsize=128K  compression=LZ4
tank/timemachine recordsize=128K  compression=LZ4
tank/work        recordsize=128K  compression=LZ4
```

All eight match the declaration, and `backup` correctly picked up ZSTD.

### Closing it cheaply

The earlier formulations needed awkward nested-attribute gymnastics. Comparing
sorted `"id:value"` strings collapses the whole thing into one `difference`:

```yaml
_want_rs: "{{ (truenas_datasets | map(attribute='name') | map('regex_replace','^', truenas_pool ~ '/') | list)
              | zip(truenas_datasets | map(attribute='recordsize') | list) | map('join', ':') | sort | list }}"
_live_rs: "{{ (_child | map(attribute='id') | list)
              | zip(_child | map(attribute='recordsize') | map(attribute='value') | list) | map('join', ':') | sort | list }}"
recordsize_drift: "{{ _want_rs | difference(_live_rs) }}"
```

Verified in **both** directions, which is the part worth insisting on — an
assert that only ever passes is indistinguishable from one that cannot fail:

```
real state              -> DRIFT=[]
negative control        -> DRIFT=['tank/media:128K']   (wrong value IS caught)
```

**Still not asserted:** NTP servers, timezone, mail config, NFS service state.
Those are all reconciled by their roles and all showed `skipped` on the re-run
(i.e. converged), but they are enforced-without-verification. Lower stakes than
recordsize — none is a one-way door — so left as a known gap rather than
speculative work.

## 2026-08-28 (cont.) — garage on TrueNAS: an S3 target that is not on Ceph

The migration plan asked for OADP, and OADP's shape is right — Velero's
`change-storage-class` RestoreItemAction does exactly "restore this PVC onto a
different StorageClass". What did not work was the *BackupStorageLocation*.

Velero file-system backup writes to object storage and nothing else — verbatim
from the docs, *"Velero FSB supports object storage as the backup storage
only"*. The cluster's only S3 is Ceph RGW, whose data pool is replicated ×3 on
the same three HDD OSDs a media migration would be draining:

```
backup of media-data-pvc  3.21 TiB x 3 = 9.63 TiB raw
cluster raw available                    6.66 TiB
```

It does not fit, and no compression closes that on an already-compressed media
library. But that is a property of *where the BSL points*, not of OADP — and
`backupLocations` is a list. So: a second BSL, on the NAS.

This also retires an older problem. The daily OADP `Schedule` has been
`paused: true` since 2026-06-08, when it snapshotted Loki's WAL PVCs into the
same Ceph it was protecting and drove the cluster to 97 % full. The committed
comment says to unpause "when HDDs land and there's space". A BSL that is not on
Ceph at all is a better answer than more space.

### garage, not seaweedfs

Both are in the TrueNAS catalog. Pulled both schemas rather than guessing:

| | seaweedfs (stable train) | garage (community train) |
|---|---|---|
| components | master + volume + filer + admin + worker | one binary |
| ports in schema | ~14 | 5 |
| storage volumes | 5 | 3 |
| S3 config in schema | **none** — needs `additional_flags` | native |

seaweedfs is the *supported* one, which is a real argument. But for a backup
target that can be rebuilt from scratch in minutes, less surface won. garage at
`replication_factor: 1` is a single-node object store, which is exactly the job.

### Four things checked instead of assumed

1. **`app.create` is a job method.** Caught by reading `core.get_methods` before
   writing the task, so it used `--job` from the start rather than repeating the
   `pool.create` race from earlier the same day.
2. **`--job`, not `-job`.** Checking that flag turned up a live bug in
   `bootstrap-pool.sh`: `midclt call -job …` is an argparse error (single dash
   swallows it as `-j` plus unknown short opts) and prints usage instead of
   running. Verified against a nonexistent method so nothing executed:
   ```
   -job   -> usage: midclt [-h] ...       # runs NOTHING
   -j     -> Method does not exist
   --job  -> Method does not exist
   ```
   It would have silently failed the next pool build.
3. **Only the backnet IP is bindable.** `app.ip_choices` returns exactly
   `{0.0.0.0, ::, 192.168.10.10}` — the mgmt address is not offered. Convenient:
   the backnet is where the nodes reach it. All five ports carry
   `host_ips: [192.168.10.10]`, confirmed by `ss -lntp` showing no `0.0.0.0`
   bind on any of them.
4. **garage runs as uid 568; fresh datasets are `root:root 0755`.** It could not
   have written a byte. The role stats each path and chowns only when wrong.

### Two failures worth recording

**"No pool configured for Docker."** TrueNAS apps run on Docker, and Docker needs
a pool assigned before *any* `app.create` succeeds. A fresh install has
`pool: null`. Now a guarded prerequisite in the role.

**`no_log: true` hid the reason.** The deploy task carries generated secrets, so
it is `no_log` — which also hid the failure, leaving only `Module failed` and a
manual round trip to dig the cause out of `core.get_jobs`. Fixed properly: the
task now registers with `failed_when: false`, and a follow-up reads the job
record and fails with the real message. The payload stays hidden; the error does
not. **Secret-hiding should never mean error-hiding.**

### Bootstrap belongs in git, not in shell history

A deployed garage is RUNNING but useless — `layoutVersion: 0`, no node role,
`/health` returns 503. It needs a one-time layout assign + apply before it
serves S3 at all.

I did that first with ad-hoc `curl`, which is precisely what this repo's
code-only rule exists to prevent, so it was converged into the role:
`GetClusterStatus` → stage + apply layout when `layoutVersion == 0` →
`CreateKey` when absent → `CreateBucket` when absent. `ansible.builtin.uri` runs
on the TrueNAS host, which is how it reaches the backnet-bound admin port.

API version was probed, not assumed — this is garage 2.x:

```
/v2/GetClusterStatus -> 200
/v1/status           -> 400
/v0/status           -> 400
```

Re-run proves idempotence — every bootstrap task skips:

```
Stage the cluster layout   skipping     (layoutVersion == 1)
Apply the cluster layout   skipping
Create the velero key      skipping
Create the velero bucket   skipping
garage S3 endpoint http://192.168.10.10:30188 bucket=velero key=velero layoutVersion=1
```

Effective capacity 7.3 TiB at replication factor 1 — comfortable for a 3.21 TiB
staging copy.

The generated `admin_token` / `rpc_secret` / `web_ui_password` are created with
`openssl rand -hex 32` **on the box** and never leave it: nothing in git, no
vault entry. The S3 secret is likewise never persisted here — garage holds it and
it can be re-read with `GetKeyInfo?showSecretKey=true` when the cluster-side
SealedSecret is minted.

## 2026-08-28 (cont.) — the BSL that could not reach the NAS

Sealed the garage credential, enabled the second BSL, waited for ArgoCD:

```
NAME             PHASE         LAST VALIDATED   AGE
default          Available     2s               91d
truenas-garage   Unavailable   2s               93s

msg=... operation error S3: ListObjectsV2, exceeded maximum number of attempts, 3,
    ... dial tcp 192.168.10.10:30188: i/o timeout
```

**`i/o timeout`, not `connection refused`.** Packets leave and nothing comes
back — a routing symptom, not a missing listener. garage was confirmed up and
answering (`ss` showed all five ports bound; `curl` from the NAS returned 403,
i.e. S3 responding unauthenticated).

### Finding out which half was broken

TrueNAS's own routing table pointed at a plausible culprit:

```
$ ip route get 10.130.1.157
10.130.1.157 via 192.168.1.1 dev eno1 src 192.168.1.25
```

A pod IP routes out the **frontnet default gateway**. If Velero's packets
arrived un-masqueraded, the reply would go to the MikroTik, which has no route
to the pod CIDR — classic asymmetric drop.

Plausible, and wrong. A 90-second socket watch on the NAS across two BSL
validation cycles:

```
$ ss -tan '( sport = :30188 )' | grep -v LISTEN
(nothing)
```

**Zero inbound SYNs.** The packets never arrive at all, so the reply path never
comes into play. The drop is upstream of the NAS.

### The actual finding

**Pod-network → storage-backnet egress does not work on this cluster, and never
has.** Everything that touches `192.168.10.0/24` today does so from the *host*
stack:

| consumer | network |
|---|---|
| Ceph mons/OSDs/RGW | `network.provider: host` |
| `csi-nfs-node`, `csi-nfs-controller` | `hostNetwork: true` |
| **velero** | **pod network** (`podIP 10.130.1.157`) |

Velero is the first pod-network client that has ever tried to reach the backnet.
Nothing was broken by today's work — this path simply never existed, and it took
a new kind of client to reveal it.

Pod → *frontnet* is fine: `synology-cert-sync` reaches `192.168.1.2` nightly.

### Fix

Rebind garage from backnet-only to `0.0.0.0` and point the BSL at
`192.168.1.25`. `app.ip_choices` offers only `{0.0.0.0, ::, 192.168.10.10}` —
the mgmt address is not individually bindable — so `0.0.0.0` is the only way to
listen on both.

That exposed a create-only gap in the role: `truenas-apps` deployed the app but
had no update path, so a changed binding would have been declared-and-never-
applied — the same trap as the auto-created scrub task. Added a
`Reconcile the garage port bindings` task comparing live `host_ips` against
desired and calling `app.update` (also a job method).

```
TASK [truenas-apps : Reconcile the garage port bindings]
changed: [truenas]

$ ss -lntp | grep 3018
0.0.0.0:30188   0.0.0.0:30189   0.0.0.0:30190   [::]:...
$ curl -o /dev/null -w '%{http_code}' http://192.168.1.25:30188/
403
```

```
NAME             PHASE       LAST VALIDATED   AGE
truenas-garage   Available   9s               12m
```

**`Available` is a strong signal, not a weak one.** Velero validates by actually
issuing `ListObjectsV2`, so one green phase proves TCP reachability, the sealed
credential decrypting correctly, path-style addressing, *and* the
`checksumAlgorithm: ""` setting all at once.

### The cost, stated plainly

Velero's S3 traffic now takes **1G frontnet instead of 10G backnet**. Irrelevant
for the ~20 MB rehearsal and for config backups.

**CORRECTION (same day).** I first wrote that this "roughly doubles" a 3.21 TiB
move because "CephFS HDD read runs ~200 MB/s (1.6 Gbps)". That number was
invented — I never measured it — and the real one was already in this repo:

```
blog/blog-hdd-tier-rollout-draft.md, Phase 5, 2026-06-12
  test RWX PVC on cephfs-hdd, IO from a pod (direct):
    write 200 MiB @ 22.1 MB/s
    read           @ 76.6 MB/s
  "Expect ~80-100 MB/s (one client, one stream, HDD OSD primary)."
```

76.6 MB/s is **0.61 Gbps** — under 1 Gbps. So the 1G link is *not* the
bottleneck; **CephFS read is**, and the frontnet penalty is close to zero. My
figure was 2.6× too high and it inverted the conclusion it supported.

The process failure is the interesting part: CLAUDE.md carries an explicit
grep-before-asserting rule, written after a previous incident of exactly this
shape, and the correct measurement sat in the draft documenting the very tier I
was reasoning about. An unmeasured estimate stated with a unit and a decimal
point reads exactly like a measurement — which is why it survived several
messages unchallenged until the operator asked "r u sure???".

Revised: 3.21 TiB at 76.6 MB/s is **~12 h single-stream**, not the ~4.7 h I also
quoted off the same bad number. A copier that parallelises across files should
beat that, which is precisely what the benchmark needs to establish.

Worth noting what is *not* affected: NFS is kernel-mounted by hostNetwork CSI
pods, so media/immich/keepers data still rides the 10G backnet. A direct
PVC→PVC copy therefore has no 1G leg at all — which sharpens the earlier
tool comparison rather than changing it.

### Follow-up: is Ceph client traffic actually on the 10G backnet?

The 76.6 MB/s read figure prompted a fair challenge — three 7200 rpm spindles
that individually sustain 100-190 MB/s should do better than 0.61 Gbps, and
`CLAUDE.md` records that a frontnet-bound Ceph "caps throughput at ~118 MB/s".
Suspiciously close.

The mon endpoints looked like the smoking gun:

```
rook-ceph-mon-endpoints : a=192.168.1.7:6789, b=192.168.1.9:6789, c=192.168.1.8:6789
CephCluster addressRanges : public + cluster = 192.168.10.0/24
```

Frontnet mons against a backnet `addressRanges` is exactly what a failed-to-apply
`addressRanges` would look like — and this repo already documents two reasons it
could happen (Rook does not auto-roll daemons on a network-only change; the
`managedFields: []` SSA gotcha keeps stale values in the live spec).

It was a false alarm, and the check settles it cleanly:

```
$ ceph config get mon public_network      -> 192.168.10.0/24
$ ceph config get osd cluster_network     -> 192.168.10.0/24
$ ceph mon dump | grep '^[0-9]:'
0: [v2:192.168.1.7:3300/0,v1:192.168.1.7:6789/0] mon.a          <- frontnet
$ ceph osd dump | grep '^osd\.'
osd.0 ... [v2:192.168.10.2:6810,...] [v2:192.168.10.2:6812,...]  <- backnet, BOTH addrs
osd.3 ... [v2:192.168.10.2:6802,...] [v2:192.168.10.2:6804,...]
```

All six OSDs carry `192.168.10.x` on **both** public and cluster addresses. The
mon is control plane only: a client fetches the OSDMap over the frontnet once,
then every byte of data IO goes straight to the OSDs on the 10G backnet.

**So 76.6 MB/s is not a network cap.** It is what EC 2+1 across three spinning
disks delivers to a single stream, and 22.1 MB/s write is EC amplification. No
1G bottleneck to hunt for — which is worth writing down precisely because the
mon/OSD address split makes it look like there is one.

Two things follow for the migration:

- **The data path already uses the 10G**, today, with no changes. CephFS is
  kernel-mounted by a `hostNetwork` nodeplugin talking to backnet OSDs; NFS is
  kernel-mounted by a `hostNetwork` csi-nfs-node talking to 192.168.10.10. A
  direct PVC→PVC copy never touches the pod network at all.
- **Only Velero's S3 leg is on 1G**, and at 0.61 Gbps single-stream reads that is
  not currently binding. It would only start to matter if a parallel copier
  pushed past ~118 MB/s — which is now a concrete question for the benchmark
  rather than a guess.

### Data-path diagram

The thing that keeps tripping people up (me included, twice in one day) is that
"which link does this use?" is decided by **whether the traffic originates in a
pod's network namespace or in the host kernel** — not by which pod it belongs to.

```
                    ┌──────────────────── OKD NODE  (×3: node4/5/6) ────────────────────┐
                    │                                                                   │
  POD NETWORK       │   ┌─────────────────┐        ┌──────────────────────────────┐     │
  10.128.0.0/14 ────┼──▶│ velero          │        │ media pods: jellyfin, *arr,  │     │
                    │   │ (S3 client)     │        │ transmission, bazarr ...     │     │
                    │   │ 10.130.1.157    │        └──────────────┬───────────────┘     │
                    │   └────────┬────────┘                      │                      │
                    │            │ pod egress                    │ read()/write()       │
                    │            │ via ovn-k8s-mp0               │ on /data             │
                    │            │ + masquerade                  │ (NO pod networking)  │
                    │            ▼                               ▼                      │
                    │      ┌───────────┐              ┌──────────────────────────┐      │
                    │      │  br-ex    │              │  KERNEL MOUNTS           │      │
                    │      └─────┬─────┘              │  cephfs:// and nfs://    │      │
                    │            │                    │  set up by hostNetwork   │      │
                    │            │                    │  CSI nodeplugins         │      │
                    │            │                    └────────────┬─────────────┘      │
                    │      enp0s31f6                        enp1s0f0np0                 │
                    │        1 GbE                             10 GbE                   │
                    └────────────┼───────────────────────────────┼────────────────────-─┘
                                 │                               │
                 VLAN 5 ─────────┘                               └───────── VLAN 10
              192.168.1.0/24                                          192.168.10.0/24
                     │                                                       │
        ┌────────────┴────────────┐                        ┌─────────────────┴─────────────────┐
        │                         │                        │                                   │
   ┌────▼─────┐            ┌──────▼──────┐          ┌──────▼──────┐                  ┌─────────▼────────┐
   │ ceph MON │            │  TrueNAS    │          │ ceph OSD    │                  │    TrueNAS       │
   │ .1.7/8/9 │            │  .1.25      │          │ x6          │                  │   .10.10         │
   │          │            │  garage S3  │          │ .10.2/3/4   │                  │   NFS exports    │
   │ OSDMap   │            │  :30188     │          │ public+     │                  │  /mnt/tank/...   │
   │ only     │            │             │          │ cluster     │                  │                  │
   └──────────┘            └─────────────┘          └─────────────┘                  └──────────────────┘
```

Reading it as flows:

```
 [1] media I/O today          media pod ─syscall→ kernel cephfs ─▶ OSDs .10.2/3/4      10G  ✅
 [2] media I/O after cutover  media pod ─syscall→ kernel nfs    ─▶ TrueNAS .10.10      10G  ✅
 [3] ceph control plane       kernel client ──────────────────▶ mons .1.7/8/9          1G   ✅ (KBs)
 [4] velero → garage S3       velero pod ─OVN─▶ br-ex ─────────▶ TrueNAS .1.25         1G   ✅
 [5] velero → garage backnet  velero pod ─OVN─▶ ??? ────────────▶ .10.10               ✗ BLOCKED
```

**[1] and [2] are the ones that carry the 3.21 TiB, and both are already 10G.**
The media pods have no network involvement at all — they issue `read()`/`write()`
against a mount the *kernel* owns, and the kernel talks to the backnet.

**[5] is the only thing that does not work**, and it is why the Velero BSL had to
be pointed at `192.168.1.25`. It affects Velero's S3 staging traffic and nothing
else. A direct PVC→PVC copy is flows [1]+[2] exclusively — 10G end to end, no
pod-network involvement, nothing to fix first.

**[3] is why the mon addresses look wrong and are not.** Control plane on the
frontnet, data on the backnet.

## 2026-08-28 (cont.) — the rehearsal: PASSED

`cephfs-hdd` → `nfs-truenas-keepers`, via Velero `change-storage-class`, staged
through the garage BSL on TrueNAS. ~19 MB instead of 3.21 TiB. This is the first
backup **and** the first restore this cluster's OADP install has ever performed
in 91 days.

### Ground truth in

```
files=301   bytes=19,686,283
manifest_digest=051b5137e678e750751d23fe16e72c60441e9c8fa876893ee7c5fd91626876f2
uid_of_files=1000990000
```

### Backup

```
phase=Completed  errors=  warnings=  location=truenas-garage  items=31/31
PodVolumeBackup  scmigrate-1-h27tm  Completed  19,685,978 bytes
```

The PVB gate is the one that matters: a backup with **zero** PodVolumeBackups is
green and empty. One PVB, Completed, non-zero bytes.

Verified on the NAS that bytes really landed, rather than trusting Velero:

```
tank/s3/data  21.3M
GetBucketInfo velero -> objects: 23  bytes: 20,075,161  unfinishedUploads: 0
```

### Restore — `namespaceMapping`, nothing deleted

`Completed` in ~40 s, 0 errors, 7 warnings. ConfigMap deleted immediately after.
The source PVC was never touched.

### Four layers of verification

**1 — backend identity.** The check that separates "the SC field got rewritten"
from "the bytes are on the NAS":

```
PVC  scmigrate-data -> nfs-truenas-keepers, Bound
PV   pvc-342353d7...   (NEW; source was pvc-6c3914a7...)
     driver = nfs.csi.k8s.io         <- not rook-ceph.cephfs.csi.ceph.com
     server = 192.168.10.10          <- the 10G BACKNET
     share  = /mnt/tank/keepers
```

That `server` value is quietly the best result of the day: **the restored volume
mounts over the backnet at 10G**, even though Velero's S3 staging went over the
1G frontnet — exactly as the data-path diagram predicts, because the mount is
made by a hostNetwork CSI nodeplugin, not by a pod.

**2 — checksum replay.** `ok=301`, and `manifest_digest` byte-identical to the
source, which is what proves the manifest was not regenerated against a degraded
tree. `uid_of_files=1000990000` matched too — the destination namespace inherited
the source's `openshift.io/sa.scc.uid-range` because Velero created it. Had the
namespace been pre-created, OpenShift would have assigned a different range and
the restored files would have been owned by a UID the pod does not have.

**3 — byte reconciliation.** `PodVolumeRestore Completed, 19,685,978` — exactly
the PVB figure.

**4 — ZFS ground truth.** `/mnt/tank/keepers/pvc-342353d7.../` with 300 files
under `tree/a`, `tank/keepers` = 19.2M.

`files=302` in the restored volume vs 301 at source is **not** a discrepancy:
`.velero/3ba7fafe-...` is a 0-byte sentinel the `restore-wait` init container
polls for.

### Third reason for `maproot_user: root`, now confirmed empirically

Restored files are owned `1000990000:1000990000`, directories `root:1000990000`.
The node-agent restores **as root and preserves uid/gid**, so under root squash
the restore fails on chown even after provisioning succeeded. The role's comment
block listed two reasons for `maproot_user: root` (csi-driver-nfs creating
per-PV subdirs; jellyfin running `runAsUser: 0`); this is the third, and it is
the one that would have bitten *this* workflow.

### Two operational gotchas

**`oc get backup` is ambiguous.** It resolves to CNPG's
`backups.postgresql.cnpg.io`, so a status query returns
`Error from server (NotFound)` while the Velero backup runs fine, and a wait
loop never matches. Use `backups.velero.io` / `restores.velero.io` explicitly.

**Teardown is where the real risk lives.** Both SCs are `Retain`, so the run left
two Released PVs (expected, deleted) plus data on both backends. Purging the
CephFS orphan means running `ceph fs subvolume rm` in a namespace that also
contains the subvolume backing the live 3.21 TiB media library. Identified three
ways before touching it:

```
media PV names its own subvolume  -> csi-vol-271e7ed8...
only one CephFS PV cluster-wide   -> everything else is orphaned
subvolume info bytes_used         -> 19,685,978 (orphan) vs 3,529,630,407,490 (media)
```

Post-purge: one subvolume left, `media-data-pvc` still `Bound 4Ti`, all media
pods Running.

### What this establishes

The design in the operator's original sketch — *"SC for ceph, new SC for truenas
NFS, move via OADP, repoint the deployment"* — **works end to end, exactly as
drawn.** What remains for the real migration is scale, not mechanism: 3.21 TiB
instead of 19 MB, and the app-downtime question that FSB's restore path forces.
