# OLM v1 on OKD 4.21: the catalog nobody uses filled a control-plane disk

Working draft. OKD 4.21 ships OLM v1 (catalogd + operator-controller) beside the OLM v0 everything in this
repo actually uses. It sat idle and unnoticed until its cache leak turned into a Ceph monitor warning.
Chronology of the diagnosis and the GitOps mitigation, with the raw output that drove each step.

## 2026-09-14 — `MON_DISK_LOW` was one pod's emptyDir

Ceph reported `MON_DISK_LOW: mon c is low on available space` from 12:09Z, the same minute an unrelated MCO
reroll started, which made it look like collateral. It was not. The mon's node, node5, had its root filesystem
at 70% used (112 GiB free of 372), right at Ceph's 30%-free `mon_data_avail_warn` line, while node4 sat at 34%
and node6 at 52%.

Under the readonly SA the kubelet stats summary names the consumer without any exec:

```
$ oc get --raw /api/v1/nodes/node5.okd.sudops.pl/proxy/stats/summary | python3 -c '...top pods by ephemeral-storage...'
node5: root used=260/372 GiB | top ephemeral:
  openshift-operator-controller/operator-controller-controller-manager-94b6fb847-c4l9n 39.4 GiB
  openshift-console/downloads-59ff9b98dd-hk7tb 3.2 GiB
  openshift-catalogd/catalogd-controller-manager-6f58c69b89-kwwwh 0.4 GiB
```

The pod's own breakdown (same summary, per volume) put all of it in one emptyDir:

```
container manager rootfs=0.0 GiB logs=0.0 GiB
volume cache 39.4 GiB
volume tmp 0.0 GiB
```

Inside the pod, `/var/cache/catalogs` held the three healthy catalogs as visible directories and **544 hidden
temp directories** for the fourth, 79 MB each, accumulating at about 90 a day since the 4.21 upgrade:

```
$ oc -n openshift-operator-controller exec operator-controller-controller-manager-94b6fb847-c4l9n -c manager -- \
    sh -c 'cd /var/cache/catalogs && ls -a | grep -E "^\." | sed -E "s/-[0-9]+$//" | sort | uniq -c; ls'
    544 .openshift-redhat-operators
openshift-certified-operators
openshift-community-operators
openshift-redhat-marketplace

per day (hidden):  30 2026-09-08 / 92 09-09 / 95 09-10 / 88 09-11 / 86 09-12 / 87 09-13 / 66 09-14
$ du -sh .openshift-redhat-operators-1007731160
79M
```

Each temp dir is one failed attempt to cache the Red Hat index, the largest of the four default
`ClusterCatalog`s. The parse times out on nearly every 10-minute poll on this cluster:

```
E0914 17:52:28 controller.go:474] "Reconciler error" err="error populating cache for catalog
  \"openshift-redhat-operators\": error parsing catalog contents: context deadline exceeded
  (Client.Timeout or context cancellation while reading body)"
I0914 18:09:08 clustercatalog_controller.go:78] "retrying cache population: found previous error from catalog cache"

$ oc get clustercatalog -o custom-columns=NAME:.metadata.name,AVAIL:.spec.availabilityMode,POLL:.spec.source.image.pollIntervalMinutes,LASTUNPACK:.status.lastUnpacked
openshift-certified-operators   Available   10   2026-09-14T12:15:01Z
openshift-community-operators   Available   10   2026-09-14T09:40:06Z
openshift-redhat-marketplace    Available   10   2026-09-14T09:01:36Z
openshift-redhat-operators      Available   10   2026-09-11T18:16:22Z
```

`operator-controller`'s `filesystemCache.writeFS` creates `.<catalog>-<random>`, fills it, and renames it into
place; on the error path nothing removed it. Upstream fixed exactly that as
operator-framework/operator-controller#2574 (OCPBUGS-78787, merged 2026-03-20: `defer os.RemoveAll(tmpDir)` plus
an orphan sweep at the next write). The openshift fork synced it into `main` on 03-23 (#670) and backported it to
`release-4.18` (#751, 06-10); the `release-4.21` backport I found (OCPBUGS-86842, merged 06-03) is the catalogd
half, so `4.21.0-okd-scos.11` still leaks on the operator-controller side. Why the parse times out here and not
in CI is not attributed; the power profile's CPU throttling is the obvious candidate and is noted, not proven.

None of this had a consumer: `oc get clusterextension -A` is empty, and the three Red Hat catalogs carry
operators that need a `registry.redhat.io` entitlement this cluster does not have. Every operator in this repo
installs through OLM v0 (`CatalogSource` okderators / community-operators + `Subscription`).

## Mitigation — `components/cluster-config/olm-v1-catalogs/`

Two halves. The **durable** one is GitOps: a chart that renders a partial `ClusterCatalog` (name plus
`spec.availabilityMode: Unavailable`) for each of the three Red Hat catalogs and lets ArgoCD server-side-apply
it onto the object cluster-olm-operator created — the same pattern as `csi-driver-config`'s hostNetwork patch.
`Unavailable` is the field the OLM docs name for disabling a default catalog; it stops the polling and drops the
catalog from catalogd's storage. `openshift-community-operators` stays `Available`.

Pre-flight facts that made the partial-object approach safe:

```
$ oc get clustercatalog openshift-redhat-operators --show-managed-fields -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.fieldsV1.f:spec}{"\n"}{end}'
CatalogdClusterCatalogOpenshiftRedhatOperators Apply {"f:priority":{},"f:source":{...}}
catalogd Update
```

The operator's own apply owns `priority` and `source` only, so `availabilityMode` has no competing manager and
nothing will fight ArgoCD for it. The CRD's only required spec field is `source`, which the merge keeps.

The **one-shot** half is operator-run: the leaked directories live in the pod's emptyDir and the 4.21 build has
no orphan sweep, so `oc -n openshift-operator-controller delete pod operator-controller-controller-manager-94b6fb847-c4l9n`
is what actually returns the 42 GiB. After the chart is live the pod cannot leak again for that catalog.

Outcome after sync: to be filled in with the `ClusterCatalog` conditions, the node5 root-disk figure and the
Ceph health line.
