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
          # cluster -- it is the OSD image, already cached on every node.
          # registry.access.redhat.com/rhel9/support-tools does NOT pull here
          # (ImagePullBackOff on node4, 2026-06-10). Do not "simplify" this to
          # a smaller generic image without confirming it pulls on all 3 nodes.
          image: __IMAGE__
          env:
            - name: BENCH_DIR
              value: /data/__RUN_ID__
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
              CLIENT="${HOSTNAME}"
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

              # envsubst the job file so one ConfigMap serves every backend and
              # size -- the WORKLOAD SHAPE stays pinned, only the scale varies.
              envsubst < "/fio-jobs/${WORKLOAD}.fio" > /tmp/job.fio
              echo "### effective fio job"
              cat /tmp/job.fio

              # --output-format=json is the whole point: the parser reads this,
              # not the human table, so a result can never be transcribed wrong.
              fio /tmp/job.fio --output-format=json --output=/tmp/out.json
              echo "### FIO_JSON_BEGIN"
              cat /tmp/out.json
              echo "### FIO_JSON_END"

              # Leave nothing behind: the next run must not read a warm file
              # written by this one, and the PVC must not silently fill up.
              rm -rf "${BENCH_DIR}"
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
