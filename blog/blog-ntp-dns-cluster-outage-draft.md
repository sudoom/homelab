# When a $3 missing clock chip took down a Kubernetes cluster — NTP → DNSSEC → etcd quorum

*Draft, 2026-07-25. A full OKD control-plane outage whose root cause was three hops
upstream of Kubernetes: a router's NTP died, a clock-less Raspberry Pi drifted, its
DNSSEC validation broke, and two nodes couldn't finish booting. Notes captured live
during recovery.*

## Symptom

Routine "how's it going" check — `oc` couldn't reach the cluster at all:

```
$ oc get nodes
... dial tcp 192.168.1.240:6443: connect: connection refused
```

**Connection *refused*, not timed out** — that's the important distinction. The workstation
reached the API VIP (192.168.1.240) but nothing was serving `:6443`. Not a network/VPN
problem, not a stale kubeconfig. A cluster-side control-plane outage.

## Localizing it

LAN probe (router, DNS, all 3 nodes, VIP all ping UP), then `:6443` on the VIP **and each
node directly** — all refused. So **every kube-apiserver was down**, cluster-wide, while the
nodes themselves were powered and networked. That points at etcd.

SSH to the nodes (the API is dead, so `oc` is useless — everything from here is node-level):

```
node4: kubelet inactive,  /var 49% (fine)
node5: kubelet inactive,  /var 8%  (fine)
node6: kubelet ACTIVE, etcd Running but restart count 32, kube-apiserver Exited
```

Disk-fill hypothesis (the obvious guess, given a pre-existing `MON_DISK_LOW` warning on
node4) — **refuted**: all `/var` healthy (the `composefs / 100%` is just the read-only ostree
image, normal). node6's etcd log was the tell:

```
4e9edf2c412cd00b is starting a new election at term 43     (looping)
prober detected unhealthy status ... 192.168.1.7:2380: connect: connection refused
prober detected unhealthy status ... 192.168.1.8:2380: connect: connection refused
```

**Pure quorum starvation.** node6's etcd is the lone survivor; its two peers (node4/node5)
are down because their kubelets are down, so it can't elect a leader → no etcd → no
apiserver anywhere. No cert error, no data corruption. So: **why are 2 of 3 kubelets down?**

## The real chain

`systemctl list-jobs` on node4 (uptime 51 min — it had **rebooted**):

```
1024 on-prem-resolv-prepender.service   start running   <- stuck
453  nodeip-configuration.service       start running   <- stuck
...  network-online.target / crio / kubelet-dependencies.target / kubelet.service  waiting
435  kubelet.service                    start waiting
```

node4 rebooted and **hung in early boot**, blocked on the on-prem services that need DNS
(`nodeip-configuration`, `node-valid-hostname`, `resolv-prepender`). And from node4:
`getent hosts quay.io` → **RESOLVE FAIL**; the kubelet journal was full of
`lookup quay.io on 192.168.1.12:53: server misbehaving`.

`server misbehaving` = the DNS server returned SERVFAIL. The operator's own observation
closed it: **the dns-master RPi's clock read 15:27 when it was 19:03** — ~3.5h behind. NTP
on the MikroTik had gone down, and the RPi has **no RTC**, so nothing corrected the drift.

### The mechanism: DNSSEC is time-sensitive

Every DNSSEC `RRSIG` carries an **inception** and **expiration** timestamp; a validating
resolver rejects a signature whose window doesn't contain "now". With the RPi's clock 3.5h
in the past, upstream RRSIGs read as **"not yet valid"** → Technitium returns SERVFAIL →
Go's resolver reports "server misbehaving". So all *recursive/forwarded* lookups (quay.io,
ghcr.io, and — critically — whatever the on-prem boot services needed) failed. There's no
spec grace; the practical tolerance is seconds (NTP-normal), and hours guarantees breakage.

### Why only 2 of 3 nodes

- **node6 survived** because its clock was correct (its etcd logs were stamped at the right
  UTC) *and* it was already running — it never had to re-resolve anything through a reboot.
- **node4 + node5 had rebooted** (~same time — likely the same power blip that killed the
  router's NTP), so they hit the broken DNS during boot and parked.

### The chicken-and-egg that made it self-sustaining

`timedatectl` on the RPi: `System clock synchronized: no`, `NTP service: active`,
`RTC time: n/a`. timesyncd was running but couldn't sync — because its NTP servers are
**hostnames** (`*.pool.ntp.org`), and resolving them needs DNS, which was down *because the
clock was wrong*. **clock → DNS → NTP → clock**, a closed loop with no way out on its own.

## Recovery

1. **Break the loop — set the clock by hand** (NTP couldn't, and manual `date` is a pure
   runtime action, no config drift):
   ```
   sudo timedatectl set-ntp false
   sudo date -u -s "2026-07-25 17:16:00"
   ```
   (DNSSEC tolerates ~an hour, so nearest-minute is fine.)
2. **Confirm DNS recovered** — from the RPi:
   ```
   dig +short api-int.okd.sudops.pl @127.0.0.1   -> 192.168.1.240   (internal ✓)
   dig +short quay.io               @127.0.0.1   -> 8 IPs           (external ✓, DNSSEC now validates)
   ```
3. **Point NTP at the router by IP** (the durable fix — an IP needs no DNS, so it can never
   deadlock again; the router is a synced stratum-2 source):
   ```
   sudo mkdir -p /etc/systemd/timesyncd.conf.d
   printf '[Time]\nNTP=192.168.1.1\nFallbackNTP=195.176.26.215 194.146.251.100 194.146.251.101\n' \
     | sudo tee /etc/systemd/timesyncd.conf.d/10-router-ntp.conf
   sudo timedatectl set-ntp true && sudo systemctl restart systemd-timesyncd
   # -> System clock synchronized: yes,  clock steps to correct
   ```
4. **The cluster then self-healed** once DNS answered: node4/node5 boot services completed →
   kubelets started → etcd static pods came up → **quorum restored** → apiservers served.
   API back ~60s after DNS returned. node4/node5 `Ready`.
5. **node6 tail** — came back `NotReady`: its OVN got wedged during the hours of solo-etcd
   crashlooping (`no CNI configuration file … network provider started?`, ovnkube-node with
   unready containers) + a pending `system:multus:node6` CSR. Fix: approve the pending
   CSR(s) + restart node6's `ovnkube-node` → node6 `Ready`. (This was only the *first* layer
   of the node6 tail — the storage/backnet fault below was the bigger one. Full sequence in
   "Recovery, part 2".)

## Lessons

- **A clock-less Pi is a terrible place for your DNSSEC validator.** It's the most
  skew-fragile box in the lab and it gates the entire cluster's ability to boot.
- **Never point NTP at hostnames on the box that also serves DNS** — use IPs, or you build a
  clock↔DNS deadlock that survives reboots.
- **"Connection refused" vs "timed out" localizes fast** — refused meant the VIP was
  reachable but unserved → control plane, not network.
- **Verify the obvious hypothesis before acting** — `MON_DISK_LOW` on node4 screamed
  "disk full → etcd", but `df` said 49%. The real cause was three layers up. (Also a reminder
  the `MON_DISK_LOW` warning itself is still unresolved and unrelated.)
- **etcd static pods don't need node-Ready** — quorum + the API can return while nodes are
  still NotReady (CNI/CSR pending), which is what let the cluster bootstrap itself back.
- **The "DNS must not depend on the cluster" design held** (DNS is a separate RPi) — but the
  *reverse* dependency bit us: the cluster depended on DNS, which depended on time. Time is
  now the thing to make bulletproof (router-IP NTP + an RTC).

## Durable follow-ups (tracked in README, all code-managed via `ansible/technitium/`)

- Ship the `timesyncd.conf.d/10-router-ntp.conf` drop-in in the role (IP-only sources) — the
  manual drop-in applied during the incident must be codified or the next playbook run wipes it.
- Add a **DS3231 RTC** to dns-master.
- Point the OKD nodes' chrony at the router by IP as a first source (belt-and-suspenders).
- Reconsider DNSSEC posture for the internal authoritative zone.

## Recovery, part 2 — the storage/network tail (the part that took longer than the root cause)

Fixing time+DNS brought the API and nodes back, but full recovery was a multi-stage
cleanup because a **second, independent fault** was hiding behind the first, plus a pile
of post-outage CSI debris. Chronology of what actually cleared it:

### 1. Nodes back, but node6 NotReady (OVN CNI)
API returned ~60s after DNS. node4+node5 `Ready`; node6 `NotReady` —
`no CNI configuration file … network provider started?` + a pending `system:multus:node6`
CSR + an ovnkube-node with unready containers. Fix: approve pending CSRs + restart node6's
`ovnkube-node`. node6 → Ready.

### 2. The "restart ALL 3 ovnkube-node" trap (re-confirmed, again)
Only node6's ovnkube-node had been restarted. A parallel-probe sweep caught that node4+node5
still had broken pod→external egress — **evidence, not theory**: rook mgr `MGR_MODULE_ERROR`
"Network is unreachable" to `172.30.0.1` (mgr runs on node4/node5), and **media** WAL
archiving failing `exit status 4` to R2 (media primary on node5). Restarting node4+node5
ovnkube-node (rolling) fixed media archiving immediately. This is the 2026-06-11 lesson a
third time: **after a multi-node disruption, restart every disrupted node's ovnkube-node, and
a "Ready" ovnkube-node can still have broken egress.**

### 3. The hidden second fault — node6's Ceph backnet NIC was DOWN
Every remaining stuck pod was RBD-backed and on node6 (both DBs, prometheus, alertmanager,
all loki). Their mounts failed `MountVolume.MountDevice … DeadlineExceeded`. node4's osd.0 log
was the giveaway:
```
heartbeat_check: no reply from 192.168.10.4:6804 osd.5 ever on either front or back
```
`192.168.10.4` = node6's storage-backnet IP. A per-node backnet check found it:
```
node4:  enp1s0f0np0  UP    192.168.10.2/24
node5:  enp1s0f0np0  UP    192.168.10.3/24
node6:  enp1s0f0np0  DOWN  192.168.10.4/24  linkdown   ← isolated on the Ceph backnet
```
Because `public_network`/`cluster_network` are both `192.168.10.0/24`, a down backnet NIC on
node6 means node6's kRBD can't reach **any** OSD → every RBD mount on node6 hangs, and node6's
OSDs can't heartbeat → Ceph degraded. **One down interface = the entire storage tail.** Fix:
`nmcli device connect enp1s0f0np0` on node6 (restores the managed IP + the load-bearing
`192.168.10.0/24` routes, not just a raw `ip link up`). Cross-node backnet pings came alive;
OSDs re-peered. **Why it was down after the others rebooted and node6 didn't is still open —
a link/carrier flap or an NM state left from the churn; the durable fix (below) is to alert on
per-node backnet reachability so this is never a manual 20-minute discovery again.**

### 4. Post-outage CSI debris (all documented patterns, all needed)
Even with backnet up, node6 pods needed three separate CSI cleanups — the classic post-node-
disruption RBD mess:
- **Stuck VolumeAttachments** — pods failing `AttachVolume.Attach … volume attachment is being
  deleted` (VAs stuck terminating on the pre-disruption node). Bulk force-clear of every VA
  with a `deletionTimestamp`:
  `oc get volumeattachment -o jsonpath='{range .items[?(@.metadata.deletionTimestamp)]}...' | patch finalizers=[]`
  (8 of them). The attach-detach controller then re-attached fresh to node6.
- **rbd-nodeplugin operation-lock** — a timed-out `NodeStageVolume` left an in-memory lock
  (`operation with the given Volume ID … already exists`); restarting node6's
  `rook-ceph.rbd.csi.ceph.com-nodeplugin` cleared it. (But per the rule — this only helps once
  the *underlying* cause is fixed; restarting it while the backnet was still down did nothing.)
- **node6 pod→ClusterIP (172.30.0.1) still broken** — immich-postgres's barman sidecar timed
  out reaching the kube API service. A *second, clean* node6 ovnkube-node restart (after the
  backnet + OSDs were stable) finally reprogrammed node6's service routing → immich WAL
  archiving flipped to `True`.

### 5. Ceph HEALTH_ERR = a lingering crash record
After OSDs rejoined, the only thing holding `HEALTH_ERR` was `RECENT_MGR_MODULE_CRASH` (the
mgr module crashed when it couldn't reach the API mid-outage; it recovered, but the crash
record is itself the ERR trigger — not `OSD_DOWN`). Cleared with `ceph crash archive-all` from
the toolbox → drops to `HEALTH_WARN` (transient `OSD_SLOW_PING` decays on its own).

### 6. Red herring — immich-server stuck ContainerCreating
Looked like another node6 egress fault (`MountVolume.SetUp … 192.168.1.2 … timeout`) but it
was the **Synology NAS being in planned maintenance** — the NFS library it mounts was simply
down. Nothing to fix; it auto-recovers when the NAS returns. Lesson: check whether a depended-on
box is *intentionally* down before chasing it as a cluster fault (and `192.168.1.2` NFS timeouts
during a NAS-maintenance window are expected, not OVN egress).

### Recovery lessons (additive to the root-cause ones)
- **Two faults can stack.** The time/DNS outage was the trigger; node6's backnet NIC being
  down was an independent fault that only surfaced once the API was back. Don't stop at the
  first root cause when symptoms remain.
- **On this cluster, a single storage-backnet NIC down = all RBD I/O on that node dead**
  (public+cluster network are the same `192.168.10.0/24`). Per-node backnet reachability
  deserves its own alert.
- **Post-node-outage RBD recovery is a known 3-step dance** (stuck VAs → nodeplugin op-lock →
  re-verify pod→ClusterIP), and it does *not* self-heal — all three are in the CLAUDE.md
  runbook and all three were needed.
- **A "Ready" ovnkube-node ≠ working egress/service routing.** Restart every disrupted node's,
  and re-verify after the *underlying* fabric (backnet) is fixed, not before.

## Part 3 (2026-07-26): the tail wasn't fully cleared — a day-later stuck failover

A day after the outage, the CNPG Grafana dashboard for `media-postgres` was red:
**Replication: None**, `media-postgres-1` (fd-a/node4) **Down** ("last failure a day ago"),
`-2`/`-3` Up but "Clustering/replication: No", **WAL Delayed**, **Backups: None recent**.
Everything else on the board (lag, storage, CPU, mem) green.

Fanned out four parallel read-only probes (media-postgres CR, etcd/control-plane, Ceph CR,
recovery-tail docs). They converged on **one root cause**: the OVN **pod→ClusterIP
(`172.30.0.1`) egress break from the 07-25 recovery was never fully cleared.** The 07-25
"second ovnkube-node restart" fixed *immich's* path but not media-postgres's / the Ceph mgr's —
node4 and node5's `ovnkube-node` pods still had 26h uptime and broken pod→service routing. The
one fault pinned three layers at once:

- **media-postgres** stuck `phase: Failing over` (`currentPrimary=media-postgres-1` unhealthy,
  1/2 Ready 7 restarts; `targetPrimary=media-postgres-2` promoting; all three
  `isPrimary=False` → *no serving primary for ~a day*). WAL archiving to R2 `ContinuousArchiving=False`
  with `dial tcp 172.30.0.1:443 i/o timeout` — the barman sidecar couldn't reach the kube API.
- **Ceph `HEALTH_ERR`** — `Module 'rook' has failed: HTTPSConnectionPool(host='172.30.0.1',
  port=443) ... [Errno 101] Network is unreachable`. Data plane fully healthy (6 OSDs up, 3 mons
  quorate, 8 TB free) — pure mgr→API egress.
- **etcd ClusterOperator** falsely `Available=False, 1 of 3 members` while the API answered every
  query — a lagging health assessment, same fabric root.

### The fix — restart all 3 ovnkube-node, one at a time (break-glass)

Not the runbook's all-at-once label delete — one at a time on a no-drain cluster, waiting for
`8/8 Running` between each:

```
export KUBECONFIG=~/.kube/config-breakglass
oc -n openshift-ovn-kubernetes delete pod ovnkube-node-cfbcw   # node4 (stuck primary + mgr-b)
#   -> ovnkube-node-mf9rm  8/8 Running in ~24s
oc -n openshift-ovn-kubernetes delete pod ovnkube-node-lpj8j   # node5 (mgr-a + target primary)
#   -> ovnkube-node-lk4t7  8/8 Running in ~30s
oc -n openshift-ovn-kubernetes delete pod ovnkube-node-dh48g   # node6
#   -> ovnkube-node-vg455  8/8 Running in ~24s
```

media-postgres self-resolved in ~30s once pod→ClusterIP was reprogrammed:

```
t+15s: pg_phase=Failing over          ready=2 primary=media-postgres-2 Ready=False Archiving=True
t+30s: pg_phase=Cluster in healthy... ready=3 primary=media-postgres-2 Ready=True  Archiving=True
```

etcd CO self-cleared to `Available=True Degraded=False`. immich-postgres unaffected (1/1, Archiving True).

### Ceph mgr — a failed module does NOT self-reload after egress returns

Ceph stayed `HEALTH_ERR` for minutes after egress was fixed: once the `rook` mgr module enters
`has failed`, it stays cached-failed until the mgr reloads it. No toolbox needed — **fail the
active mgr over via `oc delete pod`** (break-glass allows pod delete; `oc exec`/`ceph mgr fail`
are classifier-blocked):

```
oc -n rook-ceph get pods -l app=rook-ceph-mgr -o custom-columns=NAME:...,ACTIVE:.metadata.labels.mgr_role
#   rook-ceph-mgr-a-...-4rvbc  node5  active
#   rook-ceph-mgr-b-...-b7sdz  node4  standby
oc -n rook-ceph delete pod rook-ceph-mgr-a-8f475dc46-4rvbc
#   t+72s: ceph=HEALTH_WARN   <- rook module reloaded, reconnected to 172.30.0.1
```

Remaining `HEALTH_WARN` = `3 OSD(s) ... slow operations in BlueStore` (documented benign
consumer-NVMe fsync hair-trigger) + `1 mgr modules have recently crashed` (stale record). The
crash record is the one thing break-glass can't clear (toolbox exec) — operator runs
`ceph crash archive-all` to drop it, leaving only the benign slow-op alert.

### Two more debris items the crashloop sweep caught

With the shared root cause fixed, a full `phase!=Running` + actively-`WAITING` sweep turned up
exactly two real items (everything else was cumulative restart counts over 114d of node uptime —
etcd/coredns/haproxy/keepalived/multus/nmstate all restart on every reroll/reboot and mean nothing):

- **`media/transmission-slave` — `CreateContainerError`** on node4:
  `failed to resolve symlink ".../pvc-c0d00980.../mount": permission denied`. That PVC is
  **`media-data-pvc` — the shared RWX `/data` on CephFS** — its per-pod mount on node4 was left
  wedged (EACCES) by the outage churn. No other media pod was affected, so it was a stale per-pod
  mount, not node-wide CephFS breakage. Fix: `oc delete pod` → it rescheduled to node5 and came
  up `1/1 Running`. (If it had re-wedged on remount, next step is the CephFS nodeplugin restart on
  node4 — it didn't.)
- **7× `collect-profiles-2975...` OLM job pods in `Error`** — looked alarming, but the CronJob runs
  every 15 min and only the **20:15 run** failed; the 20:00, 20:30, and 20:45 (post-fix) runs are
  all `Complete` and `lastSuccessfulTime` is current. That one run failed *because it landed on a
  node whose pod→ClusterIP was still broken* — the same root cause, and a neat demonstration of the
  "silent until a pod lands on the broken node" property. The `Error` pods are stale history OLM GCs.

### Lesson (part 3)

**"Verify pod→ClusterIP after ovnkube restart" must be a real check, not a vibe.** On 07-25 we
confirmed immich archiving recovered and moved on — but media-postgres and the Ceph mgr were on a
*different* broken node's routing, and stayed broken silently for a day (mid-failover, no primary,
WAL not archiving). A CNPG cluster with no serving primary is a real mini-outage; it only didn't
page because the WAL PVC hadn't filled yet. The `CNPGWALArchiveFailing` rule (shipped 07-08)
*should* have fired within 15 min of the archive stalling — worth confirming it did and where it
went (the no-external-Alertmanager-delivery gap is likely why it went unseen). **A "Ready"
ovnkube-node lies per-node; verify pod→ClusterIP from a pod on *every* node, or add a synthetic
probe, before declaring a node-event recovery done.**

## Durable follow-ups (part 2)
- **Alert on per-node Ceph backnet reachability** (`192.168.10.x` cross-node) — a down backnet
  NIC on one node silently kills that node's RBD I/O; today it was a manual 20-min discovery.
- **Alert on `OSD_DOWN` / `OSD_HOST_DOWN`** reaching the console early (pairs with the
  external-Alertmanager-delivery gap already tracked).
- Everything in "Durable follow-ups (part 1)" (router-IP NTP in the Ansible role + DS3231 RTC)
  remains the top preventive item — it stops the whole chain at the source.
- **Synthetic pod→ClusterIP (`172.30.0.1:443`) reachability probe, per node** — the 07-26
  stuck-failover proved a "Ready" ovnkube-node hides broken service routing on a *specific* node
  for a day. A blackbox/exec probe from a pod on each node (or an alert on
  `cnpg_pg_stat_archiver_failed_count` + Ceph `MGR_MODULE_ERROR` correlated to a node) would turn
  "manual dashboard catch a day later" into "fires in 15 min". Pairs with the backnet probe above.
