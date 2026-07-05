// Reusable cluster health-review workflow for the homelab (3-node OKD 4.20 + Rook-Ceph + CNPG).
//
// INVOKE:  Workflow({ scriptPath: "workflows/health-review.js" })
//          (named resolution — Workflow({name:"health-review"}) — only covers built-in
//           workflows, so this repo-tracked script is invoked by scriptPath.)
//          Optional: pass { eventWindow: "60" } as args to widen the warning-event tail.
//
// PURPOSE: the canonical "where are we / how's it going" sweep — cluster core health +
//          backups + alerts/events/network — fanned out read-only and synthesized into a
//          GREEN/YELLOW/RED briefing with an explicit actionable list. Safe to run any time:
//          every probe is READ-ONLY under the readonly SA (no exec, no mutations).
//
// This is the distilled, reusable form of the ad-hoc session-start / "how's it going" sweeps.
// Keep the KNOWN_BENIGN list current as the cluster's documented false-positives evolve
// (mirror CLAUDE.md).

export const meta = {
  name: 'health-review',
  description: 'Read-only cluster health review: core health + backups + alerts/events → GREEN/YELLOW/RED briefing',
  phases: [
    { title: 'Probe', detail: 'parallel: core health (nodes/argo/ceph/cnpg) + backups/alerts/events/network' },
    { title: 'Synthesize', detail: 'GREEN/YELLOW/RED briefing + actionable items' },
  ],
}

const KC = 'export KUBECONFIG=$HOME/.kube/config-readonly'

// Documented false-positives on THIS cluster — do not raise these as problems.
const KNOWN_BENIGN = `KNOWN-BENIGN (never flag as a problem): BLUESTORE_SLOW_OP_ALERT (consumer-NVMe fsync, hair-trigger); CephPGImbalance (Rook rule lacks device-class grouping — 2-tier cluster); cnpg-clusters + immich ArgoCD OutOfSync/Healthy (CNPG operator-managed field drift); nmstate-handler / multus / haproxy / router cumulative restarts; KubeJobFailed on completed one-shot bootstrap Jobs; transient collect-profiles OLM one-shot Error pods; OLMv1 operator-controller crashloop (chronic, pre-existing).`

const CLUSTER = `Cluster: 3-node OKD 4.20 (Kube 1.33), nodes node4/5/6 (all control-plane+worker, no drain headroom). Storage = Rook-Ceph v1.19.5 / Ceph Squid, host-network, 6 OSDs (3 NVMe + 3 HDD), full capacity ~13538691661824 bytes. Data DBs = CloudNativePG (media-postgres 3 instances, immich-postgres 1) with offsite WAL+base backups to Cloudflare R2 via the barman-cloud plugin (verify via bucket + the plugin-barman-cloud NATIVE sidecar logs, NOT CNPG status conditions).`

const SCHEMA = {
  type: 'object', additionalProperties: false, required: ['area', 'status', 'summary', 'findings'],
  properties: {
    area: { type: 'string' },
    status: { type: 'string', enum: ['GREEN', 'YELLOW', 'RED'] },
    summary: { type: 'string' },
    findings: {
      type: 'array',
      items: {
        type: 'object', additionalProperties: false, required: ['severity', 'title', 'detail'],
        properties: {
          severity: { type: 'string', enum: ['info', 'low', 'medium', 'high', 'critical'] },
          title: { type: 'string' },
          detail: { type: 'string' },
          evidence: { type: 'string' },
          actionable: { type: 'boolean' },
        },
      },
    },
    keyMetrics: { type: 'string' },
    blindSpots: { type: 'string' },
  },
}

const tail = (args && args.eventWindow) ? String(args.eventWindow) : '40'

phase('Probe')
const results = await parallel([
  // A — cluster core health
  () => agent(`${CLUSTER}\n${KNOWN_BENIGN}

PROBE A — cluster CORE health (read-only; ${KC}).
- date -u (report the cluster clock).
- oc get nodes -o wide (all Ready?); oc get mcp master (UPDATED=True, not Degraded, machineCount==readyMachineCount).
- oc describe nodes | grep -iE "MemoryPressure|DiskPressure|PIDPressure" (any True?).
- oc get co --no-headers | awk '$3!="True"||$4!="False"||$5!="False"{print $1,$3,$4,$5}' (ClusterOperators not Available/Progressing=F/Degraded=F).
- oc -n openshift-gitops get applications -o custom-columns=NAME:.metadata.name,SYNC:.status.sync.status,HEALTH:.status.health.status --no-headers | awk '$0 !~ /Synced.*Healthy/' (only known-benign expected; diagnose anything else).
- oc get csv -A --no-headers | awk '$NF!="Succeeded"'; oc get certificate -A --no-headers | awk '$0!~/True/'; oc get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded --no-headers (ignore Completed/transient).
- Pod restart outliers: oc get pods -A -o jsonpath (containerStatuses restartCount>15) — flag non-benign.
- Ceph: oc -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.health} {.status.ceph.details} cap={.status.ceph.capacity.bytesTotal}' — benign warns only, full 6-OSD capacity, no nearfull/mon-down/pg-degraded/mgr-crash.
- CNPG: oc get cluster -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,PHASE:.status.phase,READY:.status.readyInstances --no-headers (healthy + expected ready counts).
Classify RED on node down / CO Degraded / Ceph non-benign / app OutOfSync-non-benign / CNPG unhealthy; YELLOW on minor; GREEN if all clean. Give exact offenders + key metrics.`,
    { label: 'health:core', phase: 'Probe', schema: SCHEMA, effort: 'medium' }),

  // B — backups + alerts/events + network
  () => agent(`${CLUSTER}\n${KNOWN_BENIGN}

PROBE B — backups + alerts/events + network (read-only; ${KC}).
- R2 offsite backups: oc get backup -A -o custom-columns=NS:.metadata.namespace,NAME:.metadata.name,METHOD:.spec.method,PHASE:.status.phase,STOPPED:.status.stoppedAt --sort-by=.metadata.creationTimestamp --no-headers | tail -14 — newest plugin (R2) base per cluster completed? local volumeSnapshot dailies completed (not stuck 'started')? Report newest completed base + timestamp per cluster.
- WAL archiving: for both CNPG clusters, oc -n <ns> get cluster <name> -o jsonpath of the ContinuousArchiving condition (want True). If False, read the plugin-barman-cloud sidecar logs (oc -n <ns> logs <pod> -c plugin-barman-cloud --tail=30 | grep -iE 'archive|error|denied|endpoint') for the cause.
- Alerts: readonly SA CANNOT read Thanos /api/v1/alerts (needs CREATE) — note as blind spot, infer from below. Do NOT break-glass.
- oc get events -A --field-selector type=Warning --sort-by=.lastTimestamp 2>/dev/null | tail -${tail} — bucket by reason/namespace; ignore known-benign; flag real (FailedMount, OOMKilling, repeated live-workload BackOff, FailedScheduling).
- Network: oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount --no-headers (all Ready, no cascade). oc -n openshift-gitops get pods | grep repo-server (healthy, no DeadlineExceeded).
Classify RED on backup archiving failing / real firing condition / OVN cascade; YELLOW on isolated benign noise; GREEN if quiet. Summarize + list any actionable.`,
    { label: 'health:backups-alerts', phase: 'Probe', schema: SCHEMA, effort: 'medium' }),
]).then(rs => rs.filter(Boolean))

phase('Synthesize')
const report = await agent(`Write a concise cluster health-review briefing for the operator of this 3-node OKD homelab.

Probe results (JSON):
${JSON.stringify(results, null, 2)}

Markdown, tight:
- Headline: overall state (worst subsystem status) in one line.
- Status block: Core health, R2 backups, Alerts/events, Network — each one line with the key metric.
- Actionable: ONLY genuinely actionable items (skip GREEN/benign). Each = root cause + suggested resolution + mark if it's a guardrail-gated cluster mutation the USER must run. If none, say "none — all clear."
- Blind spots: one line on what the readonly SA couldn't see (live Prometheus alerts, R2 bucket object listing, per-OSD ceph df, in-pod file state).
Be precise; use only the findings; don't restate benign items as problems. Relayed to the operator.`,
  { label: 'health:synthesize', phase: 'Synthesize', effort: 'high' })

return { report, statuses: results.map(r => ({ area: r.area, status: r.status })) }
