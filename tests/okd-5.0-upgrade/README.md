# OKD 4.22 → 5.0 upgrade: runbook and checks

Runbook for moving this cluster in place from `4.22.0-okd-scos.10` to a `5.0.0-okd-scos.N` build. The record of the
planning and of the hop itself is `blog/blog-okd-5.0-upgrade-draft.md`; the previous hop (4.21 → 4.22, 83 min) is
`blog/blog-okd-4.22-upgrade-draft.md` ("HOP 2").

| file | what | who runs it |
|---|---|---|
| `gates.sh` | go/no-go gates, `GATE PASS\|FAIL` lines | anyone, readonly |
| `watch.sh` | window watcher: events file + Monitor | the assistant, readonly |
| `verify.sh` | post-hop check (target running, nodes on the new machine-os, apps, CNPG, Ceph, etcd), `CHECK PASS\|FAIL` lines | anyone, readonly |
| `etcd-consistency.sh` | etcd revision/hash read across the three members | OPERATOR (`oc exec`) |
| `fixtures/` | small synthetic JSON for the FAIL-path tests below | tests only |

The readonly scripts use `~/.kube/config-readonly` (override with `RO_KUBECONFIG=…`), so they keep working when the
operator's OAuth token expires; from Claude Code they need the sandbox off, because the sandbox denies `~/.kube`.
They are bash 3.2 compatible (macOS `/bin/bash`). Run them with `bash`, not `sh`.

## Rules for the whole hop

- **OPERATOR** lines are run by the operator: everything with `oc adm`, `oc exec`, `oc debug`, `curl`, `ssh`, and
  every mutating `oc` verb (each prompts and each approval covers that one command). The assistant reads only.
- **Never `--force`.** The upgrade command, the etcd defrag switch, the ClusterVersion upstream/channel change and the
  catalog flip each need the operator's go for that exact command.
- **No manual `etcdctl defrag` on 5.0 while okd#2384 is open.** 5.0's etcd runs with the `NonBlockingDefrag` feature
  gate hard-coded on (cluster-etcd-operator `bindata/etcd/pod.gotpl.yaml:173`, no override), so every defrag on 5.0,
  manual or automatic, takes the non-blocking path that okd#2384 links to member divergence. The `etcd-disable-defrag`
  ConfigMap stops only the operator's automatic defrag. A manual defrag is a 4.22-only option (section 1.4).
- One disruptive change at a time (3 OSDs on 3 nodes, no drain headroom). Not Monday 19:00–23:00Z (descheduler operand
  roll, aescbc rewrite). Quiet IO. No in-cluster build. Plan about 2 h.
- No change to anything between the start command and `DONE`, other than the recovery steps below on the operator's go.

## 1. Before the window (go/no-go)

### 1.1 Target

The newest `5.0.0-okd-scos.N` that is at least 7 days old, has a green upgrade run from `4.22.0-okd-scos.10` for that
exact build, a signature in the store the 4.22 CVO reads, and no new open issue that breaks upgrades or 3-node clusters.

```bash
GH_TOKEN="$GITHUB_PERSONAL_ACCESS_TOKEN" gh api repos/okd-project/okd/releases/tags/5.0.0-okd-scos.<N> --jq .body   # 4.22.0-okd-scos.10 under Upgrades; "Pull From" digest
# OPERATOR: the upgrade runs for that build (read the edge from 4.22.0-okd-scos.10; check the field names with `jq keys` first)
curl -fsS https://amd64.origin.releases.ci.openshift.org/api/v1/releasestream/5-scos-stable/release/5.0.0-okd-scos.<N> | jq .
# OPERATOR: the signature (expect 200; anything else keeps the gate shut, okd#2369 is the precedent)
curl -fsSI https://storage.googleapis.com/openshift-ci-release/releases/signatures/openshift/release/sha256=<hex>/signature-1 | head -1
```

Also read the NetworkManager and openvswitch versions of the target machine-os against today's: the NMState 4.22
handler (a CentOS Stream 9 userland) talks to both over D-Bus and the OVS socket.

### 1.2 Disk and image state (OPERATOR)

- Root disks: `gates.sh` reads them (`node-rootfs`, from the kubelet stats summary). Prune only a node over 60%, and
  not within 24 h of the window unless it cannot wait:
  `oc debug node/<node>.okd.sudops.pl -- chroot /host crictl --timeout=600s rmi --prune`.
- The zot-only images of per-node pods must be cached on all three nodes, because `zot-0` moves when its node drains
  and these images exist nowhere else:

  ```bash
  for n in node4 node5 node6; do echo "--- $n"; oc debug -q node/$n.okd.sudops.pl -- chroot /host crictl images --digests | grep -E 'REPOSITORY|zot\.apps\.okd\.sudops\.pl/okd-test/'; done
  ```

  Required on every node, for the per-node pods: `okd-test/nmstate/handler` `sha256:2f8f3047…`,
  `okd-test/oadp/velero` `sha256:8e026079…`, `okd-test/cluster-logging/vector` `sha256:3a8b699a…`. A missing one is
  pulled now, while zot is up. Every other image of logging/Loki, NMState, OADP and the descheduler (operators,
  plugins, their test catalogs) is zot-only too and moves with its pod; cached everywhere is better.
- Time one payload pull by digest on one node (a `scos-content` digest from the target's release body). With zot up
  this proves the pull-through, not the 503 fallback HOP 2 saw:
  `oc debug -q node/node5.okd.sudops.pl -- chroot /host bash -c 'time crictl pull quay.io/okd/scos-content@sha256:<digest>'`.

### 1.3 Gates

```bash
bash tests/okd-5.0-upgrade/gates.sh            # before the defrag switch
bash tests/okd-5.0-upgrade/gates.sh --defrag-off --frag-file etcd-frag.tsv   # after section 1.4
```

Expected: `GATES PASS`. The gates: nodes Ready and schedulable; ClusterVersion Available, not Progressing, not
Failing; every ClusterOperator `True/False/False`; no `Upgradeable=False`; MCPs updated and not paused; every Argo CD
app Synced/Healthy; every Subscription `Manual`; no approved InstallPlan short of `Complete` and every CSV `Succeeded`
(an InstallPlan awaiting approval is printed as `GATE INFO`: normal on Manual, approve nothing during the window);
CNPG ×3 at 2/2 with `ContinuousArchiving=True`; CephCluster Ready with health details only `BLUESTORE_SLOW_OP_ALERT`
and the four muted `AUTH_INSECURE_*`; mgr metrics 3 OSDs up/in and all PGs active+clean; only the three CNPG primary
PDBs at 0 allowed; no active Job or running pod in `okd-build`; `zot-0` Running (its node printed) with ≥ 10 GiB free
on its PVC; every node root disk under 60%; no part of the next 150 min on Monday 19:00–23:00Z; `admin-gates` empty;
the newest completed CNPG Backup per cluster younger than 26 h; the newest OADP Backup `Completed` (age printed);
3 etcd pods Ready; `DefragControllerDisabled` printed, and with `--defrag-off` required `True` with the ConfigMap
present and every member under 45% fragmentation.

Not in the script (OPERATOR or operator-confirmed):

- `br-ex.forwarding` = 1 on all three nodes (the `network-change` skill's one-liner):

  ```bash
  for p in $(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.nodeName}{"\n"}{end}'); do echo "${p##*:} $(oc -n openshift-ovn-kubernetes exec ${p%%:*} -c ovnkube-controller -- sysctl -n net.ipv4.conf.br-ex.forwarding 2>/dev/null)"; done
  ```

- (Dropped 2026-11-10 by the operator: the hop no longer waited for the cert-manager renewal of `homelab-wildcard` on
  2026-11-20. `gates.sh` still prints its state as INFO; the check is part of the week after the hop.)
- The inputs of the accepted worst case (reinstall plus restore) exist off the cluster: the sealed-secrets key backup,
  the CNPG object-store credentials, the OADP/garage credentials, this repo.
- The Rook close-out is done (it is: c09622e, 2026-11-10).

### 1.4 etcd gate: automatic defrag off for the hop (okd#2384 open)

Facts (2026-11-10): okd#2384 is open with no maintainer statement and no fix in any 5.0 build; scos.6 runs the same
cluster-etcd-operator (`dc77052`) and etcd (`7cf5f0d`, 3.6.13) commits as the reporter's diverged scos.4. The switch is
ConfigMap `openshift-etcd-operator/etcd-disable-defrag`, checked for existence only, with the same name on 4.22 and
5.0, reported as condition `DefragControllerDisabled=True` on `etcd/cluster`. Nothing in the operator deletes it (the
rest of the 5.0 payload was not extracted to check; nothing there is expected to). The operator defragments a member at ≥ 45% fragmentation with a DB ≥ 100 MiB, one member per sync, syncs
about every 11 min. Today: DBs 195–198 MB, 40.9–41.9% fragmented, 0 defrags in the 15 days Prometheus keeps.

1. **Leave defrag on until right before the window.** 4.22 may defragment on its own when a member crosses 45%; on
   4.22 that is the blocking path, not the non-blocking one okd#2384 implicates, and it leaves 5.0 a lower starting
   point.
2. **Option for the go/no-go (operator's call; an etcd mutation, flagged):** a manual blocking defrag on 4.22, one
   member at a time, followers first, the leader last, so 5.0 starts near 0%. Only on 4.22, never on 5.0.

   ```bash
   # OPERATOR. Which member leads (IS LEADER column; the table avoids comparing uint64 IDs):
   oc -n openshift-etcd exec etcd-node4.okd.sudops.pl -c etcdctl -- etcdctl endpoint status --cluster -w table
   # OPERATOR, per member, followers first, leader last. Wait at least 1 minute between members (until its pod
   # recovers, a defragmented member does not respond), and see 3/3 healthy before the next one:
   oc -n openshift-etcd exec etcd-<node>.okd.sudops.pl -c etcdctl -- sh -c 'unset ETCDCTL_ENDPOINTS; etcdctl --command-timeout=30s --endpoints=https://localhost:2379 defrag'
   oc -n openshift-etcd exec etcd-node4.okd.sudops.pl -c etcdctl -- etcdctl endpoint health --cluster
   # afterwards, the alarms; clear a NOSPACE alarm if one is listed:
   oc -n openshift-etcd exec etcd-node4.okd.sudops.pl -c etcdctl -- etcdctl alarm list
   oc -n openshift-etcd exec etcd-node4.okd.sudops.pl -c etcdctl -- etcdctl alarm disarm   # only if NOSPACE was listed
   ```

   These follow openshift-docs `enterprise-5.0` `modules/etcd-defrag.adoc` (checked 2026-11-10).

3. **Fragmentation read (OPERATOR), within the hour before the switch.** Every member must be under 45%: a first
   sync of the defrag controller after an etcd-operator restart may run before its ConfigMap cache fills (unverified,
   read from the source), and then it finds nothing to defragment.

   ```bash
   oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- wget -qO- --post-data="query=$(jq -rn --arg q 'round(100 * (1 - etcd_mvcc_db_total_size_in_use_in_bytes{job="etcd"} / etcd_mvcc_db_total_size_in_bytes{job="etcd"}), 0.01)' '$q|@uri')" 'http://localhost:9090/api/v1/query' | jq -r '.data.result[] | [(.metric.pod // .metric.instance), .value[1]] | @tsv' > etcd-frag.tsv
   ```

4. **On the operator's go, the switch** (prompted): `oc -n openshift-etcd-operator create configmap etcd-disable-defrag`.
   Then read until `True` (at the next sync):
   `oc get etcd cluster -o jsonpath='{.status.conditions[?(@.type=="DefragControllerDisabled")].status}{"\n"}'`.
5. `gates.sh --defrag-off --frag-file etcd-frag.tsv` → `GATES PASS`. From here every script runs with `--defrag-off`.

Re-enable (only once a build with the okd#2384 fix runs here, section 6):
`oc -n openshift-etcd-operator delete configmap etcd-disable-defrag`; the condition reads `False` at the next sync.

### 1.5 Update service and channel (start path (a), decided 2026-11-10, blog "how the hop starts")

The cluster is offered nothing on `stable-scos-4`. Cincinnati `stable-5.0` offers scos.2–.5 from our build (scos.1
only as a conditional update, `SigningKeyVerificationFailure`), and it is also the final update service, so this is
one ClusterVersion change. It changes only what is offered. OPERATOR, on the operator's go:

```bash
oc patch clusterversion version --type merge -p '{"spec":{"upstream":"https://updates.okd.io/api/updates/graph","channel":"stable-5.0"}}'
# revert
oc patch clusterversion version --type merge -p '{"spec":{"upstream":"https://amd64.origin.releases.ci.openshift.org/graph","channel":"stable-scos-4"}}'
```

Read: `oc get clusterversion version -o jsonpath='{.spec.channel}{"\n"}{range .status.availableUpdates[*]}{.version} {.image}{"\n"}{end}'`.
Expected: the target listed. Compare its digest with the release body's `Pull From`; a mismatch is reported, not
guessed around. Target absent: wait for its upgrade job, or fall back to the old graph on `stable-scos-5`, then to an
explicit image by digest (`oc adm upgrade --to-image=quay.io/okd/scos-release@sha256:… --allow-explicit-upgrade`).

### 1.6 Go/no-go

Present to the operator: target and digest, the start command, every gate's evidence, and what is not known. Wait for
an explicit go.

## 2. The window

1. **OPERATOR, consistency and snapshot.** `bash tests/okd-5.0-upgrade/etcd-consistency.sh pre` → `CONSISTENT`.
   Then the snapshot (openshift-docs `enterprise-5.0` `modules/backup-etcd.adoc`) and two copies off the node:

   ```bash
   oc debug -q --as-root node/node4.okd.sudops.pl -- chroot /host /usr/local/bin/cluster-backup.sh /home/core/assets/backup
   TS=<the timestamp in its "Snapshot saved at /home/core/assets/backup/snapshot_<TS>.db" line>
   ssh core@192.168.1.7 "sudo tar -C /home/core/assets/backup -cf - snapshot_$TS.db" > <place A>/snapshot_$TS.tar
   ssh core@192.168.1.7 "sudo tar -C /home/core/assets/backup -cf - static_kuberesources_$TS.tar.gz" > <place B>/static_kuberesources_$TS.tar
   ```

   The cluster encrypts etcd (`aescbc`), and `static_kuberesources_<TS>.tar.gz` holds the encryption keys for the
   snapshot, so the docs store it apart from the snapshot; a restore needs both. Place A and place B are two different
   places, both off the cluster, chosen by the operator; neither is this repo or a synced folder. The directory on the
   node also holds older backups (HOP 2's), hence the explicit timestamp; `sudo tar` reads the root-owned files without
   changing their owner on the node.

2. **Watcher, then the start.** The assistant starts the watcher (background, sandbox off) and a Monitor, and writes
   `window-start.txt` with the UTC time:

   ```bash
   EV=.superpowers/sdd/2026-11-10-okd-5.0-upgrade/evidence/window-$(date -u +%Y%m%dT%H%M%SZ).events
   bash tests/okd-5.0-upgrade/watch.sh --defrag-off "$EV" 5.0.0-okd-scos.<N> 14400
   tail -n +1 -F "$EV" | grep -E --line-buffered '^[^ ]+ (START|ALERT|CLEARED|ETCD-ON-TARGET|settled|DONE|TIMEOUT|STOPPED)'
   ```

   Drop `--defrag-off` (here and in step 5) if the switch of section 1.4 was not set: kept without the switch, the
   watcher raises `ALERT defrag-switch` at once.
   The grep is anchored after the timestamp: a bare `ALERT` also matches `BLUESTORE_SLOW_OP_ALERT` in the `ceph:` line.
   If the watcher has to be restarted mid-hop, pass `--prehop "$EV.prehop.json"`, or `DONE` can never be reached.
   A failed read (the API blanks on each drain) changes no alert and restarts no clock; it shows as one
   `read-errors: <reads>` line and a `read-errors: none` line when reads work again.

   OPERATOR: `oc adm upgrade --to=5.0.0-okd-scos.<N>`.
   Expected within 5 min: `cv: desired=<target> … Progressing=True`, and no `ReleaseAccepted=False`.

   **Abort** (the CVO rejects the release: signature or precondition, `ALERT release-accepted`): stop. OPERATOR
   `oc adm upgrade --clear`, then confirm
   `oc get clusterversion version -o jsonpath='{.spec.desiredUpdate}{"\n"}{.status.desired.version}{"\n"}'`: no
   desired update for the target, and `4.22.0-okd-scos.10`. Do not retry with other flags. Report.

   **Point of no return:** once the first control-plane operator reports the target, the etcd snapshot no longer
   restores a working cluster. From there recovery is forward (fix the stuck component), or reinstall plus restore.
3. **Hands off until `DONE`.** Stop and ask on any `ALERT` line (section 3). At `ETCD-ON-TARGET` (the etcd operator
   reports the target, before the first node reboot): OPERATOR `bash tests/okd-5.0-upgrade/etcd-consistency.sh mid` →
   `CONSISTENT`.
4. **After each node returns:** Ready on the new kubelet (`node-<n>:` line), its etcd pod Ready (`etcd-pods: 3/3`),
   and OPERATOR `br-ex.forwarding` = 1 on that node (one-liner in 1.3). A reboot zeroes it on that node only;
   `ovnkube-node` re-asserts it on start, so it should read 1. A node NotReady for over 15 min after its reboot: the
   okd#2361 block (section 5.1).
5. **At `DONE`:**

   ```bash
   bash tests/okd-5.0-upgrade/verify.sh 5.0.0-okd-scos.<N> --defrag-off --since <window start, UTC ISO>   # RESULT PASS
   bash tests/okd-5.0-upgrade/etcd-consistency.sh post                                                    # OPERATOR, CONSISTENT
   ```

   `verify.sh` also checks `history[0].verified == true` (the start was not forced), `DefragControllerDisabled=True` on
   the 5.0 operator and no defrag event since the window start (events age out; the watcher's `defrag-events:` line is
   the record for the whole window).
6. Blog section with the watcher's timeline (`blog/blog-okd-5.0-upgrade-draft.md`).

## 3. Stop conditions (watcher `ALERT` lines)

| `ALERT` key | condition | first move (each on the operator's go) |
|---|---|---|
| `release-accepted` | `ReleaseAccepted=False` | Abort (section 2, step 2) |
| `cv-failing` | ClusterVersion `Failing=True` for over 10 min | read the Failing message and the named operator; `UpdatePayloadResourceConflict` with "object has been modified" is the okd#2384 shape (5.2) |
| `node-notready-<n>` | a node NotReady for over 15 min | okd#2361 check and recovery (5.1) |
| `stuck-drain-<n>` | a node cordoned over 20 min without a reboot | PDBs (`oc get pdb -A`), CNPG, stale VolumeAttachments: `network-change` skill |
| `mcp-degraded` | an MCP Degraded or a degraded machine | `oc describe mcp master`, the MCD log of that node |
| `etcd-co-degraded` | etcd ClusterOperator Degraded | its conditions; `etcd-consistency.sh` |
| `etcd-pods` | fewer than 3 etcd pods Ready for over 60 s with no node cordoned | the etcd pod's log: "found data inconsistency with peers" is okd#2384 (5.2) |
| `osds-down` | two OSDs down | `rook-ceph` skill; no other change |
| `cnpg-zero` | a CNPG cluster at 0 ready | its pods and PVCs; the drain that took it |
| `defrag-switch` (`--defrag-off`) | `DefragControllerDisabled` not `True` | re-create the ConfigMap; `etcd-consistency.sh` |
| `defrag-event` (`--defrag-off`) | any `DefragControllerDefragment*` / `DefragControllerLeaderTransfer*` event | `etcd-consistency.sh` now, then daily |

`TIMEOUT` (default 4 h) is a stop-and-ask too. `CLEARED <key>` marks the end of a condition.

## 4. What normal looks like (HOP 2, 2026-10-27, 83 min)

- CV desired the target within a minute; COs move to the target over about 50 min, with transient Progressing and
  short Degraded states that clear by themselves. Then the MCP rolls the nodes one at a time (HOP 2 order node4,
  node5, node6), about 8.5 min from cordon to Ready per node.
- Rook gates the nodes: with one OSD down it holds the next node's OSD PDB at 0 until the PGs are clean, so only one OSD
  is ever down (`OSD_DOWN`, `PG_DEGRADED`, 129 PGs undersized but active). Ceph returns to
  `BLUESTORE_SLOW_OP_ALERT` only at the end. mgr and mons fail over each time.
- CNPG clusters drop to 1/2 on each drain and return to 2/2 within minutes; the primaries switch over ahead of a
  drain.
- `zot-0` moves when its node drains (it is on node4 today, the first node HOP 2 drained) and moved twice in HOP 2.
  While it is down: pods needing an `okd-test/` image on a node without it cached sit in `ImagePullBackOff` (Loki
  gateway, NMState and GitOps operators, Argo CD server/applicationset/dex in HOP 2); pulls of mirrored images take
  about 1m40s (zot 503, then the source).
- Stale RBD VolumeAttachments clear by themselves after about 5 min (`Multi-Attach error` on the replacement pod in
  between). Wait 6 min before offering the finalizer patch.
- Right after completion: OLM `ResolutionFailed` on most Subscriptions while the marketplace catalog pods restart, and
  the OLM apps read Degraded in Argo CD; it cleared in about 2 min with no action.
- `br-ex.forwarding` read 1 on all nodes after the reboots.

New with 5.0: CRI-O 1.36.4 on each node after its reboot (the okd#2361 exposure starts there); the router moves to
HAProxy 3.2; the default catalogs move to the `v5.0` tag, so `community-operators` restarts and grafana-operator may
show an InstallPlan awaiting approval (leave it); MCO adds NetworkPolicies of its own.

## 5. Recovery

### 5.1 okd#2361: a node stuck NotReady after a reboot (CRI-O and Multus deadlock)

Open, no fix in any build (cri-o#10436 unmerged). OPERATOR on the node by SSH or console, one node at a time. Two
stuck control-plane nodes at once lose etcd quorum.

Check first that it is this bug:

```bash
sudo journalctl -u crio -n 200 --no-pager | grep -E 'Watchdog timeout|SIGABRT|multus-shim|unclean shutdown'
sudo ls -la /etc/kubernetes/cni/net.d/        # 00-multus.conf is there
```

Non-destructive (from the thread):

```bash
sudo mv /etc/kubernetes/cni/net.d/00-multus.conf /root/00-multus.conf.bak
sudo systemctl restart crio
# do NOT restart kubelet right away (it can cancel an in-flight sandbox creation; CRI-O then holds the retried
# RunPodSandbox for up to 8 minutes). If no static pods appear after ~2 min, restart crio once more.
sudo crictl pods                       # etcd / kube-apiserver / kcm / scheduler become Ready
systemctl show crio -p NRestarts       # stays at 0
ls -la /etc/kubernetes/cni/net.d/      # wait until multus rewrote 00-multus.conf (fresh timestamp); do NOT copy the backup back
sudo rm /root/00-multus.conf.bak
```

Thread result: the node Ready in about 5 min, etcd 3/3. From the workstation:
`KUBECONFIG=~/.kube/config-readonly oc get nodes; oc get co etcd kube-apiserver; oc -n openshift-etcd get pods -l app=etcd`.

Destructive fallback, only if that fails and never on a second control-plane node while one is down (wipes all
container storage on the node; pods re-pull through zot):

```bash
sudo systemctl stop kubelet crio
# corrected from the thread: procps-ng pkill takes one pattern, so "pkill -9 multus-shim crio conmon" kills nothing
sudo pkill -9 -x multus-shim; sudo pkill -9 -x crio; sudo pkill -9 -x conmon
# corrected from the thread: the glob must expand as root, not in core's shell
sudo sh -c 'rm -rf /var/lib/cni/* /run/cni/*'
sudo rm -rf /var/lib/containers/storage /run/containers/storage /var/lib/crio
sudo mkdir -p /var/lib/containers/storage /run/containers/storage /var/lib/crio && sudo touch /var/lib/crio/clean.shutdown
sudo systemctl start crio kubelet
```

Wiping only container storage is fatal: the CNI state goes with it.

### 5.2 okd#2384: etcd members diverged

Signatures: `etcd-consistency.sh` prints `DIVERGED` (equal `compact_revision`, different `hash`); an etcd pod refuses
to start with `checkInitialHashKV failed … found data inconsistency with peers`; a revision gap between members that
keeps growing while `raftAppliedIndex` stays in lockstep; ClusterVersion `Failing` with `UpdatePayloadResourceConflict`,
"the object has been modified" on leases, operators losing leader election.

1. Stop every other change. Make sure automatic defrag is off (ConfigMap present, `DefragControllerDisabled=True`).
2. Find the minority: `etcd-consistency.sh` prints the hash groups. Two members agree: the third is the suspect and
   the two are the source of truth. No two agree: stop; that is the accepted worst case (reinstall plus restore). A
   pre-hop etcd snapshot does not restore onto 5.0.
3. Replace only the minority member, keeping quorum, by the docs procedure "Replacing an unhealthy etcd member whose
   etcd pod is crashlooping" (openshift-docs `enterprise-5.0` `modules/restore-replace-crashlooping-etcd-member.adoc`,
   checked 2026-11-10; the same module on `enterprise-4.22`). It is also the okd#2384 reporter's route. Every line is
   OPERATOR and an etcd mutation, in this order:

   ```bash
   # a. Stop the member on its node. Deliberate deviation from the docs: the data dir goes to /var/lib/etcd-diverged
   #    instead of /tmp, so a copy of the diverged data stays on disk for the okd#2384 report.
   oc debug -q node/<node>.okd.sudops.pl -- chroot /host bash -c 'mkdir -p /var/lib/etcd-backup && mv /etc/kubernetes/manifests/etcd-pod.yaml /var/lib/etcd-backup/ && mv /var/lib/etcd /var/lib/etcd-diverged'
   # b. Remove it, from a pod on another node (a member of the majority). The table shows the hex IDs and names.
   oc -n openshift-etcd exec etcd-<majority-node>.okd.sudops.pl -c etcdctl -- etcdctl member list -w table
   oc -n openshift-etcd exec etcd-<majority-node>.okd.sudops.pl -c etcdctl -- etcdctl member remove <hex member ID>
   oc -n openshift-etcd exec etcd-<majority-node>.okd.sudops.pl -c etcdctl -- etcdctl member list -w table   # 2 members left
   # c. Turn off the quorum guard. Unconditional in the docs: "This command ensures that you can successfully re-create
   #    secrets and roll out the static pods" (the reporter hit "CheckSafeToScaleCluster found 2 healthy member(s) out
   #    of the 3" without it). unsupportedConfigOverrides was null on 2026-11-10.
   oc patch etcd/cluster --type=merge -p '{"spec": {"unsupportedConfigOverrides": {"useUnsupportedUnsafeNonHANonProductionUnstableEtcd": true}}}'
   # d. Delete the removed member's peer, serving and metrics Secrets by name (no value is read; the operator issues new ones).
   oc -n openshift-etcd get secrets -o name | grep '<node>'                    # names only: the three below
   oc -n openshift-etcd delete secret etcd-peer-<node>.okd.sudops.pl
   oc -n openshift-etcd delete secret etcd-serving-<node>.okd.sudops.pl
   oc -n openshift-etcd delete secret etcd-serving-metrics-<node>.okd.sudops.pl
   # e. Force a redeployment. The reason must be unique; the docs' `date --rfc-3339=ns` is GNU-only, hence UTC seconds.
   oc patch etcd cluster --type=merge -p "{\"spec\":{\"forceRedeploymentReason\":\"single-master-recovery-$(date -u +%Y%m%dT%H%M%SZ)\"}}"
   # f. Quorum guard back on, then check that the override is gone (empty output).
   oc patch etcd/cluster --type=merge -p '{"spec": {"unsupportedConfigOverrides": null}}'
   oc get etcd/cluster -o jsonpath='{.spec.unsupportedConfigOverrides}{"\n"}'
   # g. All members healthy once the new revision is out.
   oc -n openshift-etcd exec etcd-<majority-node>.okd.sudops.pl -c etcdctl -- etcdctl endpoint health --cluster
   ```

4. `etcd-consistency.sh recovered` → `CONSISTENT`, and each etcd pod's log on its next start shows
   `initial corruption checking passed`. Then daily reads again.
5. Draft a comment on okd#2384 for the operator (load the `upstream-pr` skill first).

## 6. After the hop

- Health sweep and alert triage (`cluster-health` skill). `SamplesImagestreamImportFailing` (okd#2366) is expected only
  if the target lacks the fix (merged 2026-10-27, build unconfirmed): `oc get co openshift-samples`.
- OPERATOR `etcd-consistency.sh d1` … `d7` daily for a week, and once right after the first automatic defrag whenever
  defrag is back on. `DIVERGED` at any point: stop everything else, section 5.2.
- Update service: Cincinnati `stable-5.0` is already set (1.5). Expected `RetrievedUpdates=True`, newer 5.0 builds
  listed when they exist:
  `oc get clusterversion version -o jsonpath='{.spec.upstream} {.spec.channel} RetrievedUpdates={.status.conditions[?(@.type=="RetrievedUpdates")].status}{"\n"}{range .status.availableUpdates[*]}{.version}{"\n"}{end}'`.
  Read ConfigMap `openshift-config-managed/release-verification` again on 5.0: the scos.1 risk names a
  `verifier-public-key-redhat` keyring, so later 5.0.z builds may verify against another key or store.
- Catalogs: `community-operators` on the `v5.0` index and READY, grafana-operator's Subscription resolves. Then
  `okderators` to `catalog-index:5.0` (`bootstrap/phase0/01_catalog_source.yaml`, commit, OPERATOR `oc apply -f`):
  catalog READY, no new InstallPlan beyond ones explained beforehand. GitOps stays `AtLatestKnown` on its installed
  CSV (OLM keeps an installed CSV the catalog no longer lists); a re-subscribe onto the catalog's build is optional
  (`bootstrap/phase0/readme.md`).
- `olm-v1-catalogs` still Synced/Healthy: if the `openshift-redhat-marketplace` ClusterCatalog is gone, remove it from
  `components/cluster-config/olm-v1-catalogs/values.yaml` (`unavailable`) and sync.
- 5.0 behaviour: routes behind `*.apps.okd.sudops.pl` answer as before on HAProxy 3.2; the console loads its plugins.
- Defrag stays off until a build with the okd#2384 fix runs here. The re-enable test: delete the ConfigMap, read
  `DefragControllerDisabled=False` at the next sync (about 11 min), wait for the first `DefragControllerDefragment*`
  event pair (a defrag starts only at ≥ 45% fragmentation), run `etcd-consistency.sh` right after it, then daily for a
  week.

## 7. Testing the checks

The readonly scripts take `--fixture-dir DIR`: a read named `<name>` comes from `DIR/<name>.json` when that file
exists, through the same jq as a live read; every other read stays live (readonly). `watch.sh` also takes
`DIR/<name>.<poll>.json` (that poll only) and `DIR/<name>.<poll>.err` (that read fails in that poll), so a sequence of
polls can be replayed. `watch.sh --once` runs one poll and prints the DONE verdict. The fixtures are small and
synthetic.

```bash
cd tests/okd-5.0-upgrade
bash gates.sh --fixture-dir fixtures/gates-co-degraded       # GATE FAIL clusteroperators … machine-config(…Degraded=True)
bash gates.sh --fixture-dir fixtures/gates-sub-automatic     # GATE FAIL subscriptions-manual … grafana-operator=Automatic
for c in node-old-config no-new-config all-new-config; do
  bash watch.sh --once --fixture-dir fixtures/$c --prehop fixtures/$c/prehop.json "$TMPDIR/$c.events" 5.0.0-okd-scos.6
  bash verify.sh 5.0.0-okd-scos.6 --fixture-dir fixtures/$c | grep -E 'nodes-|RESULT'
done
# node-old-config: CV Completed, pool claims Updated, node6 still on the 4.22 rendered config -> NOT-MET, verify FAIL
# no-new-config:   CV Completed, no node ever got a new rendered config                       -> NOT-MET, verify FAIL
# all-new-config:  control                                                                     -> MET, verify PASS
for c in osstream-config osstream-overridden; do bash verify.sh 5.0.0-okd-scos.6 --fixture-dir fixtures/$c | grep -E 'machine-os|RESULT'; done
# osstream-config:     5.0 shape, image from the pool's OSImageStream (not the ConfigMap)  -> PASS "from OSImageStream/stream-b"
# osstream-overridden: rendered config carries os-image-url-overridden                     -> FAIL
for c in consistent diverged compaction; do bash etcd-consistency.sh fx-$c --fixture-dir fixtures/etcd-$c --out-dir "$TMPDIR"; done
# CONSISTENT (0) / DIVERGED (1, names the minority member) / compaction mid-read retried once, then CONSISTENT (0)
```
