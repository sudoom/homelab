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
