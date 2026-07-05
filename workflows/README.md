# workflows/

Claude Code **orchestration scripts** (multi-agent workflows) — **not** ArgoCD manifests.
ArgoCD only syncs what `bootstrap/root-app/` points at (`components/`), so this directory is
inert to the cluster; it's version-controlled tooling for running repeatable analyses.

These are invoked with the Claude Code `Workflow` tool by **path** (named resolution only
covers built-in workflows like `deep-research` / `code-review`, and `.claude/` is gitignored —
hence a tracked `workflows/` dir invoked by `scriptPath`):

```
Workflow({ scriptPath: "workflows/<name>.js" })
```

Every script here is **read-only** against the cluster — it uses the readonly SA
(`KUBECONFIG=~/.kube/config-readonly`), never `exec`, never a mutation. Safe to run any time.

| Script | What it does | Invoke |
|---|---|---|
| `health-review.js` | Full cluster health review — core health (nodes/argo/ceph/cnpg) + backups + alerts/events/network, fanned out and synthesized into a GREEN/YELLOW/RED briefing with an actionable list. The reusable form of the ad-hoc "how's it going" / session-start sweeps. | `Workflow({ scriptPath: "workflows/health-review.js" })` (optional args `{ eventWindow: "60" }`) |

**Maintenance:** keep each script's `KNOWN_BENIGN` / cluster-facts constants in sync with
`CLAUDE.md` as documented false-positives and cluster shape evolve.
