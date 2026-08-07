# The `br-ex` forwarding outage — finding the mechanism behind the "ovnkube-node egress break"

**Date:** 2026-08-07
**Status:** RESOLVED — root cause + trigger confirmed, fixed by a one-line sysctl at ~14:20Z
**Severity:** cluster-wide, ~5 h total (09:24Z → 14:20Z)
**Trigger:** Mikrotik 10G switch rebooted for a firmware upgrade (will recur on every upgrade)

For months this cluster has had a recurring failure documented in `CLAUDE.md` purely by its
symptoms: "a node's `ovnkube-node` develops broken pod→remote-host egress; restart it." It shows
up after node reboots, after MCO rerolls, after nmstate changes. The runbook says restart all
three `ovnkube-node` pods, and that works, and nobody ever established *why*.

Today it fired again — this time on all three nodes at once, with no reboot, no MachineConfig
change, and no `ovnkube-node` restart preceding it. Because the usual trigger was absent, the
usual explanation didn't fit, and that forced an actual root-cause hunt.

The answer: **`net.ipv4.conf.br-ex.forwarding = 0` on all three nodes.** It is not an egress
failure at all. It is a *return-path* failure in the host kernel.

## Symptom surface

Session-start sweep came back dirty in a way that looked catastrophic:

```
=== APPS (non Synced+Healthy only) ===
... all 45 applications ... Unknown
=== DEGRADED CO ===
authentication avail=False prog=True degr=True
etcd           avail=False prog=False degr=True
insights       avail=False prog=False degr=True
=== CNPG ARCHIVING ===
media-postgres  ready=3/3 primary=media-postgres-2  archiving=False/ContinuousArchivingFailing
immich-postgres ready=1/1 primary=immich-postgres-1 archiving=False/ContinuousArchivingFailing
```

The scary-looking ones were false:

```
etcd: EtcdMembersDegraded: 1 of 3 members are available,
      node4.okd.sudops.pl is unhealthy, node6.okd.sudops.pl is unhealthy
```

…while all three etcd pods were `Running`/`ready=true`. This is the documented scrape-inferred
false-critical: the etcd *operator* can't reach the other two members, so it reports them down.
Same for authentication:

```
authentication: WellKnownReadyControllerDegraded: failed to GET kube-apiserver oauth endpoint
  https://192.168.1.7:6443/.well-known/oauth-authorization-server: context deadline exceeded
```

That's a plain pod→host-IP call failing. Ceph was `HEALTH_WARN` with only the known-benign
`BLUESTORE_SLOW_OP_ALERT`, `lastChanged: 2026-07-26T20:13:35Z` — storage untouched.

## The sampling trap I nearly walked into

OpenShift's own `PodNetworkConnectivityCheck` resources all pointed at node5:

```
DOWN: network-check-source-node5-to-kubernetes-apiserver-endpoint-node4
DOWN: network-check-source-node5-to-kubernetes-apiserver-endpoint-node6
DOWN: network-check-source-node5-to-kubernetes-apiserver-service-cluster
DOWN: network-check-source-node5-to-load-balancer-api-external
DOWN: network-check-source-node5-to-load-balancer-api-internal
```

And the pod placement lined up beautifully: repo-server, etcd-operator, authentication-operator,
cert-manager and the `media-postgres` primary were *all* on node5. A tidy "node5's ovnkube-node
is broken" story.

It was wrong, and the reason is worth writing down:

```
$ oc -n openshift-network-diagnostics get deploy,ds
deployment.apps/network-check-source   1/1   1   1   126d
daemonset.apps/network-check-target    3     3   3   3   3

$ oc get podnetworkconnectivitycheck -o jsonpath='{range .items[*]}{.spec.sourcePod}{"\n"}{end}' \
    | sort | uniq -c
  15 network-check-source-5d6768c4d7-ktp45      # ← node5
```

**`network-check-source` is a `replicas: 1` Deployment.** Only the *target* is a DaemonSet, and
targets are passive. So all 15 checks in the cluster — the passing ones and the failing ones —
originate from one pod that happens to live on node5. "All DOWN checks have source node5" is a
tautology, not a finding. There is *zero* connectivity-check evidence about node4 or node6.

Two symptoms had already contradicted the node5-only story anyway: `insights-operator` runs on
**node4**, and `immich-postgres-1` runs on **node6**, and both were failing outward.

The direct test settled it — `curl --max-time 8` from a pod on each node:

| source | →node4 (.7) | →node5 (.8) | →node6 (.9) | →1.1.1.1 | →gw (.1) |
|---|---|---|---|---|---|
| node4 | **403/0.021** | 000/8.00 | 000/8.00 | 000/8.00 | 000/8.00 |
| node5 | 000/8.00 | **403/0.029** | 000/8.00 | 000/8.00 | 000/8.00 |
| node6 | 000/8.00 | 000/8.00 | **403/0.020** | 000/8.00 | 000/8.00 |

Own-host works in ~20 ms; every off-node destination hangs the full timeout. Identical on all
three nodes. Pod→pod overlay was perfectly healthy in every direction, including cross-node, and
DNS resolved fine. So: not node5-scoped, not the underlay, not DNS.

## The direction of the break is backwards

The natural reading of "pod can't reach the internet" is that packets aren't getting out. Host
conntrack says otherwise. On node4, during a probe to `1.1.1.1`:

```
zone=0 : SYN_RECV  src=10.130.0.3 dst=1.1.1.1 sport=56944 dport=443
                   src=1.1.1.1 dst=192.168.1.7 sport=443 dport=56944
zone=19: SYN_SENT  src=10.130.0.3 dst=1.1.1.1 ... [UNREPLIED] ... zone=19
```

`SYN_RECV` in the host zone means **the SYN-ACK came back**. The reply tuple `dst=192.168.1.7`
proves the masquerade to the node IP was applied correctly. Yet the pod-side OVS conntrack zone
19 entry sits `[UNREPLIED]` forever. Reproduced against the live CNPG→R2 flow on node6:
`SYN_RECV src=10.128.0.12 dst=141.101.90.98 ... reply dst=192.168.1.9` alongside
`SYN_SENT ... [UNREPLIED] zone=19`.

Packets leave, are SNAT'd correctly, and remote peers answer. **The reply is what never makes it
back to the pod.**

## Root cause

This cluster runs OVN-Kubernetes in **local gateway mode**:

```
$ oc get network.operator cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.gatewayConfig}'
{"ipv4":{},"ipv6":{},"routingViaHost":true}
```

`routingViaHost: true` means pod north-south traffic does *not* exit via the OVN gateway router
and br-ex's OpenFlow pipeline. It is handed to the **host kernel** at `ovn-k8s-mp0`, routed by
the host, masqueraded by nftables, and sent out `br-ex`. The return leg is therefore an ordinary
kernel **forward**: in on `br-ex`, out on `ovn-k8s-mp0`.

And forwarding on `br-ex` was off — on every node:

```
$ for p in <ovnkube-node pods>; do
    oc -n openshift-ovn-kubernetes exec $p -c ovnkube-controller -- \
      sysctl -n net.ipv4.conf.br-ex.forwarding net.ipv4.conf.ovn-k8s-mp0.forwarding \
                net.ipv4.conf.all.forwarding net.ipv4.ip_forward
  done
node4  br-ex/mp0/all/ip_forward = 0 1 0 0
node5  br-ex/mp0/all/ip_forward = 0 1 0 0
node6  br-ex/mp0/all/ip_forward = 0 1 0 0
```

The controlled proof — same destination, only the ingress interface varied:

```
ip route get 10.130.0.3                      → dev ovn-k8s-mp0        (resolves)
ip route get 10.130.0.3 iif ovn-k8s-mp0      → resolves
ip route get 10.130.0.3 iif br-ex            → RTNETLINK answers: No route to host
```

Confirmed on node5 (→10.129.0.55) and node6 (→10.128.0.6) as well. The SYN-ACK arrives on
`br-ex`, conntrack un-NATs it back to the pod IP, the kernel tries to forward it to
`ovn-k8s-mp0`, and `conf.br-ex.forwarding=0` makes it drop the packet during routing — *before*
the nftables FORWARD hook, which is why nothing shows up in any counter and why the failure is a
silent hang with no RST.

### Why `all.forwarding=0` is correct here and `br-ex=0` is not

`ip_forward=0` globally is deliberate. From the ovnkube-node container's own startup:

```
+ ip_forwarding_flag=--disable-forwarding
+ sysctl -w net.ipv4.ip_forward=0
+ sysctl -w net.ipv6.conf.all.forwarding=0
+ exec /usr/bin/ovnkube ... --gateway-mode local --gateway-interface br-ex --disable-forwarding ...
```

That's OpenShift's default `gatewayConfig.ipForwarding: Restricted`: don't turn the node into a
general-purpose router, enable forwarding only on the specific interfaces OVN needs. Which is
exactly why `ovn-k8s-mp0.forwarding=1` — ovnkube-node set it. `br-ex` needs to be `1` for the
same reason, and it isn't.

That asymmetry is the whole story: **`mp0` kept its value and `br-ex` lost it.** `mp0` is an OVS
internal port created and owned by OVN-K; `br-ex` is a NetworkManager-managed device. A NM
reapply/reactivation of `br-ex` resets its per-interface sysctls to the `default` (`0`) while
leaving `mp0` alone.

## Trigger — CONFIRMED: a 10G switch firmware upgrade

**The Mikrotik 10G switch was rebooted for a firmware upgrade.** (Operator-confirmed mid-session;
switch uptime `04:48:54` at `16:16:18` local = boot at `11:27:24` local = **09:27:24Z**.)

The kernel logs on all three nodes agree to the second:

```
2026-08-07T09:24:35Z node4 kernel: mlx5_core 0000:01:00.0 enp1s0f0np0: Link down
2026-08-07T09:24:35Z node5 kernel: mlx5_core 0000:01:00.0 enp1s0f0np0: Link down
2026-08-07T09:24:35Z node6 kernel: mlx5_core 0000:01:00.0 enp1s0f0np0: Link down
2026-08-07T09:28:15Z node{4,5,6} kernel: mlx5_core 0000:01:00.0 enp1s0f0np0: Link up
```

Down 09:24:35Z, up 09:28:15Z — 51 s after the switch finished booting. Last successful pod→remote-host
connect was **09:23:59Z**. The two coincide exactly.

### The causal chain, end to end

1. **09:24:35Z** — 10G switch reboots. All three nodes lose `enp1s0f0np0` carrier, and with it the
   `192.168.10.x` backnet address.
2. **09:24:41Z** — the vanished address changes each node's host-address set, which fires
   **OVN-K's gateway reconcile**. Visible on every node:
   ```
   I0807 09:24:41.710033 kube.go:133] Setting annotations
     map[k8s.ovn.org/host-cidrs:["192.168.1.7/24","192.168.10.16/24"]
         k8s.ovn.org/l3-gateway-config:{"default":{"mode":"local","bridge-id":"br-ex",...}}]
   ```
   NetworkManager also logs `state change: activated -> unavailable (reason 'carrier-changed')`
   for `enp1s0f0np0` and `ceph-shim`, and `ovs-vswitchd` logs br-ex `flow_mods ... (deletes)` at
   09:24:42Z.
3. **That reconcile leaves `net.ipv4.conf.br-ex.forwarding = 0`.** The ovnkube-node entrypoint's
   restricted-forwarding setup begins by zeroing `net.ipv4.ip_forward` — and in the Linux kernel,
   **writing to `conf.all.forwarding` propagates the value to every interface**, br-ex included.
   The reconcile re-asserts `ovn-k8s-mp0.forwarding=1` but **not** `br-ex.forwarding=1`; that
   appears to happen only on full gateway init, i.e. at ovnkube-node start.
4. Pod→external and pod→remote-host return traffic is dead on all three nodes, and **stays** dead —
   nothing re-runs the init.

Step 3's write is **inferred**, not directly observed (nothing logs the sysctl). But it is the only
mechanism consistent with the end state — `all=0, ip_forward=0, mp0=1, br-ex=0` — and it explains
every otherwise-odd feature of this failure: why all three nodes broke simultaneously (all three
lost the same link), why `mp0` and `br-ex` diverge (asymmetric re-application), and why an
ovnkube-node restart is the cure.

### Why this is worse than it looks

**The trigger is on the storage backnet, but the damage is on the frontnet.** VLAN 10 has nothing to
do with pod egress — but OVN-K's gateway reconcile fires on *any* host-address change, on *any*
interface. So a 10G switch reboot, an event with no logical connection to VLAN 5, silently kills
cluster-wide pod egress and leaves it broken indefinitely.

That also retro-explains the runbook's list of triggers (reboot, MCO reroll, nmstate change): every
one of them changes the host address set. They were never the cause — they were all instances of
*this*.

**Operationally: every future firmware upgrade of the 10G switch will do this again.** It is not a
one-off. Post-upgrade, check the sysctl on all three nodes and restart `ovnkube-node` if it reads 0.

### What was ruled out along the way

- **nmstate** — no enactment since 2026-07-30 (`nnce` Available=2026-07-30T16:34:28Z), zero handler
  restarts, NNCPs unchanged at `gen=3`.
- **MCO** — `mcp/master` Updated since 2026-07-26T21:17:57Z; newest rendered MachineConfig is
  2026-05-28.
- **Tuned / `power-tuning`** — profile sets no sysctls; pods have not restarted since 2026-04-03.
- **Repo manifests** — `grep -rniE "ipv4\.conf|ip_forward|forwarding" components/ bootstrap/` → nothing.
- **NetworkManager touching br-ex** — journal shows **zero** br-ex events on any node in 09:00-10:00Z.
  This killed my own leading hypothesis; the reconcile is OVN-K's, not NM's.
- **Clock/NTP** — `node_timex_sync_status=1`.
- **The frontnet link** — `enp0s31f6` shows no carrier change on any node. The 1G path never flapped.

### A measurement trap worth remembering

My first pass used `node_network_carrier_changes_total` and concluded node4 and node5 had **no**
carrier change, only node6. That was wrong. Prometheus (`prometheus-k8s-0`, on node6) stopped being
able to scrape node4 and node5 at 09:24 *because of this very outage*, so their carrier flap was
never recorded. The kernel log shows all three flapped identically.

**Metrics gathered during an outage are truncated by that outage.** When a monitoring gap and the
incident share a start time, absence of a metric is not evidence of absence of the event — go to the
node journal.

## Original trigger analysis (superseded by the confirmation above)

Onset is sharp and precisely dated. Last successful TCP connect from the check-source to node4's
apiserver endpoint: **2026-08-07T09:23:59Z**; to node6: **09:24:13Z**. The 10-entry success list
runs 09:14:59 → 09:23:59 at exactly 1/min with no gaps, then stops dead. The probe pod did *not*
restart (container up since 2026-07-25T17:24:56Z), so this is a real change in network state.

In the same four-minute window, **node4's Ceph backnet NIC dropped its `192.168.10.2` address
with no reboot** — both node4 OSDs died with:

```
unable to find any IPv4 address in networks '192.168.10.0/24' interfaces ''
```

…and self-healed by 09:28:15Z. A VLAN10 address disappearing and coming back on hardware that
never rebooted is a NetworkManager fingerprint, in the same window as the VLAN5 forwarding reset.

I could not confirm it: `oc adm node-logs -u NetworkManager` is guardrail-denied in this repo's
permission set, so the journal around 09:24Z is unavailable to me. **The trigger remains
unproven.** The root cause does not depend on it.

Ruled out along the way: the repo ships no sysctl anywhere
(`grep -rniE "ipv4\.conf|ip_forward|forwarding" components/ bootstrap/` → nothing), and the
`power-tuning` Tuned profile sets no sysctls and hasn't restarted since 2026-04-03.

## Why the runbook's fix works

`CLAUDE.md` has always said "restart all three `ovnkube-node` pods." Now there's a mechanism:
ovnkube-node re-runs its interface setup on start and re-asserts `br-ex.forwarding=1`. It also
explains the runbook's stranger footnotes:

- **"Restart ALL 3, not a targeted subset."** Each node's `br-ex` sysctl is independent. Fixing
  one node fixes only that node's pods.
- **"It can take a *second* clean restart."** If NM reapplies br-ex again after the restart, the
  sysctl is clobbered again.
- **"A 'Ready' ovnkube-node can still have broken egress."** The pod is healthy; a *host* sysctl
  it set earlier has been overwritten out from under it. Nothing in its readiness probe looks at
  `conf.br-ex.forwarding`.
- **"Broken pod→ClusterIP (172.30.0.1) too."** ClusterIPs with host-network backends DNAT to
  node IPs; only the node-local backend needs no forwarding. Hence the ~1-in-3 flapping success
  rate against the 3-replica apiserver service — not a mysterious "LB hash" effect.

**The best pre/post check is the sysctl itself**, not a `wget` that takes 8 s to fail:

```bash
sysctl -n net.ipv4.conf.br-ex.forwarding      # 0 = broken, 1 = healthy
```

That's a one-line, instant, unambiguous verdict per node, and it beats every symptom-level probe
the old runbook offered.

## Blast radius (for the record)

Broken: pod→external and pod→remote-host from all three nodes; pod→ClusterIP with host-network
backends (~1-in-3). Downstream: 45/45 ArgoCD apps `Unknown`; OAuth/console login down;
`etcd`/`authentication`/`insights` COs degraded; cert-manager `ErrRegisterACMEAccount` since
09:54:00Z; CNPG→R2 archiving dead on both clusters; Loki ingester on node4 with 77
`dial tcp 172.30.205.101:80: i/o timeout` to the RGW ClusterIP (ingester on node6: 0);
leader-election crash-loops on all three nodes.

A `kube-apiserver` revision 66→67 rollout was in flight and flaky during diagnosis
(`installer-67-node5` in `Error`); it completed on its own — all 3 nodes at revision 67 by
13:55Z.

Untouched: Ceph data path entirely (all 14 daemons in quorum, backnet up with 80/76/129 live
sockets, zero `FailedMount`, 31/31 VolumeAttachments healthy, no Released PVs); etcd itself (all
3 members genuinely healthy); pod→pod overlay; CoreDNS; host network, LAN, VLANs, router, WAN,
Technitium DNS; and the API as served to off-cluster clients.

### RPO exposure

Last WAL successfully archived to R2: `media-postgres` `0000001400000051000000AA` at
**09:21:03Z**; `immich-postgres` `000000010000000800000084` at **08:45:11Z**. Both base backups
completed *before* the break (media 04:00:14Z, immich 04:30:14Z) and are safely on R2. So a
total-loss recovery right now lands at ~09:21Z / ~08:45Z — 4.5 and 5 h of transaction loss,
widening an hour per hour.

WAL disk headroom: `media-postgres-2` 20 G volume, 933 M used, 19 G free, 50 pending 16 MiB
segments over ~4.2 h ≈ **190 MB/h** → ~100 h to full, so treat **~3 days** as the safe window
before the documented CNPG "Not enough disk space" safe-mode deadlock (which does *not*
auto-recover and does *not* auto-expand). `immich-postgres-1` is near-idle with 1 pending
segment and weeks of headroom.

## Process note

The first synthesis I produced was confidently wrong. It got the blast radius right (all three
nodes, not node5) but asserted the mechanism was "stale OVN datapath/flow state," citing GR
`mac_binding` and `lr-nat-list` SNAT rules as evidence. In local gateway mode those objects are
**off-path** — the failing traffic never enters the gateway router. Worse, running that
hypothesis' own tie-breaker (`ofproto/trace`) returns a clean
`Datapath actions: ct(commit,zone=19,...,nat(src)),4` with no drop, which would have sent the
next debugging session chasing LAN switch logs for a fault a switch cannot possibly cause.

Three independent adversarial reviewers refuted it; two converged on the `br-ex.forwarding`
sysctl from different directions (one via `ip route get iif`, one via conntrack zone asymmetry).
The lesson worth keeping: **the cluster's own runbook was the source of the bias.** "ovnkube-node
egress break → restart it" is a *symptom-and-remedy* pair with no mechanism, and reaching for it
made the familiar remedy feel like an explanation. The right instinct when a documented failure
recurs *without its documented trigger* is to distrust the documented cause.

## Recovery (2026-08-07, ~14:20Z — ~5 h after onset)

Operator applied `sysctl -w net.ipv4.conf.br-ex.forwarding=1` on all three nodes. No pod restarts,
no ovnkube-node bounce, no disruption.

Immediate, verified:

```
node4/node5/node6  br-ex.forwarding = 1
pod -> 192.168.1.7:6443   200 / 0.020 s   (was 000 / 8.00 s hang, from every node)
media-postgres    ContinuousArchiving = True/ContinuousArchivingSuccess
immich-postgres   ContinuousArchiving = True/ContinuousArchivingSuccess
etcd              EtcdMembersAvailable: 3 members are available
etcdctl endpoint health --cluster → all 3 healthy (20-28 ms)
repo-server       GenerateManifest grpc.code=OK  (was DeadlineExceeded)
clusterissuer/letsencrypt-prod  Ready=True/ACMEAccountRegistered  (self-healed, no bounce)
all 5 Certificates Ready=True
```

ArgoCD went from **45/45 `Unknown`** to 5 still converging within minutes; the `etcd` and
`authentication` ClusterOperators cleared themselves once pod→host-IP worked again, confirming
those messages were always probe-inferred rather than real.

**A one-line sysctl write ended a five-hour cluster-wide outage.** Worth sitting with: the fix was
never the heavyweight "restart all three ovnkube-node pods" the runbook prescribed — that only
worked because full gateway init happens to re-assert this one flag. Knowing the mechanism turned a
disruptive, ordered, multi-step remediation into a single idempotent write with zero pod churn.

### Two probe artifacts that nearly caused false conclusions

Both from the *same* verification pass, both worth remembering:

1. **`curl https://1.1.1.1` returned `000` after the fix** — but in 0.038 s, not the 8 s hang. Fast
   failure ≠ the original symptom. **Read the latency, not just the status code.**
2. **`curl https://github.com` returned `000` from all three nodes**, consistently — which looked
   like a real residual failure. It was the probe pod lacking a CA bundle:
   `error setting certificate file: /etc/pki/tls/certs/ca-bundle.crt`. Raw TCP to `github.com:443`
   returned **301 in 0.074 s**. Always confirm a "failure" is not your own instrument, especially
   when it is suspiciously uniform across hosts.

### Residue

### Residue — CLEARED (same day)

Both residual items were closed the same afternoon:

**`media/transmission-{master,slave}`** — deleting the pods was enough, but it took two attempts and
the reason is worth recording. The Deployment carries
`requiredDuringSchedulingIgnoredDuringExecution` anti-affinity on `component: transmission` with
`topologyKey: kubernetes.io/hostname`, so with master on node5 the slave could only land on node4 or
node6. It drew **node6 first and failed identically** — the staging dir was still poisoned — then
node4 on the retry and came up clean. Final: master `1/1` on node5, slave `1/1` on node4, `/data`
verified live in both (`stat -f` → `fs=ceph`, matching avail blocks — a real mount, not a stale one).

**node6's poisoned CephFS staging dir** — fixed by `systemctl restart kubelet` on node6. Verified
afterwards from the node:

```
/var/lib/kubelet/plugins/kubernetes.io/csi/rook-ceph.cephfs.csi.ceph.com/<volhandle>/globalmount
  → staging dir GONE (clean slate; kubelet re-stages on next mount)
cephfs mounts on node6: 1        # bazarr's pre-existing mount survived, still 1/1
```

node6 stayed `Ready` throughout, all 93 pods on it healthy. `prometheus-k8s-0` briefly read `5/6`
during the restart and self-cleared with **zero container restarts** — the kubelet restart did not
bounce a single workload, which is exactly why it is the right tool here rather than a reboot.

Note the ordering lesson: restarting kubelet on the poisoned node **first** would have let the slave
schedule anywhere and avoided the failed attempt entirely. Chasing the pod before fixing the node
is backwards.

### Original residue notes

- `media/transmission-{master,slave}`: `CreateContainerError`,
  `failed to resolve symlink .../volumes/kubernetes.io~csi/pvc-c0d00980-.../mount: lstat ...
  permission denied` — the documented CephFS staging residue from the outage window. Fix is to
  delete the pods so they re-stage (Deployment-managed, RWX so they can land anywhere); if they
  return to the same node and fail again, `systemctl restart kubelet` on that node. **Do not
  hand-chase with `umount`/`rmdir`/`rm -rf`** — that corrupted ceph-csi staging state on 2026-07-26.
- `insights` ClusterOperator still `Available=False`: long-fuse external retrier that had not yet
  reattempted its upload. Self-heals on the next cycle, or bounce `insights-operator`.
- Leftover `Error` pods from the outage window (`installer-67-node5`, `collect-profiles-*`,
  `descheduler-*`) are completed one-shot Jobs — cosmetic.

### Follow-up worth doing

Add a node-level alert on `net.ipv4.conf.br-ex.forwarding == 0`. Nothing in `ovnkube-node`'s
readiness probe reads it, so all three pods reported healthy for the full five hours while the
cluster had no egress. This single check would have cut detection from hours to minutes, and it is
the only signal that is both unambiguous and instant.
