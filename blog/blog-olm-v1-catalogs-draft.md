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

**Outcome.** Pushed as `ee7d621` at 18:41Z; root-app created the Application on its next poll and the sync
finished at 18:49:33Z. Conditions immediately afterwards:

```
$ oc get clustercatalog -o custom-columns=NAME:.metadata.name,AVAIL:.spec.availabilityMode,SERVING:.status.conditions[?(@.type=="Serving")].status,REASON:.status.conditions[?(@.type=="Serving")].reason
openshift-certified-operators   Unavailable   False   UserSpecifiedUnavailable
openshift-community-operators   Available     True    Available
openshift-redhat-marketplace    Unavailable   False   UserSpecifiedUnavailable
openshift-redhat-operators      Unavailable   False   UserSpecifiedUnavailable
```

`operator-controller` logged one last `Reconciler error` for `openshift-redhat-operators` at 18:49:33.531Z — the
fetch that was in flight when the catalog stopped serving — and nothing after. The ArgoCD app reads
Synced/Healthy. Node5's root disk is unchanged at 260/372 GiB and Ceph still says `MON_DISK_LOW`: expected,
because the leaked directories live in the pod's emptyDir and only the pod restart (operator-run) returns them.
The operator ran the pod delete at ~18:50Z; it took over two minutes (unlinking 544 directories of catalog
content), and the replacement landed on node4 at 18:51:27Z. Four minutes later:

```
node5 root: used=219/372 GiB (59%)        # was 260/372 (70%) — 41 GiB back
ceph: HEALTH_OK                            # MON_DISK_LOW gone, lastChecked 18:54:37Z
```

Cluster back to a clean board. The remaining exposure is the operator-controller half of #2574 not being in the
4.21 payload; with the three Red Hat catalogs Unavailable there is nothing left for it to leak on.

## 2026-11-20 — facts moved from CLAUDE.md and the README TODO

The repo-level `CLAUDE.md` and the README TODO list were trimmed on 2026-11-20. These are the facts about this topic that left them, quoted as whole sentences as they stood at commit 94f34f1 so the history stays with the topic.

### From CLAUDE.md

**OLM catalogs**

- Created by hand; in `bootstrap/phase0/01_catalog_source.yaml` since 2026-10-26 with a **24h** registry poll, because every new digest of `:latest` (about 3.5 a day) left another index image on the catalog pod's node, node5, which carries mon c (README TODO "Stop the catalog image churn").
- **OLM v1 (catalogd + operator-controller) is installed and unused (2026-09-14).** Zero `ClusterExtension`s; every operator here is an OLM v0 `Subscription`. The three Red Hat default `ClusterCatalog`s (`openshift-redhat-operators`, `-certified-operators`, `-redhat-marketplace`) are held at `availabilityMode: Unavailable` by `components/cluster-config/olm-v1-catalogs/` — no entitlement for their content, and the redhat one leaked 79 MB of catalog temp dirs per failed 10-minute poll into operator-controller's emptyDir on node5 (42 GiB in six days, Ceph `MON_DISK_LOW`; upstream fix operator-framework/operator-controller#2574 not in the 4.21 payload).

### From the README TODO

**Stop the catalog image churn that fills node5 (found 2026-10-14; step 1 live since 2026-10-26; step 2 needs its own reroll, kept out of the 4.22 hop on 2026-10-27).**

- Its `:latest` moved about 3.5 times a day on quay.io (10-12 to 10-25, up to 8), so this cuts that catalog's pulls to at most one a day. It is the smaller pile: on 10-14 node5 held 85 of its images against 376 of `community-operators` (Red Hat's index, used by grafana-operator), which stays at the marketplace operator's 240m; replacing that default source is not worth it.
- Pruned 2026-10-26 (node5 80.1 % → 13.3 % used, Ceph back to `HEALTH_OK`), so the refill rate with step 1 in place is measured from there.
- **Step 1 (done):** `operatorhubio-catalog` (the CNPG source, and NMState's until that day's switch; created by hand until then) lives in `bootstrap/phase0/01_catalog_source.yaml` next to `okderators`, with `registryPoll.interval` 24h instead of 60m and the rest of the live spec unchanged; the operator applied it 2026-10-26 (`24h READY`, no catalog pod restarted, both subscriptions `AtLatestKnown`).

**OLM v1 `operator-controller` leaks a 79 MB catalog temp dir on every failed `openshift-redhat-operators` parse**

- **OLM v1 `operator-controller` leaks a 79 MB catalog temp dir on every failed `openshift-redhat-operators` parse — 42 GiB on node5's root disk in six days, and the cause of Ceph's `MON_DISK_LOW` (found 2026-09-14; MED, grows ~7 GiB/day).** `openshift-operator-controller/operator-controller-controller-manager-94b6fb847-c4l9n` keeps its catalog cache in an `emptyDir` on the node's root filesystem; `/var/cache/catalogs` held **544** hidden `.openshift-redhat-operators-<n>` directories of 79 MB each (30/92/95/88/86/87/66 per day since 09-08) beside the three healthy catalogs' visible directories.
- **Durable half SHIPPED 2026-09-14:** `components/cluster-config/olm-v1-catalogs/` (root-app wave 2) server-side-applies `spec.availabilityMode: Unavailable` onto the three Red Hat `ClusterCatalog`s — this cluster runs zero `ClusterExtension`s and they need an entitlement it does not have — which stops the polling, so nothing can leak again; `openshift-community-operators` stays Available. **Remaining, user-run once:** `oc -n openshift-operator-controller delete pod operator-controller-controller-manager-94b6fb847-c4l9n` — the leaked dirs sit in the pod's emptyDir and the 4.21 build has no orphan sweep, so only a pod restart returns the ~42 GiB and clears the Ceph warning.
