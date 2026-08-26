# node-dhcp — frontnet static → DHCP

**Status: prepared, NOT enabled.** `bootstrap/root-app/values.yaml` has
`node-dhcp.enabled: false`. Flipping it to `true` **is** the change.

Prepared 2026-08-26 for execution on a later, dedicated day.

---

## What it does, and what it costs

Replaces `/etc/NetworkManager/system-connections/enp0s31f6.nmconnection` on all
three nodes with a DHCP (`method=auto`) version. `configure-ovs.sh` reads that
file at every boot and copies its ipv4 settings onto the runtime `ovs-if-br-ex`
connection — so it is the real source of truth for node addressing, even though
`nmcli` at runtime only shows the copy.

**Why:** the nameserver list is currently frozen in an install-time profile
dated **Apr 3**. Adding `dns-slave` (192.168.1.13) required a MachineConfig
reroll. Under DHCP the list comes from the MikroTik, so future DNS changes need
none. One change, then forget.

**Cost:** an MCO reroll — every node reboots, serially. On this cluster that
means:

- 3 nodes, all control-plane. **etcd quorum is 2 of 3**: one node down is
  survivable, two simultaneously is not.
- **No drain headroom** — nothing can move off a node.
- **No BMC / remote console.** These are consumer SFF desktops. Recovery from a
  node that will not come back on the network means physically attaching a
  monitor and keyboard.
- Each reboot re-trips the `br-ex.forwarding` cascade (see CLAUDE.md network
  pre-flight) and can bring the Ceph backnet NIC back `DOWN` (node6, 2026-07-25).

---

## Preconditions — all must be true before enabling

- [ ] **MikroTik reservations exist and are verified.** Non-negotiable.

      /ip/dhcp-server/lease/add server=dhcp-frontnet address=192.168.1.7 mac-address=D0:8E:79:05:37:0A comment="node4.okd"
      /ip/dhcp-server/lease/add server=dhcp-frontnet address=192.168.1.8 mac-address=D0:8E:79:19:19:BF comment="node5.okd"
      /ip/dhcp-server/lease/add server=dhcp-frontnet address=192.168.1.9 mac-address=D0:8E:79:06:F1:0F comment="node6.okd"

      **The IPs must not change.** etcd peer/serving and kubelet serving certs
      carry them as SANs; a node that comes back on a different address is a
      cert problem, not a networking problem.

      Verified 2026-08-26: `br-ex` inherits the physical NIC's MAC on all three
      nodes, so reservations keyed on these MACs match whether the DHCP client
      ends up on the NIC or on the bridge.

- [ ] **DHCP network options are right:**
      `/ip/dhcp-server/network/print detail` → `gateway=192.168.1.1`,
      `dns-server=192.168.1.12,192.168.1.13` on `192.168.1.0/24`.

- [ ] **A monitor and keyboard are physically to hand**, and you know which box
      is which. This is the whole recovery plan.

- [ ] **Cluster is healthy first**: 3/3 nodes Ready, etcd 3/3, Ceph HEALTH_OK
      (or only the known BlueStore latch), no MCP already updating.

- [ ] **2+ hours of headroom**, quiet IO, and nobody depending on the cluster.

---

## Execution

```bash
# 1. Baseline — you are comparing against this afterwards
oc get nodes -o wide
oc -n openshift-etcd exec $(oc -n openshift-etcd get pods -l app=etcd -o name | head -1 | cut -d/ -f2) \
   -c etcdctl -- etcdctl endpoint health --cluster
oc get mcp master

# 2. Have the EMERGENCY BRAKE in a second terminal, ready to paste:
#    oc patch mcp master --type merge -p '{"spec":{"paused":true}}'
#    Pausing stops the pool moving to the NEXT node. It does not un-reboot the
#    current one.

# 3. Enable it
#    edit bootstrap/root-app/values.yaml: node-dhcp.enabled: true
#    commit + push; ArgoCD creates the Application and applies the MachineConfig

# 4. Watch. The master pool rolls ONE node at a time and waits for Ready.
oc get mcp master -w
```

**After the FIRST node comes back, pause and verify before letting it continue.**
MCO gates on `Ready`, but a node can be Ready and still subtly wrong.

```bash
oc patch mcp master --type merge -p '{"spec":{"paused":true}}'
```

Per-node verification (substitute the node that just rebooted):

```bash
mcd=$(oc -n openshift-machine-config-operator get pods -l k8s-app=machine-config-daemon \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{end}')
for p in $mcd; do
  oc -n openshift-machine-config-operator exec $p -c machine-config-daemon -- chroot /rootfs sh -c '
    echo "== $(hostname -s)"
    ip -br a show br-ex | head -1
    nmcli -g ipv4.method connection show ovs-if-br-ex
    grep nameserver /etc/resolv.conf
    ip route | grep default
  '
done
```

Want, on the rebooted node: `br-ex` holding **its original IP**, `ipv4.method`
`auto`, **both** `192.168.1.12` and `192.168.1.13` in resolv.conf, and a default
route via `192.168.1.1`.

Then the post-reboot checks this cluster always needs:

```bash
# br-ex.forwarding — 0 means BROKEN pod egress. Restart ALL 3 ovnkube-node.
for p in $(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node \
    -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.nodeName}{"\n"}{end}'); do
  echo "${p##*:} $(oc -n openshift-ovn-kubernetes exec ${p%%:*} -c ovnkube-controller -- \
    sysctl -n net.ipv4.conf.br-ex.forwarding 2>/dev/null)"
done

# Ceph backnet NIC — can come back DOWN after a reboot (node6, 2026-07-25)
oc -n openshift-machine-config-operator exec <mcd-on-that-node> -c machine-config-daemon \
  -- chroot /rootfs ip -br a show enp1s0f0np0

# Stuck VolumeAttachments
oc get volumeattachment | awk '$5=="true"'
```

Satisfied → `oc patch mcp master --type merge -p '{"spec":{"paused":false}}'` and
repeat for nodes 2 and 3.

---

## Abort criteria — stop immediately if ANY of these

- The rebooted node does **not** return within ~10 minutes.
- It returns with a **different IP** than before.
- It returns with **no** IP on `br-ex`.
- `etcdctl endpoint health --cluster` shows fewer than 2 healthy members.
- `oc get mcp master` shows `Degraded=True`.

**On abort:** pause the pool first (stops node 2 from starting), then recover the
affected node before anything else. Never let a second node reboot while the
first is unhealthy — that is the quorum-loss scenario.

---

## Rollback

**If nodes are still reachable:** revert the git commit (set
`node-dhcp.enabled: false`, or `git revert`), push. ArgoCD removes the
MachineConfig, MCO rolls the nodes back to the previous rendered config. Same
serial reboots, same verification.

**If a node is OFF the network:** MCO cannot reach it. Physical console, log in
as `core`, and restore the static profile by hand:

```bash
sudo tee /etc/NetworkManager/system-connections/enp0s31f6.nmconnection >/dev/null <<'EOT'
[connection]
autoconnect=true
autoconnect-slaves=-1
id=enp0s31f6
interface-name=enp0s31f6
type=802-3-ethernet
uuid=31e3d3e1-2926-5a24-a073-631ab0e305b7
autoconnect-priority=1

[ipv4]
address0=<THIS NODE'S IP>/24
dhcp-timeout=2147483647
dns=192.168.1.12
dns-priority=40
dns-search=okd.sudops.pl
method=manual
route0=0.0.0.0/0,192.168.1.1,0
route0_options=table=254

[ipv6]
addr-gen-mode=0
dhcp-timeout=2147483647
method=disabled

[ethernet]
cloned-mac-address=<THIS NODE'S MAC>
EOT
sudo chmod 600 /etc/NetworkManager/system-connections/enp0s31f6.nmconnection
sudo reboot
```

| Node | IP | MAC |
|---|---|---|
| node4 | 192.168.1.7 | `D0:8E:79:05:37:0A` |
| node5 | 192.168.1.8 | `D0:8E:79:19:19:BF` |
| node6 | 192.168.1.9 | `D0:8E:79:06:F1:0F` |

(Captured live 2026-08-26. This table is the emergency card — the whole reason
it is written down here rather than left to be reconstructed under pressure.)

Then pause the pool from a working machine so MCO does not immediately re-apply
the DHCP config to the node you just fixed.

---

## Design notes

Each of these would be a bug if changed casually:

- **`cloned-mac-address=permanent`** — the live per-node files each hardcode that
  node's own MAC. One MachineConfig cannot carry three values, and shipping one
  node's MAC to all three would put **duplicate MACs on the LAN**. `permanent`
  means "use the burned-in address", making the file node-agnostic while
  preserving current behaviour exactly.
- **`dhcp-timeout=2147483647`** — effectively infinite, carried over from the
  static profile. A node that cannot get a lease **keeps asking** rather than
  activating with no address. A node stuck retrying is recoverable; a node that
  is Ready-but-address-less is not.
- **No `dns-search`** — the static profile sets `dns-search=okd.sudops.pl`, and
  `components/cluster-config/nm-search-strip` exists to *strip* it, because with
  `ndots:5` it makes short-name lookups try `<name>.okd.sudops.pl` first and
  stall ~5 s (measured 2026-05-08: 6003 ms vs 0.3 ms). Re-adding it would
  recreate the problem that chart solves.
- **No `route0`** — DHCP supplies the default route.
- **`uuid` unchanged** — all three already share `31e3d3e1-…` (NM derives it
  from the interface name). Keeping it means NM updates the existing profile
  rather than creating a second, competing one for the same interface.
