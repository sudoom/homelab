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
   CSR(s) + restart node6's `ovnkube-node`. *(fill in final Ready confirmation)*

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
