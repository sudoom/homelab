# OKD Logging on a 3-node homelab: Loki + Vector backed by CephObjectStore

The cluster has been running for weeks without centralized logs. `oc logs` works, kube events scroll past in the GUI, and that's it — pod logs vanish on restart, audit events go to disk on each control-plane node and rotate, and there's no way to ask "show me everything that happened across the cluster between 14:00 and 14:05 yesterday." Time to fix that.

This commit lands the full pipeline: `Loki Operator + Cluster Logging Operator` (both okderators v6.3.0, paired release) at sync wave 1, and a `LokiStack + ClusterLogForwarder` chart at sync wave 5 that wires Vector → LokiStack → CephObjectStore S3 bucket. End-to-end GitOps; no manual `oc apply` steps; no out-of-band SealedSecret.

## Why this stack, not alternatives

Quick survey before picking:

- **EFK (Elasticsearch + Fluentd + Kibana)**: the legacy OpenShift Logging stack, *removed* in Cluster Logging v6. Elasticsearch is gone from the operator entirely. Not an option even if I wanted it.
- **Promtail + Loki single-binary on RBD**: feasible but doesn't play with OKD's `ClusterLogForwarder` or audit-log collection. The OKDerator-shipped operator path is simpler — one CRD per side, one source of truth.
- **Vector + Loki via Cluster Logging v6**: what `okderators` ships. Vector replaces Fluentd; LokiStack runs the gateway, distributor, ingesters, queriers, ruler, compactor as one CR. ClusterLogForwarder replaces the old ClusterLogging CR for the pipeline definition. This is the modern shape and it's already packaged.

Vector + LokiStack won.

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                     openshift-logging namespace                   │
│                                                                   │
│  ┌────────────────┐                                               │
│  │ ClusterLog-    │                                               │
│  │ Forwarder CR   │ ──── owns ──→  Vector DaemonSet (one/node)    │
│  │ (instance)     │                  ├─ application logs          │
│  └────────────────┘                  ├─ audit logs                │
│                                      └─ infrastructure logs       │
│                                                │                  │
│                                                ▼                  │
│  ┌────────────────┐                  ┌──────────────────────┐    │
│  │ LokiStack CR   │ ──── owns ──→    │  loki-gateway Service│    │
│  │ (logging-loki) │                  │  (multi-tenant)      │    │
│  │  size: 1x.demo │                  └──────────────────────┘    │
│  └────────────────┘                            │                  │
│           │                                    │ chunks +         │
│           │                                    │ index            │
│           ▼                                    ▼                  │
│  ┌────────────────┐                  ┌──────────────────────┐    │
│  │ Secret/        │ ──── reads ──→   │ HTTP S3              │    │
│  │ loki-storage   │                  │ (in-cluster)         │    │
│  │ (translated)   │                  └──────────────────────┘    │
│  └────────────────┘                            │                  │
│           ▲                                    ▼                  │
│           │ writes                  ┌──────────────────────┐     │
│  ┌────────────────┐                 │ rook-ceph-rgw-...   │     │
│  │ Pre-sync Job   │                 │ Service (port 80)    │     │
│  │ (translator)   │                 └──────────────────────┘     │
│  └────────────────┘                            │                  │
│           ▲                                    │                  │
│           │ reads                              │                  │
│  ┌────────────────┐  ┌──────────────────┐      │                  │
│  │ ConfigMap/loki │  │ Secret/loki      │      │                  │
│  │ BUCKET_NAME +  │  │ AWS_ACCESS_KEY + │      │                  │
│  │ BUCKET_HOST    │  │ AWS_SECRET       │      │                  │
│  └────────────────┘  └──────────────────┘      │                  │
│           ▲                  ▲                 │                  │
│           │ provisions       │                 │                  │
│  ┌────────────────┐                            │                  │
│  │ ObjectBucket-  │                            │                  │
│  │ Claim (loki)   │ ─── creates bucket ───────→│                  │
│  │ SC: ceph-bucket│                            │                  │
│  └────────────────┘                            │                  │
└──────────────────────────────────────────────────┼────────────────┘
                                                   │
                                                   ▼
                            ┌──────────────────────────────┐
                            │    rook-ceph namespace        │
                            │                               │
                            │  CephObjectStore + RGW        │
                            │  ceph-objectstore.rgw.        │
                            │   buckets.{data,index,...}    │
                            └──────────────────────────────┘
```

## Operator subscriptions (sync wave 1)

`components/operators/loki-operator/` and `components/operators/cluster-logging/`. Same chart shape as the others — one Helm template producing `Namespace + OperatorGroup + Subscription`.

Two namespace patterns:

- **`openshift-operators-redhat`** for `loki-operator`. The Loki Operator's CSV declares `installModes: AllNamespaces=true` and rejects everything else, so it's a cluster-scoped install. The `openshift.io/cluster-monitoring=true` label on the namespace is what lets the platform Prometheus scrape its metrics — without it, the operator's own metrics aren't visible.
- **`openshift-logging`** for `cluster-logging`. Namespace-scoped via `OperatorGroup.targetNamespaces`. Standard OKD location for the logging stack instance.

Both subscribe to the `okderators` catalog at `channel: alpha` (the only channel) and pin to whatever the catalog has — currently `v6.3.0-2025-08-08-133408`. They're a paired release: Loki Operator + Cluster Logging Operator versioned together; the OKD logging team doesn't ship them out of step.

## The OBC → LokiStack-Secret translation

This is the load-bearing piece. Two facts that don't compose cleanly:

1. **The OBC controller produces** a ConfigMap (`BUCKET_HOST`, `BUCKET_PORT`, `BUCKET_NAME`, `BUCKET_REGION`) and a Secret (`AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`) in the OBC's namespace. Standard PVC-of-buckets shape.
2. **The LokiStack CR expects** a Secret with keys `endpoint`, `bucketnames`, `access_key_id`, `access_key_secret`, `region` — *different keys, different format* (the endpoint is composed from BUCKET_HOST+BUCKET_PORT, not a separate field).

There's no native bridge between them. Three ways to handle it:

- **(A) `CephObjectStoreUser` + manual SealedSecret.** Apply the User CR by hand, read the Rook-generated keys, seal them + the bucket name into a SealedSecret, commit. Works but requires a manual one-time step every rebuild and isn't reproducible from `git clone && helm install`.
- **(B) `ExternalSecrets` operator.** Map fields from the OBC outputs into a new Secret. Requires standing up ESO, which we don't have yet. Adds an operator for one consumer.
- **(C) Pre-sync Job translator.** A small Job that runs once per Argo sync, reads the OBC outputs from the API, writes the LokiStack-shape Secret. Idempotent. No extra operator. **Picked.**

The Job is ~30 lines:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  annotations:
    argocd.argoproj.io/hook: Sync
    argocd.argoproj.io/hook-delete-policy: BeforeHookCreation
    argocd.argoproj.io/sync-wave: "1"
spec:
  template:
    spec:
      serviceAccountName: loki-secret-translator
      containers:
        - image: quay.io/openshift/origin-cli:4.20
          command: [/bin/bash, -eu, -o, pipefail, -c]
          args:
            - |
              # 1. Wait for OBC.status.phase == Bound
              # 2. Read CM (BUCKET_NAME/HOST/PORT) + Secret (AKID/SAK)
              # 3. oc create secret --dry-run | oc apply -f -
              # See chart for full script.
```

A few details that matter:

- **`hook: Sync` + `hook-delete-policy: BeforeHookCreation`.** Without this, Argo treats the Job as a regular resource and refuses to reconcile it after the first apply (Job templates are immutable). The Sync hook semantics: delete the prior instance, run a fresh one, on every sync.
- **`sync-wave: "1"`.** Inside the chart: OBC at wave 0, Job at wave 1, LokiStack at wave 2, ClusterLogForwarder at wave 3. Argo applies waves in order, but it doesn't natively understand OBC.phase=Bound as "Healthy" — so the Job *also* loops internally until it sees `phase=Bound` (60 retries × 5s = 5 min ceiling). Defense in depth.
- **`origin-cli:4.20` image.** Has both `oc` and `kubectl`. Pin to the cluster version so the API surface matches.
- **`oc apply --dry-run=client -o yaml | oc apply -f -`.** The classic idempotent secret-write pattern: build the desired YAML client-side, apply server-side. Re-runnable across cluster-state and repo state changes.

The RBAC for the Job's ServiceAccount is the minimum needed:

```yaml
rules:
  - apiGroups: ["objectbucket.io"]
    resources: ["objectbucketclaims"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["configmaps"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["secrets"]
    verbs: ["get", "list", "watch", "create", "update", "patch"]
```

Namespace-scoped Role, no cluster privileges. The destination Secret stays in `openshift-logging`.

## LokiStack: size 1x.demo, schema v13/tsdb

```yaml
apiVersion: loki.grafana.com/v1
kind: LokiStack
spec:
  size: 1x.demo
  storage:
    schemas:
      - effectiveDate: "2024-01-01"
        version: v13
    secret:
      name: loki-storage
      type: s3
  storageClassName: ceph-nvme-block
  tenants:
    mode: openshift-logging
```

Decision-by-decision:

- **`size: 1x.demo`** — smallest tier. One replica per component (gateway, distributor, ingester, querier, query-frontend, compactor, ruler, index-gateway). No CPU/RAM requests/limits (the CSV docs explicitly say it's for demo, not production). For homelab volume that fits well — total memory for the stack is ~2 GiB, within the cluster's headroom. Will revisit when we know how much log volume the cluster actually generates.
- **`storage.schemas[0].version: v13`** — the TSDB schema. v13 has been the recommended schema since Loki 2.9. Not v12 (BoltDB-shipper, deprecated) or v11 (older still). One schema entry; if we ever need to migrate, we add a new entry with a future `effectiveDate` — old data stays under v13, new data goes to the next version.
- **`storage.secret`** — the Secret the pre-sync Job produces. Type `s3` (s3-compatible).
- **`storageClassName: ceph-nvme-block`** — for the small persistent volumes the operator provisions for ingester WAL + ruler. Object storage holds the chunks; this is just the per-pod scratch.
- **`tenants.mode: openshift-logging`** — wires the operator's three-tenant model: `application`, `audit`, `infrastructure`. The gateway authenticates via OpenShift's `TokenReview` API and routes the right tenant per request based on the SA's permissions. This is the mode that integrates with `ClusterLogForwarder` cleanly.

## ClusterLogForwarder: Vector pipeline definition

```yaml
apiVersion: observability.openshift.io/v1
kind: ClusterLogForwarder
spec:
  serviceAccount:
    name: logcollector
  outputs:
    - name: lokistack-output
      type: lokiStack
      lokiStack:
        target:
          name: logging-loki
          namespace: openshift-logging
        authentication:
          token:
            from: serviceAccount
        tls:
          ca:
            key: service-ca.crt
            configMapName: openshift-service-ca.crt
  pipelines:
    - name: app-audit-infra
      inputRefs: [application, infrastructure, audit]
      outputRefs: [lokistack-output]
```

Worth calling out:

- **`apiVersion: observability.openshift.io/v1`** — *not* `logging.openshift.io/v1`. v6 of the operator moved the `ClusterLogForwarder` API to its own group; the old one still exists for compatibility but is deprecated. Don't write the old shape; the operator won't pick it up.
- **`serviceAccount: logcollector`** — a ServiceAccount the chart creates in `openshift-logging`, bound to three platform-shipped ClusterRoles: `collect-application-logs`, `collect-audit-logs`, `collect-infrastructure-logs`. Without these CRBs, Vector can't read from the kubelet log endpoints / journal / audit-log files. The ClusterRoles ship with the cluster-logging operator.
- **`authentication.token.from: serviceAccount`** — Vector authenticates to the LokiStack gateway using the same SA's token (mounted via projected volume by the cluster-logging operator). The gateway runs the TokenReview, accepts/rejects per tenant.
- **`tls.ca.configMapName: openshift-service-ca.crt`** — the cluster's auto-injected CA bundle for `*.svc` certs. The LokiStack gateway exposes itself with a service-CA-issued cert; Vector trusts that bundle, no manual CA wrangling.
- **One pipeline, three inputs.** Each input gets a built-in filter set by the operator (e.g. `infrastructure` is everything in `openshift-*` namespaces + node-level systemd journal; `application` is everything else). Tenants on the LokiStack side are derived from the input source.

## Sync-wave layout

Inside the chart, ordering is intra-chart sync-wave annotations:

| Wave | Resources |
|---|---|
| 0 | OBC, both ServiceAccounts, Role, RoleBinding, three ClusterRoleBindings |
| 1 | Pre-sync Job (Argo Sync hook) |
| 2 | LokiStack |
| 3 | ClusterLogForwarder |

Cross-chart, the bootstrap/root-app puts `loki-operator` + `cluster-logging` at wave 1 (Subscription only), and `logging-stack` at wave 5 — the same wave as `gatus`, `monitoring-config`, etc. Plenty of gap for the CSVs to reach `Succeeded` and the CRDs (`LokiStack`, `ClusterLogForwarder`) to be installed before anything in the stack chart tries to reference them.

## Validation

```
helm lint components/cluster-config/logging-stack/         # clean
helm template logging-stack components/cluster-config/logging-stack/ -n openshift-logging
helm template ... | kubeconform -strict -ignore-missing-schemas \
                      -schema-location default \
                      -schema-location 'https://...datreeio/CRDs-catalog/...'
                              <- silent; native kinds OK; CRDs ignored as expected
helm template ... | oc diff -f -
                              <- only net-new resources (no drift)
```

Post-deploy verification (to fill in once Argo reconciles):

- `oc get csv -n openshift-operators-redhat` shows `loki-operator.v6.3.0` Succeeded
- `oc get csv -n openshift-logging` shows `cluster-logging.v6.3.0` Succeeded
- `oc get obc -n openshift-logging loki` reaches `Bound`
- `oc -n openshift-logging logs job/loki-secret-translator` shows `done`
- `oc get secret -n openshift-logging loki-storage` exists with the 5 expected keys
- `oc get lokistack -n openshift-logging logging-loki` reaches `Ready`
- `oc get pod -n openshift-logging` shows the Loki components + Vector DaemonSet running
- `oc get clusterlogforwarder -n openshift-logging instance` shows status conditions all `True`
- A test query against the gateway returns recent log lines

## Impact on cluster

This is meaningful workload, not a refactor:

- **New pods:** ~10 (gateway, distributor, ingester, querier, query-frontend, compactor, ruler, index-gateway, two collectors per node × 3 nodes for Vector). On `1x.demo` each is 1 replica.
- **Memory:** ~2 GiB total for the LokiStack components, ~50 MiB per Vector pod (×3 = 150 MiB). Cluster has plenty of headroom.
- **CPU:** modest. Vector's CPU scales with log volume; LokiStack is ingest-bound. For homelab traffic (~tens of MB/min), single-digit % per node.
- **Object storage:** every chunk + index is written to the bucket. With default retention (24h on demo tier — short!) and our log volume, expect ~hundreds of MiB to single-digit GiB resident. No HDD pressure; this is well within NVMe headroom.
- **No OSD/RGW changes.** The only Ceph-side activity is bucket creation and chunk writes. Existing `nvme-replicated` pool is untouched.

## Open follow-ups

- **Console plugin.** `cluster-logging` ships a `ConsolePlugin` that adds a "Logs" tab to the OpenShift console UI. Not enabled by default. Decide later — the Grafana Loki datasource (next item) might be the better operator interface.
- **Grafana Loki datasource.** Add a `Datasource` CR (grafana-operator) pointing at `http://logging-loki-gateway-http.openshift-logging.svc:8080`, tenant-scoped via the `X-Scope-OrgID` header set per dashboard. Then we can query app/audit/infra logs from Grafana.
- **Retention tuning.** `1x.demo` defaults to 24 h retention. Increase via `LokiStack.spec.limits.global.retention.days` once we know we want longer. Watch bucket size.
- **Bucket lifecycle.** Loki manages chunk + index lifecycle internally; we don't need RGW-side lifecycle rules. Confirm after a week of running.
- **Audit log exclusions.** Right now we forward *everything*. Once we see what comes through, add `filter` blocks to drop noise (e.g. `system:serviceaccount:*:gatus` health probes if they're chatty).
- **Bigger size tier.** `1x.demo` is single-replica per component; if log volume warrants it, bump to `1x.extra-small` (still single replica per component but with sane resource requests) or `1x.small` (replicas + HA). Re-evaluate after a week.
- **OADP next.** Same operator-evaluation TODO calls for OADP/Velero with S3 destination — same `OBC + translator-Job` pattern will probably apply, with Velero's `BackupStorageLocation` consuming the OBC outputs directly (Velero's S3 plugin reads `aws-credentials` Secret format, slightly different shape from Loki's). Reuse the translator pattern, swap the Secret keys.
