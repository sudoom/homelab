# Descheduler: does it work, can we watch it, and moving to the operator

The cluster has run the upstream descheduler as a vendored hourly CronJob since the security-hardening work
(`components/cluster-config/descheduler/`, image `registry.k8s.io/descheduler/descheduler:v0.36.0`, two profiles:
`AffinityAndTaints` and `LoadBalancing` = `LowNodeUtilization` with hand-tuned thresholds). These notes start
with a plain question — does it actually do anything? — and follow it to tracking its rebalancing over time and to
replacing the CronJob with the Kube Descheduler Operator from `okderators`.

## 2026-10-23 — does it work?

All reads with the readonly kubeconfig.

```bash
oc -n kube-descheduler get cronjob descheduler \
  -o jsonpath='suspend={.spec.suspend} lastSchedule={.status.lastScheduleTime} lastSuccess={.status.lastSuccessfulTime}{"\n"}'
# suspend=false lastSchedule=2026-10-23T21:00:00Z lastSuccess=2026-10-23T21:00:04Z
oc -n kube-descheduler get jobs,pods -o wide
# job.batch/descheduler-29879820   Complete   1/1   4s   ...   registry.k8s.io/descheduler/descheduler:v0.36.0
oc -n kube-descheduler logs descheduler-29879820-wtr9t
```

44 log lines, 0 errors. The decisions:

```
"Total number of evictions/requests" extension point="Deschedule" evictedPods=0 evictionRequests=0   (x3)
"Node has been classified" ... category="overutilized" node="node4.okd.sudops.pl" usagePercentage={"cpu":74,"memory":31,"pods":36}
"Node has been classified" ... category="overutilized" node="node6.okd.sudops.pl" usagePercentage={"cpu":72,"memory":26,"pods":49}
"Node is appropriately utilized" ... node="node5.okd.sudops.pl" usagePercentage={"cpu":69,"memory":21,"pods":32}
"Number of underutilized nodes" ... totalNumber=0
"No node is underutilized, nothing to do here, you might tune your thresholds further"
"Number of evictions/requests" totalEvicted=0 evictionRequests=0
```

So it runs, and it correctly does nothing:

- `AffinityAndTaints`: no pod violates node affinity, taints or inter-pod anti-affinity.
- `LowNodeUtilization` classifies on pod **requests** against node allocatable, not real usage. A node is
  underutilized only when cpu < 55 **and** memory < 25 **and** pods < 30 %. node5 sat at 46 % CPU requests when
  the thresholds were tuned (2026-05-21); it has filled up since, so there is nowhere to move pods to. In practice
  the balancer now acts only when a node empties, i.e. after a reboot.

Evidence that it acts when it should: on 2026-09-25, after the node-dhcp rollout drains, the 19:00 run evicted five
logging pods from node4 (`blog/blog-node-dhcp-draft.md`).

What it never does: move a pod with a PVC (`ignorePvcPods: true`, so CNPG, Loki ingesters, Prometheus and the media
stack stay put; the media packing on node6 was fixed with spread constraints instead,
`blog/blog-hdd-tier-rollout-draft.md`), react to real load, or act on pod-count imbalance alone (node6 123 pods vs
node5 80 at the time).

History is thin: the CronJob keeps one successful Job, eviction events expire within hours
(`oc get events -A --field-selector reason=Descheduled` returned nothing), and Loki keeps 3 days. The job logs at
`--v=2`, so each eviction leaves an `"Evicted pod"` line with pod, node and strategy:

```
{kubernetes_namespace_name="kube-descheduler"} |= "Evicted pod"
```

## 2026-10-23 — tracking the rebalancing (design)

The goal: one dashboard where a node reboot, the evictions that follow and the nodes evening out afterwards sit on
one time axis.

The first design kept the vendored chart and turned the CronJob into a one-replica Deployment with
`--descheduling-interval=1h`, plus a Service and ServiceMonitor, because a 4-second Job is never scraped. The
metric exists upstream (`metrics/metrics.go` at v0.36.0):

```
descheduler_pods_evicted_total{result, strategy, profile, namespace, node}
```

The metrics port is 10258, HTTPS, with no authn/authz delegation (`cmd/descheduler/app/options/options.go`
sets up secure serving only), so the scrape needs TLS but no token.

That design was dropped once the operator turned out to be installable (next section): the operator ships its own
metrics Service, ServiceMonitor, PrometheusRule and Prometheus RBAC, so building the same thing on the vendored
chart would have been thrown away.

## 2026-10-24 — the operator is no longer blocked

The README TODO (2026-09-14) said the move was blocked: the 4.21 index held `v5.4.0-2026-07-13-120312` with
`minKubeVersion: 1.35.0`, and the pipeline's `release-4.21` had no descheduler submodule. Re-checked:

```bash
gh api 'repos/okd-project/okd-operator-pipeline/contents/.gitmodules?ref=release-4.21' --jq .content | base64 -d | grep -A2 deschedul
# [submodule "kube-descheduler/operator"]    branch = release-4.21
# [submodule "kube-descheduler/descheduler"] branch = release-4.21
oc -n openshift-marketplace get packagemanifest -l catalog=okderators -o jsonpath='...'
# okderators default=alpha ch=alpha csv=clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655 minKube=1.33.0 modes=OwnNamespace,SingleNamespace,
```

The bundle also declares `olm.maxOpenShiftVersion: 4.22`, so it does not block the 4.22 hop. The old v5.4.0 build
moved to the `release-4.20` catalog, where a `minKubeVersion` of 1.35 cannot install on OKD 4.20 (Kube 1.33);
a candidate okderators fix, not pursued here.

What the operator (`openshift/cluster-kube-descheduler-operator`, `release-4.21`) changes against the vendored
policy:

- **Thresholds:** only presets, applied to cpu, memory and pods alike — Low 10/30, Medium 20/50, High 40/70
  (`pkg/apis/descheduler/v1/types_descheduler.go`). The vendored 55/25/30 → 70/60/50 cannot be expressed. High is the
  closest; a node emptied by a reboot still falls under 40 on all three.
- **Profiles:** `AffinityAndTaints` is the same three plugins. `LongLifecycle` is `LifecycleAndUtilization` minus its
  first plugin (`PodLifeTime`), i.e. `RemovePodsHavingTooManyRestarts` (threshold 100) + `LowNodeUtilization`
  (`longLifecycleProfile` in `pkg/operator/target_config_reconciler.go`). Restart counts here are cumulative and high
  on some pods, so this needs checking in Predictive mode.
- **Protected namespaces:** the operator collects `kube-system`, `hypershift`, `openshift` and every `openshift-*`
  namespace, and applies them as `LowNodeUtilization`'s excluded namespaces when namespace inclusion is set. With no
  `namespaces` in the CR the generated policy decides; read the ConfigMap it writes before the switch rather than
  inferring it.
- **Dry run still counts:** in `openshift/descheduler` `release-4.21`, `pkg/descheduler/evictions/evictions.go`
  increments `descheduler_pods_evicted_total{result="success"}` before the `if pe.dryRun` branch that only logs
  `"Evicted pod in dry run mode"`. So in `Predictive` mode the counter reports evictions it would have made.
- **Real usage:** the CRD has an experimental `profileCustomizations.devActualUtilizationProfile` (balance on
  Prometheus metrics instead of requests). Not used; noted for later.

## 2026-10-24 — phase 1: operator in Predictive mode + dashboard

Approved order: install the operator in `Predictive` next to the vendored CronJob, build the dashboard on its
metrics, compare across a node reboot, then flip to `Automatic` and delete the vendored chart in one commit.

`components/operators/kube-descheduler/` (root-app entry `kube-descheduler-operator`, wave 1):

- Namespace `openshift-kube-descheduler-operator` (the CSV's suggested namespace), labelled
  `openshift.io/cluster-monitoring: "true"` so the platform Prometheus reads the operator's ServiceMonitor.
- OperatorGroup with `targetNamespaces: [openshift-kube-descheduler-operator]` (OwnNamespace; AllNamespaces is not
  supported by the CSV).
- Subscription `cluster-kube-descheduler-operator`, `okderators`, channel `alpha`, `installPlanApproval: Manual`.
- `KubeDescheduler/cluster` at wave 5: `mode: Predictive`, `deschedulingIntervalSeconds: 3600`,
  `profiles: [AffinityAndTaints, LongLifecycle]`, `profileCustomizations.devLowNodeUtilizationThresholds: High`.

Validation:

```bash
C=components/operators/kube-descheduler
helm lint $C                                   # 1 chart(s) linted, 0 chart(s) failed
helm template kube-descheduler-operator $C -n openshift-kube-descheduler-operator -f $C/values.yaml > kd-render.yaml
# KubeDescheduler has no datreeio schema, so validate it against the upstream CRD:
gh api 'repos/openshift/cluster-kube-descheduler-operator/contents/manifests/kube-descheduler-operator.crd.yaml?ref=release-4.21' \
  --jq .content | base64 -d > kd-crd.yaml
yq -o json '.spec.versions[0].schema.openAPIV3Schema' kd-crd.yaml > kdschema/kubedescheduler-operator-v1.json
kubeconform -strict -summary -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
  -schema-location 'kdschema/{{.ResourceKind}}-operator-{{.ResourceAPIVersion}}.json' kd-render.yaml
# Summary: 4 resources found in 1 file - Valid: 4, Invalid: 0, Errors: 0, Skipped: 0
```

`oc diff` adds nothing here: the namespace and the CRD do not exist yet, so every object is new.

Dashboard `Descheduler` (uid `descheduler`, `components/cluster-config/grafana-config/files/descheduler.json`,
folder `metrics`):

- Balance per node, the numbers the descheduler decides on, with lines at 40 and 70 %:
  `100 * sum by (node) (kube_pod_container_resource_requests{resource="cpu"} * on (namespace, pod) group_left () max by (namespace, pod) (kube_pod_status_phase{phase=~"Pending|Running"} == 1)) / sum by (node) (kube_node_status_allocatable{resource="cpu"})`,
  the same for memory, and pods as `count by (node) (kube_pod_info{node!=""} * …) / kube_node_status_allocatable{resource="pods"}`.
- Evictions per hour by node and by strategy (`increase(descheduler_pods_evicted_total{result="success"}[1h])`),
  a table by namespace and strategy over the range, and failed evictions.
- Annotations: node reboots (`changes(node_boot_time_seconds[10m]) > 0`) and hours with evictions.

The PromQL was not run before commit: reading Prometheus through the break-glass kubeconfig was refused in this
session. The check is the dashboard itself after sync — the balance panels should match the descheduler's own
21:00Z figures above (node4 74/31/36, node5 69/21/32, node6 72/26/49) within a few points.

## 2026-10-24 — phase 1 live: what the operator actually generated

The InstallPlan was approved by hand (`install-nbl8w`, one CSV: `clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655`).
CSV `Succeeded`, app `kube-descheduler-operator` Synced/Healthy, `KubeDescheduler/cluster` at
`mode=Predictive profiles=["AffinityAndTaints","LongLifecycle"]` with every `*Degraded=False`. The operator created
`deployment/descheduler`, `deployment/descheduler-operator`, `service/metrics`, `servicemonitor/kube-descheduler`
(port `https`, serverName `metrics.openshift-kube-descheduler-operator.svc`), `prometheusrule/descheduler-rules`
and `configmap/cluster` (the policy). The PrometheusRule holds only recording rules (`descheduler:nodeutilization:*`,
`descheduler:node:actuation_priority:*`, …) for the actual-utilization profile; no alerts.

The generated policy, read instead of inferred:

```bash
oc -n openshift-kube-descheduler-operator get cm cluster -o jsonpath='{.data.policy\.yaml}' > kd-policy.yaml   # 477 lines
yq '.profiles[] |= (.pluginConfig[] |= del(.args.namespaces) | .pluginConfig[] |= del(.args.evictableNamespaces))' kd-policy.yaml
```

- `AffinityAndTaints`: the same three plugins as the vendored profile (`RemovePodsViolatingInterPodAntiAffinity`,
  `RemovePodsViolatingNodeTaints`, `RemovePodsViolatingNodeAffinity` with `requiredDuringSchedulingIgnoredDuringExecution`).
- `LongLifecycle`: `RemovePodsHavingTooManyRestarts` (`podRestartThreshold: 100`, `includingInitContainers: true`) and
  `LowNodeUtilization` with `thresholds` 40/40/40 and `targetThresholds` 70/70/70 (cpu/memory/pods).
- `DefaultEvictor` in both: `ignorePvcPods: true`. **No `nodeFit`** — the vendored policy set `nodeFit: true`.
- **Every one of the five plugins excludes 77 namespaces**: `kube-system`, `hypershift`, `openshift`, and every
  `openshift-*` namespace that existed when the operator started — including `openshift-logging`, `openshift-gitops`,
  `openshift-monitoring`, `openshift-adp`, `openshift-nmstate`. The list is built once at operator start
  (`NewTargetConfigReconciler`), so an `openshift-*` namespace created later is not on it until the operator restarts.

That last point is the main behavioural difference from the vendored job. The only eviction on record, 2026-09-25,
was five logging pods in `openshift-logging`; under the operator's defaults those pods are protected and would stay
on node4. What is left evictable is the non-`openshift-*` workloads without PVCs. The CR's `profileCustomizations.namespaces`
(`excluded`/`included`) replaces that list, which is a decision for the switch, not for now. **Wrong — corrected in the next-but-one section: the list cannot be lifted.**

First Predictive run, 0 errors in 51 log lines:

```
"Total number of evictions/requests" extension point="Deschedule" evictedPods=0 evictionRequests=0   (x4)
"Node has been classified" ... category="overutilized" node="node6.okd.sudops.pl" usagePercentage={"cpu":72,"memory":26,"pods":50}
"Node has been classified" ... category="overutilized" node="node4.okd.sudops.pl" usagePercentage={"cpu":74,"memory":31,"pods":36}
"Node is appropriately utilized" ... node="node5.okd.sudops.pl" usagePercentage={"cpu":70,"memory":22,"pods":32}
"Number of underutilized nodes" ... totalNumber=0
"Number of evictions/requests" totalEvicted=0 evictionRequests=0
```

Same classification as the vendored job's 21:00Z run within a point, and `RemovePodsHavingTooManyRestarts` would
evict nothing today.

## 2026-10-24 — dashboard checked, one label fix

The first look at the synced dashboard settled the untested PromQL: the right edge of the three balance panels reads
node4 74/31/36, node5 70/22/32, node6 72/26/50 (cpu/memory/pods requested %), the same as the descheduler's own log.
The 7-day view also shows the history the CronJob never kept: node6 near 87 % CPU requests and node5 near 55 % until
10-20, all three between roughly 70 and 77 % since.

The eviction panels read "No data", which is expected with no evictions so far but cannot be told apart from a
broken scrape. The scrape plumbing is in place (`role/prometheus-k8s` + `rolebinding/prometheus-k8s` for
`openshift-monitoring/prometheus-k8s`, endpoint ready on 10258, `service.beta.openshift.io/serving-cert-secret-name:
kube-descheduler-serving-cert`), and the dashboard now says so itself: two stats at the top, `Metrics collected`
(`max(up{namespace="openshift-kube-descheduler-operator", service="metrics"})`) and `Runs (last 2h)`
(`sum(increase(descheduler_loop_duration_seconds_count[2h]))`); the eviction panels show "No evictions" when empty.

Reading the operator's ServiceMonitor found a label trap:

```yaml
metricRelabelings:
- action: replace
  sourceLabels: [exported_namespace]
  targetLabel: pod_namespace
```

`descheduler_pods_evicted_total` carries the evicted pod's namespace as `namespace`, which collides with the
target's own `namespace` label; Prometheus keeps the target's (`openshift-kube-descheduler-operator`) and renames
the metric's to `exported_namespace`, which the ServiceMonitor copies to `pod_namespace`. The table grouped
`by (namespace, strategy)` would have put every eviction under the descheduler's own namespace; it now groups
`by (pod_namespace, strategy)`.

## 2026-10-24 — what each policy may actually move (and a correction)

Asked whether to switch to `Automatic` now. Before answering, I counted what each policy is allowed to evict instead
of waiting days in Predictive for a reboot nobody has scheduled. The script applies the `DefaultEvictor` rules both
policies share — Running, controller-owned, not a DaemonSet, not static, priority below system-critical (2e9), no PVC
(`ignorePvcPods`), no emptyDir/hostPath (`evictLocalStoragePods: false`) — then the operator's namespace protection on
top (`scratchpad/evictable.py`, fed by `oc get pods -A -o json`):

```
pods: 355 blocked by: {'local-storage': 24, 'not-running': 58, 'pvc': 26, 'system-critical': 108, 'daemonset': 72, 'bare': 12, 'static': 24}
vendored evictable per node: {'node4': 7, 'node5': 23, 'node6': 1} total 31
operator evictable per node: {'node5': 11} total 11
operator evictable by namespace: {'cert-manager': 3, 'cnpg-system': 1, 'grafana': 1, 'hcloud-exporter': 1, 'mikrotik-exporter': 1, 'nmstate': 1, 'rook-ceph': 1, 'shelly-exporter': 1, 'truenas-exporter': 1}
evictable only under vendored (openshift-*): {'openshift-gitops': 3, 'openshift-logging': 9, 'openshift-marketplace': 4, 'openshift-network-diagnostics': 1, 'openshift-operators': 1, 'openshift-operators-redhat': 1, 'openshift-user-workload-monitoring': 1}
```

It is an estimate (PDBs and the balancer's own capacity checks cut further), but the shape is clear: the operator
can touch about a third of what the vendored job can, and today none of it sits on the two overutilized nodes.

**Correction.** The previous section said `profileCustomizations.namespaces` replaces the protected list. It does
not. The CRD: "Namespaces overrides included and excluded namespaces while keeping the default exclusion of all
openshift-*, kube-system and hypershift namespaces". The reconciler (`release-4.21`, around line 1319) starts
`excludedNamespaces` from the protected list and appends `excluded` to it, and an `included` entry that is protected
fails with "Protected namespace %v included. It is forbidden to include any of the protected namespaces". So under
the operator, pods in `openshift-*` namespaces are never evicted, by design.

## 2026-10-24 — switch to Automatic, vendored chart removed

Gate before switching: the operator's metrics actually collected. The dashboard first read "not scraped", while
every piece of plumbing checked out (namespace label, Service `app: descheduler` matching the ServiceMonitor,
`role/prometheus-k8s` for services/endpoints/pods, Endpoints `10.129.1.156` port `https:10258`, both Prometheus
replicas logging `config=serviceMonitor/openshift-kube-descheduler-operator/kube-descheduler/0` at 22:12:55Z,
no `forbidden` in their logs, `serviceDiscoveryRole: Endpoints`). Observe → Targets showed
`https://10.129.1.156:10258/metrics` **Up**, 15.6 ms, and a refresh turned the stat to "yes" — it had been timing.
`Runs (last 2h)` reads 0 until the second loop: the first ran at pod start, before the first scrape.

Decision: switch, accepting the operator's scope (11 evictable pods vs the vendored 31, never `openshift-*`), for
the metrics, OLM-managed upgrades and the supported 4.22 path.

One commit:

- `components/operators/kube-descheduler/values.yaml`: `mode: Automatic`.
- `components/cluster-config/descheduler/` deleted and its root-app entry removed. Child Applications carry
  `resources-finalizer.argocd.argoproj.io` and root-app has `prune: true`, so the prune cascades: the CronJob, its
  RBAC, the policy ConfigMap and the `kube-descheduler` namespace go with the Application, and the two descheduler
  never run side by side.
- README: layout line and the TODO removed (shipped); the two older TODO items that called the descheduler
  "broken for 4.21" now say it was fixed upstream. CLAUDE.md and the dashboard text say `Automatic`.

## 2026-10-29 — why no evictions after the 4.22 hop

The dashboard shows CPU requested at node4 88.7%, node5 89.2%, node6 38.9% since the hop on 10-27 (all three were
about 70-75% before), and zero evictions. node6 was drained last in the hop (drain complete 18:03:40Z); its pods
went to node4 and node5 and nothing moved back.

The descheduler sees it. The 11:49:59Z run (`oc -n openshift-kube-descheduler-operator logs deploy/descheduler`):

```
"Node has been classified" category="underutilized" node="node6..." usagePercentage={"cpu":39,"memory":13,"pods":26}
"Node has been classified" category="overutilized"  node="node4..." usagePercentage={"cpu":89,"memory":35,"pods":46}
"Node has been classified" category="overutilized"  node="node5..." usagePercentage={"cpu":89,"memory":31,"pods":50}
"Total number of evictions/requests" extension point="Balance" evictedPods=0 evictionRequests=0
```

It finds nothing it may evict. Every running pod on node4 and node5, classified with the policy's own rules (the
`LowNodeUtilization` `evictableNamespaces.exclude` list from the `cluster` ConfigMap, then `DefaultEvictor` with
`ignorePvcPods: true` and the default protections):

| Blocked by | Pods | CPU requested |
|---|---|---|
| excluded namespace (`openshift-*`, kube-system) | 192 | 18.1 cores |
| system-critical priority (Rook OSD/mon/mgr/CSI) | 9 | 5.65 |
| PVC | 16 | 1.6 |
| emptyDir/hostPath | 12 | 1.4 |
| DaemonSet | 8 | 0.7 |
| evictable | 0 | 0 |

The same shape as the 10-24 estimate ("none of it sits on the two overutilized nodes"). The imbalance is the Loki
stack: 3.4 cores of requests on node4 and 3.4 on node5, none on node6 (2.25 cores per node of that in the stateless
querier, query-frontend, gateway and distributor). `openshift-logging` is protected by the operator, so the
descheduler cannot move it whatever the profile. The planned logging removal (README TODO) takes those requests away
altogether. Until then the only way to rebalance is deleting pods by hand.

## 2026-11-02 — kube-apiserver restarts during a build; what system CPU really uses

The console showed all three `kube-apiserver` pods created within seven minutes while the OADP 1.6 build ran on node6, which
looked like starvation. It was not:

```
restartCount 0 on every container; created 21:02:45 (node5), 21:05:47 (node6), 21:09:44 (node4)
revision-status-129 2026-11-02T20:56:36Z optional secret/encryption-config has changed
revision-status-130 2026-11-02T21:06:24Z optional secret/encryption-config has changed
encryption-key-openshift-kube-apiserver-21 2026-10-12T19:53:18Z
                                        22 2026-10-19T20:14:20Z
                                        23 2026-10-26T20:35:26Z
                                        24 2026-11-02T20:56:30Z
```

`apiserver/cluster` uses `aescbc`, and the operator rotates the key every seven days, so a rolling restart lands on Monday
evening each week. Two revisions mean up to six static pod restarts. It lined up with the build by chance.

The question behind it was still fair, so I measured (`/stats/summary` per node, metrics API per pod, CPU in cores, at minimum
clock):

```
        node cpu   pods   non-pod   non-pod mem GiB
node4     6.74     4.45     2.29        1.9
node5     6.65     4.96     1.69        0.9
node6    14.58    12.96     1.62        3.0     okd-build 11.57 of its limit 14

node4 requests 13.8: openshift+kube 8.9 (used 3.7), rook-ceph 3.4 (used 0.4), apps 1.4 (used 0.4)
node5 requests 13.7: openshift+kube 9.2 (used 4.4), rook-ceph 3.5 (used 0.3), apps 1.0 (used 0.2)
node6 requests  8.2: openshift+kube 3.5 (used 2.6), rook-ceph 2.3 (used 0.2), okd-build 2.0, apps 0.4
```

The 3 GiB memory reservation holds. CPU has only the 500m default against 1.6 to 2.3 cores of real use. Raising it costs real
capacity on node4/5, which are nearly full by requests, and it means a reroll, so it is a README TODO to do with the image-GC
KubeletConfig. I could not read CPU pressure or etcd latency myself, because the classifier refuses `oc exec` reads, so the
operator ran the queries (21:14:45Z, 10 minute window, during the build and the apiserver rollout):

```
etcd WAL fsync p99 s       node6 0.049   node4 0.006   node5 0.004
etcd backend commit p99 s  node6 0.043   node4 0.007   node5 0.003
apiserver GET/LIST p99 s   node6 0.791   node4 0.191   node5 0.089
CPU PSI: no series
alerts other than the standing ones: none
```

etcd on the build's node is about ten times slower than on the other two, past etcd's usual 10 ms guidance for fsync but far
below `etcdHighFsyncDurations`, and no alert fired. The apiserver figures are muddied because every apiserver restarted inside
that window. So the build has a visible cost on node6 and has done no harm so far. It keeps running; the next round, if there
is one, gets a CPU limit of 10 instead of 14. This is a single reading.

## 2026-11-02 — planning the operator upgrade to 5.4: recon, nothing built

`ClusterVersion` reads `Upgradeable=False`, because the installed `clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655` caps
at 4.22. The operator asked to start planning while the OADP 1.6 build runs. These are the findings; the design calls in the
local spec and 12-task plan are mine and not approved. All read-only.

- **No catalog a 4.22 cluster reaches offers anything newer.** `release-4.21` and `release-4.22` hold one entry, that 5.3.0.
  `release-4.20` holds 5.4.0-2026-07-13. `release-5.0` has no descheduler.
- **Nothing has ever built from pipeline `release-4.22`.** `kube-descheduler-deploy.yaml` there triggers on `main`, and without a
  `catalog_branch` the deploy defaults to catalog `release-4.21`. All the runs: `main` success 07-13, `main` failure 09-23,
  `release-4.21` success 10-12. The September failure was `Checkout catalog index` in the catalog-PR job; the build itself passed
  and pushed `5.4.0-2026-09-23-131400`.
- **The range does not reach our install.** `5.3.0-2026-10-12-113655` is a prerelease below `5.3.0`. Walker on a synthetic
  head: Red Hat's `>=5.3.0 <5.4.3` alone, stranded; `>=5.3.0-0` alone, two heads; `replaces`, PASS.
- **The cap.** `build.sh` sets it to the OKD minor + 1. In OLM's `release-4.22` code (`helpers.go:123-176`) the check compares against
  the next minor and `normalizeOCPVersion` maps 4.23 to 5.0, so a 4.23 cap clears `Upgradeable` on 4.22. On a 5.0 cluster that
  same cap would block 5.0 → 5.1. Source reading; the upgrade checks it live.
- **Little changes for this cluster.** CRD and Go types are identical from the installed pin to both heads, the two profiles are
  unchanged in code, `High` is still 40/70, and both dashboard metrics survive. Operand v0.34 → v0.35. `minKubeVersion` goes to
  1.35.0. New: NetworkPolicy `descheduler-operand`, which admits monitoring on 10258. The operand restarts and runs a loop at once
  on upgrade, so that loop's evictions get read.
- **Proving eviction.** The operand evicted little lately (0 in the latest run, 9 since 10-27), so silence proves nothing. The plan
  uses a scratch pair of Deployments: label the anchor pod so `victim` starts violating its required pod anti-affinity, and
  `AffinityAndTaints` must evict it. On 5.3 first, then on 5.4. No node label changes, because those re-apply NNCPs.
- **The 5.0 catalog is the bigger gap.** Catalog `release-5.0` is byte-identical to `main`, the February 2025 catalog: 16 packages,
  five of ours at ancient versions (cert-manager v1.14, loki 5.9), no descheduler or NMState, an old workflow that tags `latest`,
  and no `catalog-index:5.0` on quay. So no 5.0 entry reaches anyone until okderators rebuilds and publishes it, and that goes for
  OADP 1.6 too.

## 2026-11-02 — the plan's review: the operand rolls every Monday, and the eviction check could pass by accident

An independent review of the plan found two things worth keeping beyond the plan. Both read-only.

**The operand rolled at 21:17:36Z with no change from anyone.** Counters reset (`descheduler_loop_duration_seconds_count 1`), new
ReplicaSet `descheduler-54dc68f9d`, operator pod unchanged since 10-27. The ReplicaSet list gave the shape: the previous one was
2026-10-26T20:56:01Z, also a Monday evening, which is when the `aescbc` key rotates.

```
oc get kubeapiserver cluster -o jsonpath='{range .status.conditions[*]}{.type} {.status} {.lastTransitionTime}{"\n"}{end}' | grep Encryption
EncryptionMigrationControllerProgressing False 2026-11-02T21:17:46Z

oc get cm -A -o jsonpath='{range .items[*]}{.metadata.resourceVersion} {.metadata.creationTimestamp} {.metadata.namespace}/{.metadata.name}{"\n"}{end}'
1169 ConfigMaps, 1169 of them with a resourceVersion in 172349427..172355628; 1108 of those created before 11-01
```

So the weekly key migration rewrites every ConfigMap in the cluster. The operator keeps `configmaps/cluster`'s resourceVersion in
the operand's pod template, sees it move with identical content, and rolls the Deployment (`apps.go:155`, then a loop at once:
21:18:34Z). Five things rolled in that window on both Mondays: console, oauth-openshift, controller-manager,
route-controller-manager, descheduler. OADP did not. This explains nothing being wrong and the counters still looking odd: a
"since 10-27" evictions number from this operand cannot span a Monday without Prometheus.

For the 5.4 work: no eviction check and no soak window across Monday 19:00Z to 23:00Z, loops counted from log timestamps, counter
deltas only within one pod.

**The eviction check as first written could pass without the plugin doing anything.** The design labelled an anchor pod so that
`victim` violates required anti-affinity, and passed on "an evicted line, the counter up, `victim` on another node".

```
descheduler_lownodeutilization_node_classification{node="node4.okd.sudops.pl"} 2
descheduler_lownodeutilization_node_classification{node="node5.okd.sudops.pl"} 2
descheduler_lownodeutilization_node_classification{node="node6.okd.sudops.pl"} 1
lownodeutilization.go:308] "Number of underutilized nodes" ... totalNumber=0
lownodeutilization.go:310] "Number of overutilized nodes" ... totalNumber=2
```

node4 and node5 are over the `High` threshold. Whenever node6 drops under 40%, LowNodeUtilization evicts what it can from them, and
that meets all three criteria with no anti-affinity involved. A `victim` with an `emptyDir` would fail the other way:
`evictLocalStoragePods := false` (`profiles.go:81`) makes it non-evictable. The fix: pass only on the line's strategy, which the
log and the counter both carry (`evictions.go:615`, `metrics.go`):

```
klog.V(1).InfoS("Evicted pod", "pod", ..., "reason", ..., "strategy", opts.StrategyName, "node", ..., "profile", ...)
```

`strategy="RemovePodsViolatingInterPodAntiAffinity"` passes; any other strategy on either pod invalidates the run. `anchor` is pinned
to node6 by required node affinity on the hostname label that exists already, and `victim` sits beside it by preferred pod affinity
only, with no volume that would block eviction.

## 2026-11-02 — okderators descheduler 5.4: pins

Task 1 of the Descheduler 5.4 build for okderators: record what the upstream release branches point at today, so the later pipeline submodule pins are not guesses. Nothing touched the cluster.

Clones (partial, no checkout, no submodules), under the gitignored work dir:

```
git clone -q --filter=blob:none --no-checkout https://github.com/okd-project/okd-operator-pipeline pipeline
git -C pipeline remote add fork https://github.com/sudoom/okd-operator-pipeline
git clone -q --filter=blob:none --no-checkout https://github.com/sudoom/okderators-catalog-index catalog-index
git -C catalog-index remote add upstream https://github.com/okd-project/okderators-catalog-index
```

Heads, via `gh api repos/openshift/<repo>/commits/<branch>` and proved with `gh api repos/openshift/<repo>/compare/<branch>...<sha> --jq .status` (all four `identical`); go lines from `contents/go.mod?ref=<sha>`:

| repo | branch | sha | date | go |
|---|---|---|---|---|
| cluster-kube-descheduler-operator | release-4.22 | 1eb4d75fac7d2999e06792c3856bdccb272b1de3 | 2026-10-31 | 1.25.0 |
| cluster-kube-descheduler-operator | release-5.0 | 5c0659fc46ba82ea3f3ab36acd95b19d3847a77e | 2026-10-31 | 1.26.3 |
| descheduler | release-4.22 | 076d0fc5c3e74b76885c07a393f4085a6495da16 | 2026-10-31 | 1.25.0, toolchain go1.25.1 |
| descheduler | release-5.0 | ca28d9e98897d401d38d0886a4341620fe838c4e | 2026-10-31 | 1.26.0 |

CSV at the operator heads: 4.22 is `clusterkubedescheduleroperator.v5.4.3` (version 5.4.3, skipRange `>=5.3.0 <5.4.3`), 5.0 is `v5.4.4`; both have `minKubeVersion: 1.35.0` and `replaces: v5.3.0`. Cluster Kube is 1.35, so the floor is met.

Image slots: `grep RELATED_IMAGE` on the CSV at both heads gives exactly two, `RELATED_IMAGE_OPERAND_IMAGE` and `RELATED_IMAGE_SOFTTAINTER_IMAGE`. `build_bundle()` in `kube-descheduler/build.sh` (identical on pipeline `main` and `release-4.22` apart from one comment) rewrites both, from `IMG_DESCHEDULER` and `IMG_OPERATOR`. No unmapped slot, so nothing blocks.

Catalog (`okd-project/okderators-catalog-index`): `release-4.22` head 98c6d9d54411ed494a13e2a00fd5f76ffb4d82bc, package `cluster-kube-descheduler-operator`, `alpha` channel with one entry, `v5.3.0-2026-10-12-113655`. `release-5.0` head 4daed51b21a8693b3f44feef6eee74fb4bf1c04d has no descheduler package at all. The full table is in the scratch `pins.md`.

## 2026-11-02 — okderators descheduler 5.4: pipeline change

Task 2 of the 5.4 plan: two local branches in my `okd-operator-pipeline` clone, nothing pushed. The clone is blob-less and `--no-checkout`, so I built the commits with plumbing (temporary `GIT_INDEX_FILE`, `git read-tree <base>`, `git update-index --cacheinfo 160000,<sha>,<path>`, `write-tree`, `commit-tree`, `update-ref`) and never checked out a submodule. The pins are the Task 1 table in `work/pins.md`; the two submodule paths are `kube-descheduler/operator` and `kube-descheduler/descheduler` on both bases.

Check first, `work/static-check.sh <tree> <4.22|main>`, reading committed content only. Five items: gitlinks equal the pins, `.gitmodules` `branch =` equals the pinned branch, the deploy workflow's push branch (and on 4.22 `catalog_branch: release-4.22`), `operator-deploy.yaml` declares and forwards `catalog_branch`, and each builder's Go (the `go-toolset:<major.minor>` tag in the Containerfile) is at least the pinned `go.mod` `go` line.

RED, against the unchanged bases:

    static-check origin/release-4.22 (4.22): FAIL (2 checks)
      [1] operator tree=7e5dc356... pin=1eb4d75f...; descheduler tree=f4ce79db... pin=076d0fc5...
      [3] push branches: [main], expected [release-4.22]; no 'catalog_branch: release-4.22'
    static-check origin/main (main): FAIL (1 checks)
      [1] operator tree=a24b583c... pin=5c0659fc...; descheduler tree=75b22cea... pin=ca28d9e9...

The Go check passes on both bases (4.22 builds with go-toolset:1.25 against go 1.25.0 / go1.25.1, main with 1.26 against 1.26.3 / 1.26.0), so it had to be shown able to fail: with a copy of `pins.md` whose go lines are raised to 1.27.x (`PINS=... static-check.sh`) it reports `operator.Containerfile: builder Go 1.25 < pinned go.mod go 1.27.0` and, with only the descheduler row raised, `descheduler.Containerfile: builder Go 1.26 < pinned go.mod go 1.27.0`. It compares major.minor only, because the toolset tag floats; whether the 1.26 image has reached patch 1.26.3 shows only in the build.

Edits and commits:

- `descheduler-5.4` from `origin/main` (25981072): `[kube-descheduler] Update to the release-5.0 heads`, the two gitlinks to `5c0659fc` (operator) and `ca28d9e9` (descheduler).
- `descheduler-5.4-4.22` from `origin/release-4.22` (8ab81e0): `[kube-descheduler] Update to the release-4.22 heads` (`1eb4d75f`, `076d0fc5`), then `[kube-descheduler] Deploy from release-4.22 to catalog release-4.22`: in `.github/workflows/kube-descheduler-deploy.yaml` the push branch `"main"` becomes `"release-4.22"` and `with:` gains `catalog_branch: release-4.22`. That is the shape release-4.21 already uses for the trigger; `operator-deploy.yaml` already has the `catalog_branch` input (default `release-4.21`), so it needs no change.

`.gitmodules` needed nothing: both bases already say `branch = release-4.22` / `release-5.0` for the two stanzas, the same branch as the pin (and the build resets to the gitlink anyway). `build.sh` and the Containerfiles are untouched: `build.sh` has no builder image of its own, and the bundle mapping for the two RELATED_IMAGE slots was checked in Task 1.

GREEN:

    static-check descheduler-5.4-4.22 (4.22): PASS   (5 of 5)
    static-check descheduler-5.4 (main): PASS        (5 of 5)
    bash -n kube-descheduler/build.sh: ok on both

Diffstat against each base: `origin/main..descheduler-5.4` is `kube-descheduler/descheduler`, `kube-descheduler/operator` (2 files, 2+/2-); `origin/release-4.22..descheduler-5.4-4.22` is those two plus `.github/workflows/kube-descheduler-deploy.yaml` (3 files, 4+/3-).

## 2026-11-02 — the 5.0 catalog raised upstream

The operator decided the unpublished catalog gets its own issue rather than a line in a PR:
[okderators-catalog-index #62](https://github.com/okd-project/okderators-catalog-index/issues/62). Rebuilding the catalog stays
outside the descheduler work. Checked before filing:

```
gh api repos/okd-project/okderators-catalog-index/compare/main...release-5.0 --jq .status
identical
skopeo inspect --no-tags docker://quay.io/okderators/catalog-index:5.0
... reading manifest 5.0 in quay.io/okderators/catalog-index: manifest unknown
```

`release-5.0` last moved 2025-02-26 and holds 16 packages against 35 on `release-4.22`. Its `deploy-catalog.yml` runs on pushes to
`main` and tags `latest`, so merging into that branch would publish nothing even if a catalog PR landed there. `latest` is no longer
on quay either. No PR has ever targeted the branch.

## 2026-11-02 — okderators descheduler 5.4: the build Job

Nothing ran on the cluster for this; the Job exists and is proven against fixtures, Task 4 starts it. `tests/okderators-descheduler-build/` holds `build.sh`, `catalog-edit.sh`, `catalog-walk.py`, `catalog-branches.tsv`, `job-template.yaml`, `kustomization.yaml`, `log-reader.yaml` and the README.

The shape is the other build Jobs': one Job per run, `descheduler-build-<MODE>-<DATE>`, `MODE` `full` or `catalog`, a privileged podman pod in `okd-build` on PVC `build-storage`, the shared `flock` on `/work/.lock`, the same contract lines (`STEP`, `DISK`, `PUSHED`, `CHECK`, `RESULT`), the registry guard, log files on the PVC, a new `DATE` per run. CPU limit 10. `PRUNE` as in OADP's Job, for a retry after a failed round. `MODE=full` runs:

```
tools podman-setup prune clone tag-check init pins build_containers image-smoke push_containers build_bundle verify deinit
```

A table in `build.sh` holds what differs by pipeline branch, and a branch with no row ends the run before anything starts:

```
descheduler-5.4-4.22 4.22 1eb4d75f... 076d0fc5... v20260219-v0.35.0 4.23 1.35.0
descheduler-5.4      5.0  5c0659fc... ca28d9e9... v20260520-v0.36.0 5.1  -
```

The columns are OKD release, operator pin, descheduler pin, operand version, `olm.maxOpenShiftVersion`, `minKubeVersion` (`-`: recorded, nothing required). The operand version is what the descheduler's Makefile stamps at the pin through `GO_LD_EXTRAFLAGS`, which is what the binary reports; `go.mod` at the same pins says v0.35.1 and v0.36.1.

The checks: `submodule-pins` right after `init`, read from `git submodule status` because its first column shows a submodule that never checked out. `image-smoke` and `operand-version` before the push, so a broken image takes no space in zot. After the bundle is pushed: `bundle-objects`, `no-redhat-registry`, `csv-name`, `images-by-digest`, `max-ocp`, `min-kube`, `operator-sdk-validate`. `RESULT PASS` needs a `PASS` line for each.

`MODE=catalog` adds the entry on `release-4.22` (`replaces` the 5.3.0, `skipRange: '>=5.3.0-0 <5.4.0-<DATE>'`) and creates the package on `release-5.0`, the way the pipeline's `scripts/update-catalog-package.sh` creates one, with the same `skipRange` and no `replaces`. A `NONE` row that finds the package stops that branch. Both 5.4 bundles are named `5.4.0-<DATE>`, so `bundle-<branch>` tells them apart by the cap, and pasting them the wrong way round stops before any clone.

Where I left the prior art, and why:

- **OADP's skeleton, not NMState's.** The plan named NMState's `build.sh` as the base. Its associative arrays and namerefs do not run on the Mac's bash 3.2, and the fixtures have to source the file. OADP's `var`, `digest_of` and file-based `VARS` do. The contract, lock, guard and log code are the same in both.
- **Walker `--hop` removed.** Nothing passes it. The walker's code is otherwise OADP's copy; the docstring also lost an OADP example.
- **Go, kustomize and `make` dropped from the pod's tools.** The compilers run inside the Containerfiles, and `build_bundle()` edits the committed manifests with `yq`. I read `common.sh` and `kube-descheduler/build.sh` on both branches: neither calls them. The git committer identity went too, because there is no `kube-descheduler/patches` for `git am`.
- **`catalog_required` added.** `MODE=catalog` cannot end `RESULT PASS` with a per-branch check skipped. It asks for `fresh-head-<branch>` on a `NONE` row and the two negative controls on the others.

The first version of `bundle-objects` had a hole that review caught. The plan asks for the comparison with the pin to cover "anything new such as NetworkPolicy RBAC", and I read that as a new manifest file, and proved it with a `rbac.yaml` ClusterRole I invented. Neither pin has such a file. `manifests/` holds only the CSV and the CRD at both heads, and the rule is inside the CSV, in `spec.install.spec.clusterPermissions` (and `permissions` on `release-5.0`). So a CSV with the rule deleted passed every check. This matters most on `main`, whose bundle gets no live run in this plan. The check now compares both blocks with the pin's CSV (`yq -o=json`, both through `jq -S`), and the invented fixture is gone. Before the change, against the committed check:

```
WRONG 4.22: the networkpolicies rule deleted               want FAIL got [PASS]
WRONG main: the networkpolicies rule deleted               want FAIL got [PASS]
WRONG main: the permissions block deleted                  want FAIL got [PASS]
units: 88 as expected, 10 wrong
```

After it, on the real `build_bundle()` output at both pins, and with the rule deleted. `build_bundle()` does not touch those blocks, so nothing had to be loosened:

```
descheduler-5.4-4.22: CHECK bundle-objects PASS the pin's list exactly: ...; RBAC as the pin's: 22 clusterPermissions rules, 0 permissions rules
descheduler-5.4:      CHECK bundle-objects PASS the pin's list exactly: ...; RBAC as the pin's: 26 clusterPermissions rules, 3 permissions rules
main, rule deleted:   CHECK bundle-objects FAIL the CSV's clusterPermissions and permissions differ from the pin's (< pin, > bundle): < }, < { < "apiGroups": [ < "networking.k8s.io" < ], < "resources": [;
```

The fixtures are scratch, outside the repo. `make-fixture.sh` runs the fork branch's real `kube-descheduler/build.sh build_bundle` (real yq v4.54.1, stubbed podman, skopeo and oc) over each operator pin's real `manifests/` and `metadata/`, and the real opm v1.74.0 renders the result. The end-to-end run is the real `main` of `build.sh` over both fork tips (5b6ca6b, 2b7c850), and its `submodule_status` comes from their real gitlinks, so a pass also shows the table's pins equal them. The catalog runs use the real upstream `release-4.22` (98c6d9d) and `release-5.0` (4daed51). Every check has a fixture that makes it fail.

```
./run-all.sh
units:    units: 98 as expected, 0 wrong
git:      git units: 10 as expected, 0 wrong
e2e 4.22: e2e: 84 as expected, 0 wrong
e2e main: e2e: 84 as expected, 0 wrong
catalog:  catalog: 181 as expected, 0 wrong
```

From the catalog run, on the real trees:

```
CHECK negative-control-no-edge-release-4.22 PASS without replaces and skipRange: two heads [...v5.3.0-2026-10-12-113655 ...v5.4.0-2026-11-02-120000], ...v5.3.0-2026-10-12-113655 stranded with the rest [...]; opm validate refuses it
CHECK negative-control-replaces-only-release-4.22 PASS with only replaces opm validate passes and the walker reports stranded: ...v5.4.0-2026-11-01-120000
CHECK fresh-head-release-5.0 PASS ...v5.4.0-2026-11-02-120000 is the channel's one entry and single head, no replaces
CHECK edit-release-4.22 FAIL d.tsv says release-4.22 has no package, but catalog/cluster-kube-descheduler-operator/ exists: read the branch again and fix the row
4.22 entry reads back: clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655 >=5.3.0-0 <5.4.0-2026-11-02-120000
5.0 entry reads back: none >=5.3.0-0 <5.4.0-2026-11-02-120000
```

A bare `>=5.3.0` strands the installed `5.3.0-2026-10-12-113655`, which sits below it in semver; the walker shows that on a hand-made catalog, and it is why the range starts at `-0`. The manifests validate locally, without touching the cluster:

```
kubectl kustomize tests/okderators-descheduler-build/ | kubeconform -strict -ignore-missing-schemas -summary
Summary: 1 resource found parsing stdin - Valid: 1, Invalid: 0, Errors: 0, Skipped: 0
KUBECONFIG=/dev/null oc process --local -f tests/okderators-descheduler-build/job-template.yaml -p MODE=full -p PIPELINE_BRANCH=descheduler-5.4-4.22 -p DATE=2026-11-02-120000 -o yaml
(items[0], and the same for MODE=catalog) Summary: 2 resources found in 2 files - Valid: 2, Invalid: 0, Errors: 0, Skipped: 0
```

What stays stubbed until Task 4, so none of it is proven yet:

- `operator-sdk-validate`: no darwin binary here, so its pass and its failures are stub output. The check itself is the code the other Jobs run.
- Real `podman run` of both images: the stub's help text and version line are what I read in the sources at the pins (`cmd.Short`, the cobra `Long`, `fmt.Printf("Descheduler version %+v\n", version.Get())`). If the real binaries differ, the run fails before any push, which costs a build round and no bad image.
- `oc adm release info`, which `common.sh` runs at source time.
- The real skopeo layout: `bundle_extract`'s copy to a `dir:` layout and its layer unpacking, and digests from a real registry.
- Real `init` and `deinit`: the submodule clones. `submodule-pins` itself ran against real git, on a small pipeline with real submodules.

The zot check stays an operator step before each run, as in the other Jobs: the pod has no token to read the metric with.

## 2026-11-03 — descheduler 5.4: eviction check manifests and the rollback runbook

Before the 5.3 -> 5.4 upgrade I want a check that shows the operand still evicts, on 5.3 first and again on 5.4. Waiting for
LowNodeUtilization is no check: it evicts only when node6 drops under 40%, nine times since 10-27, and not on demand. The
`AffinityAndTaints` profile is on, so I use `RemovePodsViolatingInterPodAntiAffinity` and make a pod violate its own term
(`tests/descheduler-5.4-check/`).

Shape and why:

- `anchor` is pinned to node6 by required node affinity on `kubernetes.io/hostname=node6.okd.sudops.pl`, an existing label (a new node label would re-apply NNCPs). node6 is the node that does not read overutilized, so LowNodeUtilization does not take pods from it, and the anti-affinity plugin looks only at the candidate's own terms, so it never evicts `anchor`.
- `victim` has required anti-affinity against `drill=anchor` and only a preferred (weight 100) affinity to `app=anchor`. At first no pod has `drill=anchor`, so it starts beside `anchor`; after `oc label pod <anchor pod> drill=anchor` it violates the term, and its replacement lands elsewhere because the term is required. The affinity is never a requirement, or the replacement could not schedule at all.
- No volumes, PDB or `priorityClassName`, `automountServiceAccountToken: false`: `emptyDir`, `hostPath` and PVC make a pod non-evictable (`evictLocalStoragePods` false, `ignorePvcPods` on), and a PDB or priority class would be one more thing to explain a missing eviction by.
- The pass condition names the strategy. An eviction of either pod by another strategy (LowNodeUtilization could in principle pick one) invalidates the run, so the log line and `descheduler_pods_evicted_total` must both carry `RemovePodsViolatingInterPodAntiAffinity`, `anchor`'s UID must be unchanged, and the check never runs Monday 19:00Z-23:00Z when the operand rolls and resets log and counters.

Image: the `registry.k8s.io/pause` index by digest, which zot mirrors. Resolved and verified with skopeo (sandbox off):

```
skopeo inspect --raw docker://registry.k8s.io/pause:3.10.2 | shasum -a 256
f548e0e8e3dc1896ca956272154dde3314e8cc4fde0a57577ee9fa1c63f5baf4
skopeo inspect --raw docker://registry.k8s.io/pause@sha256:f548e0e8... | shasum -a 256     # same digest back
skopeo inspect --override-os linux --override-arch amd64 --config docker://registry.k8s.io/pause@sha256:f548e0e8... | grep '"User"'
        "User": "65535:65535"
```

A numeric non-root user, so `runAsNonRoot: true` works under `restricted-v2` with no fixed UID in the manifest.

The chart gains an optional `subscription.startingCSV` for the rollback; OLM ignores it while a CSV is installed, so it matters only after the 5.4 CSV is deleted. It must not change today's render, and it does not (the "before" is the chart at HEAD):

```
helm lint components/operators/kube-descheduler/        1 chart(s) linted, 0 chart(s) failed
cmp before.yaml after.yaml                              (no output: byte-identical, 66 lines)
helm template ... --set subscription.startingCSV=clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655 | diff before.yaml -
66a67
>   startingCSV: clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655
kubeconform -strict -ignore-missing-schemas (chart, with startingCSV set)   Valid: 3, Invalid: 0, Errors: 0, Skipped: 1
kubeconform -strict -ignore-missing-schemas namespace.yaml anchor.yaml victim.yaml   Valid: 3, Invalid: 0, Errors: 0, Skipped: 0
```

The skipped one is the KubeDescheduler CR (no schema in the catalog). The rollback order is in `components/operators/kube-descheduler/README.md`: commit the revert with `startingCSV` first, delete the 5.4 CSV, approve the InstallPlan; the CRD schema is identical; the NetworkPolicy `descheduler-operand` stays behind, so the runbook lists it and leaves the decision. Every mutating command there is marked as the operator's, by prompt. Nothing has been applied to the cluster.

## 2026-11-03 — eviction check on 5.3: PASS

The installed `clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655` evicts a pod that violates required pod anti-affinity,
and the evidence names the plugin, so LowNodeUtilization cannot have produced the pass. Run with `tests/descheduler-5.4-check/`,
Tuesday 06:48Z (outside Monday's rotation window), while the OADP `main` build ran on node6. Each `oc` mutation went by the
operator's permission prompt.

Baseline, read-only, operand pod `descheduler-54dc68f9d-m227g` (started 2026-11-02 21:17:36Z):

```
KUBECONFIG=~/.kube/config-readonly oc get --raw /api/v1/namespaces/openshift-kube-descheduler-operator/services/https:metrics:10258/proxy/metrics
descheduler_loop_duration_seconds_count 10
descheduler_lownodeutilization_node_classification{node="node4.okd.sudops.pl"} 2
descheduler_lownodeutilization_node_classification{node="node5.okd.sudops.pl"} 2
descheduler_lownodeutilization_node_classification{node="node6.okd.sudops.pl"} 1
(no descheduler_pods_evicted_total series)
```

Steps:

```
oc apply -f tests/descheduler-5.4-check/namespace.yaml -f tests/descheduler-5.4-check/anchor.yaml
  anchor-785df79cc-889nq Running node6, UID 6e805e4f-15d4-48ff-b1dd-9135d57579ac, scc restricted-v2, no volumes
oc apply -f tests/descheduler-5.4-check/victim.yaml
  victim-79ffdf8f69-ctwcb Running node6
oc -n descheduler-check label pod anchor-785df79cc-889nq drill=anchor        # 06:54:00Z
```

The next hourly loop, 07:18:34Z:

```
evictions.go:615] "Evicted pod" pod="descheduler-check/victim-79ffdf8f69-ctwcb" reason="" strategy="RemovePodsViolatingInterPodAntiAffinity" node="node6.okd.sudops.pl" profile="AffinityAndTaints"
lownodeutilization.go:313] "No node is underutilized, nothing to do here, you might tune your thresholds further"

descheduler_pods_evicted_total{namespace="descheduler-check",node="node6.okd.sudops.pl",profile="AffinityAndTaints",result="success",strategy="RemovePodsViolatingInterPodAntiAffinity"} 1
descheduler_loop_duration_seconds_count 11

anchor-785df79cc-889nq   Running node6  UID 6e805e4f-15d4-48ff-b1dd-9135d57579ac (unchanged)
victim-79ffdf8f69-xt96d  Running node4
```

All four criteria hold: the line names the anti-affinity strategy, the counter with that strategy went from no series to 1 in
the same operand pod, the replacement runs off node6, and `anchor` kept its UID. Cleanup: `oc delete namespace descheduler-check`.

Two things seen on the way. The pods carry `topology.kubernetes.io/zone: fd-c` as a pod label, added by something at admission;
it plays no part here. And it took 25 minutes from label to eviction only because the loop is hourly; the plugin acted on the
first loop after the label.

## 2026-11-03 — okderators descheduler 5.4: both builds passed on the first round

Task 4 of the plan: the full build from each pipeline branch, run as a one-off Job in `okd-build` (`tests/okderators-descheduler-build/`), each command by the operator's permission prompt. This was the first build ever from pipeline `release-4.22` for this operator (the section "Nothing has ever built from pipeline `release-4.22`" above and the 2026-11-02 build-Job section say why). Both ran with `PRUNE=false`: the shared graph root on the `build-storage` PVC still holds OADP's ~87.6 GB of layers, and an OADP fix found at its upgrade would otherwise mean a ~2.5 h recompile. So the `DISK` lines include OADP's layers and this build's disk is a delta, not its own peak. Gate before each prompt: no other Job in `okd-build` (lock free), no OADP retry pending, zot measured above 5 GiB.

Evidence: `work/build-full-4.22-2026-11-03-074110.txt` and `work/build-full-main-2026-11-03-080630.txt` (scratch, not committed). Both Jobs deleted by prompt once read.

| | `release-4.22` | `main` |
|---|---|---|
| Job | `descheduler-build-full-2026-11-03-074110` | `descheduler-build-full-2026-11-03-080630` |
| `PIPELINE_BRANCH` | `descheduler-5.4-4.22` (5b6ca6b2) | `descheduler-5.4` (2b7c8503) |
| `DATE` | `2026-11-03-074110` | `2026-11-03-080630` |
| `OKD_VERSION` / `OCP_RELEASE` | `4.22.0-okd-scos.2` / 4.22 | `5.0.0-okd-scos.0` / 5.0 |
| script start to `RESULT PASS` | 07:46:19Z, 981 s (16 min 21 s) | 08:13:56Z, 1061 s (17 min 41 s) |
| Job, create to completion | 07:41Z to 08:02:52Z, ~21 min | 08:07:33Z to 08:31:50Z, ~24 min |
| `build_containers` | 740 s | 825 s |
| other steps | init 40 s, image-smoke 30 s, push 15 s, bundle 8 s | init 40 s, image-smoke 4 s, push 12 s, bundle 9 s |
| `RESULT` | PASS full 2026-11-03-074110 | PASS full 2026-11-03-080630 |

The gap between the Job's create time and the script's first `STEP` is the slow pod start (below).

### Checks

All 13 `CHECK` lines PASS on both, no retry round:

| CHECK | `release-4.22` | `main` |
|---|---|---|
| submodule-pins | 2 submodules, HEAD = pin: operator `1eb4d75fac7d`, descheduler `076d0fc5c3e7` | operator `5c0659fc46ba`, descheduler `ca28d9e98897` |
| image-smoke/operator | `--help` exit 0 | same |
| image-smoke/descheduler | `--help` exit 0 | same |
| image-smoke | 2 images each ran their own binary | same |
| operand-version | `v20260219-v0.35.0` | `v20260520-v0.36.0` |
| bundle-objects | CSV + CRD exactly as the pin's list; 22 clusterPermissions rules, 0 permissions rules | CSV + CRD; 26 clusterPermissions rules, 3 permissions rules |
| no-redhat-registry | none in CSV, objects, files, labels | same |
| csv-name | `clusterkubedescheduleroperator.v5.4.0-2026-11-03-074110` | `clusterkubedescheduleroperator.v5.4.0-2026-11-03-080630` |
| images-by-digest | 2 refs under `okd-test/kube-descheduler/`, recorded by this run | same |
| max-ocp | `olm.maxOpenShiftVersion` 4.23 | 5.1 |
| min-kube | 1.35.0 | 1.35.0 (recorded) |
| operator-sdk-validate | v1.36.1: passed, 1 warning, 0 errors | same |

The one warning is both times `found olm.properties annotation, please define these properties in metadata/properties.yaml instead`. The CSV carries `replaces=none` and `olm.skipRange=>=5.0.0 <5.4.0-<DATE>` on both; the catalog edit adds the graph edges (next section).

- **Operand version differs because the submodule pins differ.** `release-4.22` pins the operator and descheduler submodules at upstream `release-4.22` commits, whose descheduler is built as upstream v0.35.0 (`v20260219-v0.35.0`); `main` pins them at `release-5.0` commits carrying v0.36.0 (`v20260520-v0.36.0`). Kube 1.35 on both. The check reads the version out of the built image, not out of a file.
- **Cap.** The cap is the OKD minor + 1: 4.23 on the 4.22 build, 5.1 on the 5.0 build. `min-kube` 1.35.0 on both.
- **RBAC counts.** `bundle-objects` reads them out of the CSV (the NetworkPolicy rules are rules inside the CSV, not objects): the 4.22 build has 22 clusterPermissions rules and no namespaced `permissions`; the 5.0 build has 26 clusterPermissions rules and 3 `permissions` rules.

### Pushed

| ref | digest | bytes |
|---|---|---|
| `okd-test/kube-descheduler/descheduler:5.4.0-2026-11-03-074110` | `sha256:1cef5485` | 111062991 (111 MB) |
| `okd-test/kube-descheduler/operator:5.4.0-2026-11-03-074110` | `sha256:36abd4ba` | 152674119 (153 MB) |
| `okd-test/kube-descheduler/operator-bundle:5.4.0-2026-11-03-074110` | `sha256:83246c48` | 12440 |
| `okd-test/kube-descheduler/descheduler:5.4.0-2026-11-03-080630` | `sha256:1e619028` | 111770357 (112 MB) |
| `okd-test/kube-descheduler/operator:5.4.0-2026-11-03-080630` | `sha256:94fdd2e0` | 215875086 (216 MB) |
| `okd-test/kube-descheduler/operator-bundle:5.4.0-2026-11-03-080630` | `sha256:92c6368b` | 12605 |

Bundle refs in full (these are the `BUNDLES` of the catalog run), under `zot.apps.okd.sudops.pl`:

```
zot.apps.okd.sudops.pl/okd-test/kube-descheduler/operator-bundle:5.4.0-2026-11-03-074110@sha256:83246c48a473079b9b688344e4ee2f94fac8947eeedc590de8a593bdfa11b937
zot.apps.okd.sudops.pl/okd-test/kube-descheduler/operator-bundle:5.4.0-2026-11-03-080630@sha256:92c6368bae3e2ac7da49309d17977075e2f012c02a269598ad28d8f69dddce3b
```

About 264 MB went into zot for the 4.22 run and about 328 MB for the main run (the three `PUSHED` sizes each, blobs shared between tags not netted out). zot measured before each prompt: 31 GiB before the 4.22 build, 30.8 GiB before the main build (the ledger figures; the pre-run gate is at least 5 GiB free). I did not measure zot after either run, so there is no "after" figure here; the Task 5 catalog image adds 31 MB, and the test images are deleted by digest at the end of the work.

### Disk, as a delta

`DISK` is bytes used on the shared graph root, so the absolute numbers are OADP's layers plus ours:

| | start (`tools`) | after `build_containers` | end (`deinit`) | delta over start |
|---|---|---|---|---|
| `release-4.22` | 86351462400 (86.4 GB) | 92344086528 (92.3 GB) | 92345122816 | +5.99 GB |
| `main` | 92345131008 (92.3 GB) | 97082802176 (97.1 GB) | 97083899904 | +4.74 GB |

The `main` start equals the end of the 4.22 run to within 8 KB, as it should with nothing pruned in between. Together the two descheduler builds added about 10.7 GB. `DISK` dips at `clone` (86.35 to 86.25 GB on the 4.22 run, 92.35 to 91.88 GB on the `main` run) before `init` brings it back; I did not look into why. Free space on `/work` went from 71.6 GB to 65.6 GB on the 4.22 run and from 65.6 GB to 60.8 GB on the `main` run; the catalog run started at 60.8 GB free. The 97.1 GB figure is therefore not a fresh-runner peak, and it should not be read as one.

### The slow pod start

Each Job's pod took about five minutes to get its container running: the 4.22 Job was created at 07:41Z (the `DATE`) and its first `STEP` is 07:46:19Z; the `main` Job started 08:07:33Z and its first `STEP` is 08:13:56Z (6 min 23 s). The ledger recorded `CreateContainerError` as expected and not a failure, and the watcher did not treat it as one. This is the "slow create seen twice with the kept graph root" from the 2026-11-03 ruling, about 4.5 min per start on average. The cause is not proven. The leading guess, and only a guess: with `PRUNE=false` the PVC carries a graph root of ~87 GB, and the container create waits on the runtime working through that volume (an SELinux relabel or ownership pass). What would settle it: the same Job on a fresh PVC, or the kubelet and CRI-O events of the create (`oc describe pod` events on the next run), neither read yet.

## 2026-11-03 — descheduler catalog graphs validated, test catalog image

Task 5: `MODE=catalog` adds each branch's new bundle to a clone of the okderators catalog branches, proves the upgrade graph with the walker, runs two negative controls, and builds the test catalog image. Nothing is pushed to `okd-project/okderators-catalog-index`; the edit lives in the Job's `/work/run` and the image. Evidence: `work/catalog-2026-11-03-083443.txt` (scratch, not committed).

Before (Step 1, the failing check, read on the catalog branches): `release-4.22` has the package `cluster-kube-descheduler-operator`, channel `alpha`, one entry, `clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655`, which is its head; `release-5.0` has no such package. The run's own `INFO release-4.22 head before` line says the same.

Command shape (README form, run by the operator's permission prompt; the bundle refs are the two from the previous section, with the tag dropped by the script before use because opm v1.74.0 refuses tag plus digest):

```bash
DATE=2026-11-03-083443
oc process --local -f tests/okderators-descheduler-build/job-template.yaml \
  -p MODE=catalog -p DATE=$DATE \
  -p CATALOG_BRANCHES='release-4.22 release-5.0' \
  -p BUNDLES='release-4.22=zot.apps.okd.sudops.pl/okd-test/kube-descheduler/operator-bundle:5.4.0-2026-11-03-074110@sha256:83246c48a473079b9b688344e4ee2f94fac8947eeedc590de8a593bdfa11b937 release-5.0=zot.apps.okd.sudops.pl/okd-test/kube-descheduler/operator-bundle:5.4.0-2026-11-03-080630@sha256:92c6368bae3e2ac7da49309d17977075e2f012c02a269598ad28d8f69dddce3b' \
  | oc -n okd-build create -f -
```

Job `descheduler-build-catalog-2026-11-03-083443`, 08:34:59Z to 08:41:20Z; script from 08:39:27Z, 98 s (tools 25 s, catalog-edit 35 s), the rest was the slow pod start again (4 min 28 s). `RESULT PASS catalog 2026-11-03-083443`, `catalog-edit: 0 checks failed`. Job deleted by prompt afterwards. Tool versions as in the builds: opm v1.74.0, python 3.14.8.

### release-4.22 (catalog commit 98c6d9d5)

| | before | after |
|---|---|---|
| `alpha` entries | `v5.3.0-2026-10-12-113655` | `v5.3.0-2026-10-12-113655`, `v5.4.0-2026-11-03-074110` |
| head | `v5.3.0-2026-10-12-113655` | `v5.4.0-2026-11-03-074110` |

The edit adds `catalog/cluster-kube-descheduler-operator/clusterkubedescheduleroperator.v5.4.0-2026-11-03-074110.yaml` (opm render of the bundle, as `hack/add-bundle.sh` does) and three lines in the package file; 2 files, 33 insertions, no file removed, old entries unchanged:

```
  - name: clusterkubedescheduleroperator.v5.4.0-2026-11-03-074110
    replaces: clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655
    skipRange: '>=5.3.0-0 <5.4.0-2026-11-03-074110'
```

`replaces` and `skipRange` were read back from the rendered catalog (`edit-release-4.22`). Checks, all PASS: `branch-data-release-4.22`, `bundle-release-4.22` (version 5.4.0-2026-11-03-074110, CSV and CRD present, `olm.maxOpenShiftVersion` 4.23, relatedImages by digest), `bundles-release-4.22`, `edit-release-4.22`, `opm-validate-release-4.22`.

Walker (`walk-release-4.22`), starting from both CSVs a cluster may run: the installed 5.3.0 and the test-shaped `v5.4.0-2026-11-02-074110` (the name this cluster's own test build would have had a day earlier; absent from the channel):

```
walk v5.3.0-2026-10-12-113655 -(replaces+skipRange)-> v5.4.0-2026-11-03-074110
walk v5.4.0-2026-11-03-074110
walk v5.4.0-2026-11-02-074110 -(skipRange)-> v5.4.0-2026-11-03-074110 (absent from the channel)
PASS 2 entries + 1 CSV absent from the channel reach v5.4.0-2026-11-03-074110
```

### Negative controls (4.22)

- **`negative-control-no-edge`: PASS (fails as designed).** The same catalog without `replaces` and `skipRange` has two heads, `v5.3.0-2026-10-12-113655` and `v5.4.0-2026-11-03-074110`, and strands 5.3.0 together with the test-shaped CSV; `opm validate` itself refuses it (`level=fatal msg="invalid index: ... invalid package \"cluster-kube-descheduler-operat...`; the extract cuts the message there). Proves the edge is what joins 5.4 to the old graph and that the validator and the walker both see its absence.
- **`negative-control-replaces-only`: PASS (fails as designed).** With only `replaces`, `opm validate` passes, but the walker reports `v5.4.0-2026-11-02-074110` stranded. Proves `opm validate` alone is not enough: a CSV that is not a channel entry (our test build) reaches the new head only through `skipRange`, so the `skipRange` is load-bearing for the later move of this cluster off the test build.

### release-5.0 (catalog commit 4daed51b)

| | before | after |
|---|---|---|
| package | none | `cluster-kube-descheduler-operator`, `defaultChannel: alpha` |
| `alpha` entries | n/a | one: `v5.4.0-2026-11-03-080630` (head) |

New files: the package file (11 lines) and the rendered bundle `clusterkubedescheduleroperator.v5.4.0-2026-11-03-080630.yaml`; 2 files, 41 insertions, no other file changed. The entry has `skipRange: '>=5.3.0-0 <5.4.0-2026-11-03-080630'` and no `replaces`. Checks, all PASS: `branch-data-release-5.0` (replaces NONE, installed NONE), `bundle-release-5.0` (`olm.maxOpenShiftVersion` 5.1, relatedImages by digest), `bundles-release-5.0`, `edit-release-5.0` (new package, channel alpha, one entry, no other file changed), `opm-validate-release-5.0`, `walk-release-5.0` (1 entry reaches the head; installed: none), `fresh-head-release-5.0` (the channel's one entry and single head, no `replaces`). No negative controls on this branch: there is no old entry to strand.

### The image

Built from `IMAGE_BRANCH=release-4.22` (the edited tree of that branch) on the opm base image pinned by digest, `ADD catalog /configs`, cache pre-populated with `opm serve --cache-only`. The image is re-checked after the build, as the cluster would read it:

```
CHECK opm-validate-image PASS
image walk v5.3.0-2026-10-12-113655 -(replaces+skipRange)-> v5.4.0-2026-11-03-074110
image walk v5.4.0-2026-11-02-074110 -(skipRange)-> v5.4.0-2026-11-03-074110 (absent from the channel)
CHECK catalog-image PASS ...: package cluster-kube-descheduler-operator; head v5.4.0-2026-11-03-074110; every entry and installed [...] reach the head
```

```
PUSHED zot.apps.okd.sudops.pl/okd-test/descheduler-catalog:2026-11-03-083443@sha256:f0b730d3b6a7fd902c8f6adfbda23e859be5f7acc51c66168c96536a9d660420 31349230
```

31349230 bytes (31 MB), head `clusterkubedescheduleroperator.v5.4.0-2026-11-03-074110`. This is the image Task 6 Step 1 points the homelab test CatalogSource at. The `release-5.0` tree is validated but not in the image: nothing on this cluster reads it.
