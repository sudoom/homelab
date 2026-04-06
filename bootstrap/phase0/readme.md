# Phase 0 — Manual Bootstrap

Everything in this directory is applied **once, by hand**. After this, ArgoCD manages the cluster.

## Prerequisites

- OKD 3-node cluster healthy (`oc get nodes` — all Ready)
- `oc` CLI authenticated as cluster-admin
- GitHub repo `sudoom/homelab` exists (can be empty — we push before step 4)

## Execution

### Step 1: Install okderators catalog

```bash
oc apply -f bootstrap/phase-0/01-catalog-source.yaml

# Wait for READY (takes 1-2 minutes for image pull)
oc get catalogsource okderators -n openshift-marketplace -w
# READY column should appear

# Verify operators are available
oc get packagemanifest | grep -E "gitops|nmstate|cert-manager"
```

**Expected output** (operator names — record these):
```
openshift-gitops-operator    OKDerators    <age>
kubernetes-nmstate-operator  OKDerators    <age>
cert-manager-operator        OKDerators    <age>
```

If `openshift-gitops-operator` is not listed, check:
```bash
oc get packagemanifest -o wide | grep okderators
```

### Step 2: Verify channel name

```bash
oc get packagemanifest openshift-gitops-operator \
  -o jsonpath='{.status.channels[*].name}'
```

If the output is NOT `latest`, edit `02-gitops-operator.yaml` and replace the `channel:` value.

### Step 3: Install OpenShift GitOps operator

```bash
oc apply -f bootstrap/phase-0/02-gitops-operator.yaml

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
oc apply -f bootstrap/phase-0/03-cluster-admin-rbac.yaml
```

### Step 6: Push repo to GitHub

```bash
cd okd-homelab-gitops
git init
git remote add origin git@github.com:sudoom/homelab.git
git add -A
git commit -m "initial: bootstrap + gitops structure"
git branch -M main
git push -u origin main
```

### Step 7: Apply root Application

```bash
oc apply -f bootstrap/phase-0/04-root-application.yaml
```

ArgoCD now takes over. Watch progress in the ArgoCD UI — Applications appear in sync wave order:
1. CatalogSources (wave 0)
2. Operators — NMState, Rook-Ceph (wave 1)
3. Storage NNCPs (wave 2)
4. CephCluster (wave 3)
5. StorageClasses (wave 4)

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