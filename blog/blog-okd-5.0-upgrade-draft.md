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
