# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

Homelab GitOps repository for a **3-node bare-metal OKD 4.20 cluster** (OpenShift Kubernetes Distribution). The cluster is managed declaratively using **ArgoCD** with an app-of-apps pattern and Helm-based templating.

- **Cluster domain:** okd.sudops.pl
- **Nodes:** 3 control-plane+worker nodes (192.168.1.7-9, storage backnet 192.168.10.2-4)
- **Failure domains:** fd-a (node4), fd-b (node5), fd-c (node6) via `topology.kubernetes.io/zone`
- **Git remote:** `git@github.com:sudoom/homelab.git`
- **Branches:** `master` (production), `develop` (working branch)

## Architecture

### App-of-Apps structure

- `bootstrap/phase0/` — One-time manual bootstrap (CatalogSource, GitOps operator, RBAC, root Application)
- `bootstrap/root-app/` — Root Application that generates all child Applications via Helm templating
- `components/` — Infrastructure components deployed in sync waves:
  - **Wave 0:** Cluster topology (node-labels with failure domains)
  - **Wave 1:** Operators via OLM (cert-manager from okderators, NMState from community-operators)
  - **Wave 2:** Cluster config (cert-manager ClusterIssuer + certificates, NMState NNCPs for storage network)
  - **Wave 3:** TLS consumers (IngressController default cert, APIServer serving cert) and storage
- `bootstrap/root-app/values.yaml` — Central registry of all managed applications with enable/disable flags

### OLM Catalogs
- **okderators** (`quay.io/okderators/catalog-index:4.20`) — OKD community operators (cert-manager)
- **community-operators** — Upstream OperatorHub.io catalog (NMState — okderators build has ImageStream bug)

### TLS / Certificate Management
- cert-manager with Let's Encrypt production (DNS-01 via Cloudflare)
- Public DNS nameservers (1.1.1.1, 8.8.8.8) configured for DNS-01 challenges (cluster DNS can't resolve external domains)
- Wildcard cert `*.apps.okd.sudops.pl` in `openshift-ingress` namespace
- API cert `api.okd.sudops.pl` in `openshift-config` namespace
- Cloudflare API token secret managed manually (planned: ESO + Bitwarden)

### Sync policy
All managed Applications use: automated prune + selfHeal, ServerSideApply, SkipDryRunOnMissingResource, retry 5× with exponential backoff (5s→3m), CreateNamespace=true.

## Working with this repo

### Helm charts
Each component under `components/` is a standalone Helm chart. To validate templates:
```bash
helm template <release-name> components/<category>/<name>/
```

### Adding a new ArgoCD-managed component
1. Create a Helm chart under `components/<category>/<name>/` (operators, cluster-config, storage)
2. Add an entry in `bootstrap/root-app/values.yaml` with appropriate sync wave and enabled: true
3. The root app template (`bootstrap/root-app/templates/applications.yaml`) auto-generates the ArgoCD Application
4. For operators with CRDs: use intra-chart sync-wave annotations (Subscription at wave 1, CR at wave 5) to avoid CRD race conditions

### Commit and push workflow
Changes to `master` are picked up by ArgoCD automatically. Always validate templates with `helm template` before pushing.

## Context management
- Always run `/export` before the conversation is compacted to preserve full context history.

## Conventions

- Root-level `*-values.yaml` files are Helm values for tools installed outside the root app (Cilium, Istio, Prometheus, ArgoCD, Kiali)
- Renovate handles Docker image tag updates automatically via PRs labeled `dependencies`
- Operator components follow the pattern: Namespace + OperatorGroup + Subscription (+ optional CR in later sync wave)
- Cluster-scoped operators (cert-manager) use empty OperatorGroup spec (`spec: {}`)
- Namespace-scoped operators (NMState) use targetNamespaces
