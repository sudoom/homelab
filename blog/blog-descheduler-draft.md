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
