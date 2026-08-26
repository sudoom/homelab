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

- [ ] **Reservations were created MANUALLY with the client-id field EMPTY.**
      RouterOS matches static leases on `mac-address`, but a lease created via
      "make static" from a dynamically-learned one **copies the learned
      client-id**, and a client presenting a different or absent client-id then
      fails to match. The profile pins `dhcp-client-id=mac` so the identity is
      deterministic and identical before and after the bridge takes over.

- [ ] **`.7`, `.8`, `.9`, `.240` and `.241` are OUTSIDE the MikroTik dynamic
      pool range.** `.240` is the API VIP and `.241` the ingress VIP
      (keepalived-managed, confirmed on `infrastructure/cluster`). If the pool
      can hand a VIP or a node IP to an unrelated device, that is a cluster-down
      event unrelated to this change.

- [ ] **DHCP option 3 (router) = 192.168.1.1 on that pool.** The static
      profile's `route0=0.0.0.0/0,192.168.1.1,0` is **dropped** under DHCP —
      `configure-ovs.sh` does not propagate `ipv4.routes`/`ipv4.gateway` at all.
      Without option 3 the node has no egress.

- [ ] **A monitor and keyboard are physically to hand**, and you know which box
      is which. **SSH is not a recovery path** — the nodes' authorized key is
      `root@node4.okd.sudops.pl`, generated on the node at install, and it is
      not on the workstation. Once a node is off the network, `oc exec` and SSH
      are both gone. Physical console is the whole plan.

- [ ] **Cluster is healthy first**: 3/3 nodes Ready, etcd 3/3, Ceph HEALTH_OK
      (or only the known BlueStore latch), no MCP already updating.

- [ ] **2+ hours of headroom**, quiet IO, and nobody depending on the cluster.

---

## Execution — CANARY FIRST, MachineConfig second

**Do not enable the chart as the first move.** Verified 2026-08-26: this profile
is **not delivered by any MachineConfig**, and there is no
`/etc/machine-config-daemon/orig/...` backup — the MCD has never managed it. It
is an install-time assisted-installer artifact.

That is a gift. It means **one node can be converted by editing a file and
rebooting that node alone** — no MachineConfigPool, no MCD Degraded state to
unwind, and a rollback that is one `cp` and a reboot. Take the canary. Ship the
MachineConfig only once all three nodes are proven, to make the state
declarative and survive future reprovisioning.

Cost: 4 reboots instead of 3. Benefit: the irreversible-looking step becomes a
local, reversible file edit.

### Mechanism: MCD chroot, not SSH

**SSH to the nodes does not work from the workstation.** The authorized key is
`root@node4.okd.sudops.pl` (ed25519, generated on the node at install); neither
`id_rsa` nor `vadz_key` matches. So the edit goes through the machine-config-daemon
pod, which already has a host chroot:

```bash
node=node4.okd.sudops.pl        # ONE node. Start with the one holding NEITHER VIP.
mcd=$(oc -n openshift-machine-config-operator get pods -l k8s-app=machine-config-daemon \
      --field-selector spec.nodeName=$node -o jsonpath='{.items[0].metadata.name}')
```

Check which node is safest to go first — pick one holding neither VIP:

```bash
for p in $(oc -n openshift-machine-config-operator get pods -l k8s-app=machine-config-daemon -o name); do
  oc -n openshift-machine-config-operator exec ${p#pod/} -c machine-config-daemon -- chroot /rootfs sh -c \
    'printf "%-8s %s\n" "$(hostname -s)" "$(ip -4 -br a show br-ex | tr -s " ")"'
done
```

`192.168.1.240` (API VIP) and `192.168.1.241` (ingress VIP) are keepalived-managed
and float. Rebooting the node holding one just moves it, but starting with the
node holding neither removes a variable.

### Canary steps

```bash
# 1. BACK THE FILE UP OFF-NODE. This is your only guaranteed rollback source.
oc -n openshift-machine-config-operator exec $mcd -c machine-config-daemon -- chroot /rootfs \
  cat /etc/NetworkManager/system-connections/enp0s31f6.nmconnection > ~/enp0s31f6-$node.static.bak
cat ~/enp0s31f6-$node.static.bak      # sanity-check it is not empty

# 2. Write the DHCP profile (content: helm template the chart and decode the base64)
helm template node-dhcp components/cluster-config/node-dhcp/ \
  | grep -o 'base64,[A-Za-z0-9+/=]*' | cut -d, -f2 | base64 -d > /tmp/dhcp.nmconnection
cat /tmp/dhcp.nmconnection            # confirm before pushing it

oc -n openshift-machine-config-operator exec -i $mcd -c machine-config-daemon -- chroot /rootfs \
  sh -c 'cat > /etc/NetworkManager/system-connections/enp0s31f6.nmconnection && chmod 600 /etc/NetworkManager/system-connections/enp0s31f6.nmconnection' < /tmp/dhcp.nmconnection

# 3. Reboot ONLY this node
oc -n openshift-machine-config-operator exec $mcd -c machine-config-daemon -- chroot /rootfs systemctl reboot
```

Then verify per the checks below. **If it comes back correct, repeat on the
other two, one at a time.** Only after all three are proven, enable the chart —
at that point the MachineConfig matches what is already on disk, so the reroll
is a no-op adoption rather than a change.

### If you skip the canary and enable the chart directly

The pool rolls one node at a time and waits for Ready. Keep the emergency brake
in a second terminal, ready to paste:

```bash
oc patch mcp master --type merge -p '{"spec":{"paused":true}}'
```

It stops the pool moving to the **next** node. It does not un-reboot the current one.

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
