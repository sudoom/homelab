# nmstate-operator

Kubernetes NMState operator. Its handler applies the per-node NNCPs in
`components/cluster-config/nmstate-nncp/` (`storage-node4/5/6`: `enp1s0f0np0` and the `ceph-shim` macvlan, the
Ceph storage backnet `192.168.10.0/24`). A handler that misbehaves on a node can take that node's storage network
down, so every operator change here is gated per node.

**Status 2026-10-27:** switched. Live on `kubernetes-nmstate-operator.v4.21.0-2026-10-26-123722` from the test catalog
`okd-test-nmstate` (operand in `openshift-nmstate`, handler on every node) since 2026-10-26 13:55Z; the 24 h
soak passed and namespace `nmstate` is deleted. v0.87.0 from `operatorhubio-catalog` is the rollback target (Rollback, below).

## What the chart installs

root-app entry `nmstate-operator`, wave 1, destination namespace `openshift-nmstate`.

| Object | Wave | Notes |
|---|---|---|
| Namespace `openshift-nmstate` | 0 | PSA labels: see "Two namespaces" |
| OperatorGroup `openshift-nmstate` | 0 | `spec: {}` = AllNamespaces |
| Subscription `kubernetes-nmstate-operator` | 1 | channel `alpha`; source and approval in `values.yaml` |
| NMState `nmstate` (cluster-scoped) | 5 | the operator renders the whole operand from it; `spec.nodeSelector` limits the handler to labelled nodes |

Until the switch (commit `c0252f5`) the chart also carried three templates that worked around RBAC defects in the
community v0.87.0 CSV: `handler-scc-binding.yaml` (wave 1, `use` on the `privileged` SCC for the handler SA),
`handler-apiserver-rbac.yaml` (wave 1, `get/list/watch apiservers.config.openshift.io`) and
`prometheus-metrics-rbac.yaml` (wave 6, lets `openshift-monitoring/prometheus-k8s` list pods/services/endpoints in
`nmstate`). The okderators 4.21 build ships all three grants itself, so the switch deleted them; the rollback restores
them from `c0252f5^`.

Everything else (handler DaemonSet, webhook, metrics and console-plugin Deployments, MutatingWebhookConfiguration
`nmstate`, ValidatingAdmissionPolicy `nncp-validation-policy` + binding, ClusterRoles/CRB `nmstate-handler`,
ConsolePlugin `nmstate-console-plugin`, ServiceMonitor, NetworkPolicies) is rendered by the operator with an
ownerReference to the NMState CR. The CR has no finalizer: deleting it garbage-collects the whole operand and leaves
the four CRDs, the NNCPs/NNCEs/NNSs and every node's NetworkManager state untouched (applies are persistent).

No `nmstate-cert-manager` Deployment runs here, on either build. The okderators 4.21 code renders it only
`if not .IsOpenShift` (`deploy/handler/operator.yaml`), its `IsOpenShift` always returns true, and
`cleanupObsoleteResources` deletes a leftover one; the webhook's serving cert comes from the service CA
(`service.beta.openshift.io/serving-cert-secret-name`, MWC `inject-cabundle`). v0.87.0 also deletes it on OpenShift.
A `nmstate-cert-manager` pod after the switch is therefore unexpected.

## Two namespaces

- **operatorhubio v0.87.0 (until the switch):** the operator runs in `openshift-nmstate`, but the CSV hardcodes
  `HANDLER_NAMESPACE=nmstate`, so the operand lands in a second namespace, `nmstate`, created by the operator. A
  namespaced object added for the operand must set `metadata.namespace: nmstate` explicitly; the Application's
  destination is `openshift-nmstate`, and the object would land there, report Synced, and do nothing.
  `openshift-nmstate` itself runs PSA `restricted`.
- **okderators 4.21 (after the switch):** the CSV sets `HANDLER_NAMESPACE` from `metadata.namespace`, so the operand
  lands in `openshift-nmstate` next to the operator. The operator applies that Namespace itself from its
  `deploy/handler/namespace.yaml`, forcing these labels and this annotation:

  ```yaml
  annotations:
    openshift.io/node-selector: ""
  labels:
    name: openshift-nmstate
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    openshift.io/cluster-monitoring: "true"
  ```

  The chart's Namespace must declare exactly these. Any difference ping-pongs under selfHeal, and while
  `restricted` is enforced the handler pods are rejected. After the switch `nmstate` was left empty; it was deleted
  after the 24 h soak (2026-10-27).

From the switch until 2026-10-27 the NMState CR carried `spec.nodeSelector: {sudops.pl/nmstate-handler: "true"}`,
with the label set per node in `components/cluster-config/node-labels/values.yaml`, so the handler could be started
one node at a time. Both were removed after the soak: the CR is `spec: {}` again and the handler runs on every Linux
node. The webhook and metrics Deployments follow `infraNodeSelector` (unset, so any Linux node).

## Rules

- **Never set `enabled: false` on `nmstate-operator` or `nmstate-nncp`** in `bootstrap/root-app/values.yaml`. The
  resources-finalizer would cascade-delete the Namespace, the NMState CR and the NNCPs.
- **Never two operators or two handlers at once.** Both operators server-side-apply the same cluster-scoped objects
  (MWC `nmstate`, ClusterRole/CRB `nmstate-handler`, ConsolePlugin) and flip them back and forth; two handlers on
  one node block on the hostPath lock `/var/k8s_nmstate/handler_lock`. The only safe order is: CR deleted → old
  operand gone → old CSV removed → new operator sees a newly created CR.
- **A starting handler re-applies every NNCP**, `enp1s0f0np0` and `ceph-shim` included (NetworkManager `Reapply`).
  That can zero `net.ipv4.conf.br-ex.forwarding` on the node and break its pod egress; restarting that node's
  `ovnkube-node` fixes it (`network-change` skill).
- **The okderators MWC has two webhooks with `failurePolicy: Fail`** (default):
  `nodenetworkconfigurationpolicies-{create,update}-validate.nmstate.io`. With no webhook pod Ready, NNCP
  create/update fails, and so does ArgoCD's server-side diff of `nmstate-nncp`. v0.87.0's three webhooks are all
  `Ignore`.
- **Emergency stop:** with auto-sync off on `nmstate-operator`, `oc delete nmstate nmstate` removes every handler; the
  nodes keep their network configuration. On one node only: revert that node's label commit and the handler pod
  leaves that node.
- **Interim on zot:** until okderators publishes an installable 4.21 bundle, the operator, handler, webhook and
  console-plugin images exist only in zot `okd-test/nmstate/` (catalog `okd-test-nmstate`,
  `components/operators/nmstate-test-catalog/`). During a zot outage a rescheduled handler cannot start; the nodes
  keep their configuration, NNCP changes wait.

## Runbook conventions

Every mutation below is **operator-run** with the operator's own `oc login` (marked `# OPERATOR`). Every check is a
read under the readonly SA, except the `br-ex.forwarding` sysctl (needs `exec`, so the operator's kubeconfig) and
the Prometheus/Alertmanager reads (break-glass `exec`, read-only).

```bash
ocr() { KUBECONFIG=~/.kube/config-readonly oc "$@"; }

# br-ex.forwarding per node: 1 = healthy, 0 = that node's pod egress is broken (exec: operator's kubeconfig)
brex() {
  for p in $(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node \
      -o jsonpath='{range .items[*]}{.metadata.name}:{.spec.nodeName}{"\n"}{end}'); do
    echo "${p##*:} $(oc -n openshift-ovn-kubernetes exec ${p%%:*} -c ovnkube-controller -- \
      sysctl -n net.ipv4.conf.br-ex.forwarding 2>/dev/null)"
  done
}

# Ceph: health with the named checks, every OSD up, per pool active = clean = total
cephchk() {
  ocr -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health} {.status.ceph.details}{"\n"}'
  ocr get --raw "/api/v1/namespaces/rook-ceph/services/http:rook-ceph-mgr:9283/proxy/metrics" \
    | grep -E '^ceph_osd_up|^ceph_pg_(total|active|clean)\{'
}

# NNCEs: generation, Available, transition time
nnce() {
  ocr get nnce -o jsonpath='{range .items[*]}{.metadata.name} gen={.status.policyGeneration} Available={.status.conditions[?(@.type=="Available")].status} since={.status.conditions[?(@.type=="Available")].lastTransitionTime}{"\n"}{end}'
}

# NNS of the two backnet interfaces on one node (compare with the pre-switch baseline in the blog draft)
nns() {
  for i in enp1s0f0np0 ceph-shim; do
    ocr get nns "$1.okd.sudops.pl" -o jsonpath="{range .status.currentState.interfaces[?(@.name==\"$i\")]}$1 {.name} {.state} mtu={.mtu} {range .ipv4.address[*]}{.ip}/{.prefix-length} {end}{\"\n\"}{end}"
  done
}

# ArgoCD apps involved
apps() {
  for a in root-app nmstate-operator nmstate-nncp node-labels; do
    ocr -n openshift-gitops get application $a -o jsonpath="{.metadata.name} {.status.sync.status} {.status.health.status} automated={.spec.syncPolicy.automated} conditions={.status.conditions[*].type}{\"\n\"}"
  done
}
```

Pre-switch values (2026-10-26): NNCPs `storage-node4/5/6` generation 3, NNCEs Available at generation 3; CRD
storedVersions NMState `v1`, NNCP `v1`, NNCE `v1beta1`, NNS `v1beta1`; MWC `nmstate` = 3 webhooks to namespace
`nmstate`, all `Ignore`; InstallPlans `install-879xr` (v0.86.0) and `install-775wp` (v0.87.0), both Complete.

## Switch: operatorhubio v0.87.0 → okderators 4.21 test build

Target CSV: `kubernetes-nmstate-operator.v4.21.0-2026-10-26-123722` from CatalogSource `okd-test-nmstate`.

### Step 1: gates (read-only; any miss = stop)

```bash
brex                                    # 1 on all three nodes
cephchk                                 # HEALTH_OK, or HEALTH_WARN whose details name only the known benign checks
                                        # (2026-10-26: BLUESTORE_SLOW_OP_ALERT "N OSD(s) experiencing slow operations
                                        # in BlueStore"); osd.0-2 up; active = clean = total per pool;
                                        # nothing OSD-affecting in flight
ocr get cluster.postgresql.cnpg.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name} ready={.status.readyInstances}/{.spec.instances} archiving={.status.conditions[?(@.type=="ContinuousArchiving")].status}{"\n"}{end}'
                                        # every cluster 2/2, archiving=True
nnce                                    # 3 x Available=True at gen=3
ocr -n openshift-marketplace get catalogsource okd-test-nmstate -o jsonpath='{.status.connectionState.lastObservedState}{"\n"}'   # READY
ocr get packagemanifest -n openshift-marketplace -l catalog=okd-test-nmstate \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.channels[*].name} {.status.channels[*].currentCSV}{"\n"}{end}'
                                        # kubernetes-nmstate-operator alpha kubernetes-nmstate-operator.v4.21.0-2026-10-26-123722
```

The switch change is prepared and validated (lint, template, kubeconform, live compare) but not pushed.

### Step 2: auto-sync off (root-app first, or its selfHeal turns the others back on)

`root-app` auto-sync is already off since 2026-10-26 13:03Z (the operator set `enabled: false` early and hand-syncs
`root-app` once, without prune, after the test-catalog commit). Check that first: `apps` shows `root-app`
`automated={"enabled":false,...}`. If it does not, turn it off before anything else:
`oc -n openshift-gitops patch application root-app --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":false,"prune":false,"selfHeal":false}}}}'`
(# OPERATOR). Then:

```bash
# OPERATOR
for a in nmstate-operator nmstate-nncp; do
  oc -n openshift-gitops patch application $a --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
done
```

Check: `apps` shows `automated=` (empty) for `nmstate-operator` and `nmstate-nncp`, `root-app` still
`"enabled":false`; `node-labels` keeps its own auto-sync (Step 6 relies on it). While `root-app` auto-sync is off,
changes to `bootstrap/root-app/values.yaml` do not reach the cluster.

### Step 3: delete the NMState CR (the old operand goes)

```bash
# OPERATOR
oc delete nmstate nmstate
```

Check until all hold:

```bash
ocr -n nmstate get ds,deploy,svc                                   # No resources found
for r in mutatingwebhookconfiguration/nmstate validatingadmissionpolicy/nncp-validation-policy \
         consoleplugin/nmstate-console-plugin clusterrole/nmstate-handler; do
  ocr get $r 2>&1 | tail -1                                        # NotFound, each
done
ocr get nncp; nnce; ocr get nns                                    # 3 each, unchanged
ocr get crd -o name | grep nmstate.io                              # 4 CRDs
brex                                                               # unchanged (1 x3)
```

**Abort point:** to go back here, turn auto-sync back on (Step 7, gate included). selfHeal recreates the CR from the
unchanged chart and v0.87.0 rolls its operand out again, on all three nodes at once, so run Step 6's per-node checks
on all three.

### Step 4: remove the v0.87.0 operator

```bash
# OPERATOR
oc -n openshift-nmstate delete subscription kubernetes-nmstate-operator
oc -n openshift-nmstate delete csv kubernetes-nmstate-operator.v0.87.0
```

Check: `ocr -n openshift-nmstate get csv kubernetes-nmstate-operator.v0.87.0` and
`ocr -n openshift-nmstate get deploy nmstate-operator` both NotFound; `ocr get crd -o name | grep nmstate.io` still 4.
(The OLM upgrade path cannot do this: the okderators skipRange `>=4.3.0 <4.21.0` does not cover v0.87.0.)

**Abort between Step 4 and Step 5** (old Subscription and CSV gone, chart not switched yet): do **not** turn
auto-sync back on. It would recreate the unpinned, Automatic operatorhubio Subscription and a CR without the
`nodeSelector`, so v0.87.0, or whatever the catalog head is by then, would start a handler on all three nodes at
once. Go to a pinned v0.87.0 install with the `nodeSelector` instead, the rollback path below: step 0, then a commit
that changes the still-unswitched chart's `templates/operator.yaml` only (Subscription `installPlanApproval: Manual`
plus `startingCSV: kubernetes-nmstate-operator.v0.87.0`; CR `spec.nodeSelector: {sudops.pl/nmstate-handler: "true"}`),
then rollback steps 6 and 7, labelling node4 first. Rollback steps 1-4 do not apply: no CR and no operator exist in
this window.

### Step 5: push the switch, install the okderators operator

The switch commit, `nmstate: move to the okderators 4.21 test build`, touches only this chart:

- `values.yaml`: `source: okd-test-nmstate`, `installPlanApproval: Manual`,
  `startingCSV: kubernetes-nmstate-operator.v4.21.0-2026-10-26-123722`.
- `templates/operator.yaml`: the Subscription takes `installPlanApproval` and `startingCSV` from values; the
  Namespace carries the labels and annotation from "Two namespaces"; the NMState CR gets
  `spec.nodeSelector: {sudops.pl/nmstate-handler: "true"}`.
- the three workaround templates deleted.

```bash
# OPERATOR: apply the prepared and validated patch (or make the edits above by hand), commit, push
git apply <dir>/switch.patch
git add -A components/operators/nmstate/
git commit -m 'nmstate: move to the okderators 4.21 test build'
git push
SHA=$(git rev-parse HEAD)                # the switch commit
# OPERATOR: sync nmstate-operator by hand at that revision, with prune (UI: REFRESH until the app shows $SHA,
# then SYNC with PRUNE ticked), or pin the revision in the operation:
oc -n openshift-gitops patch application nmstate-operator --type merge \
  -p '{"operation":{"sync":{"revision":"'"$SHA"'","prune":true,"syncOptions":["ServerSideApply=true","ServerSideDiff=true","RespectIgnoreDifferences=true","SkipDryRunOnMissingResource=true"]}}}'
```

The sync stops at wave 1 with the Subscription `Progressing` (InstallPlan pending). Before anything is approved,
confirm the sync runs the switch commit. A sync at the old revision would recreate the Automatic operatorhubio
Subscription and a CR without the `nodeSelector`.

```bash
ocr -n openshift-gitops get application nmstate-operator \
  -o jsonpath='sync={.status.sync.revision} operation={.status.operationState.operation.sync.revision} result={.status.operationState.syncResult.revision} phase={.status.operationState.phase}{"\n"}'
echo "$SHA"                             # sync= and result= equal it (operation= too when pinned; a UI sync may
                                        # show the branch name there); phase=Running for this sync
```

Then read the InstallPlan:

```bash
ocr -n openshift-nmstate get installplan \
  -o jsonpath='{range .items[*]}{.metadata.name} {.spec.clusterServiceVersionNames} approved={.spec.approved} {.status.phase}{"\n"}{end}'
ocr -n openshift-nmstate get installplan <install-xxxxx> \
  -o jsonpath='{range .status.plan[*]}{.resource.kind}/{.resource.name} {.status}{"\n"}{end}'
```

It must name only `kubernetes-nmstate-operator.v4.21.0-2026-10-26-123722`, and its steps only that CSV, CRD
`nmstates.nmstate.io` and the CSV's RBAC/ServiceAccounts. **If it names anything else**, or a revision check above
failed: do not approve, terminate the sync (operator-run; UI: TERMINATE, or the command below, which writes what
`argocd app terminate-op` writes, Application having no status subresource), and go to Rollback.

```bash
# OPERATOR, only on that abort
oc -n openshift-gitops patch application nmstate-operator --type merge -p '{"status":{"operationState":{"phase":"Terminating"}}}'
```

Otherwise:

```bash
# OPERATOR
oc -n openshift-nmstate patch installplan <install-xxxxx> --type merge -p '{"spec":{"approved":true}}'
```

If the sync operation ended before the approval, sync `nmstate-operator` once more so wave 5 creates the CR. Check:

```bash
ocr -n openshift-nmstate get csv kubernetes-nmstate-operator.v4.21.0-2026-10-26-123722 -o jsonpath='{.status.phase}{"\n"}'   # Succeeded
ocr -n openshift-nmstate get deploy nmstate-operator \
  -o jsonpath='{.spec.template.spec.containers[0].env[?(@.name=="HANDLER_NAMESPACE")]}{"\n"}'   # valueFrom fieldRef metadata.namespace
ocr get crd nmstates.nmstate.io nodenetworkconfigurationpolicies.nmstate.io nodenetworkconfigurationenactments.nmstate.io nodenetworkstates.nmstate.io \
  -o jsonpath='{range .items[*]}{.metadata.name} served={.spec.versions[?(@.served==true)].name} stored={.status.storedVersions}{"\n"}{end}'
                                        # stored unchanged: v1, v1, v1beta1, v1beta1
ocr get nmstate nmstate -o jsonpath='{.metadata.creationTimestamp} {.spec.nodeSelector}{"\n"}'     # new CR, the selector
ocr -n openshift-nmstate get ds nmstate-handler -o jsonpath='desired={.status.desiredNumberScheduled}{"\n"}'   # 0 (no node labelled yet)
ocr -n openshift-nmstate get deploy nmstate-webhook nmstate-metrics \
  -o jsonpath='{range .items[*]}{.metadata.name} {.status.readyReplicas}/{.spec.replicas}{"\n"}{end}'   # all Ready
ocr get mutatingwebhookconfiguration nmstate \
  -o jsonpath='{range .webhooks[*]}{.name} {.clientConfig.service.namespace} {.failurePolicy}{"\n"}{end}'   # every webhook -> openshift-nmstate
```

### Step 6: one node at a time (node4, then node5, then node6)

For each node, a commit that adds the label to that node only, in `components/cluster-config/node-labels/values.yaml`:

```yaml
  - hostname: node4.okd.sudops.pl
    labels:
      topology.kubernetes.io/zone: fd-a
      sudops.pl/nmstate-handler: "true"
```

```bash
# OPERATOR
git add components/cluster-config/node-labels/values.yaml
git commit -m 'nodes: label node4 for the nmstate handler' && git push
```

`node-labels` syncs on its own. After the label is on the node, run the checks with `N` set to that node:

```bash
N=node4                                 # node5 for the second round, node6 for the third
ocr get node $N.okd.sudops.pl -o jsonpath='{.metadata.labels.sudops\.pl/nmstate-handler}{"\n"}'       # true
hpod=$(ocr -n openshift-nmstate get pods -l component=kubernetes-nmstate-handler \
  --field-selector spec.nodeName=$N.okd.sudops.pl -o jsonpath='{.items[0].metadata.name}')
ocr -n openshift-nmstate get pod "$hpod" -o jsonpath='{.status.phase} restarts={.status.containerStatuses[*].restartCount}{"\n"}'   # Running
ocr -n openshift-nmstate logs "$hpod" | grep -m1 'Successfully took nmstate exclusive lock'
nnce                                    # this node: Available=True, gen=3, since = just now
brex                                    # this node 1; if 0: OPERATOR restarts that node's ovnkube-node, then re-check:
#   oc -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node --field-selector spec.nodeName=$N.okd.sudops.pl
cephchk                                 # no OSD down; active = clean = total
nns $N                                  # equals the baseline (state up, mtu 9000, same addresses)
apps                                    # nmstate-nncp: no ComparisonError in conditions
ocr -n openshift-nmstate get deploy nmstate-webhook -o jsonpath='{.status.readyReplicas}/{.spec.replicas}{"\n"}'
```

Only when every check passes, label the next node. If a node fails: stop labelling and fix forward (`ovnkube-node`
restart, NetworkManager on that node); otherwise roll back (below).

### Step 7: auto-sync back on

**Gate first** (read-only; either check failing = stop, read the diff in ArgoCD, do not enable auto-sync). The 4.21
operator re-applied the NNCP/NNCE/NNS CRDs at Step 5; if the chart's NNCPs now differ from live, selfHeal on
re-enable rewrites them, bumps their generation and re-enacts the backnet on all three nodes at once.

```bash
apps                                    # nmstate-nncp Synced
ocr get nncp -o jsonpath='{range .items[*]}{.metadata.name} gen={.metadata.generation}{"\n"}{end}'
                                        # storage-node4/5/6 at the baseline generation (gen=3 each on 2026-10-26)
```

```bash
# OPERATOR
for a in nmstate-nncp nmstate-operator; do
  oc -n openshift-gitops patch application $a --type merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
done
oc -n openshift-gitops patch application root-app --type merge -p '{"spec":{"syncPolicy":{"automated":{"enabled":true,"prune":true,"selfHeal":true}}}}'
```

Right after, re-read the NNCP generations (same command): still the baseline. A bump means NNCPs are re-enacting on
every node; run `nnce` and `brex` at once. Then check over at least three refreshes (about 10 min): `apps` all
Synced/Healthy, and the Namespace stays put:

```bash
ocr get ns openshift-nmstate -o jsonpath='{.metadata.labels}{"\n"}{.metadata.annotations}{"\n"}'
ocr get ns openshift-nmstate -o jsonpath='{range .metadata.managedFields[*]}{.manager} {.operation} {.time}{"\n"}{end}'
                                        # times stop moving; a manager re-writing every few minutes = ping-pong
```

Three managers write those labels: `argocd-controller`, the okderators operator, and OpenShift's
`pod-security-admission-label-synchronization-controller`, which co-owns `audit`/`warn` (not `enforce`) and sets them
to its computed `security.openshift.io/MinimallySufficientPodSecurityStandard` annotation. Before the switch ArgoCD and
the syncer agree on `restricted`; after it that annotation should read `privileged` (the handler SA may use the
`privileged` SCC).

### Step 8: pass criteria

```bash
# nmstate-monitor target up (break-glass, read-only exec)
KUBECONFIG=~/.kube/config-breakglass oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=up%7Bservice%3D%22nmstate-monitor%22%7D'      # value "1", namespace openshift-nmstate
# PrometheusKubernetesListWatchFailures not firing
KUBECONFIG=~/.kube/config-breakglass oc -n openshift-monitoring exec alertmanager-main-0 -c alertmanager -- \
  wget -qO- 'http://localhost:9093/api/v2/alerts?active=true' | jq -r '.[].labels.alertname' | sort | uniq -c
# no restarts in the new operand
ocr -n openshift-nmstate get pods -o jsonpath='{range .items[*]}{.metadata.name} {.spec.nodeName} restarts={.status.containerStatuses[*].restartCount}{"\n"}{end}'
# the three workaround objects are gone
ocr get clusterrole/nmstate-handler-apiserver-reader clusterrolebinding/nmstate-handler-apiserver-reader \
  clusterrolebinding/nmstate-handler-scc-privileged 2>&1 | tail -3                                  # NotFound
ocr -n nmstate get role/nmstate-prometheus-k8s-reader rolebinding/nmstate-prometheus-k8s-reader 2>&1 | tail -2   # NotFound
```

Then the `cluster-health` sweep, clean. After the 24 h soak: the operator deletes namespace `nmstate` and the old
InstallPlans `install-879xr` and `install-775wp` in `openshift-nmstate`.

## Rollback to operatorhubio v0.87.0

The switch in reverse, every step operator-run, with the same read-only checks. v0.87.0 is still the `alpha` head of
`operatorhubio-catalog` (2026-10-26). That catalog is a floating `:latest` (24 h poll), so the rollback pins
`startingCSV` and keeps `Manual`; an unpinned Automatic Subscription would install whatever the head is by then.

0. **v0.87.0 still offered** (read-only, before anything is deleted):

   ```bash
   ocr get packagemanifest -n openshift-marketplace -l catalog=operatorhubio-catalog \
     -o jsonpath='{range .items[?(@.metadata.name=="kubernetes-nmstate-operator")]}{range .status.channels[*]}{.name} {.entries[*].name}{"\n"}{end}{end}'
                                        # alpha ... kubernetes-nmstate-operator.v0.87.0 ...
   ```

   If `kubernetes-nmstate-operator.v0.87.0` is missing: stop and decide another route first. A Subscription pinned to
   a CSV the catalog no longer offers fails with `ResolutionFailed` and leaves the cluster with no NMState operator.
1. **Auto-sync off** on `root-app`, `nmstate-operator`, `nmstate-nncp` (Step 2 commands, `root-app` first).
2. **Delete the CR**, `oc delete nmstate nmstate` (# OPERATOR). Wait until the okderators operand is gone, the MWC
   with the `Fail` webhooks first of all:

   ```bash
   ocr -n openshift-nmstate get ds,deploy                         # only nmstate-operator left
   for r in mutatingwebhookconfiguration/nmstate validatingadmissionpolicy/nncp-validation-policy \
            consoleplugin/nmstate-console-plugin clusterrole/nmstate-handler; do ocr get $r 2>&1 | tail -1; done   # NotFound
   ocr get nncp; nnce; ocr get crd -o name | grep nmstate.io      # NNCPs/NNCEs and 4 CRDs present
   ```

3. **Remove the okderators operator** (# OPERATOR):

   ```bash
   oc -n openshift-nmstate delete subscription kubernetes-nmstate-operator
   oc -n openshift-nmstate delete csv kubernetes-nmstate-operator.v4.21.0-2026-10-26-123722
   ```

   Check: CSV and Deployment `nmstate-operator` NotFound, 4 CRDs present.
4. **CRDs:** storedVersions must still be NMState `v1`, NNCP `v1`, NNCE `v1beta1`, NNS `v1beta1` (Step 5 command),
   all served by v0.87.0's CRDs.
5. **Rollback commit** (# OPERATOR). Undo the switch commit `<SW>`, but give the CR back the per-node gate the switch
   used, `spec.nodeSelector: {sudops.pl/nmstate-handler: "true"}`, so the rollback is gated per node too (v0.87.0
   honours `spec.nodeSelector`; the gate was removed after the soak on 2026-10-27):

   ```bash
   SW=<sha of 'nmstate: move to the okderators 4.21 test build'>
   git checkout "$SW^" -- components/operators/nmstate/templates/handler-scc-binding.yaml \
     components/operators/nmstate/templates/handler-apiserver-rbac.yaml \
     components/operators/nmstate/templates/prometheus-metrics-rbac.yaml
   ```

   - `values.yaml`: `source: operatorhubio-catalog`, `startingCSV: kubernetes-nmstate-operator.v0.87.0`,
     `installPlanApproval: Manual` (unchanged).
   - `templates/operator.yaml` Namespace: back to the three `pod-security.kubernetes.io/*: restricted` labels;
     drop `name`, `openshift.io/cluster-monitoring` and the `openshift.io/node-selector` annotation.

   Before the push, add `sudops.pl/nmstate-handler: "true"` to node4 only in
   `components/cluster-config/node-labels/values.yaml` (with the CR deleted no handler runs, so this changes nothing
   on the nodes). Then `helm lint` + `helm template` this chart,
   commit `nmstate: roll back to operatorhubio v0.87.0`, push. The operand returns to namespace `nmstate`; if that
   namespace was deleted after the soak, the operator recreates it. Labels and the annotation the okderators
   operator applied to `openshift-nmstate` may stay behind (it co-owns them in managedFields); they are harmless to
   v0.87.0.
6. **Install v0.87.0:** sync `nmstate-operator` by hand with prune at the rollback commit (Step 5 commands, with
   the revision check); the InstallPlan must name only `kubernetes-nmstate-operator.v0.87.0`; approve it
   (# OPERATOR). If namespace `nmstate` was deleted after the soak, the sync can fail at wave 6 (the restored
   Role/RoleBinding in `nmstate`) with namespace `nmstate` not found, before v0.87.0 has recreated it: re-sync once.
   Check: CSV `Succeeded`, `HANDLER_NAMESPACE=nmstate` in Deployment `nmstate-operator`, CR recreated at wave 5, MWC
   `nmstate` webhooks to namespace `nmstate`. Then Step 6 per node with namespace `nmstate` in place of
   `openshift-nmstate`, re-adding each node's label in turn. Leave any later upgrade InstallPlan unapproved.
7. **Auto-sync back on:** Step 7, gate included (`nmstate-nncp` Synced, NNCPs at their baseline generation), then
   watch `apps` stay Synced.
