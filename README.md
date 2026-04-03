# okd-homelab-gitops

GitOps repository for a 3-node bare-metal OKD 4.20 homelab cluster managed by ArgoCD.

**Repo:** https://github.com/sudoom/homelab

## Architecture

```
Manual bootstrap (one-time)
  └── ArgoCD Operator + Instance
        └── Root App-of-Apps (Application)
              ├── Wave 0: CatalogSources (operatorhubio-catalog)
              ├── Wave 1: Operators (NMState, Rook-Ceph)
              ├── Wave 2: Cluster Config (NMState NNCPs)
              └── Wave 3: Storage (CephCluster, pools, StorageClasses)
```

## Bootstrap

Only the ArgoCD operator installation is manual. Everything else is Argo-managed.

```bash
# 1. Install ArgoCD operator
oc apply -f bootstrap/argocd/templates/namespace.yaml
oc apply -f bootstrap/argocd/templates/operatorgroup.yaml
oc apply -f bootstrap/argocd/templates/subscription.yaml

# 2. Wait for operator
oc get csv -n openshift-gitops -w
# Wait for Phase: Succeeded

# 3. Wait for default ArgoCD instance (the operator auto-creates one)
oc get pods -n openshift-gitops -w
# Wait for all pods Running

# 4. Apply the root App-of-Apps
oc apply -f bootstrap/root-app/root-application.yaml
```

## Repo Structure

```
bootstrap/
  argocd/           # ArgoCD operator (manual apply, one-time)
  root-app/         # Root Application pointing to all components
components/
  catalog-sources/  # OLM CatalogSources (operatorhubio)
  operators/
    nmstate/        # NMState operator subscription
    rook-ceph/      # Rook-Ceph operator via Helm
  cluster-config/
    nmstate-nncp/   # Storage network NNCPs per node
  storage/
    ceph-cluster/   # CephCluster CR, toolbox
    ceph-storage-classes/  # Block pools, StorageClasses
```

## Cluster

| Node | Frontnet (VLAN 5) | Backnet (VLAN 10) | Role |
|------|-------------------|-------------------|------|
| Node 4 | 192.168.1.7 | 192.168.10.2 | control-plane + worker |
| Node 5 | 192.168.1.8 | 192.168.10.3 | control-plane + worker |
| Node 6 | 192.168.1.9 | 192.168.10.4 | control-plane + worker |

- **API VIP:** 192.168.1.240
- **Ingress VIP:** 192.168.1.241
- **Domain:** okd.sudops.pl
