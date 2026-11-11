# OKD 4.22 → 5.0: planning and running the hop

`4.22.0-okd-scos.10` (2026-09-09) is the last OKD 4.x build, so this cluster gets no more fixes until it moves to 5.0.
No 5.0 feature is wanted and no date is set: the hop goes when its gates hold. This draft follows the planning, the
checks before the window, the hop itself and the follow-ups. The previous hop (4.21 → 4.22, 2026-10-27, 83 min) is in
`blog/blog-okd-4.22-upgrade-draft.md`.

## 2026-11-10 — where 5.0 stands, and the decisions that shape the plan

OKD 5.0 is GA and on its seventh build: `5.0.0-okd-scos.6` came out 2026-11-09. It runs Kube 1.36.5 on SCOS 10, which
is already the node OS here, so there is no OS major in this hop. The repo's `4.N → 1.(N+13)` mapping ends at 4.22.
Every 5.0 build from scos.3 on lists `4.22.0-okd-scos.10` as an upgrade source, so no intermediate hop is needed.

OLM v0 is neither removed nor deprecated in 5.0, and no Kube API is removed between 1.35 and 1.36. The cluster calls
no API flagged for removal (`apirequestcounts` with `removedInRelease`: none). It has no admin gates and no
`Upgradeable=False`. The okderators `catalog-index:5.0` exists now: branch `release-5.0` was rebuilt from the 4.22
catalog on 2026-10-15 and carries cert-manager 1.20 and GitOps 1.22.

What argues for care:

- [okd#2384](https://github.com/okd-project/okd/issues/2384): etcd members silently diverge after the automatic
  defrag on a 3-master 5.0 cluster. It is open, has no maintainer reply, and this cluster has the same shape.
- [okd#2361](https://github.com/okd-project/okd/issues/2361): CRI-O and Multus deadlock after an unclean shutdown
  on bare metal. It is open with no fix.
- The 4.22 → 5.0 edge has one green CI run, on AWS. A bare-metal run was requested in okd#2375 and has no reply.
- Four operators here have no 5.0 build or catalog entry: logging and Loki, NMState, OADP and the descheduler (our
  zot test builds). cert-manager 1.20 is outside its Kube matrix on 1.36.

Operator decisions (2026-11-10):

- The hop may start from an explicit image by digest if the graph offers nothing. It never uses `--force`.
- A reinstall plus restore from the app backups is the accepted worst case. No restore rehearsal is a gate.
- If okd#2384 is still open when every other gate holds, the hop runs with automatic etcd defrag switched off.
- One green AWS upgrade run for the target build is enough evidence.
- The nodes are on a UPS and can be reached by console or SSH, so okd#2361 gets a ready recovery command in the
  runbook rather than a go/no-go gate.

The design (four phases: settle the unknowns, prepare, the window, after the hop) and the plan were reviewed on
Fable 5.2 before approval; the plan review's findings were all applied. The main ones were reading the etcd
operator's `DefragControllerDisabled` condition instead of a log line that is invisible at the default log level, a
DONE condition for the window that needs every node on the new rendered MachineConfig, and gates for backup
freshness and for the off-cluster inputs a reinstall would need.

## 2026-11-10 — how the hop starts (plan Task 1)

The cluster is offered nothing today: `spec.channel: stable-scos-4` on the release-controller graph,
`availableUpdates: []`. The release-controller's graph handler (`openshift/release-controller`,
`cmd/release-controller-api/http_upgrade_graph.go`) keeps, for channel `stable-scos-N`, only edges whose target
starts with `N.` and whose upgrade test passed, so `stable-scos-4` can never offer 5.0.

The operator read every graph (curl is denied to me), printing the versions reachable from our build:

```bash
for c in stable-scos-4 stable-scos-5; do echo "old $c: $(curl -fsS "https://amd64.origin.releases.ci.openshift.org/graph?arch=amd64&channel=$c" | jq -c '. as $g | ($g.nodes|map(.version)|index("4.22.0-okd-scos.10")) as $i | if $i==null then "NODE-ABSENT" else [$g.edges[]|select(.[0]==$i)|$g.nodes[.[1]].version] end')"; done
for c in stable-5.0 candidate-5.0; do echo "cincinnati $c: $(curl -fsS -H 'Accept: application/json' "https://updates.okd.io/api/updates/graph?arch=amd64&channel=$c" | jq -c '. as $g | ($g.nodes|map(.version)|index("4.22.0-okd-scos.10")) as $i | if $i==null then "NODE-ABSENT" else {edges:[$g.edges[]|select(.[0]==$i)|$g.nodes[.[1]].version], conditional:[($g.conditionalEdges//[])[].edges[]|select(.from=="4.22.0-okd-scos.10")|.to]} end')"; done
```

```
old stable-scos-4: []
old stable-scos-5: ["5.0.0-okd-scos.1","5.0.0-okd-scos.2","5.0.0-okd-scos.5","5.0.0-okd-scos.3","5.0.0-okd-scos.0","5.0.0-okd-scos.4"]
cincinnati stable-5.0: {"edges":["5.0.0-okd-scos.3","5.0.0-okd-scos.5","5.0.0-okd-scos.2","5.0.0-okd-scos.4"],"conditional":["5.0.0-okd-scos.1"]}
cincinnati candidate-5.0: "NODE-ABSENT"
```

scos.6 is in neither graph yet: its upgrade test from our build had not passed 12 hours after release.

**The payloads agree.** The Cincinnati graph (`updates.okd.io`, channel `stable-5.0`) gives scos.5 as
`quay.io/okd/scos-release@sha256:29ed3ecc…92ed9`, which is exactly the `Pull From` in the release body
(`gh api repos/okd-project/okd/releases/tags/5.0.0-okd-scos.5 --jq .body`). The old graph has the same digest under
`registry.ci.openshift.org/origin/release-5-scos`. Cincinnati's node for our version carries
`sha256:65f272bc…0165af`, the digest the cluster runs now (`status.desired.image`, from
`registry.ci.openshift.org/origin/release-scos`, `history[0].verified=true`).

**The conditional edge is a signature problem.** Cincinnati holds scos.1 back with risk
`SigningKeyVerificationFailure` ([okd#2369](https://github.com/okd-project/okd/issues/2369)): "Release payload fails
signature verification against the verifier-public-key-redhat keyring." A 4.22 cluster verifies differently:
ConfigMap `openshift-config-managed/release-verification` holds `verifier-public-key-ci` and
`store-openshift-ci-release=https://storage.googleapis.com/openshift-ci-release/releases/signatures/openshift/release`.
So the question was whether the 5.0 payloads are signed in that store. The operator checked scos.5 and scos.6:

```bash
for d in 29ed3ecc9819a5ee1c4c94f4b168d8e45d27fd3e32512d96c41860f5ada92ed9 ea7e0f4296e3f6e5eee0319ec64a36978059d239babec748a1da558e6187746f; do echo "$d: $(curl -s -o /dev/null -w '%{http_code}' https://storage.googleapis.com/openshift-ci-release/releases/signatures/openshift/release/sha256=$d/signature-1)"; done
```

```
29ed3ecc…92ed9: 200
ea7e0f42…187746f: 200
```

Both have a signature in the store our CVO reads. That the key matches is inferred, not proven: the same store holds
the signature our running 4.22 payload verified against. The CVO's own verification at the start of the window is
the real test, and `ReleaseAccepted=False` there is a stop with `oc adm upgrade --clear` as the way back.

**Decision: path (a), a channel and upstream change, to Cincinnati `stable-5.0`.** The cluster then lists the 5.0
builds as available updates itself, with no explicit image and no `--force`. Cincinnati rather than the old graph's
`stable-scos-5`, because:

- It is where the cluster has to end up anyway. From 5.1 Cincinnati is the default, and a cluster not on it gets an
  informational alert. So this is one ClusterVersion change instead of two.
- It holds back builds with known risks as conditional updates (scos.1 here), where the old graph offers scos.0 and
  scos.1 without conditions.

Fallback: the old graph on `stable-scos-5`, then an explicit image by digest. The change only alters what is offered;
it happens at go/no-go (plan Task 9) on the operator's go:

```bash
# OPERATOR, at go/no-go
oc patch clusterversion version --type merge -p '{"spec":{"upstream":"https://updates.okd.io/api/updates/graph","channel":"stable-5.0"}}'
# revert
oc patch clusterversion version --type merge -p '{"spec":{"upstream":"https://amd64.origin.releases.ci.openshift.org/graph","channel":"stable-scos-4"}}'
# start, once the target is listed in status.availableUpdates
oc adm upgrade --to=5.0.0-okd-scos.<N>
```

To check after the hop: the scos.1 risk names a `verifier-public-key-redhat` keyring, which is not what 4.22 uses. The
5.0 CVO may verify later 5.0.z builds against another key or store. Plan Task 11 reads the `release-verification`
ConfigMap again on 5.0.

## 2026-11-10 — what the checks before the hop found (plan Phase A)

Three read-only research passes (notes kept locally) and four operator reads. Only the facts that shape the window are
here.

### etcd and okd#2384

- **No fix exists in any 5.0 build.** okd#2384 has no comment and no label; it was assigned on 2026-11-05. scos.6
  runs the same cluster-etcd-operator commit (`dc77052`) and the same etcd commit (`openshift/etcd 7cf5f0d`, etcd
  3.6.13) as the scos.4 cluster that diverged. The commits come from the image labels (`SOURCE_GIT_COMMIT`), because
  the release bodies list only digests.
- **What changed between 4.22 and 5.0:** cluster-etcd-operator#1618 (merged 2026-08-12) turned on etcd's
  `NonBlockingDefrag` feature gate. It is hard-coded in `bindata/etcd/pod.gotpl.yaml:173` with no override, and it
  rides on a downstream carry in `openshift/etcd` ("implement not-as-blocking defrag"). On 4.22 the gate is absent,
  so 4.22's defrags block. The only change that would turn it off is cluster-etcd-operator#1724 (a revert on
  `release-5.0`), which is open and argued on performance, not on divergence. The reporter calls the link to defrag
  a correlation, not proven.
- **The switch works on both versions.** ConfigMap `openshift-etcd-operator/etcd-disable-defrag` is checked only for
  existence, with the same name on 4.22 (`defragcontroller.go:97-105` at `14ecb16`) and on 5.0 (`:108-116` at
  `dc77052`). The operator reports it as condition `DefragControllerDisabled=True` on `etcd/cluster`; today it reads
  `False`. Nothing in the operator or the payload deletes that ConfigMap, and deleting it re-enables defrag at the next
  sync (about every 11 minutes).
- **Two consequences for the runbook:**
  - The ConfigMap stops only the automatic defrag. On 5.0 every defrag, a manual `etcdctl defrag` included, takes the
    non-blocking path. So no manual defrag after the hop while okd#2384 is open.
  - The defrag controller waits for the operator-CR cache but not the ConfigMap cache, so its first sync after an
    operator restart could miss the ConfigMap. This is unverified. The cheap guard: every member under 45%
    fragmentation going into the hop, so a missed sync has nothing to defrag.
- **On 5.0 a defrag is visible as events** in `openshift-etcd-operator`: `DefragControllerDefragmentAttempt`, then
  `…Success` or `…Failed`; before a leader is defragmented, `DefragControllerLeaderTransferSuccess`. The watcher alerts
  on any of these while the switch is set.

So today the etcd gate opens only by the operator's fallback: the hop runs with automatic defrag off.

### Deprecated APIs

`apirequestcounts` is not populated on this cluster: "No resources found" for both the readonly SA and the operator.
So the earlier "no removed API in use" was an empty read. The apiserver metric is the real evidence (operator,
through `prometheus-k8s-0`):

```bash
oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- wget -qO- 'http://localhost:9090/api/v1/query?query=group%20by%20(group,version,resource,removed_release)%20(apiserver_requested_deprecated_apis)' | jq -r '.data.result[] | .metric | "\(.group)/\(.version) \(.resource) removed=\(.removed_release)"'
```

```
null/v1 endpoints removed=null
apps.openshift.io/v1 deploymentconfigs removed=6.0
```

Nothing removed in Kube 1.36 or OKD 5.0 is called. No DeploymentConfig exists, so something lists the type,
probably the console or Argo CD.

### Operators

- **None needs its 5.0 build before the hop.** Logging and Loki 6.6, NMState 4.22, OADP 1.6 and the descheduler 5.4
  (our zot test builds) all ride the hop.
  - OADP is the least certain: Velero and its operator use client-go 0.33, and Red Hat lists OADP 1.6 for OCP 4.22
    only.
  - The NMState handler talks to the host's NetworkManager over D-Bus and to its Open vSwitch. Their versions in the
    5.0 OS image are read at go/no-go.
- **GitOps stays put when `okderators` moves to `catalog-index:5.0`.** OLM's resolver (`operator-framework-olm`
  `release-5.0`) takes the installed CSV from its cache of installed CSVs, not from the catalog. A channel with no
  candidate is not an error, so the Subscription stays `AtLatestKnown`, as it did on 2026-11-09. A re-subscribe onto
  the catalog's own build is optional.
- **Images only in zot that every node needs:** the NMState handler, the OADP node-agent (velero) and the logging
  collector (vector). Each must be cached on all three nodes before the window, checked with `crictl images
  --digests` per node.
- **Kube 1.36 support elsewhere:** cephcsi v3.18.1 lists 1.34–1.36, and sealed-secrets 0.37 builds on client-go 0.36
  with CI on 1.36.0. cert-manager 1.21 supports 1.33–1.36, so a 1.21 bundle would bring cert-manager back into its
  matrix (a follow-up, not a gate). Whether grafana-operator is in `community-operator-index:v5.0` is still unknown.

### CRI-O, okd#2361 and the rest

- okd#2361 (CRI-O and Multus deadlock after an unclean shutdown) is open, and its CRI-O fix (cri-o#10436) is unmerged.
  scos.5 and scos.6 both ship CRI-O 1.36.4, the version the thread reports, so the exposure starts with the hop. The
  runbook carries the thread's recovery for a stuck node: move `00-multus.conf` aside first, the destructive wipe
  last. Two stuck control-plane nodes at once would lose etcd quorum.
- Kernels: scos.5 `6.12.0-275`, scos.6 `6.12.0-280` (today `6.12.0-254`).
- 5.0 changes to check after the hop: the router's HAProxy 2.8 → 3.2, the default catalogs moving to the `v5.0` tag,
  new MCO NetworkPolicies, and one extra etcd leader election per defrag. `components/cluster-config/olm-v1-catalogs/`
  needs no change: the payload dropped the `openshift-redhat-marketplace` ClusterCatalog at 4.22 already, and the
  live object survived that hop.
- okd#2366 (sample ImageStreams) has a fix merged 2026-10-27; which build carries it is unknown.
- The release-controller page reads scos.6's upgrade test from our build as failed or pending and scos.5's as passed.
  That is page text, not a parse, and is read directly at go/no-go. scos.6 is also not in either graph yet.

## 2026-11-10 — the cert-manager gate is dropped

The design had the hop wait for the first ACME renewal on cert-manager 1.20 (`homelab-wildcard`, 2026-11-20), so that
a renewal failure could not be mixed up with a 5.0 effect. The operator dropped that gate ("aim asap"). The renewal
now happens on 5.0, with cert-manager 1.20 outside its Kube matrix (1.32–1.35; the cluster will be on 1.36). If it
fails, the parked Helm fallback (branch `cert-manager-helm-fallback`) is the way out; the check moved to the post-hop
week. The earliest window is now set by the target's age: `5.0.0-okd-scos.5` was created 2026-11-05T10:55:47Z, so it
is 7 days old on 2026-11-12 from about 11:00Z. Before that: the window checks (`tests/okd-5.0-upgrade/`), a one-off
OADP backup of the app namespaces within 24 h, and the operator reads that need `oc exec` or `oc debug`.

## 2026-11-10 — the hop: 4.22.0-okd-scos.10 → 5.0.0-okd-scos.5 in 82 minutes

The operator chose to go the same day ("lets do now") and on scos.5, dropping the 7-day age rule. scos.6 was not
offered from our build: it was in neither graph, and the release controller had no upgrade run of it from
4.22.0-okd-scos.10. An OKD maintainer said on Slack that scos.6 and 5.1 ec.3 carry the latest base OS with an
"eMudhra" fix. What that problem is, I could not find on GitHub. So the plan is scos.5 today and scos.5 → scos.6 as a
5.0 update later.

### Before the window

| check | result |
|---|---|
| scos.5 edge (operator, release-controller API) | `{"From":"4.22.0-okd-scos.10","To":"5.0.0-okd-scos.5","Success":1,"Failure":0}`, AWS job `release-openshift-origin-installer-launch-aws-modern/2118387301678583808` |
| `gates.sh` (11:33Z, then `--defrag-off` 11:49Z) | `GATES PASS` |
| `br-ex.forwarding` (operator) | 1 on all three nodes |
| zot-only images of per-node pods (operator, `crictl images --digests`) | NMState handler, OADP node-agent, vector cached on all three |
| timed pull of scos.5's `stream-coreos` on node5, zot up | 1m50s: digest-only pulls go through zot to quay |
| OADP Backup `pre-okd5-upgrade` (`tests/okd-5.0-upgrade/backup.yaml`) | `Completed` 11:40:15Z, 588/588 items, 18 DataUploads, no errors |
| off-cluster inputs of the worst case | confirmed by the operator |

**etcd.** okd#2384 is still open, so the hop ran with automatic defrag off. Fragmentation was 36–38%, close to the
operator's 45% trigger, so the operator first defragmented on 4.22 by hand, using the blocking method, followers
first:

```bash
oc -n openshift-etcd exec etcd-<node>.okd.sudops.pl -c etcdctl -- sh -c 'unset ETCDCTL_ENDPOINTS; etcdctl --command-timeout=30s --endpoints=https://localhost:2379 defrag'
```

node5 took 2.09 s, node6 1.95 s, and node4 (the leader) 2.00 s. All three endpoints were healthy after each, and
there were no alarms. Afterwards the DBs were 115/115/125 MB with 0/0/8% not in use, the leader had not changed
(raft term 74), and the raft index was equal on all three. Then the switch:

```bash
oc -n openshift-etcd-operator create configmap etcd-disable-defrag
# DefragControllerDisabled=True AsExpected since 2026-11-10T11:48:51Z
```

**Start path.** The operator ran the patch to Cincinnati `stable-5.0`. The cluster then listed scos.2–scos.5, with
scos.5 at `quay.io/okd/scos-release@sha256:29ed3ecc…`, the same digest as the release page. scos.1 was listed as a
conditional update, `Recommended=False/SigningKeyVerificationFailure`.

The etcd consistency read before the hop, `bash tests/okd-5.0-upgrade/etcd-consistency.sh pre`, gave `CONSISTENT 3
members, hash 1551639787 at rev 178259624`. The snapshot was `cluster-backup.sh` on node4,
`snapshot_2026-11-10_120101.db` (120 MB, revision 178263222). The snapshot and `static_kuberesources` were copied
to two places off the cluster. The first copy landed in the repo root by mistake, untracked and not gitignored, and
was moved out before any commit.

### The window

`oc adm upgrade --to=5.0.0-okd-scos.5` (operator) at 12:08:55Z. Timeline from `watch.sh` (readonly, 20 s polls):

| time (Z) | event |
|---|---|
| 12:09:38 | desired 5.0.0-okd-scos.5, `ReleaseAccepted=True`, `history[0].verified=true` (the 4.22 CVO verified the 5.0 payload against `verifier-public-key-ci`); `Failing=True` for 20 s: the first try at CRD `rolebindingrestrictions.authorization.openshift.io` (22 of 1057), synced on retry |
| 12:13–12:19 | etcd revision 13 rolls one member at a time (2/3 Ready for about a minute each) |
| 12:18:18 | `ETCD-ON-TARGET`: past the point of no return; the read during the hop gave `CONSISTENT 3 members, hash 1927464603 at rev 178274371` |
| 12:24–12:53 | kube-apiserver, kube-controller-manager, kube-scheduler, then OLM and network (OVN-K) roll; never Degraded |
| 12:55:39 | 33/34 operators on 5.0; machine-config next |
| 13:01:00–13:01:42 | **ALERT mcp-degraded**, cleared by itself (below) |
| 13:01:21 | node4 cordoned; the mgr moves; zot-0 node4 → node5 (13:01:42–13:03:21); descheduler and ceph-csi-controller-manager in `ImagePullBackOff` until zot is back (13:03:41) |
| 13:02:20–13:13:03 | **ALERT defrag-switch**, cleared by itself (below) |
| 13:07:02 → 13:09:05 | node4 reboots, up on kubelet v1.36.5, Done on `rendered-master-a1f2c154`; cordon to Done 7.7 min |
| 13:09:26 → 13:19:44 | node6, the same; its OSD waited for Ceph to be clean (13:13:22 → 13:13:42) |
| 13:19:44 → 13:30:26 | node5, the same; zot-0 node5 → node6 (13:20:26–13:24:07, the RBD attach took about 3 min); cluster-logging and loki operators in `ImagePullBackOff` until about 13:25 |
| 13:30:47 | 34/34 operators on 5.0, master pool 3/3 |
| 13:31:24 | ClusterVersion `history[0]` Completed |
| 13:33:28 | watcher `DONE`, after a 2 min hold |

Only one OSD was ever down. Rook's PDBs held each node's OSD until the PGs were clean again, so a drain waited for
recovery (about 1–2 min each). The CNPG primaries switched over ahead of each drain. Throughout, Ceph showed only its
standing warnings, and the CNPG clusters stayed archiving.

**The two alerts.**

- `mcp-degraded` (40 s). The new machine-config-controller started at 12:59:05Z and refused to render the master pool:
  `ignoring MC 99-master-generated-kubelet generated by older version 90b26966… (my version: 0e255703…)`. That MC is
  generated from our KubeletConfig `system-reserved-increase`. Its controller had hit a transient `the object has
  been modified` conflict, and then regenerated the MC with the new version annotation. The render followed at
  13:01:25Z. It was a race between two controllers at start-up, and needed no action.
- `defrag-switch` (11 min). The etcd operator pod moved to node5 at 13:01:32Z when node4 drained. Its first sync
  reported `DefragControllerDisabled=False` at 13:02:00Z, while ConfigMap `etcd-disable-defrag` still existed (created
  11:46:57Z). This is exactly the race the source reading predicted: the defrag controller waits for the operator-CR
  cache but not the ConfigMap cache. The next sync, about 11 minutes later, set it back to `True` (13:13:00Z). No
  `DefragControllerDefragment*` event appeared. The manual defrag before the window had put every member far below
  the 45% trigger, so the gap had nothing to defragment. That guard paid off.

### After the hop

- `verify.sh 5.0.0-okd-scos.5 --defrag-off --since 2026-11-10T12:08:55Z`: the first run at 13:33Z failed only on Ceph
  (`Progressing`, "Configuring Ceph Mgr(s)": Rook restarted both mgrs at 13:33:16Z and 13:33:45Z). The next failed
  only on `rook-ceph-cluster` OutOfSync on `ServiceMonitor/rook-ceph/rook-ceph-mgr`, the known double writer (README
  TODO), which selfHeal put back. At 13:38:31Z: `RESULT PASS`.
- `etcd-consistency.sh post`: `CONSISTENT 3 members, hash 3928912595 at rev 178354290`. `br-ex.forwarding`: 1 on all
  three nodes.
- Nodes: CentOS Stream CoreOS 10.0.20261014-0, kernel 6.12.0-275.el10, kubelet v1.36.5, cri-o 1.36.4.
- OLM: all 9 Subscriptions `AtLatestKnown`, every CSV `Succeeded`. `community-operators` moved to
  `community-operator-index:v5.0` and is READY, and grafana-operator still resolves. `okderators` stays on
  `catalog-index:4.22` until its own step.
- The 5.0 CVO still verifies with `verifier-public-key-ci` against the `openshift-ci-release` store, so scos.6 (signed
  in that store, checked earlier today) can verify the same way.
- The alerts after the hop (operator read through Alertmanager):
  - 13× `CephNodeDiskspaceWarning`, starting at each node's reboot. They are false: root disks are 56.5% / 28.5% /
    34.3% used (174 / 286 / 262 GB free). The hop's image pulls stepped usage up, and the rule's 48 h
    `predict_linear` extrapolates that step.
  - `ClusterNotUpgradeable` (info). Three of our test builds cap `maxOpenShiftVersion` at 4.23, which OLM treats as
    equal to 5.0: loki-operator and cluster-logging 6.6.0-2026-10-20-134619, and the descheduler 5.4.0-2026-11-03.
    This blocks 5.1, not 5.0.z. The research had said logging and Loki carried no cap; they do.
  - The rest are the standing set: CNPG PDBs ×3, KubeCPUOvercommit, InsightsRecommendationActive, Watchdog.

Compared with HOP 2 (4.21 → 4.22, 83 min), this hop took about as long, despite each new image pull going through zot to
quay. Automatic etcd defrag stays off until a build with the okd#2384 fix runs here (re-enable: delete the
ConfigMap). The daily etcd consistency reads run for a week.

## 2026-11-10 — summary and design record

This section keeps the design and its reasons, so that the spec, the recon notes and the plan can be deleted.

**Result.** The cluster runs `5.0.0-okd-scos.5` (Kube 1.36.5) since 2026-11-10 13:31:24Z, 82 minutes after the start
command, from `4.22.0-okd-scos.10`. 34/34 ClusterOperators, three nodes on CentOS Stream CoreOS 10.0.20261014-0 (kernel
6.12.0-275.el10, cri-o 1.36.4), all ArgoCD apps Synced/Healthy, CNPG 2/2 and archiving, Ceph in its standing state.
Update service Cincinnati (`https://updates.okd.io/api/updates/graph`), channel `stable-5.0`; `okderators` on
`catalog-index:5.0` (commit 37fe780); all nine Subscriptions Manual.

**Why move.** scos.10 was the last OKD 4.x build, so no fixes came to that line any more. No 5.0 feature was wanted
and no date was set; the gates decided the moment. The node OS was already SCOS 10, so there was no OS major, and every
5.0 build from scos.3 lists `4.22.0-okd-scos.10` as a source, so no intermediate hop.

**Shape: four phases.** (A) settle the unknowns with no cluster change, each ending in a written answer here;
(B) prepare with small reversible commits; (C) the window, with a go/no-go list; (D) after the hop: verify, update
service, catalogs, the 5.0 builds of the operators, docs.

**Decisions and why.**

- *Start path.* Preference order: the cluster lists 5.0 itself after a channel change; else an explicit image by
  digest with `--allow-explicit-upgrade`; never `--force`. The first worked: pointing the cluster at Cincinnati
  `stable-5.0` listed scos.2 to scos.5. The 5.0 CVO still verifies with `verifier-public-key-ci` (okd#2369: scos.1
  shipped without signatures and is a conditional update with `SigningKeyVerificationFailure`).
- *Target build.* The design asked for the newest build at least 7 days old with a green CI run of the edge. The
  operator took scos.5 the same day: it had one green AWS run of the edge from `4.22.0-okd-scos.10`, which the operator
  accepted as enough (no bare-metal run needed). scos.6 was in neither graph and had no upgrade run from our build, so
  scos.5 now and scos.5 to scos.6 as a 5.0 update later.
- *etcd, okd#2384.* Open with no maintainer reply, same shape as this cluster (3 masters, automatic defrag on 5.0), so
  the hop ran with automatic defrag off (ConfigMap `openshift-etcd-operator/etcd-disable-defrag`, read through the
  `DefragControllerDisabled` condition rather than a log line). Fragmentation was 36-38%, near the 45% trigger, so a
  blocking manual defrag on 4.22 came first, followers first; that is also why the 11 minutes in which the condition
  read False after the etcd operator pod moved did nothing. Re-enable only with a fixed build running here; never a manual
  `etcdctl defrag` on 5.0 while it is open. Consistency reads (revision and hash across the members) before, during,
  after, and daily for a week.
- *Worst case accepted.* An OKD upgrade cannot be rolled back, and an etcd snapshot restores only onto the build it was
  taken on. Past the point of no return the way out is forward, or a reinstall plus restore from the app backups (CNPG to
  R2, OADP, a one-off OADP backup the same day). The operator accepted that and no restore rehearsal was a gate.
- *okd#2361* (CRI-O and Multus after an unclean shutdown): the nodes are on a UPS and reachable by console or SSH, so it
  is a runbook note with a ready recovery command, not a gate. It did not occur.
- *cert-manager stays on 1.20*, outside its Kube matrix on 1.36, as 1.18 was on 4.21 and 4.22. The design had the hop
  wait for the first ACME renewal on 1.20 (2026-11-20) so that a failure could not be mixed up with a 5.0 effect; the
  operator dropped that gate ("aim asap"). The Helm fallback branch stays.
- *Operators.* CNPG and grafana-operator went to `installPlanApproval: Manual` first (the only two on Automatic, and the
  marketplace moves `community-operators` to the `v5.0` index during the hop). The `okderators` tag stayed on 4.22
  through the hop and flipped afterwards, as in both earlier hops, once it was clear that cert-manager and gitops stay
  `AtLatestKnown`. The four zot test-build operators (logging and Loki, NMState, OADP, descheduler) rode the hop on
  their 4.22 builds: a 5.0 build cannot be soaked on a 4.22 cluster, and four builds first would have delayed the hop by
  days for no added safety. Each got a short written check for ties to Kube 1.35; none was found. The research had
  said logging and Loki carry no `maxOpenShiftVersion` cap; they do (4.23), as does the descheduler 5.4 build, which
  blocks 5.1 and not 5.0.z.
- *zot.* The 5.0 payload is on `quay.io/okd/*`, which zot mirrors by host; zot does not cache digest-only pulls, so
  payload pulls fall through to quay (measured 1m50s for one image on node5) and every node reboot while `zot-0` moves
  stalls zot-only images for a few minutes (descheduler, ceph-csi-controller-manager, logging and loki operators in
  `ImagePullBackOff` until zot was back). Per-node zot-only images (NMState handler, OADP node-agent, vector) were
  confirmed cached on all three nodes before the window.
- *Two disruptive changes never at once* (no drain headroom: 3 OSDs on 3 nodes). Not Monday 19:00-23:00Z; the Rook
  close-out finished first.

**Ruled out.** `--force` in any path; waiting for the 2026-11-20 renewal; waiting 7 days for the target's age; a
restore rehearsal or a bare-metal CI run as gates; making the four test-build operators 5.0-ready before the hop;
flipping the `okderators` tag before the hop; leaving automatic defrag on and trusting the 4.22 operator's defaults.

**Plan review.** The design and the plan were reviewed on Fable 5.2 before approval and the findings applied (the etcd
condition as the probe, a DONE condition needing every node on the new rendered MachineConfig, gates for backup
freshness and for the off-cluster inputs a reinstall needs).

**Open after the hop** (README TODO "OKD 5.0 follow-ups"): etcd defrag off until okd#2384 is fixed in a build running
here; scos.6 as a 5.0 update; 5.0 builds of NMState, the descheduler, OADP and logging + Loki; the cert-manager
renewal on 2026-11-20 and a 1.21 bundle; a 5.0 `oc` client (4.22.22 now); router HAProxy 2.8 to 3.2, the new MCO
NetworkPolicies and the extra etcd leader election per defrag still to check; 13 `CephNodeDiskspaceWarning` false
positives to age out.

## 2026-11-10 — `etcdDatabaseHighFragmentationRatio`, left firing

About three hours after the hop (16:35Z, read from the console graph in CET) the platform rule `etcdDatabaseHighFragmentationRatio` (warning, `for: 10m`) began
firing on all three members:

```
(last_over_time(etcd_mvcc_db_total_size_in_use_in_bytes{job=~".*etcd.*"}[5m]) /
 last_over_time(etcd_mvcc_db_total_size_in_bytes{job=~".*etcd.*"}[5m])) < 0.5
and etcd_mvcc_db_total_size_in_use_in_bytes{job=~".*etcd.*"} > 104857600
```

The ratio sat at 0.43-0.46 from 16:35Z. That is the expected consequence of the decision above: automatic defrag is
off (`DefragControllerDisabled=True` since 13:13Z) because of okd#2384 (still open, no comments since 2026-11-05), and
a manual defrag on 5.0 would take the same non-blocking path. The manual blocking defrag before the window had brought
fragmentation to 0-7 %; the hop's writes (every operator rolling, three reboots) left free pages behind again.

Fragmentation costs disk space in the DB file, not correctness. The limit that matters is the backend quota:

```
oc -n openshift-etcd get pod etcd-node4.okd.sudops.pl -o json | jq -r '.spec.containers[]|select(.name=="etcd")|.env[]|select(.name|test("QUOTA"))|.name+"="+.value'
ETCD_QUOTA_BACKEND_BYTES=8589934592
```

8 GiB, against about 115 MiB in use and a file of about 200-250 MiB. The operator decided to leave the alert firing
rather than silence it, so it stays visible until a build with the okd#2384 fix lets defrag back on. The daily
`etcd-consistency.sh` reads record `dbSize` and `dbSizeInUse` per member, which is where growth would show.

## 2026-11-11 — scos.6 offered, and the defrag switch has a start-up race

Cincinnati `stable-5.0` offers `5.0.0-okd-scos.6` from scos.5 since 2026-11-10 22:39Z (`UpdateAvailable`). Release
notes: the GitHub release (`okd-project/okd`, tag `5.0.0-okd-scos.6`, published 2026-11-09 22:45Z) is only the
`oc adm release info` dump: machine-os 10.0.20261014-0 → 10.0.20261108-0, Kubernetes still 1.36.5, and 191 of 196
image digests changed, which is a rebuild on a new base, not 191 code changes. The changelog is on the release
controller (`amd64.origin.releases.ci.openshift.org/releasestream/5-scos-stable/release/5.0.0-okd-scos.6?from=5.0.0-okd-scos.5`):
source changes in machine-config-operator (OCPBUGS-135085, OCPBUGS-136379), ovn-kubernetes (OCPBUGS-135003), OLM and
operator-registry (OCPBUGS-135357, OCPBUGS-129498), cluster-config-operator (`golang.org/x/net` for CVE-2026-33814) and
cloud-only components; cluster-etcd-operator (`dc770522`) and etcd (`7cf5f0db`) are rebuilt from the same commits, so
no okd#2384 fix. Base OS: kernel 6.12.0-275 → 280.el10, ca-certificates 2026.2.90 → 2026.2.92, glibc, systemd,
openssl 3.5.9; NetworkManager, openvswitch and CRI-O 1.36.4 unchanged. CI: the upgrade from scos.5 passed.

`gates.sh` (readonly) at about 18:00Z: 21 PASS, 1 FAIL, `upgradeable` (the zot test builds' `maxOpenShiftVersion`
4.23), which blocks a minor update and not a 5.0.z one.

The runbook flagged one thing as "unverified, read from the source": whether the defrag controller's first sync after
an etcd-operator restart can run before its ConfigMap cache fills. Read at `dc770522`:

```
pkg/operator/defragcontroller/defragcontroller.go
  89  return factory.New().ResyncEvery(compactionInterval+1*time.Minute).WithBareInformers(
  90          operatorClient.Informer(),
  91  ).WithSync(syncer.Sync).ToController("DefragController", ...)
 108  disableConfigMap, err := c.configmapLister.ConfigMaps(operatorclient.OperatorNamespace).Get(defragDisableConfigmapName)
 109  if err != nil && !k8serror.IsNotFound(err) {
pkg/operator/starter.go
 643  kubeInformersForNamespaces.Start(ctx.Done())
 661  go defragController.Run(ctx, 1)        (no WaitForCacheSync for the kube informers in between)
```

The controller waits only for the operator CR's informer; the ConfigMap lister comes from the namespace informers,
which are started but not waited for. An empty cache answers NotFound, which reads as "defrag enabled". So the race
is real in the code. How often it is lost is unknown: both informers start together and the namespace holds few
ConfigMaps. During the hop all three members were at about 41%, under the controller's 45% threshold, so a lost race
had nothing to do. Now all three are above 50% (the fragmentation alert), so a lost race defragments one member, on the
non-blocking path okd#2384 implicates. Every etcd-operator restart is that exposure: scos.6 changes its image, and
each drain of its node moves it. The 45% gate cannot pass any more, because defrag on 5.0 is ruled out.

## 2026-11-11 — scos.5 → scos.6 in 105 minutes

The operator dropped the 7-day rule for good ("remove 7d rule. go tonight") and accepted the defrag start-up race.
The runbook `tests/okd-5.0-upgrade/` ran unchanged apart from the target (`43f3417` notes how to reuse it for 5.0.z).

Pre-window (17:57–18:02Z): offered image = the release's `Pull From` (`sha256:ea7e0f42…746f`); signature-1 HTTP 200;
`gates.sh` 21 PASS, 1 FAIL `upgradeable` (minor-only); fragmentation node4 56.7%, node5 57.07%, node6 57.05%;
`br-ex.forwarding` 1/1/1; `etcd-consistency.sh pre` CONSISTENT (hash 1540481152, rev 179345905); etcd snapshot on node4
(`snapshot_2026-11-11_180132.db`, 272 MB) with two copies off the node. The per-node zot-only images (NMState handler
`f2ae21b0`, velero `8e026079`, vector `3a8b699a`) were proven cached by the DaemonSet pods' `imageID` on each node,
without `crictl`.

Start (operator) `oc adm upgrade --to=5.0.0-okd-scos.6` at 18:03:55Z. Timeline from the watcher
(`evidence/window-scos6-20261111T180244Z.events`):

| time (Z) | event |
|---|---|
| 18:04:06 | CV desired scos.6; `Failing=True` "the update could not be applied" for 8 s, then False |
| 18:04:59 | etcd-operator restarts on the scos.6 image (race moment 1): no defrag event |
| 18:05:32–18:13:26 | etcd revision 14 rolls node4, node5, node6 (each 2/3 for about a minute) |
| 18:12:27 | `ETCD-ON-TARGET`; `etcd-consistency.sh mid` CONSISTENT (hash 871313934) at 18:12:53 |
| 18:32 | 28/34 operators on target |
| 18:53:31 | node4 cordoned; osd.0 down |
| 19:13:32 | `ALERT stuck-drain-node4` (the CNPG race below) |
| 19:23:31 | the held pod is killed at the end of its grace period; 19:26:54 node4 reboots |
| 19:28:55 | node4 Ready (2 min reboot), Done 19:29:20 |
| 19:29:20 | node6 cordoned; zot-0 down 19:29:57–19:32:53 (moved to node4) |
| 19:36:13 | node6 reboots, Done 19:38:35 |
| 19:38:57 | node5 cordoned; 19:39:26 etcd-operator restarts on node6 (race moment 2): no defrag event |
| 19:40:16 | `ALERT cv-failing` (machine-config Degraded since 19:23:08), cleared 19:41:15 |
| 19:45:35 | node5 reboots, Done 19:47:55 |
| 19:48:47 | CV history Completed; `DONE` 19:50:55 after the 120 s hold |

**The stuck drain.** At 18:53:19Z CNPG began switching the homebox primary off the cordoned node4
(`SwitchingOver … from homebox-postgres-1 to homebox-postgres-2`). The old primary's postgres container exited 0 at
18:53:28 ("Releasing primary lease"); the drain evicted the pod at 18:53:31 with CNPG's 1800 s grace; at 18:53:42 the
kubelet started the container again (restart 1) and in the same second logged `Killing: Stopping container postgres`.
The instance manager came up as a streaming replica (18:54:15) and never shut down, so the pod sat `Terminating` until
the SIGKILL at 19:23:31. My reading, not verified: the stop signal reached PID 1 before the instance manager had
installed its handler. The primary was healthy on node6 the whole time and nothing was lost. I proposed deleting the
replica pod with `--grace-period=60`; the operator did not act and by 19:22Z it was not worth it. node6 and node5
drained normally (the old primary stopped within seconds both times), so it is a race, not a rule. The same 30 minutes
pushed machine-config past its pool deadline: `syncRequiredMachineConfigPools: context deadline exceeded` (Degraded
19:23:08Z), CV `Failing` for over 10 min, which cleared by itself while node5 rolled.

**The defrag race.** The etcd operator restarted twice (new image at 18:04:59Z, the node5 drain at 19:39:26Z), each
time with all three members above 45% fragmentation. Zero `DefragControllerDefragment*` or leader-transfer events in
the window; `DefragControllerDisabled=True` throughout. Two restarts without a defrag say the race is not usually lost;
they do not say it cannot be.

**After.** `etcd-consistency.sh post` CONSISTENT (hash 2467342476, rev 179450488). `verify.sh` first gave 16 PASS,
1 FAIL: 7 OLM apps Synced/Degraded from `ResolutionFailed` Subscriptions while the catalogs came back (the HOP 2
pattern); clear at 19:53:01Z, and the re-run gave 17/17 PASS. `br-ex.forwarding` 1 on every node after its reboot (all
three read at 19:40Z and node5 again at 19:48Z). Nodes on CentOS Stream CoreOS 10.0.20261108-0, kernel
6.12.0-280.el10, CRI-O 1.36.4. Restarts in the window all line up with the reboots (kube-apiserver check-endpoints, KCM,
csi-rbdplugin, multus, cluster-baremetal-operator, immich-server). The node5 NMState handler restarted 3 times: the
reboot, then a start at 19:47:26 before the node's pod network was up
(`dial tcp 172.30.0.1:443: connect: network is unreachable`), clean since 19:47:40. zot: 19.5 GiB free.

One change in the payload shows on the cluster: the `Upgradeable=False` message now reads "blocking minor version
upgrades to 5.1 or higher … maximum supported OCP version … is 5.0" for the logging, Loki and descheduler test builds
(it said 4.23 before), which fits OCPBUGS-135357 in the changelog.
