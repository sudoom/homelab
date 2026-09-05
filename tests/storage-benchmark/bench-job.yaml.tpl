# ---------------------------------------------------------------------------
# Template. run.sh substitutes the __TOKENS__ and applies the result.
# Do not `oc apply` this file directly -- it is not valid YAML until rendered.
# ---------------------------------------------------------------------------
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: __PVC_NAME__
  namespace: __NAMESPACE__
  labels:
    app.kubernetes.io/name: storage-benchmark
    storage-benchmark/backend: __BACKEND__
spec:
  accessModes:
    - __ACCESS_MODE__
  storageClassName: __STORAGE_CLASS__
  resources:
    requests:
      storage: __PVC_SIZE__
---
apiVersion: batch/v1
kind: Job
metadata:
  name: __JOB_NAME__
  namespace: __NAMESPACE__
  labels:
    app.kubernetes.io/name: storage-benchmark
    storage-benchmark/backend: __BACKEND__
    storage-benchmark/workload: __WORKLOAD__
    storage-benchmark/clients: "__CLIENTS__"
spec:
  # completions == parallelism: every client runs concurrently and the Job is
  # done when all have finished. This IS the multi-client dimension -- N pods
  # hitting the same RWX volume at once, which is what the real workload looks
  # like (6 media pods across 3 nodes) and what a single-client number cannot
  # tell you. The 1->2 reader jump on TrueNAS was 246 -> 431 MB/s, so this
  # dimension is worth more than another decimal place on a single client.
  completions: __CLIENTS__
  parallelism: __CLIENTS__
  # Indexed gives each pod a stable JOB_COMPLETION_INDEX, which is what makes
  # the laid-out data files REUSABLE ACROSS RUNS. Without it the per-client
  # directory has to be keyed on the pod name, which changes every run, so every
  # run re-lays out its files. At 64G on a 1G-attached Synology that is ~22
  # MINUTES PER CLIENT of pure setup before a single measured byte -- which
  # would make the whole harness impractical at the file sizes needed to defeat
  # a 31 GiB ARC.
  completionMode: Indexed
  # A benchmark that hangs must not hold a PVC forever. Sized to comfortably
  # exceed runtime x workloads with setup slack.
  activeDeadlineSeconds: __DEADLINE__
  backoffLimit: 0          # a failed benchmark is a result, not something to retry
  template:
    metadata:
      labels:
        app.kubernetes.io/name: storage-benchmark
        storage-benchmark/backend: __BACKEND__
    spec:
      restartPolicy: Never
      # Spread clients across nodes. `preferred` not `required`: with clients=3
      # on a 3-node cluster required would work, but clients>3 would leave pods
      # Pending forever and look like a hung benchmark rather than a scheduling
      # choice. Preferred still spreads 1-3 across distinct nodes in practice.
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                topologyKey: kubernetes.io/hostname
                labelSelector:
                  matchLabels:
                    app.kubernetes.io/name: storage-benchmark
      volumes:
        - name: data
          persistentVolumeClaim:
            claimName: __PVC_NAME__
        - name: fio-jobs
          configMap:
            name: storage-bench-fio-jobs
      containers:
        - name: fio
          # quay.io/ceph/ceph is used because it is PROVEN to pull on this
          # cluster. registry.access.redhat.com/rhel9/support-tools does NOT
          # (ImagePullBackOff on node4, 2026-06-10). Do not "simplify" this to a
          # smaller generic image without confirming it pulls on all 3 nodes.
          #
          # NOT already cached, despite being the OSD image family: measured
          # 2026-09-05, node6 pulled it in 67s (1.49 GB). Budget that per node on
          # first use -- it is why the Job deadline has generous setup slack.
          image: __IMAGE__
          env:
            # Keyed on BACKEND, not run id: the expensive laid-out files must
            # survive from one run to the next so layout is paid once.
            - name: BENCH_DIR
              value: /data/__BACKEND__
            - name: BENCH_FILESIZE
              value: "__FILESIZE__"
            - name: BENCH_RUNTIME
              value: "__RUNTIME__"
            - name: BENCH_NRFILES
              value: "__NRFILES__"
            - name: BENCH_IOENGINE
              value: "__IOENGINE__"
            - name: WORKLOAD
              value: __WORKLOAD__
            - name: RUN_ID
              value: __RUN_ID__
            # Which node this client landed on is part of the RESULT, not
            # trivia: a multi-client number means something different if two
            # clients shared a node than if they were spread across three.
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          command: ["/bin/bash", "-c"]
          args:
            - |
              set -euo pipefail

              # Each client gets its OWN subdirectory. Without this, N clients
              # would collide on the same filenames and the run would measure
              # lock contention rather than the storage.
              #
              # Keyed on JOB_COMPLETION_INDEX (stable) rather than $HOSTNAME
              # (changes every run), so client 0's 64 GiB file is still there
              # next time and fio skips the layout phase entirely.
              CLIENT="c${JOB_COMPLETION_INDEX:-0}"
              export BENCH_DIR="${BENCH_DIR}/${CLIENT}"
              mkdir -p "${BENCH_DIR}"

              # fio is not in the ceph image. `dnf install` needs pod egress,
              # which on this cluster breaks whenever a host address changes
              # (the br-ex.forwarding bug -- see CLAUDE.md network pre-flight).
              # Say so explicitly rather than failing with a bare dnf error,
              # because "benchmark won't start" and "cluster egress is down"
              # look identical otherwise.
              if ! command -v fio >/dev/null 2>&1; then
                echo "### installing fio"
                if ! dnf install -y fio >/tmp/dnf.log 2>&1; then
                  echo "FATAL: could not install fio." >&2
                  echo "  If this is a network timeout, check pod egress first:" >&2
                  echo "  net.ipv4.conf.br-ex.forwarding must be 1 on every node" >&2
                  echo "  (see CLAUDE.md -> Pre-flight for any network-stack change)." >&2
                  tail -20 /tmp/dnf.log >&2
                  exit 1
                fi
              fi

              echo "### benchmark run"
              echo "  run_id     ${RUN_ID:-__RUN_ID__}"
              echo "  backend    __BACKEND__"
              echo "  workload   ${WORKLOAD}"
              echo "  clients    __CLIENTS__"
              echo "  client     ${CLIENT}"
              echo "  node       ${NODE_NAME:-unknown}"
              echo "  dir        ${BENCH_DIR}"
              echo "  filesize   ${BENCH_FILESIZE}   runtime ${BENCH_RUNTIME}s   nrfiles ${BENCH_NRFILES}"
              echo "  ioengine   ${BENCH_IOENGINE}"

              # Substitute with sed, NOT envsubst: envsubst ships in gettext and is
              # NOT present in the ceph image (found by running it -- the first
              # attempt died with `envsubst: command not found` after a 67s image
              # pull and a dnf install). sed is always there.
              #
              # fio can also expand ${VAR} natively, but doing it here means the
              # job file we PRINT below is byte-identical to the one fio runs --
              # so the recorded parameters can never disagree with the executed
              # ones. That is the same principle as parsing fio's JSON instead of
              # transcribing its table.
              sed -e "s|\${BENCH_DIR}|${BENCH_DIR}|g" \
                  -e "s|\${BENCH_IOENGINE}|${BENCH_IOENGINE}|g" \
                  -e "s|\${BENCH_RUNTIME}|${BENCH_RUNTIME}|g" \
                  -e "s|\${BENCH_FILESIZE}|${BENCH_FILESIZE}|g" \
                  -e "s|\${BENCH_NRFILES}|${BENCH_NRFILES}|g" \
                  "/fio-jobs/${WORKLOAD}.fio" > /tmp/job.fio
              echo "### effective fio job"
              cat /tmp/job.fio

              # --output-format=json is the whole point: the parser reads this,
              # not the human table, so a result can never be transcribed wrong.
              fio /tmp/job.fio --output-format=json --output=/tmp/out.json
              echo "### FIO_JSON_BEGIN"
              cat /tmp/out.json
              echo "### FIO_JSON_END"

              # DELIBERATELY NOT deleting the data files. They are the expensive
              # part (64 GiB per client) and reusing them is the difference
              # between a 2-minute run and a 25-minute one. They are also read
              # with direct=1 and are far larger than any server's RAM, so a
              # warm file is not a stale-cache hazard here.
              #
              # Clean up explicitly when finished:  ./run.sh --backend X --clean
              echo "### layout retained at ${BENCH_DIR} for reuse"
              du -sh "${BENCH_DIR}" 2>/dev/null || true
          volumeMounts:
            - name: data
              mountPath: /data
            - name: fio-jobs
              mountPath: /fio-jobs
              readOnly: true
          resources:
            requests:
              cpu: "500m"
              memory: "1Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
