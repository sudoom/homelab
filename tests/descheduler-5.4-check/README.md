# descheduler-5.4-check

An eviction check for the Kube Descheduler, run on 5.3 before the upgrade and again on 5.4 after it. It proves that the
operand still evicts, through a plugin the cluster's profiles run (`AffinityAndTaints` ->
`RemovePodsViolatingInterPodAntiAffinity`), without waiting for LowNodeUtilization to find an overutilized node.

## Shape

- `anchor` pins itself to `node6.okd.sudops.pl` (required node affinity on the existing hostname label). node6 is the node
  not reading overutilized, so LowNodeUtilization does not pick pods from it.
- `victim` has required pod anti-affinity against `drill=anchor` on `kubernetes.io/hostname`, and preferred pod affinity
  (weight 100) to `app=anchor`. No pod carries `drill=anchor` at first, so it schedules beside `anchor`. Labelling the
  anchor pod then makes `victim` violate its own term, and the descheduler must evict it. Its replacement lands elsewhere
  because the term is required. The plugin looks only at the candidate's own terms, so `anchor` is never evicted.
- Both are 1-replica Deployments (owned by a ReplicaSet), small requests, image `registry.k8s.io/pause` by the digest of
  the multi-arch index (`sha256:f548e0e8...`, tag 3.10.2; runs as UID 65535, no shell, needs no write access), under
  `restricted-v2`. No volumes (`emptyDir`, `hostPath` and PVC make a pod non-evictable), no PDB, no `priorityClassName`.

## Gate

Never in Monday 19:00Z-23:00Z: the operand rolls then and its log and counters reset.

## Run

Every command that changes the cluster is run by the operator, by prompt. In order:

```
oc apply -f tests/descheduler-5.4-check/namespace.yaml
oc apply -f tests/descheduler-5.4-check/anchor.yaml
KUBECONFIG=~/.kube/config-readonly oc -n descheduler-check get pod -o wide -w     # until anchor is Running on node6
oc apply -f tests/descheduler-5.4-check/victim.yaml
KUBECONFIG=~/.kube/config-readonly oc -n descheduler-check get pod -o wide        # victim Running; note its pod name
KUBECONFIG=~/.kube/config-readonly oc -n descheduler-check get pod -l app=anchor -o jsonpath='{.items[0].metadata.name} {.items[0].metadata.uid}{"\n"}'
oc -n descheduler-check label pod <anchor pod> drill=anchor
```

The descheduler runs every 3600 s, so the eviction comes within an hour. Read it from the operand pod's log and metric:

```
KUBECONFIG=~/.kube/config-readonly oc -n openshift-kube-descheduler-operator logs deploy/descheduler | grep 'Evicted pod' | grep descheduler-check
KUBECONFIG=~/.kube/config-readonly oc get --raw /api/v1/namespaces/openshift-kube-descheduler-operator/services/https:metrics:10258/proxy/metrics | grep 'descheduler_pods_evicted_total.*descheduler-check'
```

The raw metric read works on 5.3. On 5.4 the new NetworkPolicy `descheduler-operand` may refuse it; use PromQL instead,
run by the operator. Prometheus renames the metric's own `namespace` label to `exported_namespace` (the target's
namespace wins), so the query is `descheduler_pods_evicted_total{exported_namespace="descheduler-check"}`; on 5.4 the
proxy read worked 1 time in 3 in one sample (2026-11-04, Task 8 Step 3).

## Pass

All of:

1. An `Evicted pod` log line for the `victim` pod with `strategy="RemovePodsViolatingInterPodAntiAffinity"`.
2. `descheduler_pods_evicted_total{strategy="RemovePodsViolatingInterPodAntiAffinity",namespace="descheduler-check",result="success"}` up by one, read from the same operand pod that logged the line (raw read; in PromQL the label
   is `exported_namespace`).
3. The new `victim` pod Running on another node than `anchor`.
4. `anchor`'s pod UID unchanged from the one noted before labelling.

An eviction of either pod with any other strategy invalidates the run: delete the namespace and start over.

## Cleanup

Needs the operator's approval (prompt):

```
oc delete namespace descheduler-check
```
