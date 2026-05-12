# `kubernetes-nmstate-operator` (community-operators) CSV is missing two clusterPermissions for `nmstate-handler`

**Upstream:** https://github.com/redhat-openshift-ecosystem/community-operators-prod
**Package:** `kubernetes-nmstate-operator`
**Affected channel/version:** Whatever ships on `community-operators` `CatalogSource` for OKD 4.20 (Kubernetes 1.31) — confirmed observed on the version installed mid-April 2026.
**Severity:** Functional — *new* `nmstate-handler` DaemonSet pods fail to admit or crash on startup; *existing* pods (admitted before the missing permissions mattered) keep running, masking the issue. Triggers a partial outage the next time any handler pod is rescheduled (node reboot, NNCP roll, eviction).

## Summary

The CSV's `spec.install.spec.clusterPermissions` is missing two permissions that the `nmstate-handler` DaemonSet pods require. These can be discovered only by either (a) a fresh handler pod attempting to start on a new node, or (b) any condition that forces a previously-admitted pod to restart with the current SCC / RBAC checks. Existing pods admitted at install time stay running because:

- The privileged-SCC `use` check happens only at admission, not at runtime — pods already admitted with `privileged` SCC stay admitted, and the watch loop never re-checks the binding.
- The `apiservers.config.openshift.io` read happens only on startup (fetching the cluster's TLS profile to derive cipher settings). Existing pods cached the result; new pods crash on container startup with a `Forbidden` error.

## Specific missing permissions

### 1. `use` verb on the `privileged` SCC

Needs a `ClusterRoleBinding` (or equivalent in the CSV's `clusterPermissions`) granting:

```yaml
- apiGroups: ["security.openshift.io"]
  resourceNames: ["privileged"]
  resources: ["securitycontextconstraints"]
  verbs: ["use"]
```

…bound to `ServiceAccount: nmstate-handler` in the `nmstate` namespace.

Without it, new handler pods are rejected at admission:

```
pods "nmstate-handler-XXXXX" is forbidden: unable to validate against any security context constraint:
  provider "privileged": Forbidden: not usable by user or serviceaccount
  ... [all other providers also forbidden]
```

### 2. `get/list/watch` on `apiservers.config.openshift.io`

Needs a `ClusterRole`/`ClusterRoleBinding` (or equivalent) granting:

```yaml
- apiGroups: ["config.openshift.io"]
  resources: ["apiservers"]
  verbs: ["get", "list", "watch"]
```

…bound to `ServiceAccount: nmstate-handler` in the `nmstate` namespace.

Without it, the handler crashes early in startup when it queries the cluster `apiservers/cluster` object for TLS profile config:

```
panic: apiservers.config.openshift.io "cluster" is forbidden:
  User "system:serviceaccount:nmstate:nmstate-handler" cannot get resource
  "apiservers" in API group "config.openshift.io" at the cluster scope
```

## Steps to reproduce

1. Install `kubernetes-nmstate-operator` from `community-operators` on an OKD 4.20 cluster:
   ```yaml
   apiVersion: operators.coreos.com/v1alpha1
   kind: Subscription
   metadata:
     name: kubernetes-nmstate-operator
     namespace: nmstate
   spec:
     channel: stable  # or whatever the default channel is
     name: kubernetes-nmstate-operator
     source: community-operators
     sourceNamespace: openshift-marketplace
   ```
2. Wait for the operator to become Ready and create the `NMState/nmstate` CR — handler DaemonSet rolls out across nodes.
3. **At this stage, everything appears fine.** The handler pods admit and run, because OLM / OperatorHub install machinery happens to satisfy the admission check via grandfathered SCC ownership.
4. Trigger a handler pod restart on *any* node — e.g.:
   - Reboot the node, or
   - `oc -n nmstate delete pod nmstate-handler-XXX`, or
   - Apply any NodeNetworkConfigurationPolicy that triggers handler re-roll.
5. Observe the new pod fails admission with `provider "privileged": Forbidden: not usable by user or serviceaccount`.
6. Add a temporary local `ClusterRoleBinding` granting `use` on SCC `privileged` to `system:serviceaccount:nmstate:nmstate-handler`. New pod now admits but crashes in the container startup with the `apiservers.config.openshift.io` forbidden error.
7. Add a second `ClusterRole` + `ClusterRoleBinding` granting `get/list/watch` on `apiservers.config.openshift.io` to the same SA. Pod now runs cleanly.

## Expected behavior

The CSV should ship both permissions in `spec.install.spec.clusterPermissions` so the operator's RBAC reconciler creates the bindings automatically. New handler pods admit and start without manual intervention.

## Actual behavior

Both permissions are missing from the CSV. New handler pods fail to start (one or both ways depending on which permission is hit first). Existing pods keep working because their admission/startup-time checks were satisfied (somehow — possibly by the install-time RBAC the OLM operator hub uses, which doesn't outlive the install transaction).

## Workaround (local fix)

In the homelab repo:

- `components/operators/nmstate/templates/handler-scc-binding.yaml` — `ClusterRoleBinding` for the SCC `use`.
- `components/operators/nmstate/templates/handler-apiserver-rbac.yaml` — `ClusterRole` + `ClusterRoleBinding` for the apiservers reads.

Both shipped 2026-05-11 alongside an NNCP roll that triggered the issue.

## Notes

- The Red Hat *productized* `kubernetes-nmstate-operator` (from the `redhat-operators` catalog) likely has these permissions correctly. The bug is in the community-operators repackaging.
- Worth checking whether the upstream `kubernetes-nmstate-operator` (https://github.com/nmstate/kubernetes-nmstate) project's CSV manifest is correct and the community-operators packaging dropped the permissions, vs. the upstream CSV itself being incomplete. Likely the former.
- If a **third** permission surfaces on a future fresh handler pod, audit the full set rather than patching incrementally — repackaging RBAC piecewise is brittle.

## Local context

- OKD 4.20 (Kube 1.31), 3-node bare-metal cluster.
- `nmstate` namespace, `OperatorGroup` with `targetNamespaces: [nmstate]`.
- `community-operators` `CatalogSource` (the okderators-built `kubernetes-nmstate-operator` has a separate ImageStream bug — see `nmstate-imagestream-bug.md` in the same repo).
