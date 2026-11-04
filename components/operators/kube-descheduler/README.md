# kube-descheduler

The Kube Descheduler Operator, with the `KubeDescheduler/cluster` CR that runs it. Since 2026-11-04 it comes from our
okderators 5.4 test catalog `okd-test-descheduler`, until okderators publishes 5.4; before that from `okderators` (5.3.0).
Installed CSV today: `clusterkubedescheduleroperator.v5.4.0-2026-11-03-074110`.

## What it installs

`templates/operator.yaml`, one file:

- Namespace `openshift-kube-descheduler-operator` (label `openshift.io/cluster-monitoring`, so the platform Prometheus reads the operand's ServiceMonitor), wave 0.
- OperatorGroup in OwnNamespace mode (the CSV does not support AllNamespaces), wave 0.
- Subscription `cluster-kube-descheduler-operator`: channel `alpha`, source `okd-test-descheduler` (`okderators` until 2026-11-04), `installPlanApproval: Manual`, wave 1. Do not set it to Automatic: a catalog change would then upgrade the operator unsupervised.
- `KubeDescheduler/cluster`, wave 5: mode `Automatic`, interval 3600 s, profiles `AffinityAndTaints` and `LongLifecycle`, `devLowNodeUtilizationThresholds: High`. The operator only reconciles the CR named `cluster`.

It never evicts pods in `openshift-*`, `kube-system` or `hypershift`. Pods with `emptyDir`, `hostPath` or a PVC are not evictable either (`evictLocalStoragePods` false, `ignorePvcPods` on).

`subscription.startingCSV` is unset by default and then renders nothing (the render is byte-identical to a chart without the value). It exists for the rollback below. OLM ignores it while a CSV from the Subscription is installed.

## Upgrade

The operator replaces in place and keeps the CR. The `replaces` edge in the catalog drives it, not `startingCSV`.

1. Change `subscription.source` in `values.yaml` to the catalog that carries the new build (for the 5.4 test build: `okd-test-descheduler`, `components/operators/descheduler-test-catalog/`), commit to `master`, push.
2. Read the InstallPlan, then approve it. Needs the operator's approval (prompt):

```
KUBECONFIG=~/.kube/config-readonly oc -n openshift-kube-descheduler-operator get installplan,csv,subscription
oc -n openshift-kube-descheduler-operator patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
```

3. Check: CSV `Succeeded`, CR unchanged, operand pod on the expected image, the NetworkPolicy `descheduler-operand` present and the operand still scraped, and the eviction check in `tests/descheduler-5.4-check/` again.

Do not start or approve anything in Monday 19:00Z-23:00Z. The operand rolls then on its own (weekly encryption-key migration), and its log and counters reset.

## Rollback to v5.3.0-2026-10-12-113655

The `KubeDescheduler` CRD schema is identical between 5.3 and 5.4, so the CR stays. Order matters; every `oc` mutation below needs the operator's approval (prompt), and the commit is pushed by the operator.

1. Commit the revert first. In `values.yaml` set `subscription.source: okderators` and uncomment
   `startingCSV: clusterkubedescheduleroperator.v5.3.0-2026-10-12-113655`. Check the render:

```
helm template kd components/operators/kube-descheduler/ -n openshift-kube-descheduler-operator -f components/operators/kube-descheduler/values.yaml | grep -n -e 'source:' -e startingCSV
```

2. Delete the 5.4 CSV (read its name first). Needs the operator's approval (prompt):

```
KUBECONFIG=~/.kube/config-readonly oc -n openshift-kube-descheduler-operator get csv
oc -n openshift-kube-descheduler-operator delete csv <5.4 CSV name>
```

3. OLM resolves the Subscription again, now to `startingCSV`, and writes an InstallPlan. Read it, then approve it. Needs the operator's approval (prompt):

```
KUBECONFIG=~/.kube/config-readonly oc -n openshift-kube-descheduler-operator get installplan
oc -n openshift-kube-descheduler-operator patch installplan <name> --type merge -p '{"spec":{"approved":true}}'
```

4. Wait for the 5.3 CSV to reach `Succeeded`, then check the CR and the operand pod. Remove `startingCSV` from `values.yaml` in a follow-up commit.
5. The NetworkPolicy `descheduler-operand` (ingress TCP 10258 from namespaces labelled `openshift.io/cluster-monitoring`) is not owned by the 5.3 CSV and stays behind. List it, then decide: it is harmless next to 5.3 (it only allows what Prometheus needs), so keeping it is the default. To remove it, needs the operator's approval (prompt):

```
KUBECONFIG=~/.kube/config-readonly oc -n openshift-kube-descheduler-operator get networkpolicy
oc -n openshift-kube-descheduler-operator delete networkpolicy descheduler-operand
```

If the 5.3 bundle is no longer in the catalog the Subscription points at, step 3 produces no InstallPlan; check `oc get packagemanifest cluster-kube-descheduler-operator` for the source before step 2.
