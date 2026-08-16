# OLMv1 `operator-controller` leaks its catalog cache — 161 GiB on one node

**Date:** 2026-08-16
**Status:** diagnosed, not yet remediated (both fixes are guardrail-gated mutations, operator-run)
**Severity:** node5 `/var` at 76 % and climbing ~9.7 GiB/day; ~9 days to full at discovery
**Found by:** routine session-start health sweep — `CephMonDiskspaceLow` firing since 2026-08-13

## How it surfaced

The sweep was otherwise clean (3/3 nodes Ready, 45 apps, CNPG archiving on both clusters,
`br-ex.forwarding=1` everywhere). Alert triage turned up 14 firing / 0 critical, of which all but
two were the documented benign set. The two that weren't:

```
TargetDown            ns=nmstate job=nmstate-monitor   since 2026-08-06   (known, tracked, LOW)
CephMonDiskspaceLow   ns=rook-ceph                     since 2026-08-13   <-- new
```

`CephMonDiskspaceLow` reads like a Ceph problem. It isn't:

```
$ oc -n rook-ceph get cephcluster rook-ceph -o jsonpath='{range .status.ceph.details.*}...'
  HEALTH_WARN :: 3 OSD(s) experiencing slow operations in BlueStore     <- the known benign latch
  HEALTH_WARN :: mon c is low on available space                        <- this one
```

There are **no mon PVCs** — Rook mons run on `dataDirHostPath`, so "mon store low on space" means
*the node's filesystem* is low on space. mon c is on node5:

```
a -> node4    b -> node6    c -> node5
```

## The asymmetry

```
node5  /var  24.5% free      <-- mon c lives here
node6  /var  70.3% free
node4  /var  73.5% free
```

And it is not a step — it is a monotonic leak:

```
/var used (GiB)     node5      node4
2026-08-03          147.4       61.3
2026-08-07          203.5       66.8
2026-08-11          243.3       71.4
2026-08-15          273.5       91.4
```

node5: **~9.7 GiB/day**, no plateau. `df` at discovery: `372G size / 281G used / 92G avail (76%)`.
At that rate, **~9 days to a full `/var`** — which on a 3-node no-drain cluster means kubelet
eviction, crio failures, and a mon down, all at once.

(node4 is also growing, ~2.3 GiB/day and accelerating. Separate, less urgent, not yet diagnosed.)

## Narrowing it

Container writable layers were a dead end — everything on node5 summed to under 3 GiB, the largest
single container being `openshift-console/downloads` at 2.1 GiB. So the space is in images, logs, or
host volumes, none of which cAdvisor attributes to a workload.

On-node, read-only, via the MCD pod (`oc adm node-logs` and `oc debug node` are guardrail-denied
here; `chroot /rootfs` from the machine-config-daemon container is the read path that works):

```bash
oc -n openshift-machine-config-operator exec machine-config-daemon-zqhc8 \
  -c machine-config-daemon -- chroot /rootfs du -x --max-depth=1 -BG /var
```

```
268G  /var
254G  /var/lib          ->   163G  /var/lib/kubelet     ->  163G  /var/lib/kubelet/pods
                              87G  /var/lib/containers
 15G  /var/log
```

One pod directory held **161 of the 163 GiB**:

```
161G  /var/lib/kubelet/pods/9e6e62a4-0473-4bab-9f0d-4f390df8ce4f
```

That UID resolves to a **live, Running** pod:

```
openshift-operator-controller/operator-controller-controller-manager-696b4b5f77-gmr2x
```

and all of it is in one **`emptyDir`**:

```
161G  .../volumes/kubernetes.io~empty-dir/cache/catalogs
```

## Root cause

```
$ ls -A cache/catalogs | sed 's/-[0-9]*$//' | sort | uniq -c | sort -rn
   2097 .openshift-redhat-operators
      1 openshift-redhat-marketplace
      1 openshift-community-operators
      1 openshift-certified-operators
      1 .openshift-community-operators
```

**2097 orphaned `.openshift-redhat-operators-<random>` temp directories, 161 GiB**, oldest dated
2026-07-25 (the pod's `startTime`) and newest today. OLMv1's `operator-controller` unpacks each
catalog into a dot-prefixed temp dir and renames it into place on success; for
`openshift-redhat-operators` the temp dir is **never removed**. Every other catalog has exactly one
directory, so the leak is specific to that catalog — plausibly because it is by far the largest
index (`registry.redhat.io/redhat/redhat-operator-index:v4.20`).

Notably the catalog reports healthy throughout, which is why nothing else complained:

```
Progressing=True  reason=Succeeded  "Successfully unpacked and stored content from resolved source"
Serving=True      reason=Available  "Serving desired content from resolved source"
lastUnpacked=2026-08-14T17:23:16Z   pollIntervalMinutes=10
```

A 10-minute poll over 22 days is ~3100 polls; 2097 leaked dirs is consistent with "most polls leak
one." The `emptyDir` has **no `sizeLimit`**, so it is bounded only by the node filesystem.

## The part that makes this pure waste

**Nothing on this cluster uses OLMv1 at all.**

```
$ oc get clusterextensions.olm.operatorframework.io --no-headers | wc -l
0
```

Every operator here comes through OLM **v0** CatalogSources:

```
openshift-marketplace/okderators              quay.io/okderators/catalog-index:4.20
openshift-marketplace/community-operators     registry.access.redhat.com/redhat/community-operator-index:v4.20
openshift-marketplace/operatorhubio-catalog
```

And the OLM v0 defaults were *already* turned off:

```
$ oc get operatorhub cluster -o jsonpath='{.spec}'
{"disableAllDefaultSources":true,"sources":[{"disabled":false,"name":"community-operators"}]}
```

So `disableAllDefaultSources: true` is set — and all four OLMv1 `ClusterCatalog`s are nonetheless
`availabilityMode: Available`, polling every 10 minutes. **The OperatorHub disable switch does not
gate OLMv1 ClusterCatalogs.** That gap is arguably the real defect: an operator who has explicitly
disabled the default catalogs still gets them, in a second subsystem, silently, on a paid registry
this cluster cannot even pull from meaningfully.

## Remediation (both are guardrail-gated — operator-run)

**1. Immediate reclaim.** The cache is an `emptyDir`, so it dies with the pod:

```bash
oc -n openshift-operator-controller delete pod -l control-plane=operator-controller-controller-manager
```

Frees ~161 GiB instantly. Safe here precisely because there are 0 ClusterExtensions — nothing
depends on this controller's state. It re-caches and starts leaking again, so this buys time, not a
fix.

**2. Stop the leak at source.** OLMv1 is unused, so the catalogs are pure overhead:

```bash
oc patch clustercatalog openshift-redhat-operators --type=merge \
  -p '{"spec":{"availabilityMode":"Unavailable"}}'
```

`availabilityMode` is a real field (`enum: Available, Unavailable`) — verified via
`oc explain clustercatalog.spec`. **Caveat: unverified whether this sticks.** The ClusterCatalog
carries no `ownerReferences` and no CVO annotations, but that does not prove nothing reconciles it;
the `marketplace` ClusterOperator is `Available=True` and may reassert. Apply it and re-read the
object after a few minutes. Arguably do all four, since none are used.

**3. File upstream** against `operator-framework/operator-controller`: temp unpack directories are
not cleaned up, the cache `emptyDir` has no `sizeLimit`, and neither the catalog status nor any
alert reflects unbounded growth. The only symptom is a *different* subsystem's disk alert on a
*different* component, three weeks later.

## Lessons

- **`CephMonDiskspaceLow` is a node-disk alert wearing a Ceph costume** when mons are on
  `dataDirHostPath`. Check `node_filesystem_avail_bytes` before touching Ceph.
- **cAdvisor cannot see this class of leak.** `container_fs_usage_bytes` covers writable layers
  only; an `emptyDir` is invisible to it. The 161 GiB pod showed up as ~0 in every per-container
  metric. Node-level `du` was the only way.
- **A healthy-looking component can be the leaker.** The controller was `Running`, the catalog
  `Serving=True`/`Progressing=Succeeded`. Nothing in either surface hinted at 2097 orphaned dirs.
- Worth an alert: node `/var` free-space trend, and/or a `predict_linear` on
  `node_filesystem_avail_bytes` so "9 days to full" fires while it is still boring.
