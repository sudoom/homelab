# Gateway reconcile on host-address change leaves `net.ipv4.conf.br-ex.forwarding=0`, permanently breaking pod egress (local gateway mode + `--disable-forwarding`)

**Target:** `ovn-org/ovn-kubernetes` (also reproducible as shipped in OpenShift/OKD 4.20)
**Severity:** high — cluster-wide, silent, permanent until `ovnkube-node` restart
**Status:** draft, filing-ready

## Summary

On a cluster running **local gateway mode** (`gatewayConfig.routingViaHost: true`) with
**restricted forwarding** (`--disable-forwarding`, OpenShift's `ipForwarding: Restricted` default),
a host-address change on *any* interface triggers a gateway reconcile that leaves
`net.ipv4.conf.br-ex.forwarding = 0`. Pod→external and pod→remote-host **return** traffic is then
silently dropped by the host kernel on every affected node, and never recovers on its own.

The interface whose address changed does **not** have to be the gateway interface. In our case a
storage-only NIC on an unrelated VLAN flapped, and it killed pod egress cluster-wide.

## Environment

- OKD 4.20.0-okd-scos.17 (Kube 1.33), SCOS 10, kernel 6.12.0-142.el10
- 3-node bare metal, all control-plane+worker
- `gatewayConfig`: `{"ipv4":{},"ipv6":{},"routingViaHost":true}` (local gateway mode)
- ovnkube-node args include `--gateway-mode local --gateway-interface br-ex --disable-forwarding`
- `br-ex` rides a 1G NIC (`enp0s31f6`, 192.168.1.0/24). A second, unrelated 10G NIC
  (`enp1s0f0np0`, 192.168.10.0/24) carries Ceph replication only.

## Impact

Pod→pod overlay keeps working. DNS keeps working. Pod→own-host-IP keeps working. Everything else
from the pod network dies:

- all ArgoCD Applications go `Unknown` (repo-server cannot reach github.com)
- `authentication` ClusterOperator `Available=False` (OAuth down)
- `etcd` ClusterOperator reports a **false** "1 of 3 members are available" (etcd itself is healthy)
- cert-manager `ErrRegisterACMEAccount`
- offsite Postgres WAL archiving to object storage stops
- ClusterIPs with host-network backends succeed ~1-in-3 (only the node-local backend needs no
  forwarding), producing leader-election churn cluster-wide

## Reproduction

1. Local gateway mode + `--disable-forwarding`.
2. Confirm healthy state: `sysctl -n net.ipv4.conf.br-ex.forwarding` → `1`.
3. Cause any host address to appear/disappear on **any** interface — e.g. bounce the link on a
   secondary NIC (`ip link set <other-nic> down`), or reboot the switch it is attached to.
4. `ovnkube-controller` logs a gateway reconcile within seconds:
   ```
   kube.go:133] Setting annotations map[k8s.ovn.org/host-cidrs:[...]
     k8s.ovn.org/l3-gateway-config:{"default":{"mode":"local","bridge-id":"br-ex",...}}]
   ```
5. `sysctl -n net.ipv4.conf.br-ex.forwarding` → **`0`**. It stays `0` indefinitely.

Observed end state on all three nodes:

```
net.ipv4.conf.br-ex.forwarding        = 0     ← should be 1
net.ipv4.conf.ovn-k8s-mp0.forwarding  = 1
net.ipv4.conf.all.forwarding          = 0
net.ipv4.ip_forward                   = 0
```

## Why it breaks traffic

In local gateway mode the pod egress return leg is an ordinary kernel **forward**: the reply
arrives on `br-ex`, conntrack un-NATs the destination back to the pod IP, and the kernel must
forward `br-ex` → `ovn-k8s-mp0`. The kernel checks the **ingress** device's forwarding flag, so
`conf.br-ex.forwarding=0` drops the packet during routing — before the nftables FORWARD hook, which
is why no counter moves and the failure is a silent hang with no RST.

Controlled proof (same destination, only ingress interface varied):

```
ip route get 10.130.0.3                   → dev ovn-k8s-mp0     (resolves)
ip route get 10.130.0.3 iif ovn-k8s-mp0   → resolves
ip route get 10.130.0.3 iif br-ex         → RTNETLINK answers: No route to host
```

Host conntrack confirms the direction — packets leave and peers answer; only the reply is lost:

```
zone=0 : SYN_RECV  src=10.130.0.3 dst=1.1.1.1 sport=56944 dport=443
                   src=1.1.1.1 dst=192.168.1.7 sport=443 dport=56944
zone=19: SYN_SENT  src=10.130.0.3 dst=1.1.1.1 ... [UNREPLIED]
```

`SYN_RECV` in the host zone means the SYN-ACK arrived and the masquerade was applied correctly;
the pod-side OVS zone 19 entry never completes.

## Suspected cause

The restricted-forwarding setup zeroes `net.ipv4.ip_forward`. In the Linux kernel, writing to
`conf.all.forwarding` **propagates the value to every interface** (`inet_forward_change()`), so this
clears `br-ex` as a side effect. The reconcile path then re-asserts `ovn-k8s-mp0.forwarding=1` but
not `br-ex.forwarding=1` — that appears to happen only on full gateway init, i.e. `ovnkube-node`
start.

This is inferred from the end state (`all=0, mp0=1, br-ex=0`) rather than directly observed; nothing
logs the sysctl write. If maintainers can point at the exact call path we are happy to confirm.

## Expected behaviour

A gateway reconcile should be idempotent with respect to forwarding sysctls: after any reconcile,
every interface the datapath depends on — including the gateway bridge — should end up with
`forwarding=1`, exactly as after a fresh `ovnkube-node` start.

## Workaround

```bash
sysctl -w net.ipv4.conf.br-ex.forwarding=1     # immediate, per node
```

or restart `ovnkube-node` on every affected node (full gateway init re-asserts it). Note the
restart must be done on **all** nodes: each node's sysctl is independent, and a node left unfixed
looks healthy until a pod lands on it.

## Detection

```bash
sysctl -n net.ipv4.conf.br-ex.forwarding    # 0 = broken
```

Nothing in `ovnkube-node`'s readiness probe reads this, so the pod reports healthy throughout. A
node-level alert on this sysctl would have cut our detection time from ~5 h to minutes.
