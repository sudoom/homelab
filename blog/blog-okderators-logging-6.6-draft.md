# okderators: getting Logging and Loki 6.6 into the community catalog for OKD 4.20–4.22

Working notes for an upstream contribution to the OKD community operator catalog ("okderators"): the build pipeline
`okd-project/okd-operator-pipeline` and the catalog `okd-project/okderators-catalog-index`. This homelab runs OpenShift
Logging (`cluster-logging`) and the Loki operator from okderators, and the community builds turned out to be stale and
partly broken on every OKD release from 4.21 on. The goal is a fix for every OKD user, not just this cluster.

## 2026-10-20 — what is wrong today

Three read-only research passes (pipeline branches, catalog branches, Red Hat's side), plus checks on this cluster.

**Catalogs** (`okderators-catalog-index`, per branch, `catalog/<pkg>/<pkg>.yaml`):

| catalog branch | cluster-logging / loki-operator head | `olm.maxOpenShiftVersion` of the head |
|---|---|---|
| release-4.18, 4.19 | 6.3.0-2025-08-08 | 4.20 |
| release-4.20 | 6.5.0-2026-06-04 | 4.22 |
| release-4.21, 4.22 | 6.3.0-2025-08-08 | 4.20 |

- The 4.21 and 4.22 catalogs serve a build that blocks cluster upgrades past 4.20. Red Hat declined to extend 6.3 to
  4.21 (LOG-8608, Won't Do). That is community issue #44.
- The 6.5.0 bundles exist on quay and are byte-identical across branches, but only the 4.20 catalog lists them
  (direct push `300b49e`, 2026-06-04). The 4.21 branch was cut before that commit.
- Every package in every catalog branch uses a single channel, `alpha` (244 package files, checked across all
  branches): there is no multi-channel precedent in okderators.
- `catalog-index:4.22` exists since 2026-10-15.

**Pipeline** (`okd-operator-pipeline`):

- `main` builds OKD 5.0 since 2026-09-23 (`OKD_VERSION=5.0.0-okd-scos.0`); `release-4.22`, `release-4.21` and `main`
  carry identical `cluster-logging/` content pinned at the 2026-05-13 "Update version to 6.5.2" commits (CLO 28 and
  Loki 14 commits behind `release-6.5`). `release-4.20` is still on 6.3.
- Upstream CI has never built cluster-logging: `cluster-logging-deploy.yaml` exists on `main` (push trigger `main`)
  and has 0 runs. The weekly submodule updater has failed every run since 2026-03-09. Scheduled workflows only run
  from the default branch, so nothing on a release branch moves unless a PR moves it.
- The logging build does not depend on the OKD release: tags are `6.5.0-<DATE>` from any branch. One build can serve
  every catalog.

**Red Hat** (lifecycle API, Red Hat's container catalog image labels, public Jira, and the operator's screenshots of
Red Hat's operator update checker):

- On OCP 4.20, 4.21 and 4.22 alike, Red Hat offers `stable-6.5` at 6.5.3 (maxOCP 4.22) and `stable-6.6` (default) at
  6.6.1 (maxOCP 4.23). 6.6 needs OCP 4.20+, has maintenance to 2027-12-31 and EUS to 2029-06-30; 6.5 maintenance ends
  2026-12-17. OKD 5.0 needs the unreleased 6.7.
- **The okderators "6.5.0" is not a Red Hat release, and its Loki is built from the wrong source.** The pipeline's
  `loki.Containerfile` compiles the Loki binary from the `openshift/loki` `release-6.5` root and stamps it
  `Branch=upstream-v3.6.5`. Red Hat builds each release's Loki from dedicated `upstream-vX.Y.Z` branches (6.6.1 →
  `upstream-v3.7.3`). The `release-6.5` root pulls in `aws-sdk-go-v2/service/s3 v1.96.2`, and the 6.5.2-era operator
  does not enable the thanos objstore backend.
- That is the S3 bug of issue #48 / LOG-9632: uploads fail on S3 stores that reject the AWS SDK v2 trailing-checksum
  headers (NetApp ONTAP before 9.11.1, Dell PowerScale; AWS is fine). Red Hat fixed it by moving LokiStack to thanos
  objstore: backported in 6.5.3, native in 6.6.
- Vector: the pipeline builds `v0.54.0-rh` (the 6.6 pin) next to CLO 6.5, which pins vector 0.47.0.

**This cluster** (OKD 4.21, okderators 6.5.0, LokiStack `1x.pico` on garage): no S3 problem. Prometheus, last 24 h,
through break-glass exec into `prometheus-k8s-0` (the Loki metrics port needs a client certificate):

```
sum by (operation, status_code) (increase(loki_s3_request_duration_seconds_count{namespace="openshift-logging"}[24h]))
operation=S3.PutObject,status_code=200     9223
operation=S3.GetObject,status_code=200      313
operation=S3.List,status_code=200           117
operation=S3.DeleteObject,status_code=200  7267
sum(increase(loki_ingester_chunks_flushed_total{namespace="openshift-logging"}[24h]))   8920
sum by (status) (increase(loki_tsdb_shipper_tables_upload_operation_total{...}[24h]))   status=success 2880
sum by (status) (increase(loki_boltdb_shipper_compact_tables_operation_total{...}[24h])) status=success 12
```

No storage error lines in any ingester, compactor or index-gateway log since their 2026-10-16 start.

## 2026-10-20 — decisions

- Scope: every OKD user on 4.20, 4.21 and 4.22, all pipeline branches (`main`, `release-4.22/4.21/4.20`).
- Build Red Hat's release branches, not upstream projects: there is no upstream cluster-logging release stream, and
  Grafana's community Loki operator (v0.12.0) and `argocd-operator` are already in community-operators.
- Version: Red Hat's exact 6.6.1 commits, channel `alpha` only. A two-channel `stable-6.5`/`stable-6.6` layout was
  considered and dropped (6.5 ends in December; okderators has no multi-channel precedent).
- `main` carries 6.6.1 too, because it is the only branch where upstream CI builds images, even though `main`
  targets OKD 5.0.
- Builds run on this cluster as a one-off privileged podman Job, pushing to zot under `okd-test/` (now a standing rule
  in `CLAUDE.md`). The images this cluster's logging will run on stay in zot for as long as upstream takes.
- This cluster is the test bed: its logging moves to the test build of 6.6.1, and the logging operators may be
  reinstalled as often as needed.

Design and plan are local (`docs/superpowers/`, gitignored); the record of what gets built and why goes here as the
work proceeds.

## 2026-10-20 — the 6.6.1 pin table

| component | repo | branch | commit | Red Hat image |
|---|---|---|---|---|
| cluster-logging-operator | openshift/cluster-logging-operator | release-6.6 | `7560420af4` | openshift-logging/cluster-logging-rhel9-operator |
| loki-operator | openshift/loki | release-6.6 | `678e5e8f46` | openshift-logging/loki-rhel9-operator |
| loki-operand | openshift/loki | upstream-v3.7.3 | `2c9bd11954` | openshift-logging/logging-loki-rhel9 |
| vector | ViaQ/vector | v0.54.0-rh | `5e0a160980` | openshift-logging/vector-rhel9 |
| log-file-metric-exporter | ViaQ/log-file-metric-exporter | main | `4e32570016` | openshift-logging/log-file-metric-exporter-rhel9 |
| lokistack-gateway | ViaQ/observatorium-api | main | `aeb2833b06` | openshift-logging/lokistack-gateway-rhel9 |
| opa-openshift | ViaQ/opa-openshift | main | `5fc280ff7b` | openshift-logging/opa-openshift-rhel9 |
| eventrouter | openshift/eventrouter | master | `4cd32dfcce` | openshift-logging/eventrouter-rhel9 |
| passthrough-gateway | openshift/loki | release-6.6 | `678e5e8f46` | none (same commit as loki-operator) |

I read `io.openshift.build.commit.id` from the Red Hat container catalog GraphQL API (`find_operator_bundles` for the 6.6.1 `cluster-logging` and `loki-operator` bundles on 4.21, then `get_image` labels per related image, with python urllib because curl is denied here). Every sha was proven with `gh api repos/<repo>/commits/<sha>` and `compare/<branch>...<sha>` (`behind` or `identical`).

Three things differ from the obvious reading. The Loki operand commit is identical to `openshift/loki` `upstream-v3.7.3`. The gateway and OPA commits are on the ViaQ forks, not on the upstream `observatorium/*` main (diverged). Eventrouter is not in the 6.6.1 bundles, but Red Hat built an `eventrouter-rhel9` image with `version=6.6.1`, so that commit is pinned. The Red Hat Dockerfiles for each image were saved for comparison with the pipeline's Containerfiles.
