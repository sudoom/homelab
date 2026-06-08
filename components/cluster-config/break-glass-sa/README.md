# break-glass-sa

Long-lived `cluster-admin` ServiceAccount + token Secret. Last-resort recovery channel when the normal `oc login --token=...` flow is broken (OAuth pods crashlooping, console route unreachable, expired kubelet certs blocking the apps VIP, etc.).

## Why this exists

After a 10-day power-off / power-on cycle on 2026-06-08 the cluster came up with:

- ~270 pending `node-bootstrapper` kubelet client CSRs (machine-approver doesn't auto-approve them on bare-metal-without-Machine-API);
- `tls: internal error` on every kubelet `:10250` (serving cert couldn't be renewed without a valid client cert);
- apps VIP `192.168.1.241` unclaimed by keepalived (health probe couldn't reach kubelet);
- one OAuth pod in CrashLoopBackOff with `dial tcp 172.30.0.1:443: i/o timeout` (broken pod→service-IP egress, the cascade-runbook ovnkube-node-restart scenario).

The web console was unreachable, so the "Copy login command" path for getting an `oc login --token=` was also unavailable. Recovery required SSH'ing to a control-plane node and using the per-node `localhost-recovery.kubeconfig` to approve CSRs and bounce pods — a ~90-minute exercise in bash quoting.

This chart pre-stages a write-capable kubeconfig that works in exactly that scenario. The SA token authenticates against `kube-apiserver` directly; no oauth-server, no console, no cert renewal in the path.

## What ships

- `automation` ServiceAccount `break-glass-admin` (chart reuses the namespace from `automation-sa`; this chart does NOT create it)
- `ClusterRoleBinding` `break-glass-admin` → built-in `cluster-admin`
- `Secret` `break-glass-admin-token` (type `kubernetes.io/service-account-token`) — `kube-controller-manager` populates `data.token` and `data.ca.crt` after sync

## Extracting the kubeconfig

After the chart syncs, run `bin/setup-breakglass-kubeconfig.sh` from the repo root. This writes `~/.kube/config-breakglass` with mode 0600.

Test it:

```bash
KUBECONFIG=~/.kube/config-breakglass oc get nodes
```

## Blast radius and operational rules

- The kubeconfig has `cluster-admin` scope — equivalent to a kubeadmin login. Compromise = total cluster compromise.
- **Do not commit the kubeconfig.** The repo `.gitignore` excludes `config-breakglass` and `*-kubeconfig` as belt-and-braces, but the canonical location is `~/.kube/config-breakglass` (outside the repo).
- **Do not store on cloud-synced directories** (no iCloud, no Dropbox). `~/.kube/` is the right place.
- **Do not use for routine work.** Normal day-to-day stays on the OAuth-issued token (`oc login --token=…`); the break-glass token is exercised only when the normal path is broken.

## Rotation

```bash
oc -n automation delete secret break-glass-admin-token
# kube-controller-manager mints a fresh token within seconds; re-run:
bin/setup-breakglass-kubeconfig.sh
```

To revoke entirely (decommissioning the SA): set `enabled: false` in `bootstrap/root-app/values.yaml` and commit. ArgoCD prunes the SA + binding + Secret on the next sync; the JWT becomes unverifiable immediately.
