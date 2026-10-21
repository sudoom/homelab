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

## 2026-10-20 — catalog graphs: the edit and the walker

The catalog step of the build Job: `MODE=catalog` adds the two 6.6 bundles to the okderators catalog branches,
checks the upgrade graphs, and builds the test catalog image the homelab will subscribe to. The code is
`tests/okderators-logging-build/catalog-edit.sh` plus a walker, `catalog-walk.py`; the Job has not run it yet.
Everything below ran on the Mac against local copies of the three catalog branches (tips unchanged upstream:
`release-4.20` bfbb297, `release-4.21` 6c737c9, `release-4.22` 252d764), with opm v1.74.0 for darwin-arm64,
sha256 checked against the release's `checksums.txt`.

**The failing check first.** On the unedited trees the 4.21 and 4.22 heads are the 6.3.0 builds, capped at 4.20:

```
$ opm render <tree>/catalog/<pkg> -o json | jq -s '<heads, then their olm.maxOpenShiftVersion>'
release-4.21 cluster-logging  cluster-logging.v6.3.0-2025-08-08-133408  olm.maxOpenShiftVersion="4.20"
release-4.21 loki-operator    loki-operator.v6.3.0-2025-08-08-133408    olm.maxOpenShiftVersion="4.20"
release-4.22 cluster-logging  cluster-logging.v6.3.0-2025-08-08-133408  olm.maxOpenShiftVersion="4.20"
release-4.22 loki-operator    loki-operator.v6.3.0-2025-08-08-133408    olm.maxOpenShiftVersion="4.20"
```

and the homelab's two Subscriptions (CatalogSource `okderators`, `catalog-index:4.21`, `READY`) sit at the
6.5.0 they were installed with from the 4.20 catalog, with nothing to move to:

```
$ KUBECONFIG=~/.kube/config-readonly oc -n openshift-logging get subscription \
    -o jsonpath='{range .items[*]}{.metadata.name} {.status.state} {.status.installedCSV}{"\n"}{end}'
cluster-logging AtLatestKnown cluster-logging.v6.5.0-2026-06-04-101319
$ ... -n openshift-operators-redhat ...
loki-operator AtLatestKnown loki-operator.v6.5.0-2026-06-04-101319
```

The walker says the same about the unedited 4.21 tree: 6.5.0 is not in it, and no entry's `replaces`, `skips` or
`skipRange` takes it anywhere.

```
$ python3 -I catalog-walk.py walk render-4.21-cl.json cluster-logging alpha \
    cluster-logging.v6.3.0-2025-08-08-133408 --installed cluster-logging.v6.5.0-2026-06-04-101319
FAIL stranded: cluster-logging.v6.5.0-2026-06-04-101319 (installed, absent from the channel) dead ends: cluster-logging.v6.5.0-2026-06-04-101319
```

**The edit.** Per branch: clone, find each package's single head in `alpha` (operator-registry's rule: the entry
no other entry names in `replaces` or `skips`; more than one is a FAIL before anything changes), add the bundles,
and append one entry per package with yq:

```yaml
  - name: cluster-logging.v6.6.0-<DATE>
    replaces: cluster-logging.v6.3.0-2025-08-08-133408     # 4.20: the 6.5.0 entry
    skipRange: '>=6.2.0-0 <6.6.0'
```

The script checks that yq changed nothing but those three lines (it re-emits the whole file; the only other diff
is a final newline on `loki-operator.yaml`, which has none upstream, as in the 6.5.0 commit on 4.20).

**The walker.** `opm validate` only proves a single head and no `replaces` cycle; it says nothing about whether a
cluster on 5.9.0, 6.2.0 or 6.3.0 gets to the head, and nothing at all about a CSV that is not in the catalog. So
`catalog-walk.py` follows OLM v0's upgrade edges forward from every entry and from the installed
`<pkg>.v6.5.0-2026-06-04-101319`: X → Y when Y `replaces` X, Y `skips` X, or X's version is inside Y's
`skipRange` (semver as blang/semver orders it, the library OLM uses). PASS needs the only reachable dead end to be
the head, so whichever edge OLM picks at each step it ends there. The head's own version, `6.6.0-<DATE>`, is a
prerelease below `6.6.0` and so inside its own skipRange; the walker does not count that as an edge.
`opm validate` is no evidence either way: it parses a skipRange but never evaluates it (corrected after review;
the evidence is in the next section). On the edited 4.21 tree:

```
INFO walk clusterlogging.v5.9.0-2024-05-05-192913 -(replaces)-> cluster-logging.v6.2.0-2025-05-26-200125 -(skipRange)-> cluster-logging.v6.6.0-2026-10-20-000000
INFO walk cluster-logging.v6.2.0-2025-05-26-200125 -(skipRange)-> cluster-logging.v6.6.0-2026-10-20-000000
INFO walk cluster-logging.v6.3.0-2025-08-08-133408 -(replaces+skipRange)-> cluster-logging.v6.6.0-2026-10-20-000000
INFO walk cluster-logging.v6.5.0-2026-06-04-101319 -(skipRange)-> cluster-logging.v6.6.0-2026-10-20-000000 (installed, absent from the channel)
```

**Negative control.** A copy of the edited tree with the new entries' `replaces` removed must fail `opm validate`:
`skipRange` does not count toward heads, so 6.3.0 (6.5.0 on 4.20) becomes a second head. opm prints the whole
error tree as one logfmt `msg` with literal `\n` separators, so my first matcher, a grep for the line with
"multiple channel heads" and the new CSV name, would have passed on one package's error alone; the script now
splits the message and needs one line per package naming both heads.

**Three things found on the way.**

- opm v1.74.0 refuses a bundle reference with both a tag and a digest, which is the form the full run's `PUSHED`
  lines print: `Docker references with both a tag and digest are currently not supported`. The script keeps the
  digest and drops the tag, so the test catalog references both bundles by digest only.
- `hack/add-bundle.sh` on the release branches reads the CSV name with `podman create` on the bundle. The 6.5.0 loki
  bundle on quay has no `Cmd` and no `Entrypoint` in its image config (`FROM scratch`, labels only), and podman
  refuses to create a container without a command; the 6.6 bundles are built the same way. okderators-catalog-index
  PR #59 (open) takes the name from `opm render` instead. The script runs the branch's own `add-bundle.sh` first and,
  when it fails, writes the same file the same way. Rendering the real 6.5.0 loki bundle by digest that way
  reproduced the published `loki-operator.v6.5.0-2026-06-04-101319.yaml` exactly, except the two `image:` lines
  (digest instead of tag).
- `opm validate` passes on a tree whose 6.6 entry has no `skipRange`, while the installed 6.5.0 is stranded. That is
  the case the walker exists for (RED below).

**Local results.** Test mode (`CATALOG_EDIT_TEST_BUNDLES`) swaps the add-bundle step for synthetic `olm.bundle`
documents (`<pkg>.v6.6.0-2026-10-20-000000`, version `6.6.0-2026-10-20-000000`, a placeholder digest) and builds no
image; the clones come from a throwaway bare repo holding the three branches.

GREEN, all three branches, exit 0:

```
CHECK opm-validate-release-4.20 PASS opm validate catalog
CHECK walk-release-4.20-cluster-logging PASS 5 entries reach cluster-logging.v6.6.0-2026-10-20-000000
CHECK walk-release-4.20-loki-operator PASS 5 entries reach loki-operator.v6.6.0-2026-10-20-000000
CHECK negative-control-release-4.20 PASS opm validate failed as expected, multiple channel heads: cluster-logging.v6.5.0-2026-06-04-101319, cluster-logging.v6.6.0-2026-10-20-000000 | loki-operator.v6.5.0-2026-06-04-101319, loki-operator.v6.6.0-2026-10-20-000000
CHECK opm-validate-release-4.21 PASS opm validate catalog
CHECK walk-release-4.21-cluster-logging PASS 4 entries + 1 installed CSV absent from the channel reach cluster-logging.v6.6.0-2026-10-20-000000
CHECK walk-release-4.21-loki-operator PASS 4 entries + 1 installed CSV absent from the channel reach loki-operator.v6.6.0-2026-10-20-000000
CHECK negative-control-release-4.21 PASS opm validate failed as expected, multiple channel heads: cluster-logging.v6.3.0-2025-08-08-133408, cluster-logging.v6.6.0-2026-10-20-000000 | loki-operator.v6.3.0-2025-08-08-133408, loki-operator.v6.6.0-2026-10-20-000000
CHECK opm-validate-release-4.22 PASS opm validate catalog
CHECK walk-release-4.22-cluster-logging PASS 4 entries + 1 installed CSV absent from the channel reach cluster-logging.v6.6.0-2026-10-20-000000
CHECK walk-release-4.22-loki-operator PASS 4 entries + 1 installed CSV absent from the channel reach loki-operator.v6.6.0-2026-10-20-000000
CHECK negative-control-release-4.22 PASS opm validate failed as expected, multiple channel heads: cluster-logging.v6.3.0-2025-08-08-133408, cluster-logging.v6.6.0-2026-10-20-000000 | loki-operator.v6.3.0-2025-08-08-133408, loki-operator.v6.6.0-2026-10-20-000000
CHECK opm-validate-image PASS opm validate catalog
```

(22 CHECK lines in all, every one PASS; the `bundles-` and `edit-` lines are left out here.) RED, three ways:

```
# 1. the edited 4.21 tree with the 6.6 cluster-logging entry's skipRange deleted
$ opm validate catalog; echo rc=$?
rc=0
$ python3 -I catalog-walk.py walk r.json cluster-logging alpha cluster-logging.v6.6.0-2026-10-20-000000 \
    --installed cluster-logging.v6.5.0-2026-06-04-101319
INFO walk cluster-logging.v6.3.0-2025-08-08-133408 -(replaces)-> cluster-logging.v6.6.0-2026-10-20-000000
FAIL stranded: cluster-logging.v6.5.0-2026-06-04-101319 (installed, absent from the channel) dead ends: cluster-logging.v6.5.0-2026-06-04-101319

# 2. a 4.21 branch that already carries the edit, and a 4.22 branch whose loki channel has two heads; exit 1
CHECK bundles-release-4.21 FAIL 0 new bundle files, want one per package (cluster-logging loki-operator); already in the catalog?
CHECK edit-release-4.22-loki-operator FAIL 2 heads in alpha before the edit: loki-operator.v6.2.0-2025-05-26-200125 loki-operator.v6.3.0-2025-08-08-133408
CHECK catalog-image FAIL not built: 2 checks failed before it

# 3. the same RUN_DIR a second time
ERROR <run dir>/release-4.21 exists: catalog-edit.sh runs once per RUN_DIR
```

The non-test path ran too, with the real 6.5.0 bundles from quay (passed as `tag@digest`) standing in for 6.6 on
4.21 and a `podman` stub on `PATH` that refuses everything: the tags were dropped, `add-bundle.sh` failed at
`podman pull`, the opm-render fallback wrote both files, every check up to the image passed, and the stub's refusal
of `podman build` ended the run with `CHECK catalog-image FAIL podman build failed`, exit 1 and no pushed-image
marker for `build.sh` to report.

**The test catalog image.** From the edited `release-4.21` tree, `cluster-logging` and `loki-operator` only, built
with that branch's own `catalog.Containerfile` (`ADD catalog /configs`, `opm serve --cache-only`). Its
`FROM quay.io/operator-framework/opm:latest` is pinned to the digest: `:latest` and `v1.74.0` are the same index
today, `sha256:b32d3891616662620da08d7f0ec42c2e69fa2de43427dc975d35b12f7a969a0f`. The Job pushes it to
`zot.apps.okd.sudops.pl/okd-test/logging-catalog:<DATE>` (the name is fixed in `build.sh`, which guards it and
checks that the tag does not exist yet), renders it back from zot and walks it again; `build.sh` prints its
`PUSHED` line. `build.sh` also gained `python3` in its dnf list and a ref argument for `tag_check`.

Offline checks: `bash -n` on both scripts, `oc kustomize tests/okderators-logging-build/ | kubeconform -strict …`
→ 5 valid (the ConfigMap now holds `build.sh`, `catalog-edit.sh`, `catalog-walk.py`), and the
`MODE=catalog` Job from `oc process --local` → 1 valid. The bash 4 parts of `build.sh` (`mode_catalog`) cannot run on
the Mac's bash 3.2; `catalog-edit.sh` is written for 3.2 so the same file ran here.

## 2026-10-20 — catalog graphs: review fixes

The review approved the catalog step and asked for four changes before the Job runs it.

**Old entries as start points.** `cluster-logging.v6.2.0-2025-05-25-184240` and
`loki-operator.v6.2.0-2025-05-25-184240` were channel entries once and survive only in the `skips` of the
6.2.0-2025-05-26 entries. A cluster could still run them, so the walker now starts from them too, next to the
homelab's 6.5.0 pair. They reach the head directly through the new skipRange (and through `skips`):

```
INFO walk cluster-logging.v6.2.0-2025-05-25-184240 -(skipRange)-> cluster-logging.v6.6.0-2026-10-20-000000 (absent from the channel)
CHECK walk-release-4.21-cluster-logging PASS 4 entries + 2 CSVs absent from the channel reach cluster-logging.v6.6.0-2026-10-20-000000
```

**Bundle versions up front.** Before any clone, each bundle is rendered and must be the only `cluster-logging` or
`loki-operator` bundle with a `6.6.*` version (one variable, `BUNDLE_MINOR=6.6`, which also gives the skipRange
its `<6.6.0`). Passing the real 6.5.0 bundles from quay as `BUNDLES`:

```
CHECK bundle-version-loki-operator FAIL loki-operator.v6.5.0-2026-06-04-101319 has version 6.5.0-2026-06-04-101319, want 6.6.*
CHECK bundle-version-cluster-logging FAIL cluster-logging.v6.5.0-2026-06-04-101319 has version 6.5.0-2026-06-04-101319, want 6.6.*
INFO catalog-edit: stopped before any edit, 2 checks failed
```

Two bundles for one package stop the run the same way (`two bundles for cluster-logging: …`).

**The self-in-skipRange case.** I had written that `opm validate` passing shows the catalog accepts an entry whose
own version is inside its own skipRange. It does not: `opm validate` parses a skipRange (an unparseable one fails,
`invalid skipRange "this is not a range": Could not get version from string: "this"`) but never evaluates which
versions it covers. Better evidence is OLM in use, checked today:

```
$ KUBECONFIG=~/.kube/config-readonly oc get subscription -A -o jsonpath='…' | grep oadp
openshift-adp oadp-operator AtLatestKnown oadp-operator.v1.5.0-2026-01-05-165341 okderators
$ KUBECONFIG=~/.kube/config-readonly oc -n openshift-adp get csv oadp-operator.v1.5.0-2026-01-05-165341 \
    -o jsonpath='{.spec.version} {.metadata.annotations.olm\.skipRange}'
1.5.0-2026-01-05-165341 >=1.4.0 <1.5.3
```

`cluster-logging.v6.5.0-2026-06-04-101319` is the same shape (CSV `olm.skipRange` `>=6.3.0-0 <6.5.0`) and also sits
at `AtLatestKnown`. Both are CSV annotations: in okderators' FBC the channel entries of those two bundles carry no
`skipRange`. A channel-entry skipRange covering its own entry, which is what this edit adds, is already in the
catalog this cluster serves: scanning every entry of `release-4.21` with the walker's semver code finds exactly one,
`ingress-node-firewall.v4.21.0-2026-05-19-130000` with `skipRange: '>=4.11.0 <4.21.0'`, and the packagemanifest
from `okderators` lists it as `alpha`'s current CSV. Nothing here subscribes to it, so the first live Subscription
on such an entry is the homelab's own move to 6.6.

**A second control in the run.** The case the walker exists for, the new entry without its skipRange, was only
shown on the Mac. Now every branch where the homelab's 6.5.0 CSVs are absent (4.21 and 4.22) gets
`negative-control-skiprange`: a copy of the edited tree with the new entries' `skipRange` removed must still pass
`opm validate` while the walker strands both 6.5.0 CSVs. On 4.20 they are channel entries and the control is skipped
with an `INFO` line.

```
CHECK negative-control-skiprange-release-4.21 PASS without the new skipRange opm validate passes and the walker strands cluster-logging.v6.5.0-2026-06-04-101319 loki-operator.v6.5.0-2026-06-04-101319
CHECK negative-control-skiprange-release-4.22 PASS without the new skipRange opm validate passes and the walker strands cluster-logging.v6.5.0-2026-06-04-101319 loki-operator.v6.5.0-2026-06-04-101319
```

Local test mode afterwards: 26 CHECK lines, all PASS, exit 0 (two `bundle-version`, seven per branch, two
skipRange controls, `opm-validate-image`). The earlier REDs still fail as before (a tree that already has the
bundles, a channel with two heads, a reused `RUN_DIR`). `kubeconform` on `oc kustomize` and on the `MODE=catalog`
Job: 5 and 1 valid.

## 2026-10-20 — the first in-cluster build

First run of the Job from `tests/okderators-logging-build/` on the cluster. Two full runs: the first stopped at the
tag check, the second built everything and failed only on my own branding check.

Commands (from the repo root, operator's kubeconfig, per the README):

```bash
oc apply -k tests/okderators-logging-build/
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-logging-build/job-template.yaml \
  -p MODE=full -p DATE=$DATE | oc -n okd-build create -f -
oc -n okd-build logs job/build-full-$DATE | grep -E '^(STEP|DISK|PUSHED|CHECK|RESULT) '
```

Before the first apply: zot `data-zot-0` had 18.6 GiB free of 48.9, Ceph `nvme-replicated` `MAX AVAIL` was 271.2 GiB,
so the 100Gi thin PVC fit.

### Run 1 (`2026-10-20-133814`): failed at tag-check after 65 s

Steps before it: tools 57 s, podman-setup 4 s, clone 4 s, `DISK` 1.03 GB. The tag check asks zot whether
`cluster-logging/operator:6.6.0-<DATE>` already exists, and accepts only an "absent" answer. The repository did not exist
yet (first push ever under `okd-test/cluster-logging`), and zot answers that with `NAME_UNKNOWN`, which skopeo prints as
`repository name not known to registry`. `build.sh` accepted only `manifest unknown|name unknown|not found|404`, so the
wording missed and the check failed closed. Fix: `6047126` adds `repository name not known` to `ABSENT_RE`.

Reading the pattern again for the fix showed the opposite bug: a bare `404` matched anywhere in the error text, and a
`DATE` such as `2026-10-20-404…` is part of the reference skopeo echoes back, so any error for such a tag would have read
as "absent" and the check would have failed open. The `404` alternative is now tied to an HTTP status. A scoped
re-review found no new breakage. Left as is: the `not found` alternative is unanchored, so a DNS or credential-helper
message containing it would also read as absent; pre-existing and narrow.

### Run 2 (`2026-10-20-134619`)

Step durations (`STEP` lines are epoch seconds; END minus START):

| step | duration |
|---|---|
| tools | 24 s |
| podman-setup | 3 s |
| clone | 3 s |
| tag-check | 2 s |
| init | 254 s |
| build_containers | 4914 s (81.9 min) |
| push_containers | 48 s |
| build_bundle | 263 s |
| deinit | 19 s |
| verify | 3 s |

Tools to verify took 5569 s of wall clock (92.8 min, about 93). `build_containers` is 88 % of it.

Per-image times from `podman build` to `Successfully tagged` (`oc logs --timestamps`):

| image | time |
|---|---|
| vector | 42 min 34 s |
| operator | 9 min 19 s |
| loki | 8 min 48 s |
| loki-operator | 6 min 10 s |
| lokistack-gateway | 4 min 25 s |
| opa-openshift | 3 min 20 s |
| eventrouter | 3 min 07 s |
| log-file-metric-exporter | 2 min 11 s |
| passthrough-gateway | 1 min 00 s |
| bundles (two) | 9 s and 6 s |

Vector alone is more than half of the image build time. The `powersave-experimental` Tuned (all cores at minimum
frequency) was on for the whole run, so these are slow-clock numbers.

`DISK` after each step (`du -sx` of `/var/lib/containers` + `/work`):

| after | bytes | GB |
|---|---|---|
| tools .. tag-check | 1,034,469,376 | 1.03 |
| init | 4,123,422,720 | 4.12 |
| build_containers | 33,642,942,464 | 33.64 |
| push_containers | 33,643,122,688 | 33.64 |
| build_bundle | 37,036,376,064 | 37.04 |
| deinit | 37,036,539,904 | 37.04 |
| verify | 37,038,800,896 | 37.04 |

Peak: 37.0 GB. The bundle step adds 3.4 GB on its own; I have not broken that down yet.

### What got pushed

All under `zot.apps.okd.sudops.pl/okd-test/cluster-logging/`. Digest = sha256 of the manifest bytes zot serves, first 12
hex characters; size = config + layer bytes from the `PUSHED` line.

| image | tag | digest | size |
|---|---|---|---|
| operator | `6.6.0-2026-10-20-134619` | `457d295bbdff` | 160.5 MB |
| vector | `6.6.0-2026-10-20-134619` | `3a8b699a7c29` | 141.2 MB |
| loki | `6.6.0-2026-10-20-134619` | `095978a652d8` | 115.5 MB |
| loki-operator | `6.6.0-2026-10-20-134619` | `8deb587b9b6c` | 108.9 MB |
| log-file-metric-exporter | `6.6.0-2026-10-20-134619` | `6c131fcf58d9` | 94.1 MB |
| lokistack-gateway | `6.6.0-2026-10-20-134619` | `80dd5377a699` | 89.7 MB |
| opa-openshift | `6.6.0-2026-10-20-134619` | `52d82172480f` | 83.6 MB |
| passthrough-gateway | `6.6.0-2026-10-20-134619` | `74f025435d73` | 75.4 MB |
| eventrouter | `latest` | `ded7a2403861` | 68.6 MB |
| operator-bundle | `6.6.0-2026-10-20-134619` | `2567fa857acc` | 61 KB |
| loki-operator-bundle | `6.6.0-2026-10-20-134619` | `2f191a1152c1` | 59 KB |

The nine images sum to 937,411,468 B. `eventrouter` is pushed as `latest` because that is the tag the pipeline's own
`build.sh` gives it. The OpenShift Route in front of zot carried every upload
(no haproxy timeout). zot free space: 18.6 GiB before, 16.9 GiB after (15:20Z), so 1.7 GiB for the nine images and two
bundles.

### Verify

```
CHECK max-openshift-version/cluster-logging PASS 4.23
CHECK images/cluster-logging PASS 6 refs, all zot.apps.okd.sudops.pl/okd-test/...@sha256 or the payload kube-rbac-proxy
CHECK images-built/cluster-logging PASS every zot.apps.okd.sudops.pl/okd-test ref is a digest this run pushed
CHECK provider/cluster-logging PASS OKD Community
CHECK max-openshift-version/loki-operator PASS 4.23
CHECK images/loki-operator PASS 10 refs, all zot.apps.okd.sudops.pl/okd-test/...@sha256 or the payload kube-rbac-proxy
CHECK images-built/loki-operator PASS every zot.apps.okd.sudops.pl/okd-test ref is a digest this run pushed
CHECK provider/loki-operator PASS OKD Community
CHECK passthrough-gateway/loki-operator PASS zot.apps.okd.sudops.pl/okd-test/cluster-logging/passthrough-gateway@sha256:74f025435d73…
CHECK branding/cluster-logging FAIL 3 lines: …Red Hat Managed Elasticsearch… | …Red Hat managed Loki deployment | …Red Hat tenancy model
CHECK branding/loki-operator FAIL 1 lines:       name: Red Hat, AOS Logging
RESULT FAIL verify: 2 checks failed
```

Every build-related check passed: both bundles carry `olm.maxOpenShiftVersion` 4.23, every related image is a zot
digest this run pushed, provider is `OKD Community`, and the passthrough gateway is wired into the loki-operator CSV.

### The branding finding

The branding check was my invention and stricter than the standard okderators applies: it failed on any line with
"Red Hat". The four hits are three API field descriptions in the cluster-logging CRDs (`Red Hat Managed Elasticsearch`,
`Red Hat managed Loki deployment`, `Red Hat tenancy model`) and the loki-operator maintainer entry (`Red Hat, AOS
Logging`). All four are verbatim in the accepted okderators 6.5.0 CSVs running on this cluster (checked with the live
CSVs: 3 lines in cluster-logging, 1 in loki-operator). They are maintainer attribution and API documentation, not a
release label. Anti-goal stays: a source must never be re-labelled as a Red Hat release.

Ruling P21: the check now fails on `valid-subscription` (keys or values), on a `support` annotation naming Red Hat, on a
non-OKD provider, and on any "Red Hat" line outside a 4-string baseline taken from the accepted 6.5.0 CSVs (commit
`fc99643`; the live 6.5.0 CSVs pass it with the 4 allowed lines). Ruling P22: run 2 is accepted as the full build
without a rebuild, since every other check passed and the branding hits equal the 6.5.0 baseline; later check runs
re-verify with the corrected check. Deferred minors: the baseline substrings are not anchored to a field, and
`RedHat` or odd-spacing variants are not caught (deliberate: `redhat` also matches the namespace and an email in the
accepted CSVs).

### Correction: kube-rbac-proxy

Earlier in this draft, and in ruling P14, I wrote that the payload `kube-rbac-proxy` (`quay.io/okd/scos-content@sha256:…`
resolved from the OKD release) would be pinned in the bundle, and that on `main` it would be the OKD 5.0 payload's
image. That was wrong for 6.6. Neither 6.6 CSV carries a kube-rbac-proxy: the loki-operator `678e5e8f` manager serves
its metrics itself on 8443. That is why no `CHECK kube-rbac-proxy-from-payload/<pkg>` line was printed, and why the
`images` counts are 6 (cluster-logging) and 10 (loki-operator) refs, all zot. The original spec note, "unused at 6.5+",
was right, and the 5.0-payload concern does not arise.

### Open question for the operator

Peak disk was 37.0 GB. A GitHub `ubuntu-latest` runner has about 14 GB free, which is what upstream's CI would build
on. This has to be decided before the upstream PRs are filed: whether the upstream PR text states the figure and leaves
the CI question to the maintainer, or whether the build can be shrunk (`vector` is 42 min of the 82; I have not yet
broken the 33.6 GB down by image). Wall time, 93 min on throttled cores, is
not the concern.

## 2026-10-20 — catalog graphs validated in the Job

`MODE=catalog` run of the edit and walker from the two sections above, against the real 6.6 bundles of the full run.
Job `build-catalog-2026-10-20-153109`, 15:32 to 15:35Z; the `catalog-edit` step took 102 s (tools 21 s, podman-setup
4 s, tag-check 2 s before it).

```bash
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-logging-build/job-template.yaml \
  -p MODE=catalog -p DATE=$DATE \
  -p CATALOG_BRANCHES='release-4.20 release-4.21 release-4.22' \
  -p BUNDLES='zot.apps.okd.sudops.pl/okd-test/cluster-logging/loki-operator-bundle:6.6.0-2026-10-20-134619@sha256:2f191a1152c166e21fd40327b0f4764993ecb8871541b78fc0db6c9606bac90c zot.apps.okd.sudops.pl/okd-test/cluster-logging/operator-bundle:6.6.0-2026-10-20-134619@sha256:2567fa857acca7ebc7fa077498fce9c2f648bf4a9d444c82e3d0f23d3784311f' \
  | oc -n okd-build create -f -
oc -n okd-build logs job/build-catalog-$DATE | grep -E '^(STEP|PUSHED|CHECK|RESULT) '
```

`RESULT PASS catalog 2026-10-20-153109`, 27 `CHECK` lines, all PASS.

Edits: on `release-4.20` the new entries replace the 6.5.0 head (`v6.5.0-2026-06-04-101319`); on `release-4.21` and
`release-4.22` they replace the 6.3.0 head (`v6.3.0-2025-08-08-133408`), both with `skipRange: '>=6.2.0-0 <6.6.0'`.
Both packages, same values.

| check | release-4.20 | release-4.21 | release-4.22 |
|---|---|---|---|
| `bundle-version-loki-operator`, `-cluster-logging` (once, before any clone) | PASS, both `6.6.0-2026-10-20-134619` | | |
| `bundles-<branch>` | PASS, both CSVs added via each branch's `hack/add-bundle.sh` | PASS, same | PASS, same |
| `edit-<branch>-cluster-logging` | PASS, replaces `v6.5.0-…-101319` | PASS, replaces `v6.3.0-…-133408` | PASS, replaces `v6.3.0-…-133408` |
| `edit-<branch>-loki-operator` | PASS, replaces `v6.5.0-…-101319` | PASS, replaces `v6.3.0-…-133408` | PASS, replaces `v6.3.0-…-133408` |
| `opm-validate-<branch>` | PASS | PASS | PASS |
| `walk-<branch>-cluster-logging` | PASS, 5 entries + 1 absent CSV reach the 6.6 head | PASS, 4 + 2 | PASS, 4 + 2 |
| `walk-<branch>-loki-operator` | PASS, 5 + 1 | PASS, 4 + 2 | PASS, 4 + 2 |
| `negative-control-<branch>` (edit without `replaces`) | PASS, `opm validate` fails: multiple channel heads (6.5.0 and 6.6.0, both packages) | PASS, fails: heads 6.3.0 and 6.6.0 | PASS, fails: heads 6.3.0 and 6.6.0 |
| `negative-control-skiprange-<branch>` | skipped, 6.5.0 is a channel entry here | PASS, `opm validate` passes and the walker strands both 6.5.0 CSVs | PASS, same |
| `opm-validate-image` (the built image, once) | PASS | | |
| `catalog-image` (once) | PASS, see below | | |

Count: 2 `bundle-version` + 7 on 4.20 + 8 each on 4.21 and 4.22 (the extra one is `negative-control-skiprange`) +
`opm-validate-image` + `catalog-image` = 27 `CHECK` lines, all PASS (`grep -E '^CHECK '` on the pod log, 27 PASS).

Branches where 6.5.0 is not a channel entry (4.21, 4.22) walk 4 channel entries plus 2 CSVs that exist only in `skips`
(the 6.2.0-2025-05-25 pair, as started from in the review fixes) and the homelab's 6.5.0 pair is reached through the new
skipRange; on 4.20 the walk is 5 entries + 1 absent CSV.

### `hack/add-bundle.sh` worked in the Job

The catalog repo's own script ran for both bundles on every branch, no fallback to my replacement path. The trace shows
`podman create <bundle>@sha256:…` executing and the script writing `catalog/<package>/<CSV name>.yaml`; the
`bundles-<branch>` detail names `hack/add-bundle.sh` for both bundles. I had expected the `podman create` step to fail
on a `FROM scratch` bundle without a `CMD` (okderators-catalog-index PR #59), and it did not here. I have not looked at
why; the bundles are the same ones the pipeline builds.

### The test catalog image

```
CHECK catalog-image PASS zot.apps.okd.sudops.pl/okd-test/logging-catalog:2026-10-20-153109: packages cluster-logging loki-operator; heads cluster-logging.v6.6.0-2026-10-20-134619 loki-operator.v6.6.0-2026-10-20-134619; every entry and … reach
PUSHED zot.apps.okd.sudops.pl/okd-test/logging-catalog:2026-10-20-153109@sha256:bf21cf1baaa126b6d071e3bee6da11de41f2a93a69f871f65266ca658c4a5c86 32372454
```

| | |
|---|---|
| ref | `zot.apps.okd.sudops.pl/okd-test/logging-catalog:2026-10-20-153109` |
| digest | `sha256:bf21cf1baaa1…` (full digest above) |
| size | 32,372,454 B (32.4 MB) |
| source branch | `release-4.21` (the cluster is on 4.21) |
| base | `quay.io/operator-framework/opm@sha256:b32d38916166…`, `ENTRYPOINT /bin/opm`, `serve /configs --cache-dir=/tmp/cache`, cache pre-built with `--cache-only` |

Next step is the homelab `okd-test-logging` CatalogSource pointing at this image.

## 2026-10-20 — loki-operator 6.6 live: PDBs, and the override retired

After the loki-operator upgrade to the okderators 6.6 test build, the operator creates every LokiStack PDB in `openshift-logging` with `maxUnavailable: 1` and no `minAvailable`. All six show `disruptionsAllowed: 1`, including `logging-loki-ingester` (2/2 ingesters). Before 6.6 the ingester PDB was `minAvailable: 2` with 2 replicas (0 disruptions, drains blocked), which is why `components/cluster-config/loki-pdb-override/` existed: a CronJob every 5 minutes that merge-patched `minAvailable: 1`.

Against the 6.6 PDB it reads `.spec.minAvailable`, finds it empty, and patches `minAvailable: 1`, which the API now rejects (a PDB cannot carry both fields). Every run fails; Job `loki-pdb-override-29875200` logs:

```
The PodDisruptionBudget "logging-loki-ingester" is invalid: spec: Invalid value: {"MinAvailable":1,…
```

That fires `UserNamespaceJobFailed` (emailed). Retired the component: entry removed from `bootstrap/root-app/values.yaml`, chart deleted, so ArgoCD prunes the Application and its resources-finalizer removes the CronJob, RBAC and the failed Jobs. The README TODO "expose PDB tunables on LokiStack" went with it: its only motivation was the 0 disruption budget. The `network-change` skill text (pre-flight step 1 scaling the operator to 0, step 6 restoring it) is now stale; a proposed patch is kept locally since `.claude/skills/` is user-applied.

Separately, 6.6 sets a new LokiStack condition `Warning=True`, reason `InsufficientIngesterReplicas`, message "The ingester replicas (2) are less than or equal to the replication factor (2). Which causes log ingestion to stop when ingester pods get restarted." The `1x.pico` shape is unchanged from 6.5 (2 ingesters, replication factor 2); 6.6 only reports it. Options: replication factor 1, or 3 ingesters. No change made.

## 2026-10-20 — release-branch checks

The 6.6 change has to reach the pipeline's per-release branches (`release-4.22`, `-4.21`, `-4.20`), not only `main` (see the 2026-09-09 note on which branch builds which catalog). Each got a fork branch cut from the upstream release branch, carrying the `cluster-logging/` tree and the `.gitmodules` stanzas from `cluster-logging-6.6` @ `628179e`. Per ruling P5 I did not pre-apply any `common.sh` backport: run `MODE=check` first and cherry-pick only if the check fails on `common.sh`.

| fork branch | head |
|---|---|
| `cluster-logging-6.6` | `628179e` |
| `cluster-logging-6.6-4.22` | `15ba530` |
| `cluster-logging-6.6-4.21` | `e7222e4` |
| `cluster-logging-6.6-4.20` | `50b2959` |

### The runs

Same Job template as the full build, one run per branch, sequentially (P23: all three share the Job name `build-check-2026-10-20-134619` and the PVC log files, appended in run order; the operator deleted each Job after its result was recorded):

```
oc process -f tests/okderators-logging-build/job-template.yaml \
  -p MODE=check -p DATE=2026-10-20-134619 -p PIPELINE_BRANCH=cluster-logging-6.6-4.22 | oc create -f -
# then ...-4.21, then ...-4.20
```

| branch | RESULT | init | build_bundle | CHECKs |
|---|---|---|---|---|
| 4.22 | PASS 15:50:58Z | 248 s | 42 s | 11 PASS (incl. branding at the 3/1 baseline) |
| 4.21 | PASS 16:04:19Z | 265 s | 39 s | 11 PASS |
| 4.20 | PASS 16:14:01Z | 255 s | 39 s | 11 PASS |

4.22 also reports copy 17 s and verify 3 s; the other two ledger lines carry only init and build_bundle.

### No `common.sh` backport needed

Comparing each release branch's `common.sh` with `main` found two `main` fixes it lacks:

| commit | what | on branch | why not reached |
|---|---|---|---|
| `8486ac2` | `foreach` change | 4.21, 4.20 | defect 1 needs nested submodules; neither operator has any |
| `41b80e6` | `submodule_reset` fix | 4.20 | defect 2 is not reached from a committed checkout (gitlinks are already recorded) |

I predicted this after review (before the runs) and the three checks confirmed it: none failed on `common.sh`, so P5's cherry-pick step never fired on any branch. The Job's `sh` is bash, which also avoids the bash-only pitfalls.

### What stays in zot

The checks push the two bundles per branch to `okd-test/check-*` (4.22: `operator-bundle@sha256:c9f2fdb8cd1d…`, `loki-operator-bundle@sha256:92061731e50d…`). Ruling P24: they are skopeo copies of the run-2 blobs, zot dedupes them, so they cost about nothing beyond six small bundle manifests. They stay until the final cleanup, which deletes all `okd-test/` images together.

## 2026-10-20 — the live upgrade

Two commits, one per half of the change, so each reverts alone. The loki half's consequences (PDBs, the retired `loki-pdb-override`) are in "loki-operator 6.6 live" above and not repeated here.

### Commit A: the test catalog (`b0dd862`)

Adds a chart and root-app entry for CatalogSource `okd-test-logging`, image `zot.apps.okd.sudops.pl/okd-test/logging-catalog:2026-10-20-153109`. No Subscription touched. Readonly diff was impossible (the `claude-reader` SA's `oc diff` answered NotFound), so the check was the zot manifest (200) and the result:

```
CatalogSource okd-test-logging READY 15:43:57Z on node4 (image pulled from zot in 3.0 s)
packagemanifest cluster-logging  alpha = v6.6.0-2026-10-20-134619
packagemanifest loki-operator    alpha = v6.6.0-2026-10-20-134619
```

An early TRANSIENT_FAILURE in my wait loop was pod startup, not a fault.

### Commit B: Subscriptions to the test catalog (`29511d3`)

Both Subscriptions (`cluster-logging`, `loki-operator`) change `source: okderators` -> `okd-test-logging`; `installPlanApproval: Manual` stays. Pushed, then at 15:50:37Z OLM created one pending InstallPlan per Subscription, both `UpgradePending`:

| namespace | InstallPlan | CSV |
|---|---|---|
| `openshift-operators-redhat` | `install-g8hvd` | `loki-operator.v6.6.0-2026-10-20-134619` |
| `openshift-logging` | `install-q6tmb` | `cluster-logging.v6.6.0-2026-10-20-134619` |

The installed CSV is `v6.5.0-2026-06-04-101319`, which the test catalog does not contain. OLM still resolved the upgrade, so the `skipRange` edge from the catalog-graph edit works live, not just in the offline walker.

### Approvals, in order

loki-operator first (the CLF side depends on it), then cluster-logging once LokiStack was healthy:

```
oc -n openshift-operators-redhat patch installplan install-g8hvd --type merge -p '{"spec":{"approved":true}}'   # 15:51:50Z
oc -n openshift-logging patch installplan install-q6tmb --type merge -p '{"spec":{"approved":true}}'            # 16:14:35Z
```

Run by the operator (my kubeconfig is readonly). Current state, readonly: both InstallPlans `approved=true`, `Complete`; both Subscriptions `okd-test-logging`, `AtLatestKnown`, installed CSV the 6.6.0 names; both CSVs `Succeeded`; LokiStack `Ready=True`, `Warning=True`, `Pending=False`, `Failed=False`; CLF `Authorized`/`Valid`/`Ready` all True; collector DaemonSet image `zot.apps.okd.sudops.pl/okd-test/cluster-logging/vector@sha256:3a8b699a7c29…` (3/3 updated and ready).

### Before / after

"Before" is the baseline taken 15:36Z to 15:38Z, "after" is 16:28Z to 16:30Z.

| | before (6.5.0) | after (6.6.0) |
|---|---|---|
| CSVs | `cluster-logging` / `loki-operator` `v6.5.0-2026-06-04-101319` Succeeded | both `v6.6.0-2026-10-20-134619` Succeeded |
| LokiStack | `Ready=True` | `Ready=True`, plus new `Warning=True` `InsufficientIngesterReplicas` (pico shape unchanged, 6.6 only reports it) |
| CLF conditions | Authorized, Valid, Ready all True | same |
| collector image | not recorded in the baseline | zot `okd-test/cluster-logging/vector@sha256:3a8b699a7c29…` |
| PDBs | ingester `minAvailable: 1`, forced by the override CronJob | all six `maxUnavailable: 1`, `allowed=1` |
| scrape targets | 20 up across 10 jobs, 0 down | 20 up, 0 down (6.6 metrics auth works) |
| ingestion | not recorded in the baseline | distributor ~120 lines/s |
| chunks flushed | 373 per 1 h | 201 per 30 min |
| object-store uploads | 384 `PutObject` per 1 h, all 200 | 207 per 30 min, 0 failures |
| last successful upload | not recorded | 27 s ago |

The baseline windows are 1 h and the after windows 30 min, so compare rates, not counts: 373/h is about 187 per 30 min (after: 201), and 384/h is about 192 (after: 207). No step change.

### The metric name changed

6.6 swaps the AWS-SDK S3 client for the thanos objstore client. `loki_s3_request_duration_seconds_count` (the series in the baseline) is gone; its replacements are:

```
loki_objstore_bucket_operations_total
loki_objstore_bucket_operation_failures_total
```

so the "after" row above comes from those (ruling P25; the plan's metric name no longer exists). This matters beyond dashboards: that client is the change that fixes LOG-9632, so zero failures on it over the soak is the actual evidence for the fix. Any alert or panel built on the old `loki_s3_*` name goes silent rather than red.

Query check (17:11Z): this cluster has no console Logs view (that comes from the Cluster Observability Operator's
`logging` UIPlugin, which is not installed), so the check went through Grafana's `Loki (infrastructure)` datasource.
The "error/warn/fatal lines per namespace" panel has data for the whole hour, with no gap across either approval
(loki-operator 15:52Z, cluster-logging 16:14Z), and the recent-lines panel shows current entries. Queries work end to
end through the 6.6 gateway and queriers. Two short error-rate bumps (about 16:20–16:27Z and 16:50–16:57Z) get a
namespace breakdown in the soak check.

The 24 h soak runs from the cluster-logging approval at 16:14:35Z; its checks are due from 2026-10-21 16:15Z.

## 2026-10-20 — CI disk: freeing runner space

The upstream `cluster-logging-deploy.yaml` runs on `ubuntu-latest`, which has about 14 GB free. The in-cluster build's disk figures put the peak at 37.0 GB, by step: +3.1 GB for init, +29.5 GB for `build_containers`, +3.4 GB for bundles. It would not fit as it stands.

Options were another measuring run or freeing disk in the workflow. The operator chose to free disk in the workflow.

Change (fork branch `cluster-logging-6.6`, commit 1466fa3): an opt-in boolean input `free_disk_space` on the shared `operator-deploy.yaml`, default false, so no other operator's workflow changes; only `cluster-logging-deploy.yaml` passes true. When true, a step runs `df -h /`, removes `/usr/share/dotnet`, `/usr/local/lib/android`, `/opt/ghc`, `/usr/local/.ghcup` and `/opt/hostedtoolcache/CodeQL`, prunes docker images, and runs `df -h /` again, so the log shows before and after.

The amount freed is unmeasured until the first real CI run; that run's two `df` lines are the check.

## 2026-10-20 — pipeline PRs filed

The operator asked for the PRs while the soak runs, so they went up before it ended; the main PR says a 24 h soak is running and that its results will follow as a comment.

| PR | base | head |
|---|---|---|
| [#35](https://github.com/okd-project/okd-operator-pipeline/pull/35) | `main` | `sudoom:cluster-logging-6.6` (1466fa3) |
| [#36](https://github.com/okd-project/okd-operator-pipeline/pull/36) | `release-4.22` | `sudoom:cluster-logging-6.6-4.22` (15ba530) |
| [#37](https://github.com/okd-project/okd-operator-pipeline/pull/37) | `release-4.21` | `sudoom:cluster-logging-6.6-4.21` (e7222e4) |
| [#38](https://github.com/okd-project/okd-operator-pipeline/pull/38) | `release-4.20` | `sudoom:cluster-logging-6.6-4.20` (50b2959) |

All four are drafts. `gh pr view` reads `mergeable=MERGEABLE` on each, and every fork branch was 0 commits behind its base at filing (`gh api repos/okd-project/okd-operator-pipeline/compare/<base>...sudoom:<branch>`). Titles follow the repo's `[<operator>] Update to <version>` convention; the backports add ` (release-4.2x)`, as the merged `[nmstate] Update submodules to release-4.21` does. There is no PR template.

Every PR body carries `Addresses okd-project/okderators-catalog-index#44 and okd-project/okderators-catalog-index#48`. Both issues live in the catalog repo, not the pipeline repo: the pipeline repo has no logging issue at all (`gh issue list --state all`, titles matching logging/loki/vector). "Addresses", not "Closes", because neither issue is fixed until the catalog PRs land.

Facts corrected while reviewing the drafts, before filing:

- LOG-9632 and 6.6: the reason 6.6 does not have the S3 bug is that its LokiStack config uses the `thanos-io/objstore` backend instead of the AWS SDK S3 client (Red Hat LOG-7392, fixVersion 6.6.0). The bug is fixed in 6.5.3 by a backport of the same change; Red Hat did not take grafana/loki PR #22003.
- Toolchain: the diff moves `ubi9/go-toolset` from 1.25 to 1.26 in every Go Containerfile, not only Loki's. It contains no Rust version change.
- The weekly `operator-updates.yaml` bot: `gh run list --workflow operator-updates.yaml --limit 100` returns 33 runs since 2026-03-09, none successful (latest 2026-10-19).
- The backports build nothing on merge. `release-4.22`'s `cluster-logging-deploy.yaml` triggers on pushes to `main` only; `release-4.21` and `release-4.20` have no such workflow. The images for every catalog come from the `main` build, and the backports keep each release branch's `cluster-logging/` tree at the version its catalog will list.

## 2026-10-21 — 24 h soak results

The soak window is 2026-10-20T16:14:35Z (cluster-logging 6.6 approved) to 2026-10-21T16:14:35Z. Every Prometheus number below is an instant query at the fixed `time=2026-10-21T16:15:00Z` with `[24h]` ranges, so it can be rerun and give the same figure. Read path: the break-glass kubeconfig for Prometheus and Alertmanager only, the readonly kubeconfig for everything else, no exec into any Loki pod.

```
KUBECONFIG=$HOME/.kube/config-breakglass oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=<urlencoded>&time=2026-10-21T16:15:00Z'
```

### Verdict

| check | result | number |
|---|---|---|
| object-store operations succeed | PASS | 0 failures in 24 h on every operation (below) |
| chunks flushed > 0 | PASS | 8505 in 24 h (ingester-0 4257, ingester-1 4247) |
| no `up == 0` in `openshift-logging` / `openshift-operators-redhat` | PASS | 20 up across 10 jobs, `== 0` returns nothing |
| PDBs and ingester replicas vs baseline | PASS, as expected | all six `maxUnavailable: 1`, allowed 1; ingester STS 2/2 |
| no new firing alerts | PASS, with two short transients | no new alert still firing; two that fired and cleared, neither logging (below) |
| restarts of logging pods | PASS | current restartCount 0 on all 18 pods |
| rest of the cluster unaffected | PASS | nodes, CVO, COs, 49 apps, CSVs, CNPG, Ceph as before |
| LokiStack condition | known Warning | `Ready=True`, `Warning=True` `InsufficientIngesterReplicas` |

No FAIL: the PRs stand as filed, and these results go to okd-project/okd-operator-pipeline#35 as a comment.

### Object store (the LOG-9632 evidence)

```
sum by (operation) (increase(loki_objstore_bucket_operations_total{namespace="openshift-logging"}[24h]))
sum by (operation) (increase(loki_objstore_bucket_operation_failures_total{namespace="openshift-logging"}[24h]))
```

| operation | count in 24 h | failures |
|---|---|---|
| upload | 8820 | 0 |
| delete | 5923 | 0 |
| get | 660 | 0 |
| iter | 395 | 0 |
| attributes / exists / get_range | 0 | 0 |

Against the 6.5 baseline taken before the upgrade (1 h windows) the rates are flat: 8820 uploads per 24 h is 367 per hour (baseline 384 `S3.PutObject` per hour), and 8505 chunks per 24 h is 354 per hour (baseline 373). Time since the last successful upload, from `loki_objstore_bucket_last_successful_upload_time`, at 16:15:00Z: ingester-1 99.7 s, ingester-0 110.4 s (the other components never upload and report epoch 0, which I ignore). The distributor was taking 126 lines/s at 16:15Z.

### Targets, PDBs, restarts

`count by (job) (up{namespace=~"openshift-logging|openshift-operators-redhat"} == 0)` returns an empty result; `== 1` gives the same 20 targets over the same 10 jobs as the baseline, so 6.6's metrics authentication holds over the day. PDBs after 24 h: `distributor`, `gateway`, `index-gateway`, `ingester`, `querier`, `query-frontend`, each `maxUnavailable: 1`, `disruptionsAllowed: 1`. The baseline ingester PDB was `minAvailable: 1`, forced by the override CronJob retired the same day; the new shape is the operator's own. `logging-loki-ingester` is 2/2.

Restarts: `sum by (pod) (increase(kube_pod_container_status_restarts_total{namespace=~"openshift-logging|openshift-operators-redhat"}[24h])) > 0` is empty, and the current `restartCount` is 0 on every pod: `cluster-logging-operator`, 3 collector pods `instance-*`, 2 gateway (both containers), 2 distributor, 2 querier, 2 query-frontend, 2 index-gateway, 2 ingester, the compactor, and `loki-operator-controller-manager`. The collector DaemonSet is 3/3 ready and updated.

The ~3.6 restarts seen earlier in a 23 h query are from the retired `loki-pdb-override-29875205-*` CronJob pod (removed in `9c4de03`). The three last pods of that job, `29875195`, `29875200` and `29875205`, started at 15:55, 16:00 and 16:05Z on 10-20 and each reached restartCount 5 (`max_over_time(...{pod=~"loki-pdb.*"}[24h])` evaluated at 10-20T17:00Z). All of that is before the 16:14:35Z approval, so at the fixed time those series are outside the 24 h window and the query reads 0.

### Alerts

Alertmanager `localhost:9093/api/v2/alerts?active=true`, 9 firing, all on the pre-existing list and all started 10-16: `CephHealthWarning`, `CephMonDiskspaceLow`, `InsightsRecommendationActive`, `KubeCPUOvercommit`, `PodDisruptionBudgetAtLimit` (immich, media), `TargetDown` (nmstate), `UpdateAvailable`, `Watchdog`. Nothing new is firing.

`count by (alertname,namespace) (max_over_time(ALERTS{alertstate="firing"}[24h]))` shows two alerts, besides the known list, that were firing at some point in the 24 h lookback and are gone:

| alert | seen in the 24 h lookback | cause |
|---|---|---|
| `UserNamespaceJobFailed` (`okd-build`, job `build-full-2026-10-20-134619`) | 10-20 15:20Z to 16:34Z | the in-cluster build Job, not logging; it began at 15:20Z, before the window opened |
| `CephNodeNetworkPacketDrops` (pod `node-exporter-4l2ks`, which runs on node6.okd.sudops.pl) | 10-21 11:06:14Z to 11:06:44Z | about 30 s, cleared on its own; I did not investigate the cause, and nothing in the logging checks points at it |

### The two error-rate bumps (16:20–16:27Z, 16:50–16:57Z on 10-20)

A per-namespace error breakdown is not available from any sanctioned read path, so I do not have one. What I checked:

- `log_logged_bytes_total` (log-file-metric-exporter) does not exist in this Prometheus: `count(log_logged_bytes_total)` is empty and the metric is not among the series under `namespace="openshift-logging"` matching `log_.*`.
- Vector's own error counters are zero over 24 h: `vector_component_errors_total` and `vector_component_discarded_events_total` return nothing above 0. I did not find a per-namespace error series among them.
- The distributor exposes `tenant` but not namespace. Lines received per second, `rate(loki_distributor_lines_received_total[7m])` ending at the window versus `[30m]` ending at the window's start:

| tenant | window 1 (16:27Z) | 30 min before | window 2 (16:57Z) | 30 min before |
|---|---|---|---|---|
| infrastructure | 159.8/s | 98.9/s | 261.9/s | 87.6/s |
| audit | 77.5/s | 97.3/s | 75.3/s | 69.5/s |
| application | 15.2/s | 18.4/s | 15.6/s | 15.3/s |

  Infrastructure is the only tenant that rises: +62 % in window 1 and about 3x in window 2. The window-1 baseline (the 30 min ending 16:20Z) straddles the collector restart at 16:14:44Z, so it is not a clean pre-restart figure. That fits a Grafana panel that counts error lines in `openshift-*` namespaces and node logs, but it does not say which namespace.
- Rollout alignment (from `kube_pod_start_time`): loki-operator 15:52:18Z, LokiStack pods 15:54:41Z to 15:57:06Z, `cluster-logging-operator` 16:14:34Z, collector pods 16:14:44Z to 16:14:46Z. Bump 1 starts 5.5 min after the collector restart and bump 2 about 36 min after it, so neither coincides with a pod start; I cannot say whether the new collector replaying files after its restart contributed.
- Push 429s do follow the bumps. `sum by (status_code) (increase(loki_request_duration_seconds_count{namespace="openshift-logging",status_code=~"429|5.."}[7m]))`, each evaluated at the window's end (16:27Z, 16:57Z) and at its start (16:20Z, 16:50Z):

| window | HTTP 429 in the 7 min | HTTP 500 | the 7 min before the window |
|---|---|---|---|
| 1 (16:20-16:27Z) | 24.8 | 0 | 0 (36.3 in the 30 min before, which also holds the collector restart) |
| 2 (16:50-16:57Z) | 65.7 | 0 | 15.1 (43.7 in the 30 min before) |

  So the distributor was rate-limiting pushes (all on `loki_api_v1_push`) while the infrastructure ingest rose, which fits the line-rate table above and suggests the bumps are a backlog or burst in infrastructure logs hitting the per-tenant limit; I did not check the limit value. The 30 min before window 1 also holds 258 HTTP 500s; that range covers the LokiStack pod restarts (15:54-15:57Z) and the collector restart, and I did not split the 500s by time. Over 24 h the distributor answered 2285 x 429 and 25 x 500 out of about 2.1 M requests, and vector reports 1902 of the 429s on the infrastructure output. The 24 h ending 15:30Z on 10-20 (6.5) had 1821 x 429 and 188 x 500, so 429s are 25 % higher over the soak day and 500s are lower (25 vs 188). A first attempt at these four windows used the wrong evaluation time and is not reported; the numbers above are rerun at the window times.

The stream label that the existing dashboard uses, and that Grafana returned data for on 10-20, is `kubernetes_namespace_name` (`components/cluster-config/grafana-config/files/app-errors-by-namespace.json`). The ClusterLogForwarder sets no `dataModel`, so the default Viaq labels apply. I did not read the vector config (it is in a Secret), so `level` and `log_type` as stream labels are unverified and the queries below use only `kubernetes_namespace_name`. Paste into Grafana Explore, datasource `Loki (infrastructure)`, query type `Instant`, with the evaluation time set to the window's end (UTC) and the range matching the window length:

```
# window 1: evaluate at 2026-10-20 16:27:00Z
topk(10, sum by (kubernetes_namespace_name) (count_over_time({kubernetes_namespace_name=~".+"} |~ "(?i)(error|warn|fail|fatal|panic)" [7m])))
# window 2: evaluate at 2026-10-20 16:57:00Z, same query
```

For the baselines, evaluate the same instant query at 16:20:00Z and 16:50:00Z (the preceding 7 min). Lines of the node journal carry no namespace label and are excluded by `=~".+"`.

### Rest of the sweep (readonly)

| | result |
|---|---|
| nodes | node4, node5, node6 `Ready`, v1.34.6 |
| ClusterVersion | 4.21.0-okd-scos.11, Available=True, Progressing=False, Failing=False |
| ClusterOperators | 34, none unavailable, progressing or degraded |
| ArgoCD applications | 49 Synced Healthy |
| CSVs | none outside `Succeeded`; `cluster-logging` and `loki-operator` `v6.6.0-2026-10-20-134619` |
| Subscriptions | both `okd-test-logging`, `Manual`, `AtLatestKnown` |
| CNPG | `media-postgres` 2/2 and `immich-postgres` 2/2, `ContinuousArchiving=True`, both "Cluster in healthy state" |
| Ceph | `HEALTH_WARN`: "2 OSD(s) experiencing slow operations in BlueStore" and "mon c is low on available space", both the known benign pair |
| zot PVC `data-zot-0` | 48.91 GiB capacity, 31.77 GiB used, 17.13 GiB available (kubelet stats summary on node4); 16.6 GiB free on 10-20 17:20Z, so +0.5 GiB free, nothing was added |

LokiStack right now: `Ready=True` (`ReadyComponents`), `Pending=False`, `Failed=False`, and `Warning=True` `InsufficientIngesterReplicas` ("The ingester replicas (2) are less than or equal to the replication factor (2)..."). It was kept on purpose through the soak; the choice afterwards is the operator's: keep it, replication factor 1, or 3 ingesters. Both ingesters kept restartCount 0 over the 24 h, so no restart-driven ingestion stop happened; I did not chart per-minute ingestion.

Raw query outputs are saved locally, one JSON per query (plus `cluster-sweep.txt`, `alerts.json`, `zot-summary.json`, `lokistack-cond.txt`).
