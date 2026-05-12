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

## First post-rollout snag — Vector 403 Forbidden

LokiStack came up green, OBC → Secret translator did its job, ClusterLogForwarder reconciled clean. Then Vector logs were a wall of:

```
ERROR sink{component_id=output_lokistack_output_application component_type=loki}:
  vector::sinks::util::retries:
  Non-retriable error; dropping the request.
  error=Server responded with an error: 403 Forbidden
```

All three sinks (application/audit/infrastructure). Bucket data pool stayed at 0 B.

The chart bound `logcollector` SA to `collect-application-logs`, `collect-audit-logs`, `collect-infrastructure-logs`. Looks right, isn't:

```
$ oc get clusterrole collect-application-logs -o yaml
rules:
  - apiGroups: [logging.openshift.io, observability.openshift.io]
    resources: [logs]
    verbs: [collect]
```

`verbs: [collect]` is the *collection* permission — read pods/namespaces, mount log paths, etc. The LokiStack gateway runs an OPA tenant authorizer that does TokenReview + SubjectAccessReview specifically for `loki.grafana.com/<tenant>` resource with verb `create`. Different API group entirely. The CLO ships a separate ClusterRole for that:

```
$ oc get clusterrole logging-collector-logs-writer -o yaml
rules:
  - apiGroups: [loki.grafana.com]
    resourceNames: [logs]
    resources: [application, audit, infrastructure]
    verbs: [create]
```

Fix: bind `logcollector` to `logging-collector-logs-writer` *in addition to* the three `collect-*-logs` ones (collect-* still needed for the read-side). Single line in the chart's RBAC range.

Lesson: the `collect-*-logs` naming is misleading if you assume one ClusterRole covers the whole pipeline. It doesn't. Read = `collect-*-logs`, write to gateway = `logging-collector-logs-writer`. Both are required.

## Sizing — 1x.demo's PDB trap

`1x.demo` is documented as a smoke-test tier — single replica per component, no resource requests. What's not flagged anywhere is the consequence for `PodDisruptionBudget`s:

```
$ oc -n openshift-logging get pdb
NAME                          MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
logging-loki-distributor      1               N/A               0
logging-loki-gateway          1               N/A               1
logging-loki-index-gateway    1               N/A               0
logging-loki-ingester         1               N/A               0
logging-loki-querier          1               N/A               0
logging-loki-query-frontend   1               N/A               0
```

`ALLOWED DISRUPTIONS: 0` everywhere except gateway (which has 2 replicas). That means a node drain for a kernel update — or any voluntary eviction — blocks indefinitely on every singleton.

First instinct was `1x.small` — the docs frame it as the standard "real workload" tier. The operator started rolling new replicas immediately and within seconds:

```
$ oc -n openshift-logging describe pod logging-loki-ingester-0
Events:
  Warning  FailedScheduling  default-scheduler  0/3 nodes are available:
    3 Insufficient cpu. preemption: 0/3 nodes are available: 3 No preemption
    victims found for incoming pod.
```

Pulled the per-component requests out of `operator/internal/manifests/internal/sizes.go` and totalled them. `1x.small` is **~42 CPU / ~83 GiB cluster-wide** — way too much for a 3-node baremetal cluster. The "small" framing in the docs assumes you've got a real-cluster control-plane sitting somewhere with headroom; on a homelab where the control planes are also the workers, it doesn't fit.

Right size for this cluster is `1x.pico`:
- Same 4 MB/s ingestion target as `1x.demo` (homelab volume is well under)
- HA replicas on every component except compactor (singleton by design)
- **3-replica ingesters** that map cleanly to `fd-a / fd-b / fd-c`
- ~6.8 CPU / ~18 GiB cluster-wide — fits without any preemption pressure

Notable: `1x.extra-small` has the same ingestion target as pico but heavier per-pod requests (`2 CPU / 8 GiB` ingester vs pico's `0.5 CPU / 3 GiB`) — designed for "small but not memory-starved." For a homelab, pico wins on pure footprint without losing anything that matters.

Switched to `1x.pico` and let the operator settle. The compactor stays at `ALLOWED DISRUPTIONS: 0` (singleton by design — there's only one), but every other component now accepts disruption.

## Wiring Loki into Grafana

Three datasources, one per tenant, since the LokiStack gateway encodes tenant in the URL path:

```
https://logging-loki-gateway-http.openshift-logging.svc:8080/api/logs/v1/<tenant>
```

Authentication is `Authorization: Bearer <SA-token>`. The same OPA authorizer in front of the gateway means Grafana's SA needs SAR-grantable read on the tenants. There's no built-in `cluster-logging-read-*-logs` role (write side has them; read side doesn't), so the chart ships its own:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: grafana-loki-reader
rules:
  - apiGroups: [loki.grafana.com]
    resources: [application, audit, infrastructure]
    resourceNames: [logs]
    verbs: [get]
```

Bound to a `grafana-loki` SA in the grafana namespace; static SA token Secret feeds the GrafanaDatasource via `valuesFrom`. Three GrafanaDatasource CRs (`Loki (application)`, `Loki (infrastructure)`, `Loki (audit)`) with `tlsSkipVerify: true` — easier than mounting service-CA into the Grafana pod for now.

Pattern's identical to the existing Prometheus datasource (SA + token Secret + datasource CR), so no new shape to maintain.

### Application tenant queries blocked by LOG-6894

Audit and infrastructure tenants work — both are listed under the gateway's `--opa.skip-tenants=audit,infrastructure` arg, so OPA doesn't enforce SAR for them. Application tenant goes through OPA, and that's where Grafana hits a wall:

```
{"error":"You don't have permission to access this tenant","errorType":"observatorium-api","status":"error"}
```

A direct cluster-side `SubjectAccessReview` for the `grafana-loki` SA against `loki.grafana.com/application/logs` with `verb: get` returns `allowed: true`. The same SAR shape that Vector relies on for write access (with `verb: create`) works fine. But OPA still denies the read.

This is Red Hat KCS-7113062 / bug **LOG-6894** — open at the time of writing, no public fix. The KCS suggests creating a `ClusterRoleBinding` to a `cluster-logging-application-view` ClusterRole, but that role isn't shipped in v6.3.0 and creating an equivalent doesn't change behavior — it's an OPA package bug, not a missing role.

Workarounds available now:
- Use `Loki (infrastructure)` and `Loki (audit)` datasources for system + audit logs.
- For application logs, the OpenShift console plugin (`oc -n openshift-logging patch lokistack ... --type=merge --patch ... ` to enable, or via the ClusterLogForwarder's UI plugin path) goes through a different auth path tied to the user's OAuth session — those queries succeed.
- Or run a non-OPA querier mTLS path internally for an admin pod — overkill for a homelab.

Sticking with the three datasources. Application stays broken until the upstream bug ships a fix; revisit on the next loki-operator bump.

### Querier ↔ index-gateway gRPC stuck after rapid demo→small→pico cycle

Even with audit + infrastructure tenants authorized end-to-end, Grafana queries returned **504 Gateway Time-out** at 30s. The bucket was healthy and growing (446 MiB → 588 MiB in ten minutes), so this was strictly a read-path issue.

The querier logs are unambiguous:

```
caller=pool.go:250 index-store=tsdb-2024-01-01
  msg="removing index gateway failing healthcheck"
  addr=dns:///logging-loki-index-gateway-grpc.openshift-logging.svc.cluster.local:9095
  reason="rpc error: code = DeadlineExceeded desc = context deadline exceeded"

caller=client.go:469 ... msg="client do failed for instance dns:///logging-loki-index-gateway-grpc..."
  err="rpc error: code = Canceled desc = grpc: the client connection is closing"
```

Every ~10s the querier evicts the index-gateway from its connection pool (failed healthcheck), re-resolves DNS, opens a new gRPC channel, and the cycle repeats — none of the reads ever land.

What the network looked like:

- TCP from querier pod to `logging-loki-index-gateway-grpc.openshift-logging.svc.cluster.local:9095` opens cleanly (`/dev/tcp` succeeds).
- The headless service `logging-loki-index-gateway-grpc` resolves to both pod IPs (10.128.1.95, 10.130.1.187), endpoints object lists both with `nodeName` populated.
- Index-gateway pods themselves log nothing but `Loki started` + periodic `syncing tables` — no inbound gRPC errors, no client-side EOFs. They're not seeing the calls at all.
- Index-gateway's gRPC serving cert (`logging-loki-index-gateway-grpc` Secret) has SANs for both `logging-loki-index-gateway-grpc.openshift-logging.svc` and `…svc.cluster.local`, validity 90d, signed by the OpenShift service-CA. Matches the querier's `tls_server_name` config.
- Querier mounts `service-ca.crt` and the same per-component grpc client cert it uses for ingester/compactor RPCs. Those RPCs succeed (writes are flowing); only index-gateway hangs.

So: TCP reachable, TLS material valid, server idle. The 9095 listener is accepting TCP but the gRPC client side is timing out the handshake / first RPC. Smells like a stuck connection state in the querier's gRPC client pool — likely a leftover from the rapid sizing cycle `1x.demo → 1x.small → 1x.pico` over ~10 minutes, where the previous-generation querier opened gRPC channels to index-gateway pods that no longer exist, and the new generation either inherited a bad pool entry or has stuck channel state from the connection storm.

Plan: rollout-restart `logging-loki-querier` and `logging-loki-query-frontend` to flush the gRPC pool. ArgoCD will heal the deployment state — restart only cycles pods. Defer ingester/distributor (write path) and index-gateway (no client-side issue there) so the bucket flow stays steady.

#### Restart did not fix it; hypothesis was wrong

`oc rollout restart deployment/logging-loki-querier deployment/logging-loki-query-frontend` is silently reverted by ArgoCD selfHeal — the `kubectl.kubernetes.io/restartedAt` annotation lives in the pod template, which Argo owns. Pods stay at their original AGE.

Workaround: `oc -n openshift-logging delete pod -l 'app.kubernetes.io/component in (querier,query-frontend)'` — Argo doesn't track Pods directly, only Deployments, so pod-delete sticks and the ReplicaSet recreates them. New pods came up in ~80s.

Re-probe shows the read path still hangs identically. Both fresh queriers log the same eviction loop within 30s of startup:

```
caller=pool.go:250 msg="removing index gateway failing healthcheck"
  addr=dns:///logging-loki-index-gateway-grpc...:9095
  reason="rpc error: code = DeadlineExceeded desc = context deadline exceeded"
```

So the stuck-connection-pool hypothesis was wrong. The issue is structural, not state.

#### Real diagnosis: TLS works, gRPC application layer hangs

Spun up a debug pod with `quay.io/openshift/origin-cli:4.20` to do a clean handshake test, with the querier's actual client identity (`logging-loki-querier-grpc` Secret) and the right CA bundle (`logging-loki-ca-bundle` ConfigMap, which contains the **Loki internal signing CA**, not the OpenShift service-CA — the file is named `service-ca.crt` for code compatibility but the issuer is `openshift-logging_logging-loki-signing-ca@…`).

```
$ openssl s_client -connect logging-loki-index-gateway-grpc...:9095 \
    -servername ... -cert q-cert.pem -key q-key.pem -CAfile loki-ca.pem
CONNECTED(00000003)
subject=O=system:logging, CN=system:lokistacks
issuer=CN=openshift-logging_logging-loki-signing-ca@1777647217
SSL handshake has read 2585 bytes and written 2656 bytes
Verify return code: 0 (ok)
EXIT=0
```

mTLS handshake completes in subseconds against the index-gateway, ingester, and query-frontend identically. So the failure is *above* TLS — gRPC application layer.

What we know:
- TCP open to both index-gateway pods (`/dev/tcp` succeeds).
- Full mTLS handshake succeeds (right cert chain, no cipher suite mismatch).
- Index-gateway logs nothing but `Loki started` + 5-min `syncing tables` from `table_manager.go` — no inbound gRPC errors, no client-side EOFs.
- Querier's gRPC pool calls a custom *index-gateway* health RPC (not standard `grpc.health.v1.Health`); it deadline-exceeds at the configured `1s` `remote_timeout` and the eviction loop kicks in every ~10s.

Plausible causes still open:
1. **Index-gateway TSDB shipper is blocking gRPC handlers on a slow S3 GET**. The shipper runs in RO mode here and fetches indexes from Ceph RGW on demand. Ceph is mid PNY→PM9A1 swap (CLAUDE.md storage section), only osd.0 is upgraded, the other two PNYs have `BLUESTORE_SLOW_OP_ALERT` open. If a TSDB index fetch blocks for >1s, every querier-side healthcheck against that gateway fails. Plausible but hard to confirm without index-gateway metrics — and the `loki-index-gateway` container has no curl/wget to scrape its own `/metrics`.
2. **A known bug in Loki Operator v6.3.0 / Loki 3.5 around the index-gateway pool when run at `1x.pico` scale.** The pico tier is the smallest HA tier, possibly under-tested. Worth searching upstream issues.

The write path is fine throughout — distributor → ingester writes happen in-memory and flush asynchronously, so slow RGW reads don't backpressure. Bucket grew from 446 MiB / 123 obj to 590 MiB / 175 obj across the diagnosis window.

Decision: park the read path for now, document, and revisit. The OpenShift console plugin (`oc -n openshift-logging patch lokistack ... --patch '{"spec":{"tenants":{"openshift":{"logsCollectorEnabled": ...`) might bypass the issue entirely since it talks to a different querier path. If hardware swap (PM9A1 on osd.1 + osd.2) is the missing piece, the read path may simply heal once Ceph stops returning slow reads.

## Tier-bump experiment (2026-05-01)

To rule out a `1x.pico`-specific operator wiring quirk, bumped `LokiStack.spec.size` to `1x.extra-small` in `components/cluster-config/logging-stack/values.yaml` and pushed. Argo synced; ingesters scaled 3 → 2, queriers + query-frontend doubled per-pod requests. Same symptom — index-gateway logs unchanged (`distinct_users_len=0`, periodic 5m table sync), querier still hits `pool.go:250 reason="DeadlineExceeded"` and `client connection is closing`, external probe to gateway hangs to timeout. Reverted to `1x.pico` (commit `3227b10`). Rationale captured back in `values.yaml` so a future me doesn't re-run the experiment.

## Index-gateway debug logs + packet capture (2026-05-01)

Lokistack CRD doesn't expose a per-component log-level field. Loki has a runtime `/log_level` HTTP endpoint though, exposed on the main HTTP server (`:3100`, mTLS). Spun up a debug pod with the index-gateway HTTP serving cert + Loki internal CA mounted, dialed both ig-0 and ig-1 with `--resolve <fqdn>:3100:<podIP>` to bypass the headless-svc not-resolving-per-pod problem (StatefulSet without `spec.serviceName`):

```bash
curl -X POST --cacert /tls/ca/service-ca.crt \
  --cert /tls/http/tls.crt --key /tls/http/tls.key \
  --resolve "logging-loki-index-gateway-http.openshift-logging.svc.cluster.local:3100:<podIP>" \
  "https://logging-loki-index-gateway-http.openshift-logging.svc.cluster.local:3100/log_level?log_level=debug"
# {"status":"success","message":"Log level set to debug"}
```

Both pods returned 200. Ten minutes of debug logs after the bump showed only:

```
GET /ready (200) 22µs        # every 10s — kubelet liveness
GET /loki/api/v1/status/buildinfo (200) 25µs  # every 30s — gateway probe
table_manager.go:300 ... query readiness setup completed ... distinct_users_len=0 distinct_users=
```

Zero log lines from `caller=grpc_logging.go`, the file Loki uses to log inbound gRPC requests at debug level. So either (a) gRPC requests aren't reaching the application layer, or (b) the gRPC server's per-request debug logger isn't wired through `/log_level`.

To disambiguate, ran `tcpdump` inside the index-gateway pod's network namespace. Used `oc debug node/node4` with the `nicolaka/netshoot` image, found the container PID via `crictl ps -q | crictl inspect`, and ran `nsenter -t <pid> -n -- tcpdump -ni any "port 9095 or port 3100 or port 3101" -w cap.pcap` for 60 seconds:

```
243 packets captured
... 72 Out 10.130.1.227.3101  ← internal_server (kubelet probe), 10s cycle
... 32 Out 10.130.1.227.3100  ← HTTP (querier/query-frontend healthchecks)
...  0  ANY  10.130.1.227.9095 ← gRPC port: ZERO PACKETS in 60s
```

So the queriers do reach the index-gateway pod — just on the HTTP port (`:3100`, mTLS healthchecks) and the kubelet hits `:3101` (internal_server). **No querier ever opens a TCP connection to the gRPC port `:9095`.**

That reframes the whole problem. The earlier finding — querier logging `pool.go:250 reason="DeadlineExceeded"` — must come from the gRPC client pool's *internal* health probe failing, not from a real on-the-wire RPC. The pool seems to be in a permanently-broken state where it never even retries the dial. The connection isn't slow, it's not happening. With zero TCP-level evidence of a dial, slow Ceph S3 reads (the original hypothesis) can't explain this — there's no wire activity at all to be slow.

Two new threads to chase next:

1. **DNS-side issue.** The querier's `index_gateway_client.server_address` is `dns:///logging-loki-index-gateway-grpc...:9095` — the `dns:///` prefix tells gRPC-Go to use the DNS resolver and re-resolve every 30s. If that resolution returns zero healthy endpoints (e.g., headless-service `subdomain` mismatch, or readinessProbe gating SRV records), the gRPC client just sits in `IDLE` state forever — no dial attempt, no log line. Worth grabbing `nslookup -type=srv` inside a querier pod and comparing the EndpointSlice contents to the resolver's view.
2. **gRPC client never started.** Loki splits index-gateway's reachability across `index_gateway_client` (querier-side) and `index_gateway` (server-side). If the operator-rendered config has the *querier-target* without the right `tsdb_shipper` `index_gateway_client` block, the querier may be doing local index lookups (which then fail because there's no local index data) instead of dialing a remote gateway. Should diff the querier's running `/config` against the index-gateway's.

The packet capture is also the cleaner story for the eventual blog post: "we thought it was slow, it was actually nothing at all." Will follow up on the next session.

## Root cause — DNS search-path expansion timing out (2026-05-02)

Followed up the next session. The DNS hypothesis was the right one, but at a different layer than I'd suspected.

**Inside any pod in `openshift-logging`** (or any namespace really), the cluster's default `/etc/resolv.conf` is:

```
search openshift-logging.svc.cluster.local svc.cluster.local cluster.local okd.sudops.pl
nameserver 172.30.0.10
options ndots:5
```

The Loki gRPC client target is `dns:///logging-loki-index-gateway-grpc.openshift-logging.svc.cluster.local:9095`. That hostname has **4 dots**, less than `ndots:5`, so glibc and Go both treat it as *unqualified* and walk the search path **before** the bare name. The search-path walk goes:

1. `<host>.openshift-logging.svc.cluster.local` → CoreDNS NXDOMAIN, fast
2. `<host>.svc.cluster.local` → NXDOMAIN, fast
3. `<host>.cluster.local` → NXDOMAIN, fast
4. `<host>.okd.sudops.pl` → **forwards to host resolv.conf upstream → pi-hole → router → timeout**, ~10s

`getent hosts logging-loki-index-gateway-grpc.openshift-logging.svc.cluster.local` ran 5 times in a row, each one took **exactly 10.011s** before returning empty. With `ndots:1` overridden via `dnsConfig`, the same lookup completed in **1ms** (skips search path, queries the FQDN directly, hits the in-cluster CoreDNS authoritative answer).

The Loki gRPC client config has `index_gateway_client.grpc_client_config.backoff_config.min_period: 100ms` and an effective dial deadline around 1s (driven by `ingester_client.grpc_client_config.remote_timeout: 1s` for the pool's healthcheck). 1s is way under the 10s glibc/Go DNS resolution window. Result: gRPC's `dns:///` resolver always fires its deadline before the search-path walk falls through to the bare name → returns "no addresses" → pool marks endpoint failed → no TCP SYN ever leaves the querier.

That's exactly what we saw in the packet capture: zero packets on `:9095` from any pod in the cluster.

The querier debug logs match this story. Triggering a query directly against the querier (bypassing gateway/OPA) with `X-Scope-OrgID: infrastructure`:

```
caller=engine.go:281 component=querier org_id=infrastructure msg="executing query" ...
caller=async_store.go:103 msg="got chunk ids from ingester" count=0
caller=pool.go:250 msg="removing index gateway failing healthcheck"
  addr=dns:///logging-loki-index-gateway-grpc.openshift-logging.svc.cluster.local:9095
  reason="rpc error: code = DeadlineExceeded desc = context deadline exceeded"
caller=client.go:469 msg="client do failed for instance dns:///..." err="grpc: the client connection is closing"
duration=5.009s status=500
```

This connects back to **`blog-pihole-cluster-local-draft.md`** — the same `okd.sudops.pl`-search-path bug bit ArgoCD repo-server (`server misbehaving` from `lookup github.com on 172.30.0.10:53`) and ArgoCD UI (`dial tcp: lookup openshift-gitops-redis... i/o timeout`) at different times. It's the same root issue every time: the cluster's pod resolv.conf has `okd.sudops.pl` in the search path, and any name that walks through that suffix lands at pi-hole/router for an upstream lookup that doesn't terminate cleanly. The Loki read path tripped on it because gRPC's dial deadline is short.

### Fix paths considered

1. **Drop `okd.sudops.pl` from the pod search path.** This is the cleanest cluster-wide fix but pod resolv.conf is generated by kubelet from `Node.spec.podCIDR` + `kubelet.dnsConfig` and there's no clean OKD-supported knob to remove search domains the kubelet inferred from the node FQDN.
2. **Lower `ndots` globally to 1 via per-pod `dnsConfig`.** Operator-managed pods (Loki, Argo, etc.) ignore your value override unless the operator forwards it, which Loki Operator v6.3.0 doesn't.
3. **Fix the resolution itself in cluster CoreDNS** by adding a `forward` block for `okd.sudops.pl` that points at something authoritative-and-fast, OR a `template` block that returns NXDOMAIN for `*.svc.cluster.local.okd.sudops.pl`. The OpenShift `DNS` operator exposes `spec.servers[]` for exactly this. This is the right cluster-side fix and works for *all* operator-managed pods in one place.
4. **Wait for technitium migration** to take pi-hole out of the upstream chain. Open-ended; Loki read path stays broken in the meantime.

Path 3 is what we'll try next session — it's the smallest blast radius and unblocks every ndots:5-bitten workload at once. The exact CR change goes on `DNS.operator.openshift.io/default` under `spec.servers`, with a server block scoped to `zones: [okd.sudops.pl]` and a `forwardPlugin.upstreams` list pointing at whatever responds fast. Worst case we just template-NXDOMAIN the search-path-suffixed names.

## Open follow-ups

- **Console plugin.** `cluster-logging` ships a `ConsolePlugin` that adds a "Logs" tab to the OpenShift console UI. Not enabled by default. Likely the easiest workaround for application logs while LOG-6894 is open — the console path uses OAuth, not SA tokens, and bypasses OPA's broken read SAR.
- **Retention tuning.** `1x.small` defaults stay short (similar to demo). Increase via `LokiStack.spec.limits.global.retention.days` once we know we want longer. Watch bucket size.
- **Bucket lifecycle.** Loki manages chunk + index lifecycle internally; we don't need RGW-side lifecycle rules. Confirm after a week of running.
- **Audit log exclusions.** Right now we forward *everything*. Once we see what comes through, add `filter` blocks to drop noise (e.g. `system:serviceaccount:*:gatus` health probes if they're chatty).
- **OADP next.** Same operator-evaluation TODO calls for OADP/Velero with S3 destination — same `OBC + translator-Job` pattern will probably apply, with Velero's `BackupStorageLocation` consuming the OBC outputs directly (Velero's S3 plugin reads `aws-credentials` Secret format, slightly different shape from Loki's). Reuse the translator pattern, swap the Secret keys.

## 2026-05-08 evening — closure: read path works, with two cosmetic residuals

After the DNS-search-list `MachineConfig` rolled (full chronology in `blog-rook-ceph-draft.md` correction note), bounced Grafana to drop the stale in-memory token cache and tested directly:

```
$ TOKEN=$(oc -n grafana get secret grafana-loki-token -o jsonpath='{.data.token}' | base64 -d)
$ curl -sk -H "Authorization: Bearer $TOKEN" \
    https://logging-loki-openshift-logging.apps.okd.sudops.pl/api/logs/v1/infrastructure/loki/api/v1/labels
{"status":"success","data":["__stream_shard__","k8s_container_name","k8s_namespace_name", ...]}    # 200, 91 ms
```

`audit` tenant: same shape, 200 in 37 ms. `application` tenant: still 403 from observatorium-api OPA — that's the **separate, still-open LOG-6894** TODO; nothing today's work changed.

Confirmed in Grafana UI: Explore panel against `Loki (infrastructure)` returns log lines for `{kubernetes_namespace_name="openshift-logging"}` — basic query works.

### Two residual 404 toasts in the Grafana UI that are *not* a regression

Grafana's Loki datasource plugin makes side-channel calls during a query that the Loki Operator gateway doesn't proxy:

- `/api/datasources/uid/<uid>/resources/index/stats?...` → 404
- `/api/datasources/uid/<uid>/resources/drilldown-limits` → 404

The plugin uses these for query-stats panels and the drilldown UI hints. They're newer Loki HTTP API endpoints (`/loki/api/v1/index/stats`, etc.) that the **observatorium-api gateway in the Loki Operator stack allowlists selectively** — only the core paths needed for log ingestion + standard read (`query`, `query_range`, `labels`, `series`, `tail`, `push`) are routed; richer Loki API surface isn't exposed.

Net effect:
- Real log queries work fine.
- The toasts flash on every query. Cosmetic, not functional.
- Suppression options for later if the toasts get annoying:
  - Grafana datasource setting → disable the "show query stats" feature (plugin stops calling `/index/stats`).
  - Or wait for Loki Operator to allowlist those endpoints upstream — track in a future Red Hat KCS / loki-operator issue.

Closing the read-path 504 saga. Final scoreboard on the three hypotheses we chased:

| hypothesis | how it died |
|---|---|
| TSDB shipper blocking on slow PNY OSDs | survived the full PM9A1 swap to 3+0 (proven 2026-05-07 evening) |
| Loki Operator `1x.pico` resource-limit bug | survived the swap too; symptom unchanged |
| **`okd.sudops.pl` in pod search list + ndots:5 + 5 s gRPC dial deadline** | **fixed by MCO rolling reboot recreating all long-lived pods with the current (clean) host resolv.conf snapshot** |

The dispatcher script we shipped is a defensive no-op today (host resolv.conf doesn't carry the suffix anyway under KNI prepender), kept in place against future regression. And the actual mechanism — pod recreation — is what closed the issue. **One reboot beats one careful sed**, this time.
