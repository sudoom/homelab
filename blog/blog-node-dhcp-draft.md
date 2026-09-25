# Moving the OKD nodes from static addresses to DHCP

Working draft. The three nodes were installed with a static frontnet profile
(`/etc/NetworkManager/system-connections/enp0s31f6.nmconnection`, dated Apr 3)
that hardcodes the nameserver list. Adding the second DNS server
(`dns-slave`, `192.168.1.13`) therefore meant a MachineConfig reroll, and so would
every future DNS change. Under DHCP the MikroTik hands out the list and the nodes
follow it. The change was prepared on 2026-08-26 (`4b5b7bb`, `f6c1d5a`) as the
`components/cluster-config/node-dhcp/` chart, shipped disabled, and run on
2026-09-25. The chart README holds the runbook; this is what happened.

## 2026-08-26 — prepared, shipped disabled

The findings that shaped the chart, recorded in its README:

- `configure-ovs.sh` copies the on-disk profile's ipv4 settings onto the runtime
  `ovs-if-br-ex` connection at every boot, so the file is the source of truth.
  A DHCP reservation alone changes nothing — the interfaces never ask.
- No MachineConfig manages that file (it is an assisted-installer artifact), so
  one node can be converted by editing the file and rebooting it alone: a
  canary with a one-`cp` rollback.
- `br-ex` inherits the NIC's MAC on all three nodes, so reservations keyed on the
  NIC MACs match whether the DHCP client runs on the NIC or the bridge.
- One MachineConfig cannot carry three MACs, so the profile uses
  `cloned-mac-address=permanent`, and pins `dhcp-client-id=mac`.

## 2026-09-25 — node4 by hand, then the chart

### Pre-flight, re-checked against today's cluster

The runbook was a month old, from before the 4.21 upgrade and the move to
two-instance CNPG clusters, so the preconditions were re-read live.

- NodeNetworkState (readable under the readonly SA): all three nodes still
  resolve through `192.168.1.12` only, MACs match the runbook's emergency card,
  node5 held both VIPs (`.240`, `.241`), so node4 went first.
- The reservations were already on the router. With no SSH to it from the
  workstation, the in-cluster MikroTik exporter answered instead, through the
  apiserver service proxy:

  ```bash
  KUBECONFIG=~/.kube/config-readonly oc get --raw \
    "/api/v1/namespaces/mikrotik-exporter/services/http:mikrotik-exporter:49090/proxy/metrics" \
    | grep '^mktxp_dhcp_lease_info' | grep okd
  ```

  Three leases on `dhcp-frontnet`, correct MAC to IP, `client_id=""` on all
  three. node5's still carried `host_name="DESKTOP-7HF9LFP"`, a learned name from
  whatever ran on that box before OKD; the reservation matches on MAC, so it is
  cosmetic.
- `oc get machineconfiguration cluster` showed only the default node disruption
  policies, none covering the profile path. That exposed an error in the
  runbook: it said that after converting all three nodes by hand, enabling the
  chart would be "a no-op adoption". It is not — a new rendered config drains
  and reboots every node regardless of what is already on disk. Converting all
  three by hand first would have cost six reboots. Chosen instead: node4 by hand,
  then the chart for everything (four reboots, node4 twice).

### node4

Paused the Loki operator (network pre-flight step 1) and drained, as MCO would:

```bash
oc -n openshift-operators-redhat scale deploy loki-operator-controller-manager --replicas=0
oc adm drain node4.okd.sudops.pl --ignore-daemonsets --delete-emptydir-data --timeout=20m
```

The first drain cordoned the node and then refused to evict anything:

```
cannot delete Pods that declare no controller (use --force to override):
openshift-etcd/etcd-guard-node4.okd.sudops.pl, openshift-kube-apiserver/kube-apiserver-guard-node4.okd.sudops.pl,
openshift-kube-controller-manager/kube-controller-manager-guard-node4.okd.sudops.pl,
openshift-kube-scheduler/openshift-kube-scheduler-guard-node4.okd.sudops.pl
```

The guard pods have no owner by design; their PDBs (`*-guard-pdb`, 1 allowed)
are what actually protect quorum, and `--force` still evicts through them. MCO's
drain uses force for the same reason. The cordon alone was enough for CNPG to
switch `media-postgres` over from `media-postgres-3` (on node4) to
`media-postgres-1` before any eviction. Re-run with `--force`: 54 pods evicted,
`node/node4.okd.sudops.pl drained`. Ceph went to the expected degraded window —
mon-a and osd.0 down, Rook set `noout` on the host, 33.333% of objects degraded.

Backed up the static profile off-node through the MCD pod's host chroot, then
wrote the rendered DHCP profile and read it back:

```bash
oc -n openshift-machine-config-operator exec machine-config-daemon-68676 -c machine-config-daemon -- \
  chroot /rootfs cat /etc/NetworkManager/system-connections/enp0s31f6.nmconnection > ~/enp0s31f6-node4.static.bak

helm template node-dhcp components/cluster-config/node-dhcp/ \
  | grep -o 'base64,[A-Za-z0-9+/=]*' | cut -d, -f2 | base64 -d > dhcp.nmconnection

oc -n openshift-machine-config-operator exec -i machine-config-daemon-68676 -c machine-config-daemon -- \
  chroot /rootfs sh -c 'cat > /etc/NetworkManager/system-connections/enp0s31f6.nmconnection && chmod 600 /etc/NetworkManager/system-connections/enp0s31f6.nmconnection' < dhcp.nmconnection
```

Read back: `600 root:root 359 bytes`, byte-identical to the render. No other
profile in the directory claims `enp0s31f6` (the others are the backnet NIC, the
spare NIC and `ceph-shim`; a 1-byte file named `nmconnection` has sat there since
install day and NetworkManager ignores it).

Rebooted through the same pod (`chroot /rootfs systemctl reboot`). The node went
`Unknown` at 16:03:15 and was `Ready` on a new boot ID at 16:05:10.

On the node afterwards:

```
br-ex:  192.168.1.7/24
method: auto  client-id: mac
dhcp_lease_time = 600   dhcp_server_identifier = 192.168.1.1
domain_name_servers = 192.168.1.12 192.168.1.13   routers = 192.168.1.1
default via 192.168.1.1 dev br-ex proto dhcp src 192.168.1.7 metric 48
resolv.conf: nameserver 192.168.1.7 / 192.168.1.12 / 192.168.1.13   (no search line)
backnet: enp1s0f0np0 UP 192.168.10.2/24, pings to .10.3 and .10.4 OK
br-ex.forwarding=1
```

The router agreed: `status=bound`, `active-client-id="1:d0:8e:79:5:37:a"` (type 1
plus the MAC — what `dhcp-client-id=mac` sends), bridge port `ether6`. etcd
healthy on all three members; `br-ex.forwarding` 1 on all three nodes, so no
ovnkube-node restart was needed.

### The mon failover that nearly happened

After the uncordon a `rook-ceph-mon-d` pod sat Pending. The operator log told the
story:

```
15:58:13 op-mon: marking mon "a" out of quorum
16:08:20 op-mon: mon "a" NOT found in quorum and timeout exceeded, mon will be failed over
16:08:20 op-mon: skipping stopping mon "a" during failover, since with host networking a new mon cannot be started on the same node
16:08:56 op-mon: canary monitor deployment rook-ceph-mon-d-canary scheduled to node4.okd.sudops.pl
16:09:00 op-mon: starting mon "d"
```

Rook's mon health check fails a mon over after 10 minutes out of quorum. node4's
mon was out from the drain to just after the uncordon, a little over ten
minutes. The canary for `mon-d` landed on node4 in the moment between the
uncordon and `mon-a`'s own pod starting; `mon-a` then took host port 6789 first,
and `mon-d` could never schedule (`didn't have free ports`). Ceph itself was
unaffected — quorum a,b,c — but `rook-ceph-mon-endpoints` listed `d` at
`192.168.1.7:6789` alongside `a`, and the mon PDB dropped to `maxUnavailable: 0`,
which would have blocked the next drain.

Rook v1.19.5 undoes a failover whose new mon never starts:
`pkg/operator/ceph/cluster/mon/health.go` `failoverMon` defers a cleanup that
removes the replacement and reverts `maxMonID`, and `waitForQuorumWithMons` gives
up after 60 tries at 5 s. So the prediction was cleanup at about 16:14, and:

```
16:14:01 op-mon: removed monitor d
16:14:03 op-mon: reverting maxMonId to 2
16:14:03 op-mon: failed to failover mon "a". failed to start new mon d: ... exceeded max retry count waiting for monitors to reach quorum
16:14:05 op-mon: setting mon pdb maxUnavailable=1 (0 mons down)
```

Ceph `HEALTH_OK`, endpoints back to a,b,c, mon PDB 1 allowed. Nothing was
touched by hand. The lesson for the MCO rollout: a node's window has to stay
under ten minutes, and if it does not, wait for the mon PDB to recover before
the next node, rather than fighting it.

### The lease length

node4's first lease was 600 s. The reservations inherited the server's
10-minute lease, and a reservation fixes which address a node gets, not for how
long — NetworkManager drops the address when a lease expires unrenewed. With all
three nodes on DHCP, a router outage longer than the lease would pull every node
IP and etcd with it; with static addresses the same outage only cut internet
access. RouterOS 7.24.2 (CCR2004) takes a per-lease `lease-time` that overrides
the server's, so only the three nodes change:

```
/ip/dhcp-server/lease/set [find where comment~"okd"] lease-time=1d
```

node4 renewed at 16:19:57 with `dhcp_lease_time = 86400`, same address, DNS and
gateway. The price: a DHCP option change reaches a node at its next renewal (up
to 12 h) or reboot.

### Paused after node4

The chart commit was ready to push when Jellyfin came into use, and it runs on
node6. Enabling the chart hands the node order to MCO, which could take node6
first; pausing the pool controls when the next node goes, not which. So the rest
waits for a window with Jellyfin idle, and the chart stays disabled. The mixed
state is stable: node4's profile is unmanaged by any MachineConfig, and nodes on
static and DHCP profiles coexist with nothing reconciling either.

The open choice for node5 and node6: convert both by hand like node4, then enable
the chart together with a `nodeDisruptionPolicy` entry on
`MachineConfiguration/cluster` (action `None` for the profile path), so MCO
writes the identical file without draining anything — three reboots in total —
or enable the chart without it and accept three more drains and reboots in
MCO's order.

### The chart, the same evening

Jellyfin went idle, so the order MCO would pick stopped mattering and the chart
went on as it was (`96d20ad`, pushed 18:01:14Z). The `nodeDisruptionPolicy`
alternative was dropped rather than chosen: with action `None`, MCO writes the
file on node5 and node6 without rebooting them, and the profile only takes
effect at boot — it only makes sense once every node is already converted.

Pre-flight was the network-change runbook, re-read against the live cluster:
Ceph `HEALTH_OK`, pool `master` Updated 3/3, the two structural CNPG primary
PDBs the only ones at 0, both CNPG clusters 2/2, and the Loki operator still at
0 from the node4 canary.

MCO's rollout, from a 20-second poll of the pool, node state, the mon PDB, Ceph
health and `br-ex.forwarding` on every node:

```
18:05:16  MachineConfig 99-master-frontnet-dhcp created (ArgoCD)
18:05:38  node4 cordoned, Working            (mon PDB → 0, Ceph WARN during the drain)
18:10:58  node4 back, new boot ID            br-ex.forwarding 1/1/1
18:11:22  node6 cordoned
18:17:03  node6 back                         br-ex.forwarding 1/1/1
18:17:27  node5 cordoned
18:24:02  node5 back
18:24:24  pool Updated 3/3 on the new rendered config
```

About six to seven minutes per node, node4 onto the file it already had. Each
mon was out of quorum for less than Rook's ten-minute failover timeout, so there
was no repeat of the canary's `mon-d`: the operator log shows mon-c "back in
quorum" at 18:24:29 and nothing more. `br-ex.forwarding` read 1 on every node
after every reboot, so no ovnkube-node restart was needed. osd.1 on node5 took
the longest to rejoin; Ceph was back to `HEALTH_OK` a few minutes after the
pool finished.

On every node afterwards, through the MCD chroot:

```
node4  method=auto  192.168.1.7  dhcp_lease_time = 86400  dns .12 .13  default via .1 proto dhcp  backnet UP .10.2
node5  method=auto  192.168.1.8  dhcp_lease_time = 86400  dns .12 .13  default via .1 proto dhcp  backnet UP .10.3
node6  method=auto  192.168.1.9  dhcp_lease_time = 86400  dns .12 .13  default via .1 proto dhcp  backnet UP .10.4
profile sha256 a2e14d29… on all three (the same file node4 got by hand)
```

The router's lease table agreed: all three `bound`, bridge ports `ether6/7/8`,
about 23 h 40 min left on each, and node5's lease now carries host name `node5`
instead of the `DESKTOP-7HF9LFP` it had learned from whatever that box ran
before OKD. The sweep after the rollout was clean: 48/48 ArgoCD apps Synced and
Healthy (the repo-server could still reach GitHub, so no bounce), both CNPG
clusters 2/2 and archiving, no Pending or crashlooping pods, every
ClusterOperator clean. The Loki operator went back to one replica afterwards.

The nameserver list that started all this now comes from the router: all three
nodes resolve through `.12` and `.13`, and the next DNS change is a MikroTik
setting, picked up at each node's next renewal (up to 12 h) or reboot — no
MachineConfig.

The rollout overlapped the Alertmanager dead-man's switch test (see
`blog/blog-monitoring-foundation-draft.md`, 2026-09-25): both Alertmanager pods
were drained and restarted during a 25-minute Watchdog silence, and the silence
survived — silences live on Alertmanager's volume and are gossiped between the
replicas.
