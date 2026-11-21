# Remove the logging stack entirely

Design and assessment for removing the logging stack; not built, timing not decided. The README TODO keeps a short summary of the item and links here.

**Remove the logging stack entirely (operator's intent 2026-10-27; timing not decided).** Why: logging holds under 1 GiB of data, yet LokiStack `1x.pico` reserves 590 GiB of thin RBD on `ceph-nvme-block` (three 150 GiB WALs, two 50 GiB index-gateways, four 10 GiB). The WAL size is fixed by the tier (the 6.6 CRD exposes only `nodeSelector`/`podAntiAffinity`/`replicas`/`tolerations` for the ingester). The WALs' 450 GiB ceiling is above the pool's 233 GiB MAX AVAIL, and a WAL that cannot flush grew to about 117 GiB each on 2026-06-08 (OSD_FULL followed on 07-05).

**What goes:** root-app entries `logging-stack`, `cluster-logging-operator`, `loki-operator`, `logging-test-catalog` and their charts; the ClusterLogForwarder and its Vector DaemonSet; the LokiStack and its nine PVCs; the garage `loki` bucket on TrueNAS; and `grafana-config`'s Loki datasources and logs dashboards (`templates/dashboards-logs.yaml`, `files/app-errors-by-namespace.json`). The two Loki items under this heading (LOG-6894, the `infrastructure` rate limit) close with it.

**What is lost:** logs of a container older than its `--previous` instance or of a deleted pod, and audit and journal search (a node's journal stays readable through a debug pod).

**What it frees:** the Loki pods' CPU and memory requests (`KubeCPUOvercommit` fires today, and Loki's 3.4 cores each on node4 and node5 are the 89/89/39% imbalance since the 4.22 hop, which the descheduler may not touch: `openshift-*`) and the Ceph overcommit risk.

**Order when doing it:** ClusterLogForwarder, then the LokiStack (wait until its PVCs and pods are gone), then the two operators (Subscription, CSV), then the test catalog. Deleting the operators first leaves the LokiStack with a finalizer nobody removes. Disabling the root-app entries cascades through the resources finalizer, which is what is wanted here. The okderators logging PRs (#35-#38) stay unaffected; only this cluster stops being their test bed.

**Interim, if it waits long:** an alert on `kubelet_volume_stats_used_bytes` for the `wal-*` PVCs (more than 10 GiB) gives warning before the pool fills.
