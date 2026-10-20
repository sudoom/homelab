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

## 2026-10-20 — the in-cluster build Job

The images have to be built on the cluster (amd64), not on the Mac (arm64), so I wrote a one-off Job that runs the
pipeline's own `cluster-logging/build.sh` inside a privileged podman pod and pushes to zot under `okd-test/`. It lives
in `tests/okderators-logging-build/` and is not ArgoCD-managed; the operator applies and deletes it. Nothing has run
yet, so everything below is the design and the offline checks.

Shape:

- `manifests.yaml`: Namespace `okd-build` (PSA `privileged` on enforce/audit/warn,
  `security.openshift.io/scc.podSecurityLabelSync: "false"`), ServiceAccount `builder` with
  `automountServiceAccountToken: false` (the build needs no API), RoleBinding to `system:openshift:scc:privileged`,
  PVC `build-storage` 100Gi `ceph-nvme-block` RWO.
- `kustomization.yaml`: the above plus ConfigMap `build-scripts`, generated from `build.sh` with
  `disableNameSuffixHash`, so the script is a plain file and exists once.
- `job-template.yaml`: an OpenShift Template, one Job per run, `build-${MODE}-${DATE}`, `backoffLimit: 0`,
  `activeDeadlineSeconds: 43200`, no `ttlSecondsAfterFinished`, requests 2 CPU / 8Gi, limits 14 / 48Gi,
  `quay.io/podman/stable:v5.8.9@sha256:dc02649067d5…` (tag kept for readability, digest because quay re-pushes the
  tag). `MODE` and `DATE` are required parameters with no default, so every full run is a
  deliberate new tag.

```bash
oc apply -k tests/okderators-logging-build/
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-logging-build/job-template.yaml -p MODE=full -p DATE=$DATE \
  | oc -n okd-build create -f -
oc -n okd-build logs job/build-full-$DATE | grep -E '^(STEP|DISK|PUSHED|CHECK|RESULT) '
oc -n okd-build delete job build-full-$DATE      # after saving the log
oc delete -k tests/okderators-logging-build/     # when the build work is done
```

Modes: `full` runs `init`, `build_containers`, `push_containers`, `build_bundle` and `deinit` as separate
`./build.sh <step>` calls, so each is timed, then a verify step. `check` builds no images: it copies a full run's
images of the same `DATE` to `okd-test/check-<branch>/` with `skopeo copy --all` (zot dedupes the blobs) and runs
`init build_bundle deinit` plus verify there, for the other pipeline branches. `catalog` runs a `catalog-edit.sh` that
comes later and fails cleanly until it exists.

The log contract, for reading results without scrolling through the pipeline's `set -x` trace:
`STEP <name> START|END <epoch seconds>`, `DISK <bytes>` (du of `/var/lib/containers` + `/work` after each step),
`PUSHED <ref>@<digest> <bytes>` (sha256 of the manifest bytes zot serves, and config + layer sizes from that manifest),
`CHECK <name> PASS|FAIL <detail>`, and a final `RESULT PASS|FAIL <reason>`. An `EXIT` trap prints
`RESULT FAIL <step>` on any error, and a `TERM` trap does the same when the deadline or a delete kills the pod; the
long steps run in the background with `wait` so bash (PID 1) can take the signal.

The pod log alone loses exactly the runs that matter (review finding): at `activeDeadlineSeconds` the Job controller
deletes the pod and its log, and the kubelet rotates container logs at 50Mi while the pipeline's `set -x` traces the
whole release-info JSON on every `./build.sh` call. So every contract line is also appended, before it is printed, to
`/work/logs/build-<MODE>-<DATE>.contract` on the PVC, and the whole output is copied there by
`exec > >(tee -a /work/logs/build-<MODE>-<DATE>.log) 2>&1` (a redirection, so exit statuses are unchanged; at exit
the script closes its end and gives tee up to 5 s to drain). `log-reader.yaml` is a read-only pod for reading them
afterwards: PVC attached and mounted read-only, `sleep 3600`, privileged like the build pod so CRI-O does not
relabel and the SCC does not chown the volume.

The same review found that nothing kept two runs off the PVC: RWO only blocks other nodes, and a second pod on the
same node would have wiped `/work/run` under the first and shared its podman graph root. `build.sh` now takes
`flock -n` on `/work/.lock` right after opening its log files and before anything touches `/work/run`, the caches or
the graph root (`flock` is in `util-linux-core`; it is installed first if the image lacks it).

Verify renders each bundle with `opm render <repo>@<digest>`, decodes the CSV from its `olm.bundle.object`, and
checks `olm.maxOpenShiftVersion` 4.23, that every related image and every `RELATED_IMAGE_*`/`*_IMAGE` env value is a
zot `okd-test` reference by digest that this run pushed, that the CSV has no `valid-subscription` or `Red Hat` line,
that the provider is `OKD Community`, and, if the cloned `build.sh` builds passthrough-gateway, that the loki CSV
carries `RELATED_IMAGE_PASSTHROUGH_GATEWAY`. The image list comes from sourcing the cloned `build.sh` and reading its
`IMG_*` variables. The jq filters were tried against the published 6.3.0 loki-operator entry in the catalog repo
(itself `opm render` output): it read `maxOpenShiftVersion` 4.20, provider `OKD Community`, and one
`valid-subscription|Red Hat` line, so the branding check would have failed 6.3.0. One exception had to go in: the
loki CSV's kube-rbac-proxy is the OKD payload image (`quay.io/okd/scos-content@sha256:…`) that `build.sh` resolves
from the release, so verify accepts exactly that value, by digest, and nothing else from outside zot. It prints that
reference on its own line, `CHECK kube-rbac-proxy-from-payload/<pkg> PASS <ref>`, so each run's log records which
payload image the bundle carries (on `main` the pipeline targets OKD 5.0.0-okd-scos.0).

Choices:

- **PVC, not node disk.** One PVC mounted twice by `subPath`: `containers` → `/var/lib/containers`, `work` → `/work`
  (clones, tools, Go caches, `TMPDIR`, podman's `image_copy_tmp_dir`). The image declares `/var/lib/containers` a
  `VOLUME`, which would otherwise be a directory on the node's root disk, and node5's root disk carries a mon at the
  `MON_DISK_LOW` line. No node pinning: RBD attaches anywhere.
- **Privileged podman.** `quay.io/podman/stable` already runs nested containers in host namespaces with
  `cgroups="disabled"` and cgroupfs, and sets `BUILDAH_ISOLATION=chroot`. I swap its fuse-overlayfs for the kernel
  overlay driver, since the graph root is ext4 on RBD rather than the container's own overlay, and turn SELinux
  relabelling off (`label = false`). The pod asks for the SCC with `openshift.io/required-scc: privileged`.
- **zot `okd-test/` only.** zot mirrors quay.io, docker.io, ghcr.io and registry.k8s.io for the whole cluster in one
  namespace, with no auth. The pod has no registry credentials at all, and `build.sh` refuses a `BASE_REGISTRY` that
  does not match `^zot\.apps\.okd\.sudops\.pl/okd-test(/component)*$` and any `IMG_*` from the cloned `build.sh` that
  points elsewhere. `full` also refuses to run if `operator:<MAJOR>.<MINOR>.0-<DATE>` already exists, so no tag is
  pushed twice. The 5 GiB zot free-space check stays outside the Job, because the pod has no API rights.
- **Pinned tools.** Go 1.26.10, operator-sdk v1.36.1 (what the pipeline's CI installs), opm v1.74.0, yq v4.54.1,
  kustomize v5.8.1 (loki's own bingo pin; CLO's is v5.4.3) and oc 4.21.36 (`stable-4.21` today). Each has its
  sha256 in the script, taken from the project's published checksums. I downloaded each artifact once here and all
  six hashes matched; the oc tarball holds `oc`, `kubectl`, `README.md` and the kustomize tarball holds `kustomize`.
  `quay.io/podman/stable:v5.8.9` exists; quay re-pushes it (last modified 2026-10-20 03:41), so the Job pins the
  manifest list it pointed at then, `sha256:dc02649067d5f7afd93db0bf31fbc604b56811c64594178eae3a72bdbb555e2e`.

Offline checks:

```
$ bash -n tests/okderators-logging-build/build.sh && echo "bash -n OK"
bash -n OK
$ oc kustomize tests/okderators-logging-build/ | kubeconform -strict -ignore-missing-schemas -summary …
Summary: 5 resources found parsing stdin - Valid: 5, Invalid: 0, Errors: 0, Skipped: 0
$ oc process --local -f tests/okderators-logging-build/job-template.yaml -p MODE=full \
    -p DATE=2026-10-20-000000 -p PIPELINE_BRANCH=cluster-logging-6.6 | kubeconform -strict …
stdin - Job build-full-2026-10-20-000000 is valid
```

`oc diff` cannot run with the read-only kubeconfig: it is a server-side dry run, which RBAC authorizes like a real
create (`namespaces is forbidden: User "system:serviceaccount:automation:claude-reader" cannot create resource
"namespaces"`). Read-only `oc get` shows that every object would be new (`namespaces "okd-build" not found`) and that
what they depend on exists: ClusterRole `system:openshift:scc:privileged` (`use` on SCC `privileged`), SCC
`privileged` (`allowPrivilegedContainer=true`, `RunAsAny`), StorageClass `ceph-nvme-block` (ext4, `Immediate`).
The local bash is 3.2, so `bash -n` here does not exercise the bash 4+ parts (`local -n`, `declare -A`,
`inherit_errexit`); those first run in the pod. If verify trips over a script bug at the end of a long build, `check`
redoes the bundles and verify without rebuilding the images.
