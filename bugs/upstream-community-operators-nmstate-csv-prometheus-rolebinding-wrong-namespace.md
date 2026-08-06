# `kubernetes-nmstate-operator` (community-operators): metrics RoleBindings bind subject namespace `monitoring`, which does not exist on OpenShift

## Summary

The operator creates two RoleBindings in its operand namespace (`nmstate`) so that
Prometheus can perform Kubernetes service discovery against the targets behind its
`ServiceMonitor`. Both bind the subject `ServiceAccount prometheus-k8s` in namespace
**`monitoring`** — the upstream kube-prometheus convention.

On OpenShift there is no `monitoring` namespace. The platform Prometheus ServiceAccount is
`openshift-monitoring:prometheus-k8s`. The result is that platform Prometheus is denied
`list`/`watch` on `pods`, `services` and `endpoints` in `nmstate`, its service discovery
never syncs, and **nmstate metrics are never scraped at all**.

This is distinct from `upstream-community-operators-nmstate-csv-missing-rbac.md`, which
covers two *absent* `clusterPermissions` for the `nmstate-handler` ServiceAccount. Here the
bindings are present and correct in every respect except the subject namespace, and the
subject is a different ServiceAccount. It is **not** covered by
[okd-operator-pipeline PR #19](https://github.com/okd-project/okd-operator-pipeline/pull/19).

## Environment

- OKD 4.20.0-okd-scos.17 (Kube API ~1.33), 3-node bare-metal.
- `kubernetes-nmstate-operator` from the `operatorhubio-catalog` CatalogSource
  (`quay.io/operatorhubio/catalog:latest`, i.e. github.com/k8s-operatorhub/community-operators).
- Install namespace `openshift-nmstate`; operand namespace `nmstate`.
- Platform monitoring enabled; `nmstate` namespace carries `openshift.io/cluster-monitoring: "true"`.

## Observed

Everything needed for scraping is in place except the subject:

```console
$ oc get ns nmstate -o jsonpath='{.metadata.labels}'
{... "openshift.io/cluster-monitoring":"true" ...}

$ oc -n nmstate get servicemonitor
NAME                                 AGE
controller-manager-metrics-monitor   101d

$ oc -n nmstate get role nmstate-monitor \
    -o jsonpath='{range .rules[*]}{.apiGroups} {.resources} {.verbs}{"\n"}{end}'
[""] ["services","endpoints","pods"] ["get","list","watch"]

$ oc -n nmstate get rolebinding nmstate-monitor prometheus-k8s \
    -o jsonpath='{range .items[*]}{.metadata.name} -> {.roleRef.kind}/{.roleRef.name} subj={.subjects[*].namespace}:{.subjects[*].name}{"\n"}{end}'
nmstate-monitor -> Role/nmstate-monitor subj=monitoring:prometheus-k8s
prometheus-k8s  -> Role/prometheus-k8s  subj=monitoring:prometheus-k8s

$ oc get ns monitoring
Error from server (NotFound): namespaces "monitoring" not found
```

Resulting denials, logged continuously by both platform Prometheus replicas:

```
failed to list *v1.Pod: pods is forbidden: User
  "system:serviceaccount:openshift-monitoring:prometheus-k8s"
  cannot list resource "pods" in API group "" in the namespace "nmstate"
failed to list *v1.Endpoints: endpoints is forbidden: User ... in the namespace "nmstate"
failed to list *v1.Service: services is forbidden: User ... in the namespace "nmstate"
```

```console
$ ... query 'sum(rate(prometheus_sd_kubernetes_failures_total[5m])) by (pod)'
prometheus-k8s-0  0.0667
prometheus-k8s-1  0.0667
```

This fires the default OpenShift alert `PrometheusKubernetesListWatchFailures`
(`increase(prometheus_sd_kubernetes_failures_total{job=~"prometheus-k8s|prometheus-user-workload"}[5m]) > 0`).
Because the `endpoints` discovery role blocks on informer cache sync, no `up` series is
ever produced for the namespace — this is a total scrape failure, not degraded scraping.

## Expected

The RoleBindings' subject namespace should be the namespace the monitoring stack actually
runs in. Upstream parametrizes this as `MONITORING_NAMESPACE` on the operator Deployment;
the community-operators build leaves it at the upstream default `monitoring`. The
okderators build of the same operator sets it to `openshift-monitoring` correctly (see
`nmstate-imagestream-bug.md` in this directory, which is why we are on community-operators
in the first place).

## Impact

- nmstate metrics unavailable cluster-wide for the entire life of the install.
- A permanently-firing `PrometheusKubernetesListWatchFailures` warning, which desensitizes
  the alert board.
- **Low discoverability.** Unlike the two `nmstate-handler` RBAC defects, nothing crashes
  and no pod restarts — the bindings exist, so the usual "fresh pod fails to start" signal
  never appears. The alert names no namespace, so it reads like a transient API-server
  hiccup. Observed 2026-07-25 → 2026-08-06 (12 days) before diagnosis.

## Suggested fix

Build the community-operators bundle with `MONITORING_NAMESPACE=openshift-monitoring`, or
make the operator resolve the monitoring namespace at runtime rather than baking the
upstream default into an OpenShift-targeted package.

## Workaround (local fix)

`components/operators/nmstate/templates/prometheus-metrics-rbac.yaml` — a self-contained
`Role` + `RoleBinding` in ns `nmstate` granting `get/list/watch` on
`services,endpoints,pods` to `openshift-monitoring:prometheus-k8s`.

Deliberately a *new* Role rather than a second binding to the operator's `nmstate-monitor`
Role: that Role is owned by the cluster-scoped `NMState` CR, so an upgrade that renames or
drops it would leave our binding dangling with no admission error — metrics would silently
stop again, reproducing the failure mode.

Deliberately *not* an edit to the operator's own RoleBindings: they carry controller
`ownerReferences` to the `NMState` CR and are reconciled every few hours, so an edit would
flap permanently against ArgoCD selfHeal.

## Notes

- Third RBAC defect found in this packaging. See
  `upstream-community-operators-nmstate-csv-missing-rbac.md` for (a) the `privileged` SCC
  `use` grant and (b) `get/list/watch apiservers.config.openshift.io`, both for the
  `nmstate-handler` SA. That file's closing note predicted a third; this is it, though it
  arrived via a different subject and a different symptom than anticipated.
- Worth filing as a single issue against the k8s-operatorhub/community-operators packaging
  rather than folding into PR #19, which is scoped to the handler `clusterPermissions`.
