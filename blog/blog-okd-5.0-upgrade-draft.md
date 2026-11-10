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
