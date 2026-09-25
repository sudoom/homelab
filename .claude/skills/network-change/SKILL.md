---
name: network-change
description: Pre-flight runbook and failure knowledge for network-stack changes on the homelab OKD cluster — NNCP/nmstate, MachineConfig rerolls, Network/cluster, IPsec, MTU, node reboots, 10G switch firmware — plus node-drain blockers (CNPG primary PDB, Loki ingester PDB, the Tuned reroll trap) and the br-ex.forwarding=0 pod-egress break. Use before planning or applying any such change, when a node drain stalls, and when pods lose egress to remote hosts (ArgoCD sync=Unknown, false etcd-critical alerts, ContinuousArchiving=False on a CNPG cluster, curl exit code 28).
---

# Network-stack changes, node drains and the br-ex.forwarding break

Moved verbatim from the root `CLAUDE.md` on 2026-09-24. Sections the moved text refers to by name now live here:

- The storage and Ceph sections, "RBD CSI quirks", "Upgrading Rook/Ceph" → `.claude/skills/rook-ceph/SKILL.md`; the used-drive DDF false alerts → `.claude/skills/rook-ceph/disk-ops.md`
- Health sweep and alert triage → `.claude/skills/cluster-health/SKILL.md`
- The standing `br-ex.forwarding` alert → README TODO

## Pre-flight for any network-stack change (MCO reroll OR nmstate-only)

Full chronology + per-incident detail: `blog/blog-security-hardening-draft.md`.

**Scope** — the cascade triggers on any change that reloads NetworkManager / OVS gateway state, not just MachineConfig events:
- IPsec mode flip on `Network/cluster` (MC delta)
- OVN-K pod-overlay MTU change (operator-side MC churn even when final MC is identical)
- nmstate NNCP applying any interface change incl. MTU-only (no MC at all)
- Probably any future `Network/cluster` mutation, NNCP, multus NAD change
- **Any full node power-cycle** (e.g. installing a non-hot-swap 3.5" HDD) — re-trips the same OVN-egress cascade *per reboot* (observed 2026-06-10: node5 reboot → all 42 ArgoCD apps `sync=Unknown`, repo-server `DeadlineExceeded` on manifest gen). Fix = restart that node's `ovnkube-node` (look it up via `--field-selector spec.nodeName=...`, NOT awk columns — the `RESTARTS (x ago)` field shifts positions) + bounce repo-server; a bare repo-server bounce alone does NOT fix it (egress, not cold-cache). **After a multi-node disruption, restart EVERY disrupted node's `ovnkube-node`, and re-verify — a "Ready" ovnkube-node can still have broken egress AND broken pod→ClusterIP (172.30.0.1) service routing; the second is what stalled a CNPG barman sidecar (couldn't reach the kube API) even after the first restart. It can take a *second* clean ovnkube-node restart once the underlying fabric is stable (2026-07-25).**
- **A node reboot can bring the Ceph storage-backnet NIC (`enp1s0f0np0`, VLAN 10) back up `DOWN`/`linkdown`** (observed 2026-07-25: node6's came back down after the others rebooted). Because `public_network`/`cluster_network` are both `192.168.10.0/24`, a single node's backnet NIC being down = **that node's OSDs can't heartbeat (marked down) AND its kRBD client can't map ANY image** → every RBD pod on that node hangs `MountVolume.MountDevice … DeadlineExceeded`, and other nodes' OSD logs show `heartbeat_check: no reply from 192.168.10.<x>`. **Post-reboot storage check: `ip -br a show enp1s0f0np0` UP with its `192.168.10.x` IP on every node + cross-node `ping 192.168.10.2/3/4`.** Fix a down one with `nmcli device connect enp1s0f0np0` (restores the managed IP + the load-bearing `/24` routes — NOT a bare `ip link up`). Then the post-outage RBD cleanup dance is needed on that node (stuck VAs → nodeplugin op-lock → re-verify pod→ClusterIP), none of which self-heals.

**Cluster-shape gotchas to remember**:
- **`MinAvailable: N` PDB with replicas == N blocks ALL voluntary evictions.** LokiStack hardcodes ingester `MinAvailable=2` with 2 replicas → 0 disruption budget → drain hangs forever. CRD doesn't expose PDB tunables. Pre-flight: `oc get pdb -A`, ALLOWED DISRUPTIONS ≥ 1 everywhere **except the two structural CNPG primary PDBs** (`media/media-postgres-primary`, `immich/immich-postgres-primary`) — CNPG's per-cluster primary PDB is `minAvailable: 1` over exactly the one primary pod, so `disruptionsAllowed` is permanently 0 by construction (on `media-postgres` too, whatever its instance count). Those do NOT block draining a node that holds a *replica*, and with 2+ instances CNPG switches the primary over ahead of the drain. **Both clusters run 2 instances since 2026-09-15** (media was 3 until then), so neither has the replica PDB (`<cluster>`, created only at 3+ instances) and the lone replica is freely evictable. A 1-instance CNPG cluster is the one shape that stalls a drain — never run one on the master pool (see "Node drain" above). Any OTHER 0 is a real blocker.
- **Cross-node host-network breakage between mismatched-MC nodes during IPsec rollouts** (observed 2026-05-20, root cause TBD). Don't re-attempt IPsec without diagnosing. **CANDIDATE EXPLANATION (2026-08-07, unverified):** this may be the `br-ex.forwarding=0` bug above. An IPsec rollout is an MCO reroll → node reboots → host-address changes → OVN gateway reconcile → `br-ex.forwarding` zeroed, which breaks pod→remote-host-IP exactly as described. **Before relying on this, resolve the one distinguishing detail the 2026-05-20 notes don't record: was the failing source a POD-network pod or a genuinely host-network pod?** Only the former is explained by `br-ex.forwarding` (host-network traffic never traverses `ovn-k8s-mp0`). If it was pod-network, this TBD is closed and the check is a one-liner; if host-network, it is still a separate unknown.
- **Storage chaos compounds with MCO chaos rapidly.** Schedule with 2+ hour headroom.

**Pre-flight runbook** (run for any of the trigger shapes above):

1. Scale `openshift-operators-redhat/loki-operator-controller-manager` → 0. The 5-min `loki-pdb-override` CronJob loses the race against operator reconciles; scaling the operator to 0 holds the PDB at `MinAvailable: 1` throughout.
2. Apply the change. Monitor `oc get mcp master -w` (MC-class) OR `oc get nncp` (nmstate-class).
3. **During the rollout**, watch for stuck VolumeAttachments (`oc get volumeattachment -o jsonpath='{range .items[?(@.status.attached==true)]}{.metadata.name} {.spec.source.persistentVolumeName} {.spec.nodeName}{"\n"}{end}'`) and force-clear with `oc patch volumeattachment <name> -p '{"metadata":{"finalizers":[]}}' --type=merge`. RBD VAs frequently stay bound to the previous node after pod move.
4. **After the change settles**, restart all 3 `ovnkube-node` pods one at a time (`oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node`). Pod→host-network egress breaks; restart restores it. Symptom: ArgoCD `sync=Unknown` (repo-server can't reach github.com), etcd CO degrades (`EtcdMembersAvailable: 1 of 3`) though etcd itself is healthy. **Restart ALL 3 — not a targeted subset (2026-06-11 lesson).** A node whose `ovnkube-node` isn't restarted keeps **broken pod→*remote*-host-IP egress** (it can still reach its OWN host IP, so it looks fine) and the breakage stays **silent until a pod lands on it** — that day, only node5's `ovnkube-node` got restarted in the morning cascade fix; node6's stayed broken all day and only surfaced when `prometheus-k8s-0` rescheduled onto node6 and couldn't scrape node4/node5 host-metrics (`:10250`/`:9100`/etc. hung 30s), throwing ~20 **false** `TargetDown` + critical `etcdMembersDown`/`etcdInsufficientMembers`/`ClusterVersionOperatorDown`. Diagnose with a per-source-node reachability test: `oc -n <ns> exec <pod-on-suspect-node> -- sh -c 'time wget -qO- -T8 http://<remote-host-ip>:9100/metrics'` — fast to own host IP + 30s+ hang to remote host IPs == that node's `ovnkube-node` needs a restart. (Distinct from the DDF-cAdvisor false-alert cause in the storage section — both throw the same etcd-critical symptom; rule out etcd-real with `etcdctl endpoint health --cluster` first.)

   **MECHANISM (found 2026-08-07 — this entry was symptom-only for months).** The "ovnkube-node egress break" is a **host-kernel return-path** failure, not an egress failure: **`net.ipv4.conf.br-ex.forwarding` gets reset to `0`.** This cluster runs OVN-K **local gateway mode** (`gatewayConfig.routingViaHost: true`), so pod north-south traffic leaves via `ovn-k8s-mp0` into the host kernel, is masqueraded, and exits `br-ex` — making the **reply** an ordinary kernel forward (in `br-ex` → out `mp0`). With `conf.br-ex.forwarding=0` the kernel drops the reply *during routing*, before the nftables FORWARD hook: silent hang, no RST, no counter moves. Packets really do go out (host conntrack zone 0 shows `SYN_RECV` with the reply tuple `dst=<node-IP>`) while the pod-side OVS zone 19 entry sits `SYN_SENT [UNREPLIED]` forever. `ip_forward=0` globally is **correct and deliberate** here (ovnkube-node runs with `--disable-forwarding`, OpenShift's `ipForwarding: Restricted` default) — forwarding is enabled per-interface, so healthy state is **`br-ex=1`, `mp0=1`, `all=0`, `ip_forward=0`**. `mp0` survives because it's an OVS internal port owned by OVN-K; `br-ex` is NetworkManager-managed, so an NM reapply resets its per-interface sysctls to the `default` (`0`) and leaves `mp0` alone. Restarting `ovnkube-node` works because it re-asserts `br-ex.forwarding=1` on start.

   **Use the sysctl as the pre/post check — it is instant and unambiguous, unlike an 8-30s `wget` hang:**
   ```bash
   for p in $(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node \
       -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.nodeName}{"\n"}{end}'); do
     echo "${p##*:} $(oc -n openshift-ovn-kubernetes exec ${p%%:*} -c ovnkube-controller -- \
       sysctl -n net.ipv4.conf.br-ex.forwarding 2>/dev/null)"      # 0 = BROKEN, 1 = healthy
   done
   ```
   This also explains the entry's odd footnotes: each node's sysctl is independent (**hence restart ALL 3**); a *second* restart is sometimes needed because NM can clobber it again; a "Ready" `ovnkube-node` can still be broken because nothing in its readiness probe reads that sysctl; and the pod→ClusterIP `172.30.0.1` breakage is ~1-in-3 flapping because only the **node-local** host-network backend needs no forwarding. **TRIGGER (confirmed 2026-08-07): ANY host-address change on ANY interface — including the Ceph storage backnet.** That day the **Mikrotik 10G switch was rebooted for a firmware upgrade**; all 3 nodes logged `mlx5_core ... enp1s0f0np0: Link down` at **09:24:35Z** and `Link up` at **09:28:15Z**, and 6 s after the drop every node's `ovnkube-controller` logged `Setting annotations map[k8s.ovn.org/host-cidrs:[...] k8s.ovn.org/l3-gateway-config:{...}]` — OVN-K's **gateway reconcile**, fired because the backnet address vanished. That reconcile leaves `br-ex.forwarding=0` (the restricted-forwarding setup zeroes `net.ipv4.ip_forward`, and writing `conf.all.forwarding` **propagates to every interface**; it then re-asserts `mp0=1` but not `br-ex=1`, which only happens on full gateway init = ovnkube-node start). **The trigger is on VLAN 10; the damage is on VLAN 5** — the two have no logical connection, which is exactly why this is easy to misdiagnose. This also retro-explains this entry's whole trigger list (reboot / MCO reroll / nmstate change): each changes the host address set, so each was an instance of *this*, not a separate cause. **Every future 10G-switch firmware upgrade will re-break pod egress cluster-wide** — treat a backnet link flap as a mandatory post-check of the sysctl above. **SECOND INSTANCE (2026-09-08), CAUSE PARTLY MIS-ATTRIBUTED AT FIRST — READ THE RETRACTION BELOW.** No reboot, no MCO reroll, no nmstate enactment, no switch event — just a tie-break at 05:09 that moved the API VIP (`192.168.1.240`) and the ingress VIP (`.241`) off node4 (`(okd_API_0) Master received advert from 192.168.1.8 with same priority 68 but higher IP address than ours` → `Entering BACKUP STATE`, `oc -n openshift-kni-infra logs keepalived-<node> -c keepalived`). Two addresses moving across three hosts inside a second is a host-address change on every node, so `br-ex.forwarding` went to 0 cluster-wide. **RETRACTED SAME DAY.** I wrote that up as "a bare VRRP failover is a sufficient trigger". Later that morning node5 was powered down for phase 4, the ingress VIP failed over to node6 (`(okd_INGRESS_0) Entering MASTER STATE`, node6 ending up with BOTH `.240` and `.241`) — and `br-ex.forwarding` stayed **1** on both surviving nodes. A VIP move alone does **not** do it. What the 09-08 evidence actually supports is that the ~05:09 **frontnet blip** hit all three nodes at once, and the VIP re-election was a *sibling symptom* of that blip, not its cause — which also explains why Ceph lost mon quorum and marked all 6 OSDs down in the same minute. That fits the confirmed 2026-08-07 mechanism (a link event flapping host addresses on every node) rather than adding a new one. **What IS confirmed by both 09-08 reboots: a node reboot reliably zeroes THAT NODE'S `br-ex.forwarding`, and only that node's** — node4's reboot left node5/node6 at 1. So blast radius = the set of nodes whose addresses actually changed, and a single-node reboot is a single-node fix (measure all three with the sysctl, then restart what reads 0). The standing alert (README TODO) remains the right mitigation because the cluster-wide variant is still triggered by link events nobody schedules. Same blip also cost Ceph its mon quorum and marked all 6 OSDs down (mons advertise FRONTNET addresses — a frontnet blip IS a Ceph event) and crashed the `rook` mgr module; Ceph self-recovered, PGs back to `active+clean`. **Symptom trap from that day: `oc get csv -A` showed `cloudnative-pg.v1.30.0` flapping `Failed`/`InstallReady`, which reads as a broken operator upgrade and is not** — it is OLM's install-plan check failing to reach `172.30.0.1`. Likewise a `ContinuousArchiving=False` on BOTH CNPG clusters (not one) is the all-three-nodes shape of this bug. Ruled out that day: nmstate (no enactment since 07-30, 0 handler restarts), MCO (no rendered MC since 05-28), Tuned, repo manifests, NM touching br-ex (**zero** br-ex journal events on any node), clock. Full diagnosis: `blog/blog-ovn-brex-forwarding-outage-draft.md`; upstream bug draft: `bugs/upstream-ovn-kubernetes-gateway-reconcile-drops-br-ex-forwarding.md`.

   **Measurement trap:** `node_network_carrier_changes_total` showed node4/node5 as having NO carrier flap that day — false. `prometheus-k8s-0` (on node6) could not scrape them from 09:24 *because of this outage*, so their flap was never recorded. **When a monitoring gap and the incident share a start time, absence of a metric is not evidence of absence of the event** — go to the node journal (`chroot /rootfs journalctl -k` via the MCD pod; `oc adm node-logs` is guardrail-denied).

   **Diagnostic trap — `PodNetworkConnectivityCheck` cannot localise this.** `network-check-source` is a **`replicas: 1` Deployment** (only `network-check-target` is a DaemonSet), so *every* check in the cluster is sourced from whichever single node hosts that pod. "All DOWN checks have source nodeX" is a **tautology**, not evidence that nodeX is the broken one — and it gives **zero** information about the other two nodes. Localise with the per-node sysctl check above, or a `curl --max-time 8` matrix from a pod on each node.
5. Restart `openshift-gitops` repo-server pod (`oc -n openshift-gitops delete pod -l app.kubernetes.io/name=openshift-gitops-repo-server`). Clears the `DeadlineExceeded` on manifest generation.
5b. **Sweep for long-fuse external-egress retriers** at T+10-15 min. Pods polling external endpoints on schedules longer than the cascade window (cert-manager → LE ACME, anything calling Cloudflare, etc.) keep retrying with stale connections and don't recover. Symptom: ArgoCD app `Synced/Degraded` with `dial tcp ...: i/o timeout` in conditions. Known one: `oc -n cert-manager delete pod -l app.kubernetes.io/name=cert-manager,app.kubernetes.io/component=controller`. Critical for cmdline-only changes (early-symptom cascade is silent there).
6. Restore: scale `loki-operator` back to 1, trigger `loki-pdb-override` CronJob one-shot if needed. (A step that scaled `IngressController/default` to 1 replica was removed 2026-09-24: it only existed to leave RGW a router-free node, and RGW is retired.)

Skipping 4-5 re-trips the cascade; skipping 5b leaves cert-manager in a degraded loop until the next renewal attempt times out.

## Node drain — a single-instance CNPG cluster blocks it unconditionally (immich FIXED 2026-09-15 by going to 2 instances)

Found the hard way during the 4.20 → 4.21 upgrade (2026-09-08): node6's drain stalled ~20 minutes and would
never have completed on its own.

```
E0908 drain_controller: error when evicting pods/"immich-postgres-1" -n "immich"
  (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
```

CNPG creates a `minAvailable: 1` PDB over the **primary**. CLAUDE.md already noted these are "permanently 0 by
construction" and "do NOT block draining a node that holds a *replica*" — both true, and both miss the corollary:
**`immich-postgres` is `instances: 1`, so every node is the primary's node.** The budget can never be satisfied
and the eviction retries forever. `media-postgres` (3 instances) drained fine — CNPG just moved the primary.

**Unblock:** `oc -n immich delete pod immich-postgres-1` — CNPG recreates it on another node (the draining one is
cordoned). Two gotchas: the delete takes **>120 s** (graceful Postgres shutdown + RBD unmount), long enough that
the drain controller hits its 10-minute threshold and backs off to a **5-minute retry** — so the unblock is not
instant. And `oc` may fail `Unauthorized` at that exact moment, because the `authentication` operator updates
during the upgrade and an `oauth-openshift` replica can be Pending on the cordoned node: **this is what the
break-glass kubeconfig is for** (SA token, not OAuth).

**It recurred on 2026-09-14, and not on an upgrade.** An unplanned MCO reroll (next paragraph) selected node4 at
12:09Z; the drain sat on `immich-postgres-1` for 5+ hours, the MCD went Degraded after the first hour
(`failed to drain node: node4.okd.sudops.pl after 1 hour`), and five control-plane replicas plus mon-a and osd.0
were Pending the whole time. **Every master-pool MachineConfig change hits this, not just the 4.22 hop.**

**Resolved 2026-09-15: `immich-postgres` runs `instances: 2`** (`components/apps/immich/values.yaml`, commit
`e460c61`). With two or more instances CNPG performs a switchover ahead of the drain when the primary's node is
cordoned, and the old primary is then evicted as a replica — the documented 1.30 behaviour and what
`media-postgres` already did. The replica PDB (`<cluster>`, `minAvailable: instances-2`) is only created at
three or more instances (`pkg/specs/poddisruptionbudget.go`), so the lone replica is freely evictable and the
only PDB left is the structural `immich-postgres-primary`, which no longer blocks because the primary can move.
Cost: one more 10Gi RBD image and 512Mi/1Gi memory; the daily volume snapshot now comes from the standby
(`backup.target` default `prefer-standby`), which is a valid restore source. **The unblock recipe above stays
valid for any FUTURE single-instance CNPG cluster** — the rule is "never run a 1-instance CNPG cluster on the
master pool", not "delete the pod". Chronology: `blog/blog-cnpg-draft.md` 2026-09-15.

**What starts a reroll without a commit — never delete the `powersave-experimental` Tuned CR by hand (2026-09-14).**
NTO turns that CR's `[bootloader]` line into `50-nto-master`. Delete the CR and NTO deletes the MachineConfig within
a second; MCO renders a master config without `intel_pstate=passive processor.max_cstate=9` and selects a node
inside the next minute (`render_controller: now targeting rendered-master-d9509ea…` at 12:08:59Z, node4 cordoned
at 12:09:10Z). ArgoCD selfHeal recreates the Tuned, NTO recreates `50-nto-master`, and the pool target flips back
to the original rendered config — but **the node already selected keeps the transient `desiredConfig`**: the node
controller never reassigns a node it counts as unavailable, so that node reboots onto the argument-less config
and then a second time back onto the real one. To turn power tuning off, change `bootArgs` in
`components/cluster-config/power-tuning/values.yaml` and run the network pre-flight — one controlled reroll.
Side effect seen the same minute: the cordon made Rook re-reconcile CSI (12:09:21Z), which rewrote the RBD
`Driver` CR; `csi-driver-config` re-applied `hostNetwork` (12:09:27Z) and both RBD ctrlplugin pods restarted.
Chronology: `blog/blog-power-consumption-draft.md` 2026-09-14.
