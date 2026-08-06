# Monitoring foundation — platform Prometheus + user-workload monitoring

Working notes on `components/cluster-config/monitoring-config/`, the chart that owns the
OpenShift monitoring stack's configuration surface: platform Prometheus retention and
storage, Alertmanager storage, and the user-workload-monitoring (UWM) enablement +
retention. It is a *configuration* chart — it does not install anything. The
cluster-monitoring-operator (CMO) reads two ConfigMaps and renders the actual
`Prometheus`/`Alertmanager` CRs from them.

This is deliberately small and deliberately load-bearing: the UWM half of it is what makes
`CNPGWALArchiveFailing` (offsite-backup detection) evaluable at all, and the platform half
is what keeps 15 days of cluster history on Ceph RBD.

---

## 2026-08-06 — `retentionSize`: bounding the TSDB by disk, not just by age

### How it surfaced

Routine session-start alert triage. 15 alerts firing, zero critical — but one was not on
the known-benign list:

```
KubePersistentVolumeFillingUp   ns=openshift-monitoring   since 2026-08-06T02:40:53Z
  Based on recent sampling, the PersistentVolume claimed by
  prometheus-k8s-db-prometheus-k8s-1 in Namespace openshift-monitoring is expected to
  fill up within four days. Currently 10.66% is available.
```

First read of the filesystem, via the prometheus container:

```
$ oc -n openshift-monitoring exec prometheus-k8s-1 -c prometheus -- df -h /prometheus
Filesystem      Size  Used Avail Use% Mounted on
/dev/rbd0        49G   44G  5.3G  90% /prometheus

$ oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- df -h /prometheus
/dev/rbd10       49G   40G  9.7G  81% /prometheus
```

The obvious question was whether this was still ramping toward steady state or already at
it. Oldest block settles that:

```
$ oc -n openshift-monitoring exec prometheus-k8s-1 -c prometheus -- \
    sh -c 'ls -1dt /prometheus/01* | tail -1 | xargs stat -c "%y %n"'
2026-07-22 17:05:03.126747479 +0000 /prometheus/01KY5CG5QBTNK8QP7GFWY2DXDK
```

2026-07-22 → 2026-08-06 is exactly 15 days. Time retention is already pruning. So this is
**not** a fill trajectory — 15 days of current ingest simply *is* ~41 GiB on a 49 GiB
volume, and the only thing that moves it is series growth.

### The measurement that changed the framing

A second read ~30 minutes later disagreed with the first, which was the interesting part:

```
$ oc -n openshift-monitoring exec prometheus-k8s-1 -c prometheus -- \
    sh -c 'df -B1 /prometheus | tail -1; stat -f -c "blocks=%b free=%f avail=%a bsize=%S" /prometheus'
/dev/rbd0      52521566208  44298727424  8206061568  85% /prometheus
blocks=12822648 free=2007529 avail=2003433 bsize=4096
```

- capacity 52,521,566,208 B = **48.91 GiB**
- used 44,298,727,424 B = **41.26 GiB**
- available 8,206,061,568 B = **7.64 GiB**
- `free` (7.66 GiB) ≈ `avail` (7.64 GiB) → **no meaningful ext4 root reserve** to subtract

So 90% at 13:00 and 85% at 13:30 were *both* real: the filesystem swings roughly 3 GiB
across a compaction cycle. Prometheus writes the compacted block *before* dropping its
sources, so peak usage transiently exceeds steady-state by about the size of the largest
block being written.

Prometheus's own accounting, which is what `retention.size` actually measures:

```
$ ... query 'prometheus_tsdb_storage_blocks_bytes{job="prometheus-k8s"}'
prometheus-k8s-1  blocks = 40.28 GiB
prometheus-k8s-0  blocks = 38.37 GiB
$ ... du -sh /prometheus/wal /prometheus/chunks_head
1.5G  /prometheus/wal
344M  /prometheus/chunks_head
```

The real risk was never "it fills in four days". It is that a **7.6 GiB headroom absorbing
a ~3–4 GiB periodic swing** has no floor under it as series count grows. ENOSPC on a
Prometheus TSDB stops ingestion and can corrupt the WAL.

### Why not just grow the PVC

That was the previous reflex — `1d9bd22` bumped these from 30Gi to 50Gi on 2026-05-13.
It is the wrong lever now:

```
$ ceph df
--- POOLS ---
POOL              ID  PGS   STORED  OBJECTS     USED  %USED  MAX AVAIL
nvme-replicated    1  128  282 GiB   91.33k  819 GiB  60.49    178 GiB
```

`nvme-replicated` is at 60% with 178 GiB MAX AVAIL, and at `size=3` every +1 GiB of PVC
costs 3 GiB raw. Taking both replicas 50 → 75 Gi is +50 GiB stored = **+150 GiB raw**,
i.e. most of the remaining headroom on the tier that also backs every RBD workload on the
cluster. Growing the volume converts a bounded monitoring problem into an unbounded
storage-tier problem.

### The fix

`retention` bounds the TSDB by **age**; it says nothing about bytes. Prometheus also
supports a size bound, and prunes on whichever limit trips first. CMO exposes it:

```yaml
# components/cluster-config/monitoring-config/values.yaml
prometheus:
  retention: 15d
  retentionSize: 38GiB
  volumeSize: 50Gi

userWorkload:
  retention: 15d
  retentionSize: 7GiB
  volumeSize: 10Gi
```

Note the parent-key asymmetry in the rendered ConfigMaps — same field name, different
parent: platform is `prometheusK8s.retentionSize`, UWM is `prometheus.retentionSize`.

### Verification before shipping — what the review caught

This went through an adversarial review pass before commit, and three of the original
premises did not survive:

1. **"90% full and filling"** — wrong, or rather half-right. 84–85% at rest, 90% at a
   compaction peak. The change is a guardrail against series growth, not an emergency.
   Shipping it under an urgency framing would have been a lie in the commit message.
2. **"rolling restart of the 2 prometheus-k8s pods"** — understated by 2×. Capping UWM as
   well means `prometheus-user-workload` also re-renders its args, so the real blast radius
   is **4 pods across 2 StatefulSets**. UWM is where `CNPGWALArchiveFailing` evaluates —
   the sole offsite-backup guard — so that is worth knowing before syncing, even though a
   StatefulSet RollingUpdate takes them one at a time and one replica always keeps
   evaluating.
3. **Sizing derived from the inflated number.** Against the real 41.26 GiB, a 38GiB cap
   drops roughly 3 GiB of oldest blocks on the first reload — about 1.1 days of history —
   not the ~6 GiB implied by the bad premise.

Two footguns worth recording:

- **`38Gi` fails; it must be `38GiB`.** The Prometheus CRD validates this as a ByteSize:
  ```
  $ oc get crd prometheuses.monitoring.coreos.com -o jsonpath='...retentionSize}'
  {"pattern":"(^0|([0-9]*[.])?[0-9]+((K|M|G|T|E|P)i?)?B)$", ...}
  ```
  A trailing `B` is mandatory. This is nastier than a key typo because `volumeSize: 50Gi`
  sits two lines away in the same file and *is* a plain Kubernetes quantity — the natural
  mistake is to match it. A bad **key** fails loudly (CMO parses with `UnmarshalStrict`,
  so an unknown key rejects the entire config and degrades the `monitoring`
  ClusterOperator). A bad **unit** sails through the ConfigMap and only dies later at
  Prometheus-CR admission inside CMO's reconcile loop — a much muddier signal.
- **The `volumeClaimTemplate` is the thing not to disturb.** CMO delete/recreates the
  StatefulSet only on a 422 `Invalid` (an immutable field, i.e. a VCT change); an
  args-only change is a legal update → plain RollingUpdate. And per
  `blog/blog-multus-ceph-migration-draft.md`, when this ConfigMap *vanished* entirely, CMO
  re-rendered the StatefulSets without a VCT at all and auto-deleted the PVCs. The `oc
  diff` below exists specifically to prove the VCT is untouched.

### Sizing rationale

- Volume 48.91 GiB usable, no root reserve.
- Upstream guidance: set retention size to at most 80–85% of allocated disk.
- `38GiB` = **77.7%** — deliberately just under the band, because the compaction transient
  is *not* counted against the cap. Worst-case compacted block spans ~10% of the retention
  window (~36 h ≈ 4.1 GiB at the observed 2.75 GiB/day density), so peak on-disk lands near
  42 GiB = 86% of the volume, leaving ~6.8 GiB.
- Effective retention becomes ~13 d instead of 15 d.
- UWM: `7GiB` of a 9.75 GiB volume = 71.8%, deliberately looser in ratio than the platform
  cap because 1 GiB of *absolute* headroom on a small volume is worth more than a
  percentage point of retention. UWM is at 0.18 GiB today, so this never binds at current
  volume — it is insurance against per-namespace exporter growth.

Residual, recorded honestly: at a compaction peak this leaves ~13.9% available, and
`KubePersistentVolumeFillingUp` warns below 15%. The rule also requires a negative
`predict_linear` trend, which a bounded steady state should not produce — but if it does
keep tripping at peaks, the answer is `36GiB` (~12.4 d), **not** a bigger PVC.

### Validation

```bash
helm lint components/cluster-config/monitoring-config/
helm template monitoring-config components/cluster-config/monitoring-config/ \
  -f components/cluster-config/monitoring-config/values.yaml
helm template monitoring-config components/cluster-config/monitoring-config/ | \
  kubeconform -strict -ignore-missing-schemas -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
helm template monitoring-config components/cluster-config/monitoring-config/ | oc diff -f -
```

`oc diff` is a server-side dry-run apply, so it needs patch/update — the readonly SA
(`claude-reader`) returns `no` for `oc auth can-i patch configmap -n openshift-monitoring`
and the diff fails. Run it with the operator kubeconfig. Do not `|| true` it: that step is
the only guard on the volumeClaimTemplate footgun above.

The diff was exactly the two keys and nothing else:

```
     prometheusK8s:
       retention: 15d
+      retentionSize: 38GiB
       volumeClaimTemplate:
...
     prometheus:
       retention: 15d
+      retentionSize: 7GiB
       volumeClaimTemplate:
```

### Post-sync checks

- `oc -n openshift-monitoring get prometheus k8s -o jsonpath='{.spec.retentionSize}'` → `38GiB`
- STS args gain `--storage.tsdb.retention.size=38GiB` alongside the existing
  `--storage.tsdb.retention.time=15d` (the prometheus-operator emits both when both are set)
- `oc get co monitoring` stays `Available=True Degraded=False` (a bad key would degrade it)
- 4 VolumeAttachments, not just the 2 platform ones — the RWO RBD PVs re-attach if a pod
  lands on a different node, which on this cluster is the documented stuck-VA path
- **Freed blocks do not return to the Ceph pool.** `ceph-nvme-block` has no `discard`
  mountOption, so the ~3 GiB pruned frees filesystem space but leaves the RBD allocation
  until the weekly `node-fstrim` DaemonSet pass. Expect no `ceph df` movement; do not chase it.

Not a degraded-window event — 4 pods replaying WAL off RBD. Safe any time, just not
concurrent with OSD-impacting work on the no-drain topology.

### Open

- Nothing reports that the retention *window* has silently shrunk below 15 d once the size
  cap starts binding. `prometheus_tsdb_lowest_timestamp` is the metric; no rule watches it.
- The UWM volume will start receiving nmstate metrics once the RoleBinding fix in
  `components/operators/nmstate/` lands (see `blog/blog-multus-ceph-migration-draft.md`),
  which is the first real growth this TSDB has seen in a while.
