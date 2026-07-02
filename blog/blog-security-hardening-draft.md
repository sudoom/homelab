# Security hardening — working draft

Running notes for security-focused changes on the cluster. One file per
discrete change, chronologically appended. Anything that touches the
threat-model floor (etcd encryption, OSD encryption, NetworkPolicies,
SCC tightening, key rotation) belongs here.

## 2026-05-18 — etcd encryption at rest (`aescbc`)

### What

Set `spec.encryption.type: aescbc` on the cluster `APIServer/cluster`
CR. OpenShift's kube-apiserver-operator handles everything else:
key generation, weekly auto-rotation, and re-encryption of existing
objects on the first enable.

### Why now

Cheapest meaningful security floor we can set today. Previously, every
Secret in the cluster sat in etcd as a base64-decoded plaintext — pull
the etcd database file off any node's disk and the entire credential
graph is yours (CNPG superuser, sealed-secrets master key, OAuth
tokens, Cloudflare API token, NORDVPN creds, etc.). With encryption
on, the etcd blob is AES-CBC-encrypted with a key that lives **only in
memory and on the master nodes** (the operator manages key material in
the openshift-config-managed namespace via per-resource Secrets).

Threat model coverage:
- ✅ **Compromised disk** (lost node, decommissioned drive, image
   snapshot from a hypervisor) — etcd contents unreadable.
- ✅ **Offline etcd backup** — encrypted at rest, useless without the
   in-memory key material.
- ❌ **Compromised live API server** — encryption is at rest, not in
   transit; anyone with API access gets plaintext like before. (Not a
   regression: this was always the case. RBAC + audit logs are the
   defense here.)
- ❌ **Compromised master node** — the operator's encryption-key
   Secrets live in the same etcd. Total node compromise = key
   exposure. (Out of homelab threat model.)

Not a silver bullet, but: ~5 minutes of API-server-operator churn for
zero ongoing operational cost is one of those rare unambiguous wins.

### What gets encrypted

Per the OpenShift docs (matches `kube-apiserver-operator` source):

- `secrets` (in every namespace, all kinds)
- `configmaps` (in every namespace — non-obvious, but ConfigMaps often
  carry sensitive data in homelabs)
- `oauthaccesstokens.oauth.openshift.io`
- `oauthauthorizetokens.oauth.openshift.io`
- `routes.route.openshift.io` (TLS cert data inlined in Route specs)

Not encrypted (intentionally; required for cluster bootstrap):
- ServiceAccount tokens
- CSRs
- Cluster events
- Plain API objects (Pods, Deployments, etc.) — they don't carry
  credentials.

### Algorithm choice — `aescbc` vs `aesgcm`

OpenShift supports both. Going with `aescbc` because:

- It's the OpenShift-recommended default (long-tested, FIPS-compatible).
- `aesgcm` provides authenticated encryption (ties an integrity tag
  to the ciphertext) — modestly better cryptographic properties — but
  is newer and less battle-tested in the OKD ecosystem.
- Performance is functionally identical for the workload (etcd reads
  happen at boot + on object updates; not in app hot paths).
- Switching algorithms later is supported — the operator handles
  the migration by re-encrypting everything under the new algorithm
  before retiring the old keys.

Will reassess if there's a stated reason to flip — e.g. FIPS-180-4
compliance preference, NIST guidance shift, or a CVE in the AES-CBC
implementation.

### Implementation

Single change to the existing `components/cluster-config/api-server/`
chart (which already owns the CR — was previously only setting
`servingCerts.namedCertificates` for the api.okd.sudops.pl TLS).

```yaml
# components/cluster-config/api-server/values.yaml
encryption:
  type: aescbc
```

Template renders the `spec.encryption.type` field conditionally; empty
string disables (leaves the spec block out, so existing encryption
state is preserved if you ever want to manually pause without
re-encryption side effects).

`helm template ... | oc diff -f -` shows the change is purely additive
— no field removals, no managedFields surprises (this CR has clean
SSA ownership from prior changes).

### Roll-out behavior

What happens after ArgoCD syncs the change:

1. kube-apiserver-operator notices `spec.encryption.type` changed.
2. Generates the first encryption-key Secret in
   `openshift-config-managed`.
3. Rolls a new kube-apiserver Deployment revision with the encryption
   provider configured.
4. Once the new pods are up, marks the cluster as `Encrypted=True` in
   the APIServer CR's status conditions.
5. Walks the encrypted-resource list (secrets, configmaps,
   oauthaccesstokens, etc.) and re-writes each object with the new
   cipher — this triggers an etcd write per object but takes
   ~minutes for a homelab-sized cluster.
6. Sets the `EncryptionInProgress` condition False and
   `Encrypted=True` finalized.

No app downtime. The API server stays available throughout — the
encryption-provider chain is configured so the new pods can decrypt
old (unencrypted) objects via the identity provider fallback, then
re-encrypt with the active key on next write.

### Post-sync verification

Wait ~5 min after ArgoCD reports the app `Synced+Healthy`, then:

```bash
# Top-level condition — should flip to True
oc get apiserver/cluster -o jsonpath='{.status.conditions[?(@.type=="Encrypted")]}{"\n"}'

# Per-resource progress (one entry per encrypted GVR)
oc get apiserver/cluster -o jsonpath='{.status.conditions[?(@.type=="EncryptionInProgress")]}{"\n"}'

# Verify a Secret is actually encrypted in etcd (debug node access required)
# — read the raw etcd value and confirm it's an AES-CBC blob, not plaintext base64
oc -n openshift-etcd debug node/node4.okd.sudops.pl -- chroot /host etcdctl get /kubernetes.io/secrets/default/<some-secret> 2>&1 | head -5
# Expected: binary blob starting with `k8s:enc:aescbc:v1:` prefix
# Pre-encryption: prefixed with the type, then plaintext-ish protobuf
```

### Key rotation

The operator auto-rotates the encryption key every **7 days** by
default. No manual intervention needed. To force an immediate rotation
(e.g., suspected key compromise):

```bash
oc patch apiserver/cluster --type=merge \
  -p '{"spec":{"encryption":{"type":"aescbc"}}}'
# (touching the field even with the same value triggers rotation)
```

After rotation, the operator re-encrypts under the new key on the next
write of each resource. There's also a passive re-encryption sweep
that walks all encrypted-resource GVRs to migrate everything
proactively — same logic as the first enable.

### Open follow-ups

- **Verify after initial roll-out** — capture the `Encrypted=True`
  condition timestamp + the actual etcd blob byte-level check (the
  `k8s:enc:aescbc:v1:` prefix is the irrefutable proof).
- **Trigger a manual key rotation drill** once verification passes —
  not for operational reasons but to validate the rotation flow works.
- **Consider `aesgcm` later** — newer, authenticated. Not urgent;
  algorithm migration is reversible.
- **Sealed-secrets master key rotation** — DONE (auto-rotation, not the
  quarterly-manual drill originally scoped here). See the dedicated
  `2026-06-27 — sealed-secrets key auto-rotation` section at the end of this
  file for the cert-expiry incident, the usage patterns, and the runbook.

### Proof: same etcd key, before vs after

Created a canary Secret in `default` before the rollout and read it
directly from etcd via `etcdctl` on a master node — both reads bypass
the API server, so they see the raw stored bytes:

```bash
oc create secret generic etcd-encryption-canary \
  --from-literal=plaintext-marker=DEMO_SECRET_VALUE_2026_05_18 \
  -n default

oc -n openshift-etcd exec etcd-node4.okd.sudops.pl -c etcdctl -- \
  etcdctl get /kubernetes.io/secrets/default/etcd-encryption-canary
```

**Before** (spec.encryption.type not yet set):
```
/kubernetes.io/secrets/default/etcd-encryption-canary
k8s
v1Secret
  etcd-encryption-canary default" *$977f7cb5-7436-43c5-...
  plaintext-markerDEMO_SECRET_VALUE_2026_05_18Opaque
```

The marker string `DEMO_SECRET_VALUE_2026_05_18` is plainly visible in
the binary protobuf — `grep` against the etcd snapshot would find it.

**After** (post-`EncryptionMigrationController` sweep):
```
/kubernetes.io/secrets/default/etcd-encryption-canary
k8s:enc:aescbc:v1:1:P�`�z/��Ȫ�E<* �#����B�� v���,r��2���V%p��SkP�c�...
```

The envelope is the irrefutable proof:
- `k8s:enc:aescbc:v1:1:` = AES-CBC v1, key index 1
- Key index `1` matches the `encryption-key-openshift-kube-apiserver-1`
  Secret in `openshift-config-managed` (gets rotated weekly by the
  operator; index increments on each rotation).
- The marker string is no longer grep-able — the ciphertext is
  AES-CBC-encrypted under the in-memory key.

### What gets encrypted — actual list

The Progressing message during rollout showed only
`[core/configmaps core/secrets]` being migrated by the
`EncryptionMigrationController`. That looked too narrow at first, but
post-rollout there are **three separate encryption configs** in
`openshift-config-managed`:

```
encryption-config-openshift-apiserver         # OpenShift-specific APIs
encryption-config-openshift-kube-apiserver    # core kube APIs
encryption-config-openshift-oauth-apiserver   # OAuth tokens
encryption-key-openshift-apiserver-1
encryption-key-openshift-kube-apiserver-1
encryption-key-openshift-oauth-apiserver-1
```

Each API server runs its own migration cycle against its own keys. So
the original docs claim holds:

- **kube-apiserver** encrypts: core `secrets`, core `configmaps`.
- **openshift-apiserver** encrypts: `routes.route.openshift.io` and a
  few other OpenShift-specific resources.
- **oauth-apiserver** encrypts: `oauthaccesstokens.oauth.openshift.io`,
  `oauthauthorizetokens.oauth.openshift.io`.

The `EncryptionMigrationControllerProgressing` message visible during
rollout was only the kube-apiserver's portion because that's the
component my watch was scoped to. The other two API servers run their
migrations independently and update their own clusteroperator messages.

### Rollout timing

For reference, on this 3-node cluster on PM9A1 NVMe:

- Spec change to first Progressing=True: ~30s (kube-apiserver-operator
  reconcile cycle).
- Each node revision install: ~2-3 min (new static pod manifest +
  kubelet roll + readiness wait).
- Three-node revision roll (23 → 24): ~9 min wall-clock.
- Re-encryption migration of all existing Secrets+ConfigMaps:
  ~tens-of-seconds (the workload is tiny — ~hundreds of objects total,
  not the thousands a production cluster would have).
- Total wall-clock from `git push` to ciphertext-confirmed:
  approximately 12 minutes (including ArgoCD poll lag).

No app-visible disruption observed throughout — API requests stayed
responsive (ArgoCD apps held `Synced+Healthy`, ScheduledBackup
continued archiving WAL).

### Cleanup

```bash
oc -n default delete secret etcd-encryption-canary
```

Trivial demo artifact; not worth keeping in etcd as historical noise.

## 2026-05-20 — OVN-Kubernetes IPsec (in-transit encryption for the overlay)

### What

Flipped `Network/cluster` `spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode` from `Disabled` → `Full`. Every packet between pods on different nodes now rides inside an IPsec ESP tunnel (IP protocol 50) between the host IPs. Pod-on-same-node traffic stays on the local OVS bridge in cleartext (no host crossing, no IPsec scope).

### Why now

In-transit counterpart to the 2026-05-18 etcd-at-rest enable. Closes the "what's on the wire" half of the cluster encryption story:

| | Before | After |
|---|---|---|
| etcd on disk | plaintext base64 | AES-CBC |
| pod ↔ pod over geneve | cleartext UDP/6081 | IPsec ESP |

Host-network workloads (Ceph daemons on the storage backnet, CSI hostNetwork plugins, RGW) bypass OVN-K entirely and stay unaffected. That's fine — the storage backnet is a dedicated VLAN with no other hosts on it.

### Doesn't replace service-mesh mTLS

These are different layers, not competing options:
- **OVN-K IPsec**: L3 host-to-host (kernel ESP), blanket coverage, no workload identity
- **Mesh mTLS (Istio/OSSM)**: L7 per-connection, workload identity (SPIFFE), fine-grained AuthorizationPolicy

IPsec gives cheap blanket cover today. Mesh stays a separate decision (still queued under "platform expansion") for when a workload genuinely needs per-request auth or traffic shifting. If/when mesh ships, mTLS would ride on top of IPsec.

### Implementation

Extended the existing `components/cluster-config/cluster-network-config/` chart (already managed the `Network/cluster` CR for `routingViaHost: true`). Single new conditional block:

```yaml
{{- if .Values.ipsec.mode }}
ipsecConfig:
  mode: {{ .Values.ipsec.mode }}
{{- end }}
```

`helm template ... | oc diff -f -` showed exactly one field change (Disabled → Full). Clean SSA, no surprises in the diff.

### Surprise: MCO reroll on IPsec mode change

**Process miss I should have flagged pre-apply.** I scoped IPsec as "non-storage" (it's a `Network/cluster` field, not a `MachineConfig`), but enabling IPsec needs IPsec kernel modules + NetworkManager service config delivered to each node — and that delivery rides MCO. So the apply triggered a rolling master-pool reboot.

Symptoms within seconds:
- `MCP master: UPDATED=False UPDATING=True`
- node4 → `Ready,SchedulingDisabled`
- node4's mon + OSD down → Ceph `HEALTH_WARN`, 1/3 mons down, 33% objects degraded

This is the same shape as any MCO change and Ceph held (size=3, min_size=2 quorum). But it's a degraded window I should have explicitly named in the pre-flight on a 3-OSD no-drain cluster.

For the future: any change to `Network/cluster` that adds new daemon-set-class functionality (IPsec, egress firewall, multus, etc.) is likely an MCO event. Diff the new ovnkube-master/node spec against the current rendered MachineConfig; if there are deltas, expect a serial reboot of the master pool (3 × ~10-15 min on this cluster).

### Proof: ESP-only, no cleartext geneve

Captured post-rollout on node4 via `oc debug node`:

```bash
# 15-second filter for cleartext geneve overlay (UDP/6081):
oc debug node/node4.okd.sudops.pl --quiet -- \
  timeout 15 tcpdump -ln -i any 'udp port 6081'
# → 0 packets captured (190 packets received by filter, all dropped)

# 5-second filter for IPsec ESP (IP proto 50):
oc debug node/node4.okd.sudops.pl --quiet -- \
  timeout 5 tcpdump -ln -i any 'ip proto 50' | grep -c "ESP(spi"
# → 1632 packets

# Sample line:
# 18:04:14.116131 br-ex Out IP 192.168.1.7 > 192.168.1.9: ESP(spi=0xd74fa6bd,seq=0x2b9b), length 1472
#                          node4               node6     IP-protocol 50 = ESP
```

`spi=0xd74fa6bd` (outbound node4→node6) and `spi=0x19f54f87` (inbound node6→node4) are the two unidirectional security parameter indexes that identify the SA pair between these two nodes. With 3 nodes there are 3 SA-pairs (n×(n-1)/2): node4↔node5, node4↔node6, node5↔node6.

### Etcd-style "before vs after" miss

For etcd-at-rest I created a canary Secret BEFORE enabling encryption, read it via `etcdctl` to see plaintext, enabled encryption, re-read to see `k8s:enc:aescbc:v1:1:` ciphertext envelope. Side-by-side proof of behavior change.

For IPsec I went straight to push without the pre-capture of cleartext geneve. The post-state proof above shows encryption is active (zero UDP/6081, abundant ESP), but it doesn't have the side-by-side. Next dual-state change (msgr2 secure mode is the natural one), do the pre-capture first.

### Reversibility

```yaml
ipsec:
  mode: Disabled
```

One field flip. OVN-K operator tears down SAs automatically, kernel removes the IPsec state, traffic returns to cleartext geneve UDP/6081. **But** the reversal also triggers an MCO reroll (same MachineConfig-class change in reverse), so undoing costs another ~30-45 min wall-clock. Not free.

### Open follow-ups

- **Verify per-node latency impact**: tcpdump-based throughput proof (e.g., a simple `iperf3` between two pods on different nodes) before vs after. Skipped today; would be useful for confirming the "10-15% CPU overhead" handwave on this hardware.
- **Re-encryption key rotation policy**: OVN-K's IPsec SAs use the IKE SAs to rotate. Default lifetime is operator-managed; check `oc get network.operator/cluster -o yaml` for the actual lifetime once rollout completes.
- **Pre-capture pattern for next encryption flip**: when we eventually enable Ceph msgr2 secure mode (cluster-storage TODO), capture cleartext OSD↔OSD traffic on the storage backnet BEFORE the flip, then compare to the encrypted-mode capture.


## 2026-05-20 (cont.) — IPsec rollback

The Full mode triggered a cascade of compounding failures:

### What broke

1. **MCO reroll on IPsec mode change** — the field flip looks small in the Network CR, but enabling IPsec installs kernel modules + NetworkManager IPsec service via MachineConfig. So the apply triggered a serial reboot of the master pool. **Should have flagged this pre-apply.**

2. **Loki ingester PDB MinAvailable=2 with 2 replicas** — earlier today we dropped Loki ingester replicas from 3→2 during the OSD_FULL emergency. With MinAvailable=2 / 2 replicas, ANY drain is blocked because the PDB can never tolerate an eviction. Hit MCO drain on the first node and stuck for 50 min until force-delete bypassed it. **This is a structural drain-headroom problem we created earlier and didn't notice.**

3. **Image pulls extremely slow across IPsec** — observed mon-b pulling its image in 14m59s and cephfs-nodeplugin in 19m07s on the node that was being rolled. Cause not fully diagnosed; suspect MTU or path-MTU issues with ESP overhead on a 1400 MTU geneve. Need to investigate before next attempt.

4. **RGW + router anti-affinity contention** — RGW has `requiredDuringSchedulingIgnoredDuringExecution` against router pods. With 2 routers spreading across 2 of 3 nodes, only 1 node is router-free. When that 1 node is the one being drained, RGW becomes unschedulable cluster-wide. Cascade: RGW Pending → Loki S3 puts return ConnectionRefused → ingesters never Ready → PDB stays blocked.

5. **Cross-node host-network breakage** — most surprising. `openshift-apiserver` on the post-IPsec-reboot node couldn't reach etcd on the other masters (`192.168.1.7:2379`, `192.168.1.9:2379`). These are HOST network IPs, not pod overlay. IPsec is supposed to only encrypt the geneve overlay, not host-network traffic. But empirically, host-network traffic between mismatched-MC nodes was unreliable. Root cause TBD.

### The rollback

```yaml
# components/cluster-config/cluster-network-config/values.yaml
ipsec:
  mode: Disabled
```

ArgoCD repo-server was timing out generating manifests (`DeadlineExceeded`) — likely under stress from the cluster chaos. Bypassed by `oc patch network.operator/cluster --type=merge` directly. Operator immediately tore down the IPsec daemonsets, kernel SAs cleared, traffic returned to cleartext geneve. **Cluster networking recovered within seconds of the spec patch.**

The MachineConfig-layer rollback is a separate, slower process — MCO will roll the kernel-modules/NM-service MC off each node over the coming hour(s). The cluster is functional during this; daemonsets are gone so runtime IPsec is off; the only residue is the now-idle IPsec service/modules on whichever nodes still have the with-IPsec MC.

### Cluster state at end-of-session 2026-05-20

- ✅ IPsec daemonsets removed (0 ovn-ipsec pods)
- ✅ Cross-node networking healthy (Loki ingesters running, apiservers reachable)
- ⚠️ MCP master `Degraded=True` (node5 left in MCD `state=Degraded` from the earlier stuck drain)
- ⚠️ node6 cycling (MCO rolling rollback MC onto it)
- ⚠️ `argocd-repo-server` returning `DeadlineExceeded` on manifest generation — likely a transient stress effect; should recover once cluster settles
- ⚠️ **Multiple manual interventions in place** that need cleanup tomorrow:
  - `loki-operator-controller-manager` Deployment scaled to 0
  - `logging-loki-ingester` PDB patched to `MinAvailable: 1` (will revert when operator comes back)
  - `default` IngressController replicas patched to 1 (revert to 2 once cluster stable)

### Pre-flight checklist before next IPsec attempt

Do NOT re-enable IPsec without:

1. **Restore Loki ingester drain headroom** — either bump replicas to 3 OR patch LokiStack operator to expose PDB tunables OR accept manual pod-delete during every drain. Filed as TODO.
2. **Install Kube Descheduler** — exactly the symptom the queue rationale called out: pod clustering after node reboots. Bumped to "next priority" in the TODO.
3. **Diagnose cross-node host-network breakage** — reproduce in a smaller test (one MC-changed node) and inspect IPsec policy + kernel SAs to understand why host traffic was affected. Without understanding this, IPsec will break the same way again.
4. **Diagnose slow cross-node image pulls** — possibly MTU. Try `ovnKubernetesConfig.mtu: 1380` (or lower) on the next attempt to leave room for ESP overhead inside a 1400 MTU underlay.
5. **Schedule attempt for a quiet window with 2h headroom** — not after-hours-into-evening. Storage chaos on top of network chaos compounds rapidly.
6. **Capture pre-state tcpdump** — etcd-style "before vs after" proof; was the explicit miss this attempt.


## 2026-05-21 — IPsec pre-flight baseline (captured before next attempt)

Raw data: `data/ipsec-baseline-2026-05-21/`.

### Environment

- IPsec mode: `Disabled` (confirmed via `oc get network.operator/cluster -o jsonpath='{.spec.defaultNetwork.ovnKubernetesConfig.ipsecConfig.mode}'`)
- OVN-K MTU: **1400**
- 3 nodes, kernel 6.12.0-142.el10, cri-o 1.33.4
- `ovn-ipsec-*` daemonsets: not deployed (clean baseline)

### Cleartext geneve sample — what we're encrypting

10s tcpdump on node4, UDP/6081 (geneve overlay): **200 packets captured** in <2s. Sample with full inner headers visible:

```
10:34:32.228734 enp0s31f6 In  IP 192.168.1.8.62614 > 192.168.1.7.geneve:
  Geneve, Flags [C], vni 0xff0003, options [8 bytes]:
  IP 10.129.0.10.pcsync-https > 10.130.0.2.55898: Flags [P.],
  seq 1882865881:1882866124, ack 3736560695, win 376, length 243
```

Inner pod IPs (`10.129.0.10 → 10.130.0.2`), inner TCP sequence numbers, window sizes, payload length — **all readable on the wire**. Anyone with a span port between any two nodes can reconstruct pod-to-pod traffic.

ESP-protocol filter in parallel: **0 packets in 5s** — confirms IPsec is not active.

### East-west throughput baseline

iperf3 4-stream 30s test, client on node6 → server on node5 (cross-node, rides OVN-K overlay):

```
[SUM]   0.00-30.00  sec  3.07 GBytes  879 Mbits/sec  944 retransmits  sender
[SUM]   0.00-30.01  sec  3.06 GBytes  877 Mbits/sec                  receiver
```

**~879 Mbits/sec** — capped by the 1G frontnet (interface utilization at line rate). Retransmits ~1% (944/3700 segments).

This is the number to compare post-IPsec. Expected: 10-15% drop due to ESP encryption overhead (per OpenShift docs handwave). On 1G we may not see CPU as the bottleneck since wire-rate caps below CPU saturation.

### Cross-node service latency (RGW = the path that broke yesterday)

Pod on node6 → RGW Service (`rook-ceph-rgw-ceph-objectstore.rook-ceph.svc:80`, RGW pod on node5). 10 sequential GET requests:

| Sample | connect | ttfb | total | http |
|---|---|---|---|---|
| 1 | 3.57 ms | 4.42 ms | 4.65 ms | 200 |
| 2 | 1.44 ms | 1.85 ms | 2.04 ms | 200 |
| 3 | 1.35 ms | 1.80 ms | 2.00 ms | 200 |
| 4 | 1.40 ms | 1.88 ms | 2.07 ms | 200 |
| 5 | 1.40 ms | 1.84 ms | 2.06 ms | 200 |
| 6 | 1.34 ms | 1.81 ms | 2.03 ms | 200 |
| 7 | 1.21 ms | 1.64 ms | 1.81 ms | 200 |
| 8 | 1.17 ms | 1.54 ms | 1.73 ms | 200 |
| 9 | 1.18 ms | 1.55 ms | 1.76 ms | 200 |
| 10 | 1.32 ms | 1.69 ms | 1.89 ms | 200 |

p50 connect ≈ 1.3 ms, p50 total ≈ 2.0 ms, 100% HTTP 200.

This is the exact path that timed out under IPsec yesterday (Loki ingester → RGW). The "after" number for this path is the single most important post-IPsec measurement.

### What's still missing for a complete pre-flight

The baseline above gives us **comparison data**. It does NOT address the structural pre-conditions for re-attempting IPsec:

1. Loki ingester drain headroom (PDB still `MinAvailable: 2` with 2 replicas → 0 disruption budget).
2. Kube Descheduler not installed.
3. Cross-node host-network breakage during mismatched-MC window — root cause undiagnosed.
4. MTU not lowered. Current geneve MTU is 1400. IPsec ESP adds ~58 bytes (header+IV+ICV+padding). Without dropping to ~1340, large packets will fragment or PMTU-discover, killing throughput. **The 14-19 min image pulls observed yesterday across IPsec likely trace to this.**

Plan: address (4) first (single config change, no MCO event), then (1) and (2) before any next IPsec apply.


## 2026-05-21 — OVN-K MTU pre-flight (1400 → 1340) — standalone

Raw data: `data/mtu-migration-2026-05-21/`.

Shipped MTU change ahead of next IPsec attempt to isolate one variable. If something breaks during this MCO event, we know it's NOT MTU-related when we later layer IPsec on top.

### Procedure (3-step, OpenShift OVN-K live migration)

```bash
# Step 1: declare migration intent (no MCO reroll on its own)
oc patch network.operator/cluster --type=merge -p '{"spec":{"migration":{"mtu":{
  "network":{"from":1400,"to":1340},
  "machine":{"from":1500,"to":1500}
}}}}'

# Step 2: actually change MTU (THIS triggers the MCO master-pool reroll)
oc patch network.operator/cluster --type=merge -p '{"spec":{"defaultNetwork":{
  "ovnKubernetesConfig":{"mtu":1340}
}}}'

# Step 3: clear migration field after MCP master Updated=True
oc patch network.operator/cluster --type=merge -p '{"spec":{"migration":null}}'
```

**Gotcha #1**: omitting the `machine` block (since we're not changing host MTU) made the operator immediately mark `Degraded=True` with `[invalid Migration.MTU, at least one of the required fields is missing]`. Schema requires both, even if `machine.from == machine.to`.

**Gotcha #2**: after the MCO rollout completed, `ovn-k8s-mp0` and existing pod veth pairs still showed MTU 1400 — the operator updated the CR but ovnkube-node pods hadn't restarted to pick up the new config. Manually rolling all three ovnkube-node pods (one at a time) brought them onto MTU 1340. Existing application pods still on 1400; will pick up 1340 on next restart.

**Gotcha #3**: post-rollout, node4 was left `Ready,SchedulingDisabled` by MCO (same bug as 2026-05-20). Manual `oc adm uncordon node4` to clear. Once node4 was schedulable again, the RGW pod (anti-affinity to routers; routers now occupied node5+node6) could move to node4 — without this, post-MTU RGW latency capture would have been against a Pending RGW pod.

### Rollout timeline

| Event | Wall clock | Notes |
|---|---|---|
| Step 1 (migration declared) | 13:24 | No MCO event |
| Step 2 (MTU change) | 13:25 | MCP master `Updating=True`, drain starts on node4 |
| node4 done | 13:30 (+5m) | Loki PDB MinAvailable=1 let drain proceed cleanly |
| node5 done | 13:39 (+14m) | mid-rollout ceph quorum blips while mon-c evicted, recovered automatically |
| node6 done | 13:48 (+23m) | Whole rollout 23 min — vs the 4+h cascade of 2026-05-20 IPsec attempt |
| ovnkube-node rolled | 13:54 | Required to land new MTU on `ovn-k8s-mp0` |
| Step 3 (clear migration) | 13:48 | Cosmetic |

### Pre/post comparison

| Measurement | Pre (MTU=1400) | Post (MTU=1340) | Delta |
|---|---|---|---|
| iperf3 cross-node 4×30s, sender | 879 Mbits/sec | 852 Mbits/sec | -3.1% |
| iperf3 cross-node 4×30s, receiver | 877 Mbits/sec | 851 Mbits/sec | -3.0% |
| iperf3 retransmits | 648 | 616 | -5% |
| RGW p50 connect | 1.21 ms | 1.06 ms | ~unchanged (noise) |
| RGW p50 total | 1.86 ms | 1.55 ms | ~unchanged (noise) |

Throughput dropped ~3% — expected since smaller MTU means more packets per byte and fixed per-packet overhead is amortized over less payload. Still well above usable for our workload (the actual demand is single-digit Mbits/sec average). Latency essentially unchanged.

### What this proved for the next IPsec attempt

1. **The pre-flight items work.** Loki PDB drain headroom (`loki-pdb-override` CronJob) made every node's drain cycle proceed without manual force-delete-pod intervention. Compared to 2026-05-20 where every drain hung for 50+ min on the PDB wall.
2. **Descheduler hasn't kicked yet** but didn't hurt either; first scheduled run was post-rollout, will see if it helps re-balance any clustered workloads.
3. **The RGW/router anti-affinity gotcha is still real** — even after the cluster came back clean, RGW landed Pending until node4 was manually uncordoned. Worth scripting or documenting in the runbook.
4. **No host-network cross-node breakage** like we saw with IPsec. So that issue specifically traces to the libreswan/IPsec layer, not to MachineConfig rollouts in general. Narrows the diagnosis space for item (3) of the IPsec pre-flight.

### Remaining IPsec pre-flight

- ~~(1) Loki ingester drain headroom~~ DONE
- ~~(2) Kube Descheduler installed~~ DONE
- (3) Cross-node host-network IPsec interaction — open, NOT MTU-related
- ~~(4) MTU pre-flight~~ DONE 2026-05-21

Down to one item — (3) is the qualitative work remaining (reproduce in test, understand what libreswan startup does to host networking).


## 2026-05-21 — MTU rollout lessons learned (in detail)

What looked like a clean 23-min MCO event turned into a 3-hour saga of 3 sequential MCO events and a familiar drain-interlock cascade. Worth documenting because the **biggest finding inverts the original assumption**: OVN-K MTU changes have **no MachineConfig artifacts** on this stack.

### What the operator actually rolled out

| MCO event | Trigger | Resulting MC | What was in it |
|---|---|---|---|
| #1 | `oc patch network.operator/cluster ...defaultNetwork.ovnKubernetesConfig.mtu: 1340` | `rendered-master-c20be5dbe1f44717b1b83bb1a24d25d4` (new) | Operator-rendered intermediate; ~23 min serial rollout, drains proceeded with the loki-pdb-override CronJob keeping the PDB at MinAvailable=1 |
| #2 | `oc patch network.operator/cluster ...migration:null` | `rendered-master-c20be5dbe1f...` -> same | Re-rendered; second-pass rollout fired even though MC content matched — generation/annotation diff was enough |
| #3 | None (operator-side reconcile) | Back to **`rendered-master-72361e71434ff638b25ff5b9762c11cb`** (the ORIGINAL pre-MTU MC) | The operator decided no MC delta was required for `mtu: 1340` and reconciled all 3 nodes back to the original baseline MC |

**End state:** every node on the same `rendered-master-72361e71...` they started on — the MC name that was already there BEFORE today's MTU work. The MTU change persists only in the live OVN-K runtime config (`spec.defaultNetwork.ovnKubernetesConfig.mtu: 1340`), enforced at the OVS/geneve interface level by ovnkube-node, not via any MachineConfig artifact.

### The drain-interlock cascade (same as 2026-05-20)

Once MCO event #2 fired, we re-tripped the familiar chain:

1. **Loki PDB**: loki-operator reconciled `MinAvailable: 2` back (the 5-min CronJob is too slow to outrun the operator). Worked around by scaling `loki-operator-controller-manager` to 0 for the duration.
2. **VolumeAttachment stuck**: ingester-0 + ingester-1 PVCs stayed bound to the old node after pod move → Multi-Attach errors → pod stuck `0/1 Running`. Force-cleared `metadata.finalizers` to break them loose; new VAs created for the new node.
3. **RGW + router scheduling deadlock**: routers default to 2 replicas with anti-affinity; RGW requires a router-free node. After node6 came back, routers spread to node5+node6, RGW had only node4 → MCO drain of node4 (later) would evict RGW with nowhere to go. Worked around by scaling `IngressController` to 1 router. **Ceph PRECONDITION**: RGW endpoint must be reachable for Loki ingesters to flush chunks; if it's not, ingester readiness probe returns 503, PDB stays at 0 disruptions, drain blocks. The cycle: drain → RGW evicted → Loki readiness fails → drain blocks. This is the same trap as 2026-05-20.
4. **Pod-network egress broken after rollout**: same symptom as 2026-05-20 — restarting all 3 `ovnkube-node` pods cleared stale gateway state.
5. **ArgoCD repo-server `DeadlineExceeded`**: same as 2026-05-20 — repo-server pod restart cleared it.

### Key takeaways for next IPsec attempt

1. **OVN-K MTU change is functionally a runtime config knob.** No MC artifacts. The MCO events fired by the migration declare/clear are operator bookkeeping overhead. **Don't conflate runtime changes with MachineConfig-class changes.**

2. **IPsec WILL be different.** IPsec install drops real files via MachineConfig (`ipsec.service`, `wait-for-ipsec-connect.service`, `ipsecenabler.service`, `/usr/local/bin/ipsec-connect-wait.sh`). That MCO event will produce a genuinely new rendered MC and require a full serial reboot — not just operator overhead.

3. **Loki PDB workaround is fragile.** The 5-min CronJob lets the operator win the race during high-frequency PDB writes. For MCO events, **scale `loki-operator-controller-manager` to 0 before applying the change** and back to 1 only after the rollout completes.

4. **RGW + router pre-flight before any MCO event**: scale `IngressController` to 1 BEFORE applying anything that triggers a master-pool drain. Restore to 2 after.

5. **ovnkube-node restart is mandatory post-MCO-event** (regardless of whether MCO actually changed any MachineConfig). Pod-to-host-network egress consistently breaks across MCO drains on this stack; ovnkube-node restart is the only known fix.

6. **OpenShift docs were misleading about the MTU procedure** (or my reading of them). The "3-step migration" reads like a single rollout. In practice each step's spec write produces an MC reconcile, and the final state turned out identical to the pre-migration MC. For a runtime-only knob, a direct `oc patch` of `ovnKubernetesConfig.mtu` would have worked just as well — without needing the migration field gymnastics. Verify this claim before saving time on the next attempt.

### Updated IPsec pre-flight checklist

| Item | Status |
|---|---|
| (1) Loki ingester drain headroom — `loki-pdb-override` CronJob | DONE |
| (2) Kube Descheduler installed | DONE |
| (3) Cross-node host-network IPsec interaction diagnosed | **OPEN** |
| (4) MTU pre-flight (1400 -> 1340) | DONE |
| **NEW (5)** Scale `loki-operator` to 0 before applying; scale back to 1 after | runbook step |
| **NEW (6)** Scale `IngressController` to 1 before; back to 2 after | runbook step |
| **NEW (7)** Restart all 3 `ovnkube-node` pods post-rollout | runbook step |
| **NEW (8)** Restart `openshift-gitops-repo-server` pod post-rollout | runbook step |

(3) remains the blocker. Best path: stand up a single-node test of just the libreswan service + `wait-for-ipsec-connect.sh` without OVN-K daemonset involvement; capture what `ip xfrm policy` looks like immediately after libreswan starts; verify host-network traffic to 2379/etc. isn't affected. Without understanding (3), the next IPsec attempt risks the same `openshift-apiserver` Degraded state as 2026-05-20.

## 2026-06-15 — node6 reboot re-tripped the OVN-egress cascade (38 false alerts)

Textbook recurrence of the documented "any full node power-cycle re-trips the
OVN-egress cascade per reboot" rule — captured here as a clean, fully-diagnosed
instance because it's the first time the per-source-node reachability test was
run end-to-end as the primary diagnostic.

**Trigger:** the operator rebooted node6 (~07:52). node4/node5 did *not* reboot
(their `ovnkube-node` pods kept 0 restarts since 2026-06-10; MCP `master` was
`Updated=True, 3/3 Done` — not a cluster-wide MC roll, just node6). The MCO
events on node6 (`Rebooted, boot id 6cf25185…` → `NodeNotReady` → `NodeReady` →
`Uncordon` for `rendered-master-056bb4f5…`) are the normal post-boot reconcile,
not a new config.

**Symptom:** 38 firing alerts (30 visible from prometheus-k8s-0's local API):
16× `TargetDown` + criticals `etcdMembersDown`×2, `etcdInsufficientMembers`,
`ClusterVersionOperatorDown`, `NoOvnClusterManagerLeader`, plus 3× `KubeJobFailed`
(collect-profiles, loki-pdb-override ×2 — cronjobs that failed in the reboot
window). The start-of-session health sweep was otherwise *clean* (3/3 nodes Ready,
all 42 ArgoCD apps Synced+Healthy, all CSVs Succeeded, all certs Ready) — the
cascade is invisible to those checks because it's scrape-inferred.

**Diagnosis (the right order):**
1. etcd is *actually* healthy — `etcdctl endpoint health --cluster` → all 3
   members committing (23–32 ms). So every etcd/CVO critical is false. (Always
   confirm this before touching etcd.)
2. `up==0` from prometheus-k8s-0: **31 targets down — 16 @ 192.168.1.7 (node4) +
   15 @ 192.168.1.8 (node5)**, but node6's own targets fine. prometheus-k8s-0
   runs on node6.
3. `up==0` from prometheus-k8s-1 (on node5): only 3 pod-network targets down,
   **zero host targets** → node4/node5 egress is fine; the breakage is
   node6-specific.
4. Explicit per-source-node reachability from prometheus-k8s-0 (node6):
   `wget http://192.168.1.9:9100/metrics` (own host) = **0.010 s**;
   `wget http://192.168.1.7:9100/metrics` (node4 host) = **black-holed** (>30 s,
   past the 8 s `-T`). Fast to own host + hang to remote host = that node's
   `ovnkube-node` has broken pod→remote-host egress.

So: node6 reboot → node6's `ovnkube-node` lost pod→remote-host egress →
prometheus-k8s-0 (resident on node6) can scrape node6 but black-holes node4/node5
host metrics → 31 false `TargetDown` → derived false etcd/CVO/OVN criticals.
repo-server is on node5 (healthy) so ArgoCD never went `sync=Unknown` this time —
which is why the sweep looked clean. cert-manager controller also on node5 → no
long-fuse egress-retrier to sweep.

**Fix (per the runbook):** restart all 3 `ovnkube-node` one at a time (operator
authorized; OAuth token was expired so via break-glass). Started with node6 (the
confirmed-broken one):

```bash
# per node, one at a time, wait Ready between:
oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node \
   --field-selector spec.nodeName=node6.okd.sudops.pl
oc -n openshift-ovn-kubernetes wait pod -l app=ovnkube-node \
   --field-selector spec.nodeName=node6.okd.sudops.pl --for=condition=Ready --timeout=150s
# re-test egress immediately after node6: wget .7:9100 from prometheus-k8s-0 → 0.011 s (was >30 s)
# then node5, then node4
```

**Result:** node6 egress restored the instant its `ovnkube-node` came back
(0.011 s to node4). After all 3: `up==0` → **0 targets**, firing alerts **30 → 10**
(remaining 10 = baseline: Watchdog, KubeCPUOvercommit, PodDisruptionBudgetAtLimit,
AlertmanagerReceiversNotConfigured, Insights/UpdateAvailable info, + the 3 spent
KubeJobFailed which self-clear next schedule).

**Why restart all 3 and not just node6:** the 2026-06-11 lesson — a node whose
`ovnkube-node` isn't restarted keeps *silent* broken pod→remote-host egress until
a pod lands on it. Here node4/node5 were proven-healthy (k8s-1 scraped everything),
so node6-only would have sufficed this time, but the runbook's all-3 is the safe
default. The whole episode (alert → root cause → cleared) took ~10 min once the
reachability test pointed at node6.

**Standing takeaway:** every node reboot on this cluster needs the
`ovnkube-node` restart as a deliberate post-reboot step. The false etcd-critical
shape is identical to the DDF-cAdvisor wedge (storage section) — `etcdctl endpoint
health --cluster` is the one query that tells them apart from a real etcd problem.

## 2026-06-27 — sealed-secrets key auto-rotation (cert-expiry incident + runbook)

Consolidated home for everything sealed-secrets. The one-liner in the 2026-05-18
follow-ups ("should be on a quarterly rotation") was overtaken by events: the
controller had been running with rotation *disabled*, the sealing cert silently
expired, and the fix was to turn auto-rotation on — not to script a manual
quarterly drill. Full chronology, the usage patterns, and the standing runbook
below.

### The incident — expired sealing cert blocked all new sealing

Surfaced 2026-06-27 while sealing the CNPG R2-backup credentials (the barman-cloud
plugin rollout, see `blog/blog-cnpg-draft.md`). Before I could seal anything,
`kubeseal` failed hard with **`expired certificate`** — it refused to use the
controller's sealing cert.

Root cause: the controller was running with **`--key-renew-period=0`** — i.e.
**auto-rotation disabled**. The single sealing key's cert was minted ~30 days
earlier and **expired 2026-05-28** with nothing queued to replace it. So every
*new* seal was blocked cluster-wide.

The nuance that made this invisible for a month: **expiry only breaks *sealing*,
not *decrypting*.** Every SealedSecret already committed kept decrypting fine — the
controller's private key still worked for unseal, and existing Secrets stayed
materialised. Nothing looked broken until I tried to seal a *new* value. That's
exactly the failure mode a health sweep misses: no pod crashed, no app degraded, no
alert fired — the door was just quietly locked against new keys.

### The fix — turn rotation on; the controller heals itself

Set the renew period to `720h` (30 days) in
`components/operators/sealed-secrets/values.yaml`:

```yaml
sealed-secrets:
  fullnameOverride: sealed-secrets-controller
  args:
    - --key-renew-period=720h
```

On the next reconcile the controller **minted a fresh sealing key with a 10-year
cert** and — critically — **retained the old key for decryption** of everything
already sealed. No re-seal fire-drill: old blobs keep unsealing under the retained
key, new blobs seal under the new key.

Then I committed the controller's **new public sealing cert** so offline sealing
keeps working without reaching the cluster:

```bash
kubeseal --controller-namespace sealed-secrets --fetch-cert \
  > components/operators/sealed-secrets/sealed-secrets-pub.pem
```

Current committed cert validity: **Jun 2036** (fetched 2026-06-27, post-fix).

### How sealed-secrets is used on this cluster

The controller (bitnami sealed-secrets, vendored chart `2.18.6` / controller
appVersion `0.37.0`, committed `charts/*.tgz` + `Chart.lock`) decrypts
`SealedSecret` CRs into plain `Secret`s in-cluster; the cluster-private key never
leaves the controller. It's **bootstrap-critical** — it decrypts the Cloudflare API
token cert-manager needs — which is why the chart is vendored (a fresh bootstrap
never depends on the remote Bitnami repo, which itself moved `bitnami-labs.github.io`
→ `bitnami.github.io` in 2026).

Two distinct patterns for landing credentials, chosen by where the secret comes
from:

- **Human-held secrets → committed `SealedSecret` + `kubeseal`.** For any credential
  a person holds (API tokens, OAuth client secrets, VPN creds), the value is sealed
  and committed. Standard flow:
  ```bash
  kubeseal --controller-namespace sealed-secrets --format yaml \
    < secret.yaml > components/<chart>/templates/sealed-<name>.yaml
  ```
  Current in-repo SealedSecrets:
  - `cluster-config/cert-manager-config/…/sealed-cloudflare-api-token.yaml` (DNS-01 token, bootstrap-critical)
  - `cluster-config/oauth-idp/…/sealed-github-oauth-client-secret.yaml`
  - `cluster-config/grafana-config/…/sealed-grafana-credentials.yaml`
  - `cluster-config/mikrotik-exporter/…/sealed-mktxp-config.yaml`
  - `cluster-config/synology-cert-sync/…/sealed-dsm-credentials.yaml`
  - `apps/keepers/…/sealed-vpn-creds.yaml`, `apps/media/…/sealed-vpn-creds.yaml`
  - `apps/cnpg-clusters/…/sealed-media-postgres-r2-creds.yaml`, `apps/immich/…/sealed-immich-postgres-r2-creds.yaml`

  Rotation of any of these = re-`kubeseal` the new value + commit; ArgoCD applies
  and the controller updates the Secret. Gotcha from the OAuth rollout: **pipe the
  pasted value through `cat | wc -c` before sealing** — a truncated / multi-line
  clipboard paste seals cleanly but ties the blob to the wrong bytes, and you lose
  ten minutes to "but I just sealed it."

- **Cluster-generated secrets (RGW/S3 creds) → OBC + pre-sync translator Job, *not*
  a SealedSecret.** Loki's `logging-stack` chart uses an `ObjectBucketClaim` + a
  `loki-secret-translator` Job that reads the OBC outputs and writes the
  LokiStack-shape Secret — idempotent, reproducible from `git clone && helm install`,
  no manual one-time seal per rebuild. This is the precedent to reuse for OADP / any
  future S3 consumer; don't ship `CephObjectStoreUser` + a hand-sealed SealedSecret
  for RGW creds.

### Key-rotation runbook

- **Auto-rotation is the mechanism.** `--key-renew-period=720h` → the controller
  mints a new sealing key + 10-year cert every 30 days and **retains old keys for
  decryption**. No manual quarterly drill, no re-seal fire-drill on rotation. This
  is the whole point of the fix: a key can never silently reach end-of-life again.
- **Refresh the committed pub cert after a rotation (forward-secrecy hygiene, not a
  hard requirement).** New seals should target the newest key; old blobs still
  decrypt under retained keys either way:
  ```bash
  kubeseal --controller-namespace sealed-secrets --fetch-cert \
    > components/operators/sealed-secrets/sealed-secrets-pub.pem
  git commit -m "sealed-secrets: refresh public sealing cert post-rotation"
  ```
- **Offline sealing uses the committed cert** (CI / no `oc login`):
  ```bash
  kubeseal --cert components/operators/sealed-secrets/sealed-secrets-pub.pem \
    --format yaml < secret.yaml > sealed.yaml
  ```
  The `.pem` is a **public** key — seal-only, never unseal — so it is safe to commit
  and share. It is the *only* sealed-secrets artifact that is safe to commit.
- **Per-controller pubkey caveat — blobs don't transplant.** A SealedSecret is
  encrypted to *this* controller's public key. A fresh cluster / a new controller has
  different key material, so committed blobs will NOT unseal there — every in-repo
  SealedSecret must be re-sealed against the new controller's cert on a rebuild.
  (This is also why the pub cert is pinned in-repo: it's specifically this
  controller's.)
- **Standing forward-secrecy chore (optional, low priority):** periodically re-seal
  the in-repo SealedSecrets against the newest key and let the controller prune the
  oldest retained keys. Not required for correctness (retained keys keep old blobs
  decrypting), purely limits how long a compromised old key stays useful. Deferred;
  auto-rotation already covers the operationally-important half.

### Standing guardrail

**Never set `--key-renew-period` to `0`.** `0` disables rotation, which is exactly
what expired the sealing cert on 2026-05-28 and blocked all new sealing cluster-wide
for a month before anyone noticed (because decryption kept working). Any sane period
is fine; `720h` is what's committed. Mirrored as a hard rule in `CLAUDE.md` and the
component `README.md`.

### Renovate note — PR #141 (sealed-secrets 2.18.6 → 2.19.0): HOLD

Open Renovate PR bumps the chart minor `2.18.6` → `2.19.0`, which is a controller
image bump `0.37.0` → `0.38.1` (not just a chart-source change), so it's a supervised
bump, not an auto-merge. The diff touches **only** `Chart.yaml` + `Chart.lock` — it
does **not** touch `values.yaml`, so the `--key-renew-period=720h` arg pass-through is
structurally preserved. Before merging, verify the `0.38.1` controller still honours
`--key-renew-period` with the same flag name/semantics and hasn't changed rotation
defaults (release notes + a `kubeseal --fetch-cert` smoke-seal against the upgraded
controller). Given the cert-expiry history, confirming rotation survives the bump is
the whole review.

