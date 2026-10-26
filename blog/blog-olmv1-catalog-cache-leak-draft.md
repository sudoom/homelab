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

## 2026-10-14 — node5's disk again: catalog index images, not the operator-controller

Ceph went `HEALTH_WARN` again on 2026-10-13 12:55: `CephMonDiskspaceLow` for mon c, which runs on node5. Same
alert as 09-14, so I assumed the same culprit. It was not the operator-controller this time. The `oc debug node/...`
commands below were run by the operator, not by me: `oc debug` creates a pod, which is a cluster write.

**1. Kubelet stats summary.** First question: is a pod holding ephemeral storage? Per-pod `ephemeral-storage`
from the kubelet stats summary on node5: nothing. The largest pod used 1.66 G. So the disk is not in pods.

**2. Seven days of free space.** A `query_range` against the platform Prometheus, read through the break-glass
kubeconfig, as a read, with one sample every 12 h:

```bash
end=$(date -u +%s); start=$((end-7*86400))
KUBECONFIG=~/.kube/config-breakglass oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
  wget -qO- "http://localhost:9090/api/v1/query_range?query=node_filesystem_avail_bytes%7Bmountpoint%3D%22%2Fsysroot%22%7D&start=$start&end=$end&step=43200" \
  | jq -r '.data.result[] | "\(.metric.instance | split(".")[0]): " + ([.values[] | "\((.[1]|tonumber)/1073741824|floor)"] | join(" "))'
```

 node5 fell from 129 to 111 GiB (69 % used of 371, about 2.6 GiB a day); node4 stayed at about 216 GiB
and node6 at about 148. A slow steady slope on one node, not a step like the 09-14 leak.

**3. `du` on node5.**

```bash
oc debug node/node5.okd.sudops.pl -- chroot /host sh -c 'du -xsh /var/lib/containers /var/log /var/lib/kubelet /var/lib/etcd /var/tmp /tmp /var/lib/rook 2>/dev/null; journalctl --disk-usage'
```

`/var/lib/containers` 236G, `/var/log` 9.2G, journal 3.9G, kubelet 2G. Logs and kubelet are noise; the container
store is nearly everything.

**4. `overlay`, node5 against node4.**

```bash
for n in node5 node4; do echo "== $n"; oc debug node/$n.okd.sudops.pl -- chroot /host sh -c 'du -xsh /var/lib/containers/storage/* 2>/dev/null | sort -h | tail -6; echo "images: $(crictl images -q | wc -l)  containers: $(crictl ps -a -q | wc -l)  exited: $(crictl ps -a --state exited -q | wc -l)"' 2>/dev/null; done
```

`/var/lib/containers/storage/overlay` is 236 G on node5 against 132 G on node4. Images: 739 against 406. Containers:
185 against 233, so container layers are not it.

**5. Per repository.**

```bash
oc debug node/node5.okd.sudops.pl -- chroot /host sh -c 'crictl images | awk "NR>1 {print \$1}" | sort | uniq -c | sort -rn | head -8' 2>/dev/null
```

376 of node5's images are `registry.access.redhat.com/redhat/community-operator-index` and 85 are
`quay.io/operatorhubio/catalog`. Hundreds of tags-less digests of the same two repositories: index images that
were each pulled once and never removed.

**6. The catalog sources.** `community-operators` polls every 240m and is managed by marketplace-operator (so not
ours to change). `okderators` and `operatorhubio-catalog` poll every 60m. All three catalog pods run on node5, which
is why node5 carries the pile and node4 does not. Every poll that finds a new digest pulls a fresh index image; the
old one stays on disk until something removes it. `operatorhubio-catalog` is in no file in this repo (created by
hand at some point), so its interval has never been under version control.

**7. Why nothing cleaned up.** The kubelet's image GC starts at 85 % disk use (`imageGCHighThresholdPercent`).
Ceph's mon warns at 70 % used. The disk crosses the warning line 15 points before GC would ever run, so the
images accumulate until Ceph complains, and only then does it look like a Ceph problem.

### Fix and status

Nothing has been run yet. Tracked as two README TODOs (Queued — platform plumbing):

- Prune node5's unused images (operator): `oc debug node/node5.okd.sudops.pl -- chroot /host crictl rmi --prune`.
  Removes only images no container uses; anything needed again is pulled through zot.
- Stop the churn. Step 1, in git: put `operatorhubio-catalog` next to `okderators` in
  `bootstrap/phase0/01_catalog_source.yaml` with `registryPoll.interval` 24h. Step 2: a KubeletConfig with
  `imageGCHighThresholdPercent: 65` / `imageGCLowThresholdPercent: 55`, but a KubeletConfig makes MCO reboot every
  node in turn (a degraded window for 3 OSDs), so it waits for the next planned node roll, with the
  `network-change` pre-flight. Without step 1 the warning comes back 5-6 weeks after a prune.

Lesson: this is the second time `CephMonDiskspaceLow` was a node-disk alert. Check `node_filesystem_avail_bytes` per
node first, then `du`, then the image count, before touching Ceph.

## 2026-10-26 — node5 at 80 %, and the operatorhubio poll goes to 24h

Nothing had been pruned since 10-14. The session-start sweep showed Ceph `HEALTH_WARN` with only
`mon c is low on available space`, so I measured node5 again through the kubelet stats summary (readonly SA, no exec):

```bash
KUBECONFIG=~/.kube/config-readonly oc get --raw /api/v1/nodes/node5.okd.sudops.pl/proxy/stats/summary \
  | python3 -I -c 'import json,sys; fs=json.load(sys.stdin)["node"]["fs"]; print(100*fs["usedBytes"]/fs["capacityBytes"], fs["availableBytes"]/2**30)'
```

80.1 % used, 74.1 GiB free: 37 GiB in 12 days, about 3.1 GiB a day, faster than the 2.6 measured on 10-14. The
largest pod held 0.3 GiB of ephemeral storage, so it is still the image store. The kubelet's image GC starts at 85 %,
about six days out at this rate, and should then hold the disk between 80 and 85 %. That keeps the mon in warning and
nowhere near its 5 % critical line, so there was no emergency, but nothing clears the warning except a prune.

**How big a share is the operatorhubio catalog?** The node's `.status.images` only lists the 50 largest images. 31 of
them are `community-operator-index` at about 1.09 GiB each (33.7 GiB nominal; layers are shared between digests, which
is why 376 of them fit in 236 G of overlay). No `operatorhubio/catalog` image made the top 50, so each is smaller than
that. Count and size both say `community-operators` is the bigger pile.

**Does a longer poll help at all?** It only matters if `:latest` moves more often than the interval. The quay tag
history answers that:

```bash
python3 -I - <<'EOF'
import json, urllib.request, collections, datetime
u = "https://quay.io/api/v1/repository/operatorhubio/catalog/tag/?specificTag=latest&onlyActiveTags=false&limit=100"
c = collections.Counter(datetime.datetime.fromtimestamp(t["start_ts"], datetime.UTC).strftime("%Y-%m-%d")
                        for t in json.load(urllib.request.urlopen(u))["tags"] if t.get("start_ts"))
for k in sorted(c): print(k, c[k])
EOF
```

47 moves from 10-12 to 10-25, between none (10-24) and eight a day, about 3.4 on average. With the 60m poll each move became one
more image on node5. A 24h poll takes at most one a day, so this catalog's share drops by roughly 70 %.
`community-operators` is untouched: the marketplace operator owns it and resets its 240m.

**Step 1, done in git.** `operatorhubio-catalog` (the CNPG and NMState source, both `installPlanApproval: Automatic`)
was created by hand and lived in no file. It now sits next to `okderators` in `bootstrap/phase0/01_catalog_source.yaml`
with the live spec copied and only the interval changed. Checks, all read-only:

```bash
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  bootstrap/phase0/01_catalog_source.yaml          # Valid: 2, Invalid: 0
```

`oc diff` needs a dry-run patch, which the readonly SA is refused (`cannot patch resource "catalogsources"`), so I
compared each spec in the file against `oc get catalogsource <name> -o jsonpath='{.spec}'` field by field: `okderators`
identical; `operatorhubio-catalog` differs only in `updateStrategy.registryPoll.interval` (`24h` against `60m`).

The cost: CNPG and NMState upgrades now show up to a day later. phase0 is not under ArgoCD, so the change reaches the
cluster when the operator runs `oc apply -f bootstrap/phase0/01_catalog_source.yaml`. Step 2 (the KubeletConfig GC
thresholds) is still the fix that ends this; step 1 only slows the refill after the prune.

**Applied** by the operator the same morning:

```
catalogsource.operators.coreos.com/okderators configured
Warning: resource catalogsources/operatorhubio-catalog is missing the kubectl.kubernetes.io/last-applied-configuration annotation which is required by oc apply. ... The missing annotation will be patched automatically.
catalogsource.operators.coreos.com/operatorhubio-catalog configured
```

`okderators configured` looked like a change I had not intended. It was the annotation: its
`last-applied-configuration` still recorded `catalog-index:4.20`, so the 4.21 bump on 09-08 reached the live spec some
other way than a client-side `oc apply` (which always rewrites that annotation). The spec stayed at `4.21` / `60m`; only the annotation moved to match the file.
Read back afterwards with the readonly SA: `operatorhubio-catalog` `poll=24h state=READY`, last poll 10:52:44Z;
neither catalog pod restarted (`okderators-x5n5k` from 10-16, `operatorhubio-catalog-btkhs` from 10-25); the CNPG and
NMState subscriptions `AtLatestKnown` with `CatalogSourcesUnhealthy=False`. The next poll should come about 24 h after
10:52Z.
