# okderators Logging 6.6: in-cluster build Job

A one-off Job that runs okd-operator-pipeline's own `cluster-logging/build.sh` on this
cluster and pushes the images and bundles to zot under `okd-test/`. Container builds do not
run on the Mac: it is arm64, and these images have to install on the amd64 nodes (CLAUDE.md,
"Container image builds run on the cluster"). This cluster's logging will run the images built
here until upstream CI publishes its own.

Not ArgoCD-managed. The operator applies, runs and deletes everything in this directory.
Chronology and results: `blog/blog-okderators-logging-6.6-draft.md`.

**Status 2026-10-20:** written and validated offline (`bash -n`, `kubeconform`); not run yet.

## Files

| file | what |
|---|---|
| `manifests.yaml` | Namespace `okd-build` (PSA `privileged`, SCC label sync off), ServiceAccount `builder` (no token), RoleBinding to ClusterRole `system:openshift:scc:privileged`, PVC `build-storage` 100Gi `ceph-nvme-block` RWO |
| `kustomization.yaml` | `manifests.yaml` plus ConfigMap `build-scripts`, generated from `build.sh` (no hash suffix), so the script exists once |
| `build.sh` | the Job's entry point, mounted at `/scripts/build.sh` |
| `job-template.yaml` | OpenShift Template for one run: Job `build-<MODE>-<DATE>` |
| `log-reader.yaml` | read-only pod for the log files on the PVC once a build pod is gone |

## Before each run (operator)

- **zot has at least 5 GiB free.** The pod has no API rights, so this check stays outside the
  Job. In the console (Observe → Metrics):
  `kubelet_volume_stats_available_bytes{namespace="zot",persistentvolumeclaim="data-zot-0"}`.
  A full zot breaks image pulls for the whole cluster.
- **Before the first apply: `nvme-replicated` has room for the PVC** (per-pool `MAX AVAIL` from
  `ceph df`, not the cluster-level figure). The RBD image is thin; the `DISK` lines show what a
  build really writes.

## Apply, run, read, delete

```bash
# static part: namespace, SA, RBAC, PVC, ConfigMap (re-run after editing build.sh)
oc apply -k tests/okderators-logging-build/

# one run
DATE=$(date -u +%Y-%m-%d-%H%M%S)
oc process --local -f tests/okderators-logging-build/job-template.yaml \
  -p MODE=full -p DATE=$DATE | oc -n okd-build create -f -

# watch, then pull out the contract lines
oc -n okd-build logs -f job/build-full-$DATE
oc -n okd-build logs job/build-full-$DATE | grep -E '^(STEP|DISK|PUSHED|CHECK|RESULT) '

# step durations (STEP times are epoch seconds)
oc -n okd-build logs job/build-full-$DATE | awk '$1=="STEP" && $3=="START" {s[$2]=$4} $1=="STEP" && $3=="END" {print $2, $4-s[$2] "s"}'
```

`check` reuses the `DATE` of a full run: `-p MODE=check -p DATE=<that DATE> -p PIPELINE_BRANCH=<branch>`.

Cleanup:

```bash
# a finished run (its contract and full log stay on the PVC, see below)
oc -n okd-build delete job build-full-$DATE

# all build work done: namespace, PVC (reclaimPolicy Delete removes the RBD image), Jobs
oc delete -k tests/okderators-logging-build/
```

Test images in zot are deleted by digest once nothing runs on them; the `PUSHED` lines carry
the digests. zot's GC (`gcDelay` 1h, `gcInterval` 24h) then frees the blobs; measure zot again.

```bash
# contract file saved with the log-reader commands below
awk '$1=="PUSHED" {print $2}' build-full-$DATE.contract | sed 's/:[^:@/]*@/@/' \
  | while read -r ref; do skopeo delete "docker://$ref"; done   # wherever skopeo runs
```

## Reading the logs later

The pod log is not enough on its own. At `activeDeadlineSeconds` the Job controller deletes
the pod, and with it the log; the kubelet rotates container logs at 50Mi and `oc logs` returns
only the current file, while the pipeline's `set -x` traces the whole release-info JSON on every
`./build.sh` call. So `build.sh` also writes, on the PVC:

- `/work/logs/build-<MODE>-<DATE>.contract`: every contract line, appended synchronously before it
  is printed, including the final `RESULT` (also the `RESULT FAIL <step> (terminated)` of a
  deadline kill);
- `/work/logs/build-<MODE>-<DATE>.log`: everything the run printed, copied by `tee`.

Read them with the read-only `log-reader` pod (PVC attached and mounted read-only; it only
sleeps, and ends by itself after an hour). It is RWO storage: while a build pod runs, the reader
has to land on that pod's node, which its pod affinity prefers.

```bash
oc -n okd-build create -f tests/okderators-logging-build/log-reader.yaml
oc -n okd-build wait --for=condition=Ready pod/log-reader --timeout=5m
oc -n okd-build exec log-reader -- ls -l /work/logs
oc -n okd-build exec log-reader -- cat /work/logs/build-full-$DATE.contract > build-full-$DATE.contract
oc -n okd-build exec log-reader -- cat /work/logs/build-full-$DATE.log > build-full-$DATE.log
oc -n okd-build delete pod log-reader
```

The files are deleted with the PVC (`oc delete -k`), so copy what the blog draft needs first.
A validation failure (bad `MODE`, `DATE` or `BASE_REGISTRY`) happens before the files are opened
and is in the pod log only.

## Modes

| `MODE` | does |
|---|---|
| `full` | tools → podman setup → clone `PIPELINE_BRANCH` → tag check → `init` → `build_containers` → `push_containers` → `build_bundle` → `deinit` → verify. Each pipeline step is a separate `./build.sh <step>` run, the same functions `main` runs when given no arguments, so each is timed. |
| `check` | no image build. `skopeo copy --all` of every `IMG_*` image of `DATE` from `${BASE_REGISTRY}/cluster-logging/` to `${BASE_REGISTRY}/check-<branch>/cluster-logging/` (zot dedupes the blobs), then `init` → `build_bundle` → `deinit` against that registry, then verify. For the other pipeline branches, and to redo bundles and verify after a fix without rebuilding images. |
| `catalog` | runs `/scripts/catalog-edit.sh`, which the catalog step of this work adds to this directory and to the `configMapGenerator`. Until then the run ends `RESULT FAIL catalog-edit.sh not present`. It gets `CATALOG_BRANCHES`, `BUNDLES`, `BASE_REGISTRY`, `DATE` and `RUN_DIR` (an empty working directory); a `CHECK … FAIL` line from it fails the run. |

`./build.sh update` never runs (it moves the gitlinks to branch tips).

## Parameters

| parameter | default | meaning |
|---|---|---|
| `MODE` | required | `full`, `check` or `catalog` |
| `DATE` | required | `YYYY-MM-DD-HHMMSS`; the image tags end in `<MAJOR>.<MINOR>.0-<DATE>`. New for every full run. |
| `PIPELINE_REPO` | `https://github.com/sudoom/okd-operator-pipeline.git` | |
| `PIPELINE_BRANCH` | `cluster-logging-6.6` | |
| `BASE_REGISTRY` | `zot.apps.okd.sudops.pl/okd-test` | anything outside `zot.apps.okd.sudops.pl/okd-test` is refused |
| `CATALOG_BRANCHES` | empty | `catalog` only |
| `BUNDLES` | empty | `catalog` only |

## Output contract

Free-form output (the pipeline's own `set -x` trace, `INFO`, `ERROR`) is interleaved with
these lines in the pod log and the `.log` file; the `.contract` file holds only these lines:

| line | meaning |
|---|---|
| `STEP <name> START\|END <seconds>` | epoch seconds; the duration is END − START |
| `DISK <bytes>` | `du -sx` of `/var/lib/containers` + `/work`, after every step |
| `PUSHED <ref>@<digest> <bytes>` | after `push_containers` / the `check` copy and after `build_bundle`. Digest = sha256 of the manifest bytes zot serves; bytes = config + layer sizes in that manifest (compressed, as stored), summed over the children of an index |
| `CHECK <name> PASS\|FAIL <detail>` | verify, below |
| `RESULT PASS\|FAIL <reason>` | the last line. On an error, or on SIGTERM (deadline, deleted Job), the reason is the step that was running. A SIGTERM is handled while a pipeline step, a skopeo copy or the catalog script runs; during a shorter command it waits for that command, and the kubelet's SIGKILL 30 s after SIGTERM leaves no `RESULT` line at all. |

## Verify

After the bundles are pushed, `opm render <bundle repo>@<digest>` for every `IMG_BUNDLE*`
image, and per package:

| check | passes when |
|---|---|
| `max-openshift-version/<pkg>` | `olm.maxOpenShiftVersion` is `4.23` |
| `images/<pkg>` | every `relatedImages[].image` and every `RELATED_IMAGE_*` / `*_IMAGE` env value in the CSV is `${BASE_REGISTRY}/…@sha256:…` (no `quay.io/openshift-logging`, no `registry.redhat.io`, no tags). One exception: the kube-rbac-proxy image `build.sh` resolves from the OKD release payload (`quay.io/okd/scos-content@sha256:…`), accepted only if it is exactly that value and by digest |
| `images-built/<pkg>` | each of those `${BASE_REGISTRY}` references is a digest this run pushed or copied |
| `kube-rbac-proxy-from-payload/<pkg>` | printed (always PASS) when the bundle carries the payload kube-rbac-proxy, with the exact reference, so the log records which OKD release it came from |
| `branding/<pkg>` | `grep -ciE 'valid-subscription\|Red Hat'` on the CSV is 0 |
| `provider/<pkg>` | `spec.provider.name` is `OKD Community` |
| `passthrough-gateway/loki-operator` | only if the cloned `build.sh` defines `IMG_PASSTHROUGH_GATEWAY`: the loki-operator CSV carries `RELATED_IMAGE_PASSTHROUGH_GATEWAY` pointing at that image |

The image list is never written down here: `build.sh` sources the cloned
`cluster-logging/build.sh` and reads its `IMG_*` variables. Any `FAIL` ends the run
`RESULT FAIL`.

## How it runs, and why

- **Privileged podman in a pod.** `quay.io/podman/stable` is built for nested use: its
  `containers.conf` runs containers in the host namespaces with `cgroups="disabled"` and
  cgroupfs, and the image sets `BUILDAH_ISOLATION=chroot`, so `RUN` steps need no OCI runtime,
  cgroup or network namespace. Privileged is for the overlay mounts. The namespace is PSA
  `privileged` with the SCC label syncer off, the RoleBinding grants the `privileged` SCC, and
  the pod asks for it with `openshift.io/required-scc`.
- **One PVC, two mounts.** `build-storage` is mounted by `subPath` at `/var/lib/containers`
  (podman's graph root) and `/work` (clones, tools, Go caches, `TMPDIR`), so nothing large lands
  on a node's root disk (node5's carries a mon and sits at the `MON_DISK_LOW` line). `build.sh`
  swaps the image's fuse-overlayfs for the kernel overlay driver: the graph root is ext4 on RBD,
  not the container's own overlay, so native overlay works and is faster. If `podman-setup`
  fails on the overlay mount, put `mount_program = "/usr/bin/fuse-overlayfs"` back in the
  generated `storage.conf`. Only the dnf packages land in the container's own layer.
- **Pushes go to zot `okd-test/` only.** There are no registry credentials in the pod, and
  `build.sh` refuses a `BASE_REGISTRY` outside `zot.apps.okd.sudops.pl/okd-test` and any `IMG_*`
  the cloned `build.sh` would push elsewhere. zot mirrors quay.io, docker.io, ghcr.io and
  registry.k8s.io for the whole cluster in one namespace, so a push to a real upstream path
  would shadow that image cluster-wide.
- **One run at a time.** Two runs would wipe each other's `/work/run` and share one podman graph
  root, which containers/storage does not support; RWO only keeps pods on other nodes away. So
  `build.sh` takes `flock -n` on `/work/.lock` before it touches `/work/run`, the caches or the
  graph root, and a second run ends `RESULT FAIL another run holds /work/.lock`. The kernel
  drops the lock when the pod dies; the log reader takes no lock.
- **No tag is pushed twice.** `full` stops with `RESULT FAIL tag exists` when
  `${BASE_REGISTRY}/cluster-logging/operator:<MAJOR>.<MINOR>.0-<DATE>` already exists.
- **Job shape.** `backoffLimit: 0` (a failed build is read, not retried), 12 h
  `activeDeadlineSeconds`, no `ttlSecondsAfterFinished` (the log stays until read), requests
  2 CPU / 8 Gi, limits 14 CPU / 48 Gi, no node pinning. The image is
  `quay.io/podman/stable:v5.8.9@sha256:dc02649067d5…` (the manifest list the tag pointed at on
  2026-10-20): quay re-pushes version tags, so the digest pins it. Expect about 3× longer builds while the
  `powersave-experimental` Tuned profile pins cores at their minimum frequency.

Tools, all pinned and checked against the sha256 their project publishes:

| tool | version | checksum source |
|---|---|---|
| Go | 1.26.10 | `https://go.dev/dl/?mode=json` |
| operator-sdk | v1.36.1 (what the pipeline's CI installs) | release `checksums.txt` |
| opm | v1.74.0 | release `checksums.txt` |
| yq | v4.54.1 | release `checksums` (SHA-256 column) |
| kustomize | v5.8.1 (loki's own bingo pin) | release `checksums.txt` |
| oc | 4.21.36 (`stable-4.21` on 2026-10-20) | `mirror.openshift.com/…/4.21.36/sha256sum.txt` |
| git, make, jq, skopeo | Fedora packages of the podman image | dnf |
