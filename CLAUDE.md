# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Homelab GitOps repository for a **3-node bare-metal OKD 4.20 cluster** (OpenShift Kubernetes Distribution). The cluster is managed declaratively using **ArgoCD** with an app-of-apps pattern and Helm-based templating.

- **Cluster domain:** okd.sudops.pl
- **Nodes:** 3 control-plane+worker nodes (192.168.1.7-9, storage backnet 192.168.10.2-4)
- **Git remote:** `git@github.com:sudoom/homelab.git`
- **Branches:** `master` (production/main), `develop` (working branch)

## Architecture

### Two-layer structure

1. **`okd-homelab-gitops/`** — Core cluster infrastructure managed by ArgoCD root app
   - `bootstrap/argocd/` — One-time ArgoCD operator setup (Subscription, OperatorGroup)
   - `bootstrap/root-app/` — Root Application that generates all child Applications via Helm templating
   - `components/` — Infrastructure components deployed in sync waves:
     - Wave 0: CatalogSources (OLM)
     - Wave 1: Operators (NMState, Rook-Ceph)
     - Wave 2: Cluster config (NMState NNCPs for storage network)
     - Wave 3: CephCluster
     - Wave 4: Ceph StorageClasses

2. **Root-level directories** — Application workloads and configuration (deployed separately from the root app):
   - `media/` — Media stack: Jellyfin, Bazarr, Radarr, Sonarr, Prowlarr
   - `keepers/` — Transmission+OpenVPN, WebTLO
   - `ai/` — Open WebUI (connects to external Ollama at 192.168.1.4:11434)
   - `monitoring/` — ServiceMonitors, Grafana dashboards, Prometheus values
   - `network/` — Cilium LB IP pool (192.168.1.210-220), L2 announcement policy
   - `storage/` — NFS CSI (server 192.168.1.2:/volume1/kubenfs), Longhorn values

### Key technologies
- **Storage:** Rook-Ceph (primary, NVMe RAID, replicated×3), NFS CSI, Longhorn
- **CNI:** Cilium (with LB, L2 announcement, ingress controller)
- **Service mesh:** Istio (multiple config variants in root-level values files)
- **Monitoring:** Prometheus + Grafana
- **Automation:** Renovate Bot for dependency updates (all .yaml files scanned)

### ArgoCD sync policy
All managed Applications use: automated prune + selfHeal, ServerSideApply, retry 5× with exponential backoff (5s→3m), CreateNamespace=true.

## Working with this repo

### Helm charts
Each component under `okd-homelab-gitops/components/` is a standalone Helm chart. To validate templates:
```bash
helm template <release-name> okd-homelab-gitops/components/<component-path>
```

For charts with external dependencies (e.g., rook-ceph operator):
```bash
cd okd-homelab-gitops/components/operators/rook-ceph && helm dependency build
```

### Adding a new ArgoCD-managed component
1. Create a Helm chart under `okd-homelab-gitops/components/<category>/<name>/`
2. Add an entry in `okd-homelab-gitops/bootstrap/root-app/values.yaml` with appropriate sync wave
3. The root app templates (`bootstrap/root-app/templates/applications.yaml`) will auto-generate the ArgoCD Application

### Application workloads (media, keepers, ai)
These are plain Kubernetes YAML manifests applied directly (not managed by the root app). They use PVCs backed by `nfs-csi` or `longhorn` StorageClasses.

### Sealed secrets
The `sealed-secret/` directory exists for SealedSecret resources. Secrets (e.g., VPN credentials in `keepers/`) are stored as Kubernetes Secrets in the manifests.

## Conventions

- Root-level `*-values.yaml` files are Helm values for tools installed outside the root app (Cilium, Istio, Prometheus, ArgoCD, Kiali)
- The root app targets the `main` branch in its Application spec — be aware of branch alignment with the `master`/`develop` workflow
- Renovate handles Docker image tag updates automatically via PRs labeled `dependencies`
