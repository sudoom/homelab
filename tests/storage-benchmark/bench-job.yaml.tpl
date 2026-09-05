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

              # LAY OUT FIRST, AS A SEPARATE STEP, AND VERIFY THE SIZE.
              #
              # Two reasons this is not folded into the measured run. First, a
              # run killed mid-layout leaves a SHORT file, and the next run then
              # reads a file small enough to sit in the server's cache and
              # reports a throughput that never crossed the wire -- observed
              # 2026-09-05 at 127.1 MiB/s against a 969.5 Mb/s link. Second,
              # measuring a run that includes layout mixes write time into a
              # read number.
              #
              # --create_only=1 lays out without measuring, and is a no-op when
              # the files are already the right size -- which is what makes the
              # retained layout cheap to reuse.
              # --alloc-size RAISES FIO'S INTERNAL smalloc ARENA, and without it the
              # 64 GiB smallfile corpus is unreachable. fio keeps a struct per
              # file in a fixed pool set (8 pools); at the default 16384 KiB per
              # pool that tops out near 322k files. 64 GiB / 64 KiB is 1,048,576
              # files per client, 3.3x over, and fio does not degrade -- it
              # aborts mid-layout:
              #   smalloc: OOM. Consider using --alloc-size ...
              #   fio: filesetup.c:1746: alloc_new_file: Assertion `0' failed.
              # leaving a 4-file corpus that the old count check happily printed
              # and ran against. 131072 KiB = 128 MiB per pool = ~2.5M files of
              # headroom, allocated lazily, well inside the pod's 4Gi limit.
              # It is passed to BOTH fio invocations because layout and the
              # measured run each build the full file list.
              FIO_ALLOC="--alloc-size=131072"
              echo "### fio $(fio --version 2>/dev/null || echo unknown), ${FIO_ALLOC}"

              # --fsync=0 ON THE LAYOUT ONLY. Measured on the DS418 2026-09-05:
              # laying out the smallfile corpus with the job's fsync=1 ran at
              # 1.1 MB/s = 17 files/s across three clients, an ETA of FIFTY HOURS
              # for 3.1M files. Each 64 KiB file was costing ~166 ms, which is a
              # disk commit, not a network round trip.
              #
              # Durability during CORPUS CREATION is not part of the measurement:
              # smallfile-write's measured run rewrites those files with fsync=1
              # and smallfile-read only reads them, so how the bytes first landed
              # changes neither number. Overriding it here buys back two orders of
              # magnitude on the single most expensive step in the campaign while
              # leaving both workloads' semantics untouched. Command-line options
              # override the job file's global section, so this affects the layout
              # invocation and nothing else.
              echo "### layout (create_only, fsync off; no-op if already correct size)"
              fio /tmp/job.fio ${FIO_ALLOC} --fsync=0 --create_only=1 >/tmp/layout.log 2>&1 || {
                echo "WARN layout returned non-zero; tail follows" >&2
                tail -15 /tmp/layout.log >&2
              }

              # WANT is substituted by run.sh, NOT computed here.
              #
              # It used to be a `python3 - <<'PY' ... PY` heredoc, which broke
              # the manifest: this whole script is a YAML block scalar indented
              # 14 spaces, and a heredoc terminator must sit at column 0 -- less
              # indented than the block, which ENDS THE BLOCK SCALAR. The result
              # was `could not find expected ':'` and a Job that never applied,
              # while run.sh happily reported "job did not complete".
              # Never put a column-0 heredoc terminator inside this block.
              WANT=__FILESIZE_BYTES__
              # SIZE CHECK APPLIES ONLY TO THE BIG-FILE WORKLOADS.
              # smallfile-* deliberately writes 64k files and takes its size
              # from nrfiles, so "largest file >= BENCH_FILESIZE" is not just
              # inapplicable there, it is guaranteed to fail.
              case "${WORKLOAD}" in
                smallfile-*)
                  # For these the corpus is many files, so "largest file" means
                  # nothing; the COUNT is the thing to check. This used to only
                  # PRINT the count, which is why a fio layout that aborted at 4
                  # files out of 1,048,576 still went on to "measure" and record
                  # a result. Printing is not checking.
                  NFILES=$(find "${BENCH_DIR}" -type f 2>/dev/null | wc -l)
                  NUMJOBS=$(awk -F= '/^numjobs=/{print $2; exit}' /tmp/job.fio)
                  EXPECT=$(( ${BENCH_NRFILES} * ${NUMJOBS:-1} ))
                  FLOOR=$(( EXPECT - EXPECT / 100 ))          # allow 1% slack
                  echo "  smallfile corpus: ${NFILES} files, want >= ${FLOOR} (${EXPECT} nominal)"
                  if [ "${NFILES}" -lt "${FLOOR}" ]; then
                    echo "FATAL: smallfile corpus is INCOMPLETE (${NFILES} < ${FLOOR})." >&2
                    echo "  Measuring against a partial corpus reports the speed of whatever" >&2
                    echo "  fraction got created, which is not a storage figure at all." >&2
                    echo "  Layout log tail:" >&2
                    tail -15 /tmp/layout.log >&2
                    exit 1
                  fi
                  ;;
                *)
                  # awk, NOT `sort -rn | head -1`: head exits after one line,
                  # sort takes SIGPIPE writing the second, and `set -o pipefail`
                  # turns that into a fatal error. It only bites once there are
                  # enough files to overflow the pipe buffer -- which is why it
                  # passed on every big-file run and killed smallfile-write with
                  # exit 141. awk streams and never closes the pipe early.
                  GOT=$(find "${BENCH_DIR}" -type f -printf '%s\n' 2>/dev/null \
                        | awk 'BEGIN{m=0} $1>m{m=$1} END{print m+0}')
                  echo "  largest file: ${GOT} bytes, want >= ${WANT}"
                  if [ "${GOT}" -lt "${WANT}" ]; then
                    echo "FATAL: layout is SHORT (${GOT} < ${WANT})." >&2
                    echo "  A short file is served from the server's cache and yields a" >&2
                    echo "  throughput that never crossed the wire. Refusing to measure." >&2
                    echo "  Most likely a previous run was killed mid-layout; clear it with" >&2
                    echo "  ./run.sh --backend <b> --clean and re-run." >&2
                    exit 1
                  fi
                  ;;
              esac

              # --output-format=json is the whole point: the parser reads this,
              # not the human table, so a result can never be transcribed wrong.
              # Bracket the measured run with epochs so the switch counter can be
              # read over EXACTLY this window. Previously run.sh guessed the
              # window from job start/end, which (a) reached back into the
              # previous job and (b) leaned on rate()[1m] when mktxp only
              # scrapes every 30s -- two samples, so a 60s burst straddling a
              # scrape boundary is averaged with idle time and reads ~25% low.
              # ---- RENDEZVOUS BARRIER ------------------------------------
              # NOTHING previously made the N clients measure at the SAME TIME.
              # Each pod installs fio at startup and lays out its own corpus, both
              # of variable duration, so the measured windows drifted apart --
              # and the parser SUMS bandwidth across clients as though they were
              # concurrent. Observed 2026-09-05 on rand-write-4k at 3 clients:
              #   c2 1788631522-1788631588
              #   c0 1788631607-1788631673   <- started after c2 had finished
              #   c1 1788631689-1788631755
              # Three strictly sequential runs, summed, reported as 74.2 MiB/s.
              # The MikroTik counter said 255 Mb/s, which is 74.2/3. The wire was
              # right. Worse, it was INTERMITTENT -- seq-* overlapped fine the
              # same hour -- so no single row revealed which kind it was.
              #
              # Marker file per client on the shared volume, then a GO file
              # carrying a common start epoch. GO exists because detecting "all
              # markers present" is not enough on NFS: directory attributes are
              # cached (acdirmin 30s), so clients notice each other at different
              # times. A shared absolute target absorbs that skew -- everyone
              # sleeps until the same wall-clock second instead of starting when
              # they happen to notice. mkdir is the atomic primitive that elects
              # a single GO writer.
              BARRIER_DIR="/data/__BACKEND__/.barrier/__JOB_NAME__"
              mkdir -p "${BARRIER_DIR}"
              : > "${BARRIER_DIR}/${CLIENT}"
              WANT_CLIENTS=__CLIENTS__
              BARRIER_TIMEOUT=__BARRIER_TIMEOUT__
              BARRIER_PAD=45
              T0=$(date +%s)
              while :; do
                SEEN=$(ls -1 "${BARRIER_DIR}" 2>/dev/null | grep -c '^c[0-9]' || true)
                if [ "${SEEN:-0}" -ge "${WANT_CLIENTS}" ]; then
                  if mkdir "${BARRIER_DIR}/.go.lock" 2>/dev/null; then
                    echo $(( $(date +%s) + BARRIER_PAD )) > "${BARRIER_DIR}/GO.tmp"
                    mv "${BARRIER_DIR}/GO.tmp" "${BARRIER_DIR}/GO"
                  fi
                fi
                if [ -f "${BARRIER_DIR}/GO" ]; then
                  TARGET=$(cat "${BARRIER_DIR}/GO" 2>/dev/null || echo 0)
                  [ -n "${TARGET}" ] && [ "${TARGET}" -gt 0 ] && break
                fi
                if [ $(( $(date +%s) - T0 )) -ge "${BARRIER_TIMEOUT}" ]; then
                  echo "FATAL: barrier timed out after ${BARRIER_TIMEOUT}s with ${SEEN:-0}/${WANT_CLIENTS} clients ready." >&2
                  echo "  A run whose clients did not start together cannot have its" >&2
                  echo "  bandwidth summed, so there is nothing worth measuring here." >&2
                  exit 1
                fi
                sleep 2
              done
              while [ "$(date +%s)" -lt "${TARGET}" ]; do sleep 1; done
              echo "### BARRIER_RELEASED waited $(( $(date +%s) - T0 ))s, ${WANT_CLIENTS} clients, target ${TARGET}"

              echo "### FIO_START_EPOCH $(date +%s)"
              fio /tmp/job.fio ${FIO_ALLOC} --output-format=json --output=/tmp/out.json
              echo "### FIO_END_EPOCH $(date +%s)"
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
              # 2Gi, not 1Gi: --alloc-size=131072 lets fio claim up to 8 x 128 MiB
              # of smalloc arena for the 1M-file smallfile corpus, on top of its
              # own working set. The 4Gi limit is the backstop.
              memory: "2Gi"
            limits:
              cpu: "2"
              memory: "4Gi"
