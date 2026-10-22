# Phase 0 — Manual Bootstrap

Everything in this directory is applied **once, by hand**. After this, ArgoCD manages the cluster.

## Prerequisites

- OKD 3-node cluster healthy (`oc get nodes` — all Ready)
- `oc` CLI authenticated as cluster-admin
- GitHub repo `sudoom/homelab` exists (can be empty — we push before step 4)

## Execution

### Step 1: Install okderators catalog

```bash
oc apply -f bootstrap/phase0/01_catalog_source.yaml

# Wait for READY (takes 1-2 minutes for image pull)
oc get catalogsource okderators -n openshift-marketplace -w
# READY column should appear

# Verify operators are available
oc get packagemanifest | grep -E "gitops|nmstate|cert-manager"
```

**Expected output** (operator names — record these):
```
gitops-operator              OKDerators    <age>
kubernetes-nmstate-operator  OKDerators    <age>
cert-manager-operator        OKDerators    <age>
```

If `gitops-operator` is not listed, check:
```bash
oc get packagemanifest -o wide | grep okderators
```

### Step 2: Verify channel name

```bash
oc get packagemanifest gitops-operator \
  -o jsonpath='{.status.channels[*].name}'
```

okderators publishes one channel, `alpha`. If the output differs, edit `02_gitops_operator.yaml` and replace the `channel:` value.

### Step 3: Install OpenShift GitOps operator

```bash
oc apply -f bootstrap/phase0/02_gitops_operator.yaml

# Wait for CSV
oc get csv -A -w | grep gitops
# Wait for Phase: Succeeded

# Wait for pods
oc get pods -n openshift-gitops -w
# All pods should reach Running (takes 2-3 minutes)
```

### Step 4: Verify ArgoCD instance and access

```bash
# Check the default ArgoCD instance was created
oc get argocd -n openshift-gitops
# Should show: openshift-gitops

# Get the Route URL
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'

# Get admin password
oc get secret openshift-gitops-cluster -n openshift-gitops \
  -o jsonpath='{.data.admin\.password}' | base64 -d && echo
```

Open the Route URL in a browser and login with `admin` + the password.

### Step 5: Verify cluster-admin RBAC

```bash
oc get clusterrolebinding | grep gitops | grep cluster-admin
```

If no output (ArgoCD doesn't have cluster-admin), apply:

```bash
oc apply -f bootstrap/phase0/03_cluster_admin_rbac.yaml
```

### Step 6: Repo credentials

The root Application pulls `git@github.com:sudoom/homelab.git` (branch `master`) over SSH. `04_credential_template.yaml`
is a `repo-creds` Secret template with placeholders: fill in the base64 SSH private key and repo URL in a copy outside
the repo, apply that copy, and never commit it.

```bash
oc apply -f <filled copy of 04_credential_template.yaml>
```

### Step 7: Apply root Application

```bash
oc apply -f bootstrap/phase0/05_root_application.yaml
```

ArgoCD now takes over. Applications appear in sync-wave order; the waves are set per app in
`bootstrap/root-app/values.yaml`.

## Troubleshooting

### CatalogSource stuck / not READY

```bash
oc describe catalogsource okderators -n openshift-marketplace
oc get pods -n openshift-marketplace | grep okderators
oc logs -n openshift-marketplace <okderators-pod>
```

Common cause: image pull failure. Verify nodes can reach `quay.io`.

### GitOps operator CSV stuck in Pending

```bash
oc get installplan -n openshift-operators
oc describe installplan <name> -n openshift-operators
```

Common cause: wrong channel name. Re-check step 2.

### ArgoCD Application shows "namespace not managed"

This means the ArgoCD instance doesn't have cluster-scoped permissions. Apply step 5.

### Root Application sync fails with "repo not found"

Verify the repo is public, or add deploy keys:
```bash
# If private repo, add a deploy key in ArgoCD:
oc get route openshift-gitops-server -n openshift-gitops -o jsonpath='{.spec.host}'
# → Settings → Repositories → Connect Repo
```

## Step 8: ArgoCD CephCluster health override (`06_argocd_cephcluster_health.yaml`)

Needed before the GitOps operator moves to Argo CD 3.3+ (the 1.22 upgrade); harmless on 3.1.

Why: Argo CD 3.3 added a built-in health check that maps CephCluster `HEALTH_WARN` to Degraded. This cluster is
permanently `HEALTH_WARN`, and a Degraded resource fails a multi-wave sync, so `rook-ceph-cluster`'s hourly sync would
fail before its wave-10/11 bootstrap Jobs. The override reports `HEALTH_WARN` as Healthy (warning names in the
message) and only `HEALTH_ERR` as Degraded. The ArgoCD CR is operator-defaulted and not in git, hence a hand-applied patch.

```bash
# The merge patch REPLACES the whole spec.resourceHealthChecks list: confirm the live CR has none first
oc get argocd openshift-gitops -n openshift-gitops -o jsonpath='{.spec.resourceHealthChecks}{"\n"}'
oc patch argocd openshift-gitops -n openshift-gitops --type merge \
  --patch-file bootstrap/phase0/06_argocd_cephcluster_health.yaml

# Verify: the operator renders it into argocd-cm
oc get cm argocd-cm -n openshift-gitops \
  -o jsonpath='{.data.resource\.customizations\.health\.ceph\.rook\.io_CephCluster}' | head -5
```

**Re-apply after any GitOps operator reinstall** (the CR is recreated without it).

Offline test of the Lua with the local `argocd` CLI (v3.5.x): put the check under
`data.resource.customizations.health.ceph.rook.io_CephCluster` in a copy of `argocd-cm` and run
`argocd admin settings resource-overrides health <cephcluster.yaml> --argocd-cm-path <argocd-cm.yaml>`.

## Recovering from a failed GitOps operator upgrade (UNTESTED)

Written for the 1.19 to 1.22 upgrade; none of this has been run. Order of preference:

1. **Fix forward.** Use the break-glass kubeconfig (`~/.kube/config-breakglass`, cluster-admin SA token) because
   OAuth/console may be down. Read `oc get csv,installplan,subscription -n openshift-operators` and the operator pod
   logs, and fix the cause.
2. **Last resort: reinstall 1.19.0.** CRDs, the ArgoCD CR and every Application stay in place; only the operator
   is replaced.

```bash
export KUBECONFIG=~/.kube/config-breakglass
# a. remove the Subscription and the installed CSV (not the CRDs, not the ArgoCD CR)
oc delete subscription gitops-operator -n openshift-operators
oc get csv -n openshift-operators | grep gitops        # note the failing CSV name
oc delete csv <gitops-operator.vX.Y.Z...> -n openshift-operators
# b. re-create the Subscription: source okderators, installPlanApproval Manual
oc apply -f bootstrap/phase0/02_gitops_operator.yaml
# c. approve the 1.19.0 InstallPlan (check its clusterServiceVersionNames first; it must list v1.19.0)
oc get installplan -n openshift-operators
oc patch installplan <install-xxxxx> -n openshift-operators --type merge -p '{"spec":{"approved":true}}'
oc get csv -n openshift-operators -w | grep gitops     # wait for Succeeded
# d. re-apply the CephCluster health override
oc patch argocd openshift-gitops -n openshift-gitops --type merge \
  --patch-file bootstrap/phase0/06_argocd_cephcluster_health.yaml
```

If the catalog offers a newer head than 1.19.0 first, the InstallPlan may not list v1.19.0; do not approve it,
and pin the Subscription with `spec.startingCSV: gitops-operator.v1.19.0-2026-02-07-151505`.
