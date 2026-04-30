# Running Rook-Ceph on a 3-Node OKD 4.20 Bare-Metal Cluster

Running a hyperconverged storage layer on a small bare-metal cluster comes with real constraints — no spare nodes for dedicated storage, limited RAM, and every daemon competes with workloads for resources. This post covers how I deployed Rook-Ceph on a 3-node OKD 4.20 cluster, the problems I hit, and the decisions I made along the way.

## The hardware

Three identical nodes running as both control-plane and workers:

| Node | Frontend IP | Storage backnet IP | NVMe device |
|------|-----------|-------------------|-------------|
| node4.okd.sudops.pl | 192.168.1.7 | 192.168.10.2 | /dev/disk/by-id/nvme-... |
| node5.okd.sudops.pl | 192.168.1.8 | 192.168.10.3 | /dev/disk/by-id/nvme-... |
| node6.okd.sudops.pl | 192.168.1.9 | 192.168.10.4 | /dev/disk/by-id/nvme-... |

Each node has a dedicated NVMe drive for Ceph OSDs. The storage network (`192.168.10.0/24`) is a separate VLAN configured via NMState NNCPs, keeping Ceph replication traffic off the frontend network.

## Why Rook-Ceph

I needed block storage for Prometheus, Alertmanager, and Grafana — workloads that need persistent, replicated volumes. The alternatives:

- **Local-path provisioner**: No replication. A node failure means data loss.
- **NFS**: I have a Synology NAS on the network, but NFS is wrong for database-like workloads (SQLite, Prometheus TSDB). Write latency matters.
- **OpenShift Data Foundation**: Requires a separate subscription and minimum 3 dedicated storage nodes. Overkill for a homelab.

Rook-Ceph gives me 3-way replicated block storage using the NVMe drives I already have, with no licensing requirements.

## Deployment architecture

Everything is managed by ArgoCD using an app-of-apps pattern with sync waves:

```
Wave 0  →  Node labels, failure domains, kubelet config
Wave 1  →  Rook-Ceph operator (Helm subchart, v1.19.3)
Wave 3  →  CephCluster CR, toolbox, monitoring, dashboard route
Wave 4  →  CephBlockPool + StorageClass
Wave 5  →  Monitoring stack (Prometheus/Alertmanager PVCs on Ceph)
           Grafana (PVC on Ceph, dashboards for Ceph metrics)
```

The ordering matters. The Rook operator must be running before the CephCluster CR is applied, and storage classes must exist before anything tries to create PVCs.

## Operator installation

The Rook operator is deployed as a Helm subchart wrapping the official `rook-ceph` chart from `https://charts.rook.io/release` (v1.19.3). OpenShift requires extra configuration compared to vanilla Kubernetes:

```yaml
# values.yaml (operator)
crds:
  enabled: true
hostpathRequiresPrivileged: true
csi:
  enableRbdDriver: true
  enableCephfsDriver: true
monitoring:
  enabled: true
```

The namespace needs privileged pod security labels and cluster monitoring enabled:

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: rook-ceph
  labels:
    pod-security.kubernetes.io/enforce: privileged
    pod-security.kubernetes.io/audit: privileged
    pod-security.kubernetes.io/warn: privileged
    openshift.io/cluster-monitoring: "true"
```

The `openshift.io/cluster-monitoring: "true"` label is what tells OpenShift's Prometheus to scrape ServiceMonitors in this namespace. Without it, your Ceph metrics go nowhere.

### SCC: pod security labels are not enough on OpenShift

Pod-security labels in the namespace let pods *request* privileged contexts, but on OpenShift each ServiceAccount also needs explicit access to a SecurityContextConstraint via RBAC. The Rook v1.19 subchart ships its own `rook-ceph` SCC (preferred over the built-in `privileged` — narrower scope, identical effect for our daemons) and binds it to the SAs it manages: `rook-ceph-system`, `rook-ceph-osd`, `rook-ceph-mgr`, etc.

The subchart only covers SAs it owns. Two extras need a separate binding: the `default` SA in `rook-ceph` (used by the CSI plugin pods Rook creates dynamically) and `rook-ceph-tools` (the toolbox, which uses host networking):

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: rook-ceph-scc-extra
rules:
  - apiGroups: ["security.openshift.io"]
    resources: ["securitycontextconstraints"]
    resourceNames: ["rook-ceph"]
    verbs: ["use"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: rook-ceph-scc-extra
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: rook-ceph-scc-extra
subjects:
  - kind: ServiceAccount
    name: default
    namespace: rook-ceph
  - kind: ServiceAccount
    name: rook-ceph-tools
    namespace: rook-ceph
```

Without this binding, the toolbox pod gets stuck in `CreateContainerConfigError` and CSI plugin pods fail to start with `unable to validate against any security context constraint`. The error doesn't mention SCC by name, which is what makes it annoying to debug the first time.

## CephCluster configuration

The CephCluster CR is where the interesting decisions live.

### Network: host networking with a dedicated storage VLAN

The first iteration looked like this:

```yaml
network:
  provider: host
  addressRanges:
    public:
      - "192.168.10.0/24"  # 10G storage backnet
    cluster:
      - "192.168.10.0/24"
```

Host networking means Ceph daemons bind directly to node IPs instead of getting pod IPs. On bare-metal it avoids CNI overhead and lets you pin Ceph to a dedicated 10G interface. The `192.168.10.0/24` VLAN is configured via NMState `NodeNetworkConfigurationPolicy` resources, separated from the 1G frontend network (`192.168.1.0/24`).

This config is technically correct — and it broke RBD provisioning the first time anyone created a PVC.

#### The trap: CSI clients live on the SDN

When a PVC is created, the `csi-rbdplugin` controller pod handles `CreateVolume`. It runs as a regular pod on the OVN SDN (`hostNetwork: false`). The flow:

1. Client (CSI plugin) talks to mons → asks for the OSD map.
2. Client connects to OSDs at the addresses returned by the mons.

Mons happened to advertise on `192.168.1.x` because they bind to whatever the host's primary IP is, but **OSDs bind on `public_network`**, which I'd set to `192.168.10.0/24`. The CSI pod, sitting on the SDN, has no route to `192.168.10.0/24`. Result:

```
ProvisioningFailed  rpc error: code = DeadlineExceeded desc = context deadline exceeded
ProvisioningFailed  rpc error: code = Aborted desc = an operation with the given Volume ID ... already exists
```

The "already exists" looks like a CSI bug — it's actually the in-memory operation tracking saying "the previous CreateVolume is still hanging at the OSD connect step, don't queue another one". The first call never completes because TCP to `192.168.10.4:6800` times out from inside an SDN pod.

I wasted a fair bit of time restarting CSI pods (the documented workaround for "operation already exists") before realizing the issue was below the CSI layer.

#### Diagnosing it

Two commands made it obvious:

```bash
# From the toolbox pod (hostNetwork: true, has 10G interface)
oc -n rook-ceph exec deploy/rook-ceph-tools -- rbd ls -p nvme-replicated
# → returns instantly

# From the CSI plugin pod (SDN-only)
oc -n rook-ceph exec rook-ceph.rbd.csi.ceph.com-ctrlplugin-... -c csi-rbdplugin -- \
  rbd ls -p nvme-replicated -m <mons> --id csi-rbd-provisioner.1 --key=... --debug-ms 1
# → hangs, with debug output:
#   conn(... v2:192.168.10.4:6800 ...) tick see no progress in more than 10000000 us
```

The mons are reachable from both pods (because mons happen to advertise on `.1.x`), but only host-network pods can reach the OSDs.

#### The temporary fix: move client traffic back to 1G

Changed `public_network` to the frontend subnet:

```yaml
network:
  provider: host
  addressRanges:
    public:
      - "192.168.1.0/24"   # SDN-reachable, but only 1G
    cluster:
      - "192.168.10.0/24"  # OSD↔OSD replication stays on 10G
```

Rook updates the ceph config when you commit this, but it does **not** roll the daemons. Mons happened to already advertise on `.1.x` so they were fine; OSDs needed a manual rolling restart (one at a time, waiting for `HEALTH_OK` between each) to rebind on the new addresses:

```bash
for i in 0 1 2; do
  oc -n rook-ceph delete pod -l app=rook-ceph-osd,osd=$i
  until oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s | grep -q HEALTH_OK; do sleep 5; done
done
```

After that, `ceph osd metadata` shows the new bind addresses:

```
"front_addr": "[v2:192.168.1.7:6800/...,v1:192.168.1.7:6801/...]"
```

PVC binds, pod mounts, life is good — except for the throughput hit. Now client writes traverse the 1G NIC, capped at ~118 MB/s sustained. Replication still happens on the 10G backnet via `cluster_network`, so OSD-to-OSD recovery isn't degraded. But user-visible I/O is suddenly an order of magnitude slower than the hardware can do.

#### The proper fix: Multus

The right answer is to give the CSI plugin pods a second NIC on the storage backnet via Multus, and put `public_network` back to `192.168.10.0/24`. Rook supports this directly:

```yaml
network:
  provider: multus
  selectors:
    public:  rook-ceph/ceph-public
    cluster: rook-ceph/ceph-cluster
```

With `NetworkAttachmentDefinition` resources (using the existing 10G NIC plus `whereabouts` IPAM), Rook attaches the NAD to mons, OSDs, **and** CSI plugin pods. Clients reach OSDs at line rate, the SDN keeps its single-NIC simplicity for everything else.

This is a non-trivial migration — the same kind of rolling daemon restart, plus NAD plumbing — so it's a separate piece of work, queued behind a couple of cheaper wins (PG count, slow-op investigation) covered below.

### Topology: failure domains

```yaml
nodes:
  - name: "node4.okd.sudops.pl"
    devices:
      - name: "/dev/nvme0n1"
  - name: "node5.okd.sudops.pl"
    devices:
      - name: "/dev/nvme0n1"
  - name: "node6.okd.sudops.pl"
    devices:
      - name: "/dev/nvme0n1"
```

Each node maps to a failure domain (`fd-a`, `fd-b`, `fd-c`) via Kubernetes topology labels. The block pool uses `failureDomain: host`, so Ceph distributes replicas across all three nodes. With `size: 3` and `min_size: 2`, the cluster can tolerate one node failure without data loss and continues serving I/O in degraded mode.

#### Why positional `/dev/nvme0n1` instead of `/dev/disk/by-id/`

I started with `/dev/disk/by-id/nvme-...` paths, which is the conventional advice — the by-id link is keyed off the drive's serial number, so it survives `nvme0` and `nvme1` swapping at boot. The downside is that the path is **specific to this physical drive**, and it changes the moment you replace the drive. With three nodes and three drives, you'd need a values.yaml change every time you swap a disk.

The cluster's hardware story is simpler than that: every node has exactly one NVMe slot, populated, and that's the device Ceph should use. The OS sits on a different bus (SATA M.2). So `/dev/nvme0n1` is **always** the right device on every node, regardless of which physical drive is plugged in. Disk replacements become a hot-swap with zero git changes.

The values.yaml comment captures the intent:

```yaml
# Positional device name — stable across disk replacements (all nodes use NVMe slot 0)
nodes:
  - name: "node4.okd.sudops.pl"
    devices:
      - name: "/dev/nvme0n1"
```

If a future node ever has two NVMe drives — say one for OSD, one for OS — this assumption breaks and we go back to by-id. For now, positional is the smaller blast radius.

### Resource tuning for small clusters

On a 3-node cluster where every pod counts, you can't give Ceph unlimited resources:

```yaml
resources:
  mon:
    requests:
      cpu: "500m"
      memory: "1Gi"
    limits:
      memory: "1Gi"
  mgr:
    requests:
      cpu: "500m"
      memory: "512Mi"
    limits:
      memory: "512Mi"
  osd:
    requests:
      cpu: "1"
      memory: "5Gi"
    limits:
      memory: "5Gi"
```

The OSD memory target is set to 4GB with BlueStore cache autotuning:

```yaml
cephConfig:
  global:
    osd_pool_default_size: "3"
    osd_pool_default_min_size: "2"
  osd:
    osd_memory_target: "4294967296"
    bluestore_cache_autotune: "true"
```

4GB per OSD is a reasonable floor for NVMe-backed OSDs. Going lower causes excessive cache eviction and visible latency spikes. The `bluestore_cache_autotune` setting lets Ceph manage the split between BlueStore cache and RocksDB metadata cache automatically.

I also increased the system reserved memory on each node via a `KubeletConfig` to 3Gi, preventing the kernel OOM killer from targeting Ceph OSDs when the node is under memory pressure:

```yaml
apiVersion: machineconfiguration.openshift.io/v1
kind: KubeletConfig
metadata:
  name: system-reserved-increase
spec:
  machineConfigPoolSelector:
    matchLabels:
      pools.operator.machineconfiguration.openshift.io/master: ""
  kubeletConfig:
    systemReserved:
      memory: "3Gi"
```

The `master` pool selector covers all three nodes — they're control-plane and worker simultaneously. Applying this rolls each node sequentially via the MCO; expect ~10 minutes of churn the first time you commit it. The 3Gi value is calibrated against OSDs requesting 5Gi (limit 6Gi) plus headroom for kubelet, container runtime, and OVN — it leaves the OSDs as the largest *evictable* workload but keeps system services off the OOM list.

### Manager modules

```yaml
mgr:
  count: 2
  modules:
    - name: pg_autoscaler
      enabled: true
    - name: rook
      enabled: true
    - name: devicehealth
      enabled: true
```

`pg_autoscaler` is essential — it automatically adjusts placement group counts as pools grow, which saves you from the classic "too few PGs" warning. `devicehealth` monitors NVMe SMART data and can predict drive failures.

## The toolbox: keyring init quirk

The Rook toolbox pod (`rook-ceph-tools`) is what you `oc rsh` into to run `ceph -s`, `rbd ls`, and similar admin commands. Following upstream's example, the deployment mounts the admin keyring secret at `/etc/ceph/keyring-store/keyring` and runs an init script to set up `ceph.conf`.

The wrinkle: the secret stores **just the raw key**, not a full keyring file. Pointing `ceph` at the mounted file directly fails because Ceph expects keyring files in `[client.admin]\n  key = ...` format. The toolbox script needs to wrap the raw key into a real keyring at startup:

```bash
CEPH_CONFIG="/etc/ceph/ceph.conf"
MON_CONFIG="/etc/rook/mon-endpoints"
KEYRING_FILE="/etc/ceph/keyring"

cat <<KEYEOF > "$KEYRING_FILE"
[client.admin]
key = $(cat /etc/ceph/keyring-store/keyring)
KEYEOF

cat <<EOF > "$CEPH_CONFIG"
[global]
mon_host = $(cat "$MON_CONFIG" | sed 's/[a-z]\+=//g; s/=/ /; s/  */ /g')

[client.admin]
keyring = $KEYRING_FILE
EOF

sleep infinity
```

Without that wrap, every `ceph` command in the toolbox hangs waiting for an auth handshake that never completes — no useful error message, just silence. Worth knowing before you go down a "why can't the toolbox talk to mons" rabbit hole.

The toolbox also runs `hostNetwork: true` so it can reach OSDs on the storage backnet. That's why it shows up in the SCC binding above — host networking on OpenShift requires SCC `use` permission.

## Storage classes

A single replicated block pool backed by NVMe drives:

```yaml
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: nvme-replicated
  namespace: rook-ceph
spec:
  failureDomain: host
  deviceClass: nvme
  replicated:
    size: 3

---
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: ceph-nvme-block
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: rook-ceph.rbd.csi.ceph.com
parameters:
  pool: nvme-replicated
  imageFormat: "2"
  imageFeatures: layering
  csi.storage.k8s.io/fstype: ext4
reclaimPolicy: Delete
allowVolumeExpansion: true
```

Setting `ceph-nvme-block` as the default storage class means any PVC without an explicit `storageClassName` automatically lands on Ceph. I chose ext4 over XFS for the filesystem — it's simpler to debug and resize, and for my workloads (Prometheus TSDB, SQLite) there's no meaningful performance difference.

## Monitoring: the tricky part

Getting Ceph metrics into Prometheus on OKD required understanding how OpenShift's monitoring stack actually works.

### ServiceMonitor

```yaml
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: rook-ceph-mgr
  namespace: rook-ceph
spec:
  endpoints:
    - port: http-metrics
      path: /metrics
      interval: 15s
  selector:
    matchLabels:
      app: rook-ceph-mgr
      rook_cluster: rook-ceph
```

This tells Prometheus to scrape the Ceph Manager's `/metrics` endpoint. But Prometheus needs RBAC to reach into the `rook-ceph` namespace:

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: prometheus-k8s-rook-ceph
  namespace: rook-ceph
rules:
  - apiGroups: [""]
    resources: [services, endpoints, pods]
    verbs: [get, list, watch]
```

Without this Role and RoleBinding, Prometheus discovers the ServiceMonitor but can't resolve the target endpoints.

### Ceph dashboard and Prometheus integration

The Ceph dashboard runs on port 8080 (SSL disabled for simplicity behind the OpenShift router's edge TLS):

```yaml
cephConfig:
  global:
    mgr/dashboard/ssl: "false"
    mgr/dashboard/server_port: "8080"
```

I initially tried connecting the Ceph dashboard to Prometheus for its built-in graphs. This turned into a rabbit hole:

1. **Prometheus on OKD binds to `127.0.0.1:9090`** — it's not directly accessible from other pods.
2. The `prometheus-operated` service actually hits `kube-rbac-proxy` on port 9091, which requires a bearer token.
3. The Ceph MGR on host networking can reach ClusterIPs but not pod IPs.

After building (and then deleting) a Python auth proxy, I realized Grafana with dedicated Ceph dashboards is a far better solution than the built-in dashboard graphs. The Ceph dashboard is still useful for cluster management, but metrics visualization belongs in Grafana.

### Exposing the dashboard via Route

The dashboard listens on plain HTTP port 8080 inside the cluster (SSL terminated at the OpenShift router) and is reached via a Route at `ceph.apps.okd.sudops.pl`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: ceph-dashboard
  namespace: rook-ceph
spec:
  host: ceph.apps.okd.sudops.pl
  to:
    kind: Service
    name: rook-ceph-mgr-dashboard
  port:
    targetPort: http-dashboard
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
```

Edge termination + the wildcard `*.apps.okd.sudops.pl` cert (managed by cert-manager) means the browser sees a valid Let's Encrypt cert and no warnings. The alternative — passthrough with the dashboard's self-signed cert — would force a browser exception every time, which gets old fast.

`insecureEdgeTerminationPolicy: Redirect` quietly bumps any `http://ceph.apps...` request up to HTTPS. Cheap and useful.

### Grafana dashboards

Three Ceph-specific dashboards from grafana.com:

- **Ceph Cluster overview** (ID: 2842) — overall health, IOPS, throughput
- **Ceph OSD overview** (ID: 5336) — per-OSD latency and utilization
- **Ceph Pools overview** (ID: 5342) — pool-level stats

The Grafana datasource authenticates to OpenShift's Thanos Querier using a ServiceAccount token with `cluster-monitoring-view` privileges:

```yaml
datasource:
  name: Prometheus
  type: prometheus
  url: https://thanos-querier.openshift-monitoring.svc:9091
  jsonData:
    httpHeaderName1: Authorization
    tlsSkipVerify: true
  secureJsonData:
    httpHeaderValue1: "Bearer ${token}"
```

This gives Grafana access to all cluster metrics, including Ceph, node-level, and Kubernetes metrics from a single datasource.

## Performance: the first benchmark, and what it taught me

After the network detour, I ran a 200 GB random-write test from a test pod to validate the cluster:

```yaml
spec:
  containers:
    - name: test
      image: quay.io/ceph/ceph:v19.2.3
      command: ["/bin/bash","-c"]
      args:
        - dd if=/dev/urandom of=/data/testfile bs=1M count=200000 status=progress
      volumeMounts:
        - { name: data, mountPath: /data }
  volumes:
    - name: data
      persistentVolumeClaim: { claimName: ceph-test-pvc-200 }
```

Ceph dashboard reported peaks around 580 MB/s, settling to ~150 MB/s sustained. Cluster health flipped to:

```
HEALTH_WARN  3 OSD(s) experiencing slow operations in BlueStore
```

Two real problems behind this, both fixable.

### Problem 1: only one PG in the pool

```
$ ceph osd pool ls detail
pool 2 'nvme-replicated' replicated size 3 ... pg_num 1 pgp_num 1 autoscale_mode on
```

A pool with one PG funnels every write through a single primary OSD. The other two OSDs only ever see replica writes for that one PG. With 53k objects on 1 PG, queue depth piles up, and `BLUESTORE_SLOW_OP_ALERT` fires when individual ops cross the slow threshold (default 5s) under sustained load.

The pg_autoscaler had been on the whole time. It just hadn't bumped pg_num because:

- `bulk` is `false` on the pool — without that hint, the autoscaler treats it as a small pool and grows reactively.
- `target_size_ratio` is unset — without an explicit "this pool will hold X% of cluster capacity" signal, growth is conservative.

Setting either nudges the autoscaler. For an RBD pool that's the cluster's only block backend, `bulk: true` is the right answer:

```yaml
# CephBlockPool
spec:
  parameters:
    bulk: "true"
```

This alone takes the pool from 1 → ~32 PGs (the autoscaler picks based on `100 × replicas / OSD count`, capped at `mon_target_pg_per_osd`).

### Problem 2: it isn't actually the 1G client link (revised)

I assumed the settled 150 MB/s was the 1G frontend NIC saturating, since that's the obvious story when you've put `public_network` on a 1G subnet. The Mikrotik switch data killed that theory:

```
1G frontend (.1.x), node6:
  Tx 2.9 Mbps   Rx 3.1 Mbps   peak ~100 Mbps    ← 10% of capacity
10G backnet  (.10.x), node6:
  Tx 50 kbps    Rx 13 kbps    peak ~2 Gbps Rx   ← replication, doing its job
```

The 1G link is barely used. Replication on the 10G backnet is doing what it should (every client write fans out to two replica writes between OSDs, and that's where the bandwidth goes — not the client side).

So the throughput ceiling at ~150 MB/s sustained isn't a NIC limit at all. It's the combination of:

1. **Single PG** — every write through one primary OSD, queue depth saturates that one BlueStore.
2. **NVMe random-write IOPS** under `dd if=/dev/urandom`. Consumer/prosumer NVMe drives degrade hard on sustained random writes once SLC cache fills.
3. **Ceph write amplification** — `size: 3`, journaling, RocksDB compaction.

The Multus migration is still on the roadmap (it's a cleaner architecture and removes the public_network hack), but it's no longer expected to be a *throughput* win. The cheap, high-impact lever is the PG count.

### Combined effect on slow ops

The slow-op alert is the union of these:

1. Single-PG serialization → BlueStore queues stretch
2. 1G client link → backpressure makes ops sit in the queue longer
3. Cold caches after the rolling restart we did to fix the network → first GBs of the test hit raw NVMe with full write amplification
4. RocksDB compaction kicking in mid-test, competing for IOPS

It's transient on this hardware. After the test stops and compaction settles, the warning clears. But all four contributors get smaller after fixing PG count and putting 10G back in front of clients.

### Problem 3: with PG=32, what's the bottleneck *now*?

After `pg_num: 1 → 32` shipped and the cluster re-stabilized, dd into a fresh 100 GB test PVC produced a different shape on the Grafana panel: writes plateau at ~30 MB/s commit immediately, no sawtooth, no slow ramp. That's the textbook symptom of the parallelism win — primary PGs distribute across all 3 OSDs from the first write instead of stacking onto one.

But the ceiling is suspicious. 30 MB/s is **240 Mbps** — about 25% of a single 1 GbE link, and roughly **1% of what the NVMe drives are spec'd for** (PNY CS1030: 1750 MB/s sequential write). Neither network nor raw drive bandwidth is the constraint. So what is?

The answer is in `bluestore`'s perf counters. After 25 hours of cluster uptime since the last roll, lifetime averages across all three OSDs:

```bash
$ for osd in 0 1 2; do
    oc -n rook-ceph exec deploy/rook-ceph-tools -- \
      ceph tell osd.$osd perf dump | \
      jq '{kv_commit_lat: .bluestore.kv_commit_lat.avgtime,
           kv_sync_lat:   .bluestore.kv_sync_lat.avgtime}'
  done
```

| OSD | `kv_commit_lat` avg | `kv_sync_lat` avg | sample count |
|---|---|---|---|
| osd.0 | **133 ms** | 136 ms | 262,811 |
| osd.1 | **144 ms** | 147 ms | 258,550 |
| osd.2 | **125 ms** | 127 ms | 250,361 |

Reference points:
- Enterprise NVMe with PLP: **0.1–1 ms** per kv commit
- "Decent" consumer NVMe without PLP: 5–15 ms
- These drives: **~130 ms** — roughly 1000× worse than enterprise, ~10× worse than typical consumer

That single number explains the ceiling. Single-client sequential math:

```
single_pipeline_throughput ≈ block_size / commit_latency
                          = 1 MiB / 130 ms
                          ≈ 7.7 MB/s

with ~3 parallel primary pipelines per OSD (32 PGs / 3 OSDs / size=3):
                          ≈ 23 MB/s
```

That matches the ~25–30 MB/s sustained number we see almost exactly.

### What the drives actually are

Looked them up:

```bash
$ oc debug node/node6.okd.sudops.pl -- chroot /host nvme list
Node          Generic     SN                    Model                       Format         FW Rev
/dev/nvme0n1  /dev/ng0n1  PNB48250038340500238  PNY CS1030 500GB SSD       512   B + 0 B  GT67d92d
```

PNY CS1030 is essentially the worst-case profile for Ceph BlueStore:

| Property | This drive | Why it kills Ceph specifically |
|---|---|---|
| **DRAM-less + HMB** | uses host RAM for FTL via PCIe | Every metadata access has PCIe round-trip latency; under sustained QD1 sync writes the FTL becomes the bottleneck, not the NAND |
| **No PLP** | consumer drive, no power-loss capacitors | Every `fdatasync()` forces a real NAND program; the controller cannot ack from DRAM and rely on capacitor flush |
| **TLC NAND, consumer firmware** | desktop-burst tuned | QD1 random sync IOPS collapses to the low hundreds/sec |
| **TBW = 250 TBW** | 0.5 DWPD over 5 yrs | At Ceph's 5–10× write amp, ~25–50 TB of *client* writes total before the drive enters wear-out warnings |

The fsync chain on this drive looks like:

1. Host issues `fdatasync` over PCIe to controller
2. Controller has no PLP — must finish all in-flight programs to NAND before ack
3. Controller has no DRAM — must read FTL metadata back over HMB (PCIe round-trip again)
4. Each step has fixed latency that doesn't shrink with workload size or queue depth

So `kv_commit_lat` of ~130 ms isn't a bug or a misconfig — it's what this hardware delivers at QD1 sync, and Ceph's write path is mostly QD1 per primary OSD by construction.

### Practical implications

1. **Don't expect more than ~30–50 MB/s sustained** on this hardware regardless of further Ceph tuning. iodepth helps a bit, but the per-pool single-client test is going to live near the calculated ceiling.
2. **TBW is the real risk.** Each 200 GB benchmark writes ~1.2 TB of raw data across the cluster (200 × 3 replicas × ~2× BlueStore amp). That's ~5% of total TBW per drive *per benchmark run*. The SMART monitoring TODO is more urgent than I initially framed it — burn-rate could be days, not years, under a heavy test cadence.
3. **The hardware fix isn't a full drive swap.** A small enterprise NVMe per node (Micron 7450 PRO 480 GB, Kioxia CD8 800 GB, used Samsung PM9A3) hosting WAL+DB *only* would put rocksdb sync on PLP without replacing the bulk data drives. Typical published result for that split: `kv_commit_lat` from ~100 ms range to <1 ms, throughput up 5–10×. Bluestore data can stay on the consumer drives because their read path and queue-depth-32 write path are fine.
4. **Multus, encryption, and other items in the roadmap don't address this.** They're all good ideas for other reasons (architecture, security) but none of them shorten `kv_commit_lat`. Only PLP does.

This is the hard wall, and it's the right one to hit. PG=1 → 32 unlocked the parallelism that was on the table; everything beyond that requires hardware that supports the workload Ceph generates.

### Validating the diagnosis on a known-different drive

The theory said: *the bottleneck is fsync latency on consumer NVMe without PLP*. Before buying replacement hardware, I wanted a direct measurement on a drive that *should* behave differently — same physical interface, but enterprise-class firmware and DRAM cache.

I had a Samsung **PM9A1 512 GB** sitting on the shelf (mid-life, 18% wear, 13.55 TB lifetime writes — fine as a test sled, not a production drive). Booted CentOS 10 live on an Optiplex 7050, attached the drive, ran the same workload BlueStore generates: 4k random write at QD1 with `fsync=1` after each IO.

```bash
sudo fio --name=qd1-fsync --filename=/dev/nvme0n1 --direct=1 \
  --rw=randwrite --bs=4k --iodepth=1 --numjobs=1 --fsync=1 \
  --time_based --runtime=60 --group_reporting
```

Run it twice — the first 60 s on a freshly inserted drive can show artificially good numbers from idle SLC cache. The second run is the steady-state value worth reporting.

| Drive | mean fsync | 99th-pct fsync | bw at QD1+fsync | Notes |
|---|---|---|---|---|
| **PNY CS1030 500 GB** (in cluster) | **~130 ms** (`bluestore.kv_commit_lat`, 250k+ samples) | — | — | DRAM-less + HMB + no PLP |
| **Samsung PM9A1 512 GB** (run 1, cold) | 1.6 ms | 3.1 ms | 2.41 MiB/s, ~617 IOPS | DRAM cache, enterprise firmware |
| **Samsung PM9A1 512 GB** (run 2, steady) | 2.9 ms | 3.7 ms | 2.41 MiB/s, ~600 IOPS | same drive, back-to-back |

The PM9A1 commits a 4k fsynced IO **45–80× faster** than the PNY's lifetime average, on the exact metric BlueStore is bottlenecked on. The bandwidth headline (2.41 MiB/s) looks tiny because `--fsync=1` after every 4k IO is a pathological pattern — but it's the right pattern, because that's what rocksdb does.

Sanity check via the QD1 throughput math from earlier:

| Drive | bs / commit_lat | × 3 parallel pipelines | Predicted client ceiling | Observed |
|---|---|---|---|---|
| PNY (production) | 1 MiB / 130 ms ≈ 7.7 MB/s | 23 MB/s | ~25 MB/s | **~25 MB/s ✓** |
| PM9A1 (theoretical, in same role) | 1 MiB / 3 ms ≈ 333 MB/s | 1000 MB/s | network-limited (1 GbE) | TBD |

So a swap is predicted to move the ceiling from "fsync-limited at ~25 MB/s" to "network-limited at ~110 MB/s". The cluster wouldn't be fast — it'd just hit a different wall.

Drive wear cost of the test: 540 `data_units_written` (~276 MB) for 120 s of synthetic load. The 0.5 °C/s temperature climb (sensor 2 hit 57 °C) is the bigger live concern than wear at this duration. The full output of `nvme smart-log`, `nvme id-ctrl -H`, and both fio runs is captured under `data/pre-swap/pm9a1-*.txt` for reproducibility.

### Next step: single-OSD swap, in-cluster A/B

The synthetic test rules out *the drive isn't the issue*. To rule out *something else in the cluster makes Ceph slow regardless of drive*, the next step is to swap **one** PNY for the PM9A1 in node4 and let the cluster run normal load for ~24 h. With three OSDs sharing the same PG distribution, network, workload mix, and configuration, `ceph daemon osd.N perf dump | jq .bluestore.kv_commit_lat` becomes a clean A/B:

- If `osd.0` (PM9A1) drops from ~130 ms to single-digit ms while `osd.1` and `osd.2` (still PNY) stay at ~130 ms → diagnosis confirmed, `kv_commit_lat` is hardware-dependent.
- If all three stay at ~130 ms → the bottleneck is somewhere other than NAND commit latency, and I need to keep digging.

That single-OSD experiment is the cheapest possible test: one drive, ~1–2 h of backfill, no procurement. Results to follow in a sequel post.

### Swap done — the in-cluster A/B confirms it

I executed the swap on node4 (full procedure in `data/pre-swap/swap-runbook.md`). Stop osd.0, cordon + drain node4, power down, swap PNY CS1030 → PM9A1, boot, wipe device, let Rook re-provision the OSD, backfill ~315 GiB of replicated data back into osd.0. Total degraded window ~30 min, no data loss (size=3, min_size=2 kept the cluster serving I/O the whole time).

After backfill completed and the cluster ran normal load for ~50 min, lifetime `kv_commit_lat` per OSD:

| OSD | Drive | `kv_commit_lat` avg | sample count |
|---|---|---|---|
| osd.0 | **PM9A1 (new)** | **4.4 ms** | 104k |
| osd.1 | PNY CS1030 | 96.4 ms | 408k |
| osd.2 | PNY CS1030 | 82.7 ms | 401k |

→ **~20× faster** on the metric BlueStore is bottlenecked on. And the BlueStore slow-op alert that used to flag all three OSDs now only flags osd.1 and osd.2 — corroborating evidence.

To make the divergence visible in real-time (not just lifetime averages), I ran a 4k QD1 fsync `fio` against a fresh `ceph-nvme-block` PVC for 120 s. This is the cluster-side mirror of the standalone test from earlier.

Cluster-side fio result (against an RBD volume, replicated 3-way):

| Metric | Value |
|---|---|
| Bandwidth | **442 B/s** |
| IOPS | 2 |
| Mean fsync latency | **9,257 ms** |
| 99th-pct fsync | 13,221 ms |
| osd.0 commit_latency (live) | 9 ms |
| osd.1 commit_latency (live) | up to 3,236 ms |
| osd.2 commit_latency (live) | up to 1,795 ms |

Compare to the standalone PM9A1 result (2.9 ms mean fsync, ~600 IOPS) and the cluster-side number reads as a benchmark of the slowest replica. Ceph's RBD client must wait for all three replicas to ack each write — so even though osd.0 acks in 9 ms, osd.1 sometimes takes 3.2 *seconds*, and the client sees the worst of the three. Replace the remaining two PNYs and the cluster-side fsync should drop ~3 orders of magnitude. The single-OSD swap was the cheap experiment; the verdict is unambiguous.

Raw post-swap data (perf dumps, fio output, ceph status) is captured under `data/post-swap/`.

## Lessons learned

### 1. `network.addressRanges.public` is a client-reachability decision, not a performance one

I picked the storage backnet for `public_network` thinking "more bandwidth = better". The trap is that **CSI plugin pods are clients too**, and they live on the SDN. If the public network isn't routable from the SDN, your provisioner times out and you get a misleading "operation already exists" error from the CSI layer.

The clean fix is Multus (give CSI pods a NIC on the storage network). The quick fix is putting `public_network` on something the SDN can reach. Either way, ask "what speaks to the OSDs?" before picking the subnet.

### 2. Host networking changes the debugging model

With host networking, Ceph daemons don't have pod IPs. When troubleshooting connectivity, you're debugging at the node level, not the pod level. `oc debug node/` becomes more useful than `oc exec`. And Ceph's `--debug-ms 1 --debug-monc 20` is the single most useful diagnostic — it tells you exactly which `v2:IP:PORT` it's failing to reach.

### 3. Rook updates ceph config but doesn't restart daemons for network changes

Changing `network.addressRanges.public` updates `ceph config` immediately on the next operator reconcile, but mons and OSDs keep their old bind addresses until they restart. After this kind of change you need a **manual** rolling restart, one daemon at a time, waiting for `HEALTH_OK` between. Rook will not do it for you.

### 4. The pg_autoscaler is conservative by default

Pools start at `pg_num: 1` with `bulk: false`. For RBD pools that will hold real data, set `bulk: true` (or an explicit `target_size_ratio`) at creation time. Otherwise you're running on 1 PG until the autoscaler's reactive heuristics finally trip — long after performance has been miserable for everyone.

### 5. OKD's Prometheus is not a general-purpose Prometheus

It's locked down with kube-rbac-proxy and only accessible via Thanos Querier with proper auth. Don't try to point things directly at port 9090 — it won't work.

### 6. `monitoring.enabled: true` doesn't do what you think

In the Rook v1.19.3 CRD, `monitoring.enabled: true` creates ServiceMonitors but **not** PrometheusRules. The field description in the docs is misleading. You need to manage alerting rules separately.

### 7. Memory pressure kills OSDs first

On small clusters, the OSD is often the largest memory consumer per node. If you don't reserve system memory via `KubeletConfig`, the kernel OOM killer targets OSDs under pressure, which triggers recovery storms that make things worse. Reserve at least 3Gi system memory on nodes running OSDs.

### 8. Separate your storage network — but keep CSI in mind

A dedicated storage VLAN is worth the configuration effort, especially with replication factor 3. Just remember that the CSI plugin needs to reach the OSDs too, so isolating the storage network requires either Multus or routable connectivity from the SDN. (See lesson #1.)

## What's next

In rough order of impact-per-effort:

1. **`bulk: true` on the RBD pool** — shipped (PR `feat/nvme-pool-bulk-true`, merged). The flag landed on the pool (`flags hashpspool,selfmanaged_snaps,bulk` in `ceph osd dump`), but the autoscaler emitted *zero* recommendations afterward (`ceph osd pool autoscale-status` returns `[]`) and `pg_num` stayed at 1. Bouncing the active mgr didn't help.
2. **`pg_num_min: "32"` on the pool** — follow-up. The autoscaler is bailing out for reasons I haven't fully traced, so force the floor explicitly. Setting `pg_num_min` is a documented Rook parameter that gets passed straight to `ceph osd pool set`. This skips the autoscaler entirely and gets us to ~32 PGs in one reconcile.
3. **Multus migration for CSI** — add `NetworkAttachmentDefinition` resources for public/cluster, flip `network.provider: multus`, do another rolling daemon restart. Cleaner architecture (removes the `public_network` workaround), but per the switch data it's no longer expected to lift throughput — the 1G link wasn't actually the constraint.
3. **CephFS storage class** for ReadWriteMany workloads.
4. **S3-compatible object storage** via CephObjectStore for backups.
5. **Alerting rules** for OSD down, PG degraded, and nearfull warnings.
6. **Encryption at rest** for the OSD volumes.

## Update 04/2026: alerting rules shipped (vendored)

Following up on lesson #6 — `monitoring.enabled: true` on the operator only creates ServiceMonitors, not PrometheusRules. Confirmed live: `oc -n rook-ceph get prometheusrules` returned zero before this change.

Rook does ship a curated rule set, but only via the `rook-ceph-cluster` subchart's `monitoring.createPrometheusRules: true` flag. We don't use that subchart — we deploy the CephCluster as a raw CR template under `components/storage/ceph-cluster/templates/`, plus a separate `components/storage/ceph-storage-classes` for the StorageClasses. Two options surfaced:

1. **Vendor the rules file**: pull `release-1.15`'s `localrules.yaml` (~870 lines, ~30 alerts covering OSD/Mon/Mgr/PG/capacity/network/RGW/RBD-mirror) into `components/storage/ceph-cluster/files/ceph-prometheus-rules.yaml`, wrap it in a minimal PrometheusRule template, and load via `.Files.Get` to bypass Helm's templating engine — necessary because the upstream alert annotations contain `{{ $min := query "..." }}` runtime expressions that Helm would otherwise try to evaluate.
2. **Migrate to the `rook-ceph-cluster` subchart**: cleaner long-term, but the subchart wants to own BlockPool + StorageClass + CephFilesystem, which we've split across two charts; combined with our 3-OSD topology (no drain headroom) and the in-progress PNY → PM9A1 swap, doing this mid-flight makes regressions harder to attribute.

Picked option 1 for now — closes the alerting gap immediately at zero risk. Subchart migration deferred until after the drive swaps are complete; logged as a TODO.

Failure mode worth noting: a first attempt put the rules content directly under `templates/` and got `parse error at (...:39): function "query" not defined` from `helm lint` — Helm tried to evaluate the Prometheus-side template expressions. Moving the file out of `templates/` and loading via `{{ .Files.Get "files/ceph-prometheus-rules.yaml" | indent 2 }}` fixed it because Helm doesn't template files outside `templates/`. The wrapper template itself stays trivial.

After this, validation:

```bash
helm lint components/storage/ceph-cluster/                     # 0 failed
helm template ... | kubeconform -strict ...                    # silent → ok
helm template ... | oc diff -f -                               # only the new PrometheusRule, no other deltas
```

`oc -n rook-ceph get prometheusrules` after sync confirms the rule object lives in the right namespace, and UWM Prometheus picks it up automatically (no namespace selector tweaks needed — UWM's default ruleSelector is namespace-agnostic outside `openshift-*`).

## Repository

The full configuration is available at [github.com/sudoom/homelab](https://github.com/sudoom/homelab). The relevant paths:

```
components/operators/rook-ceph/        # Operator (Helm subchart)
components/storage/ceph-cluster/       # CephCluster CR, toolbox, monitoring
components/storage/ceph-storage-classes/ # Block pools and StorageClasses
components/cluster-config/grafana-config/ # Grafana with Ceph dashboards
```

## 2026-05-01 — `pg_num_min` bump 32 → 128 + dashboard host inventory refresh

Two storage-side actions in one session, both worth a paragraph each.

### `pg_num_min: 128` on `nvme-replicated`

Pre-state:

```
$ ceph osd pool ls detail | grep nvme-replicated
pool 2 'nvme-replicated' replicated size 3 min_size 2 crush_rule 1 ... pg_num 32
  pgp_num 32 autoscale_mode on last_change 194 ... flags hashpspool,selfmanaged_snaps,bulk
  pg_num_min 32 application rbd read_balance_score 1.22
```

Pool sat at `pg_num=32`, even though it has `bulk: true` and the textbook target for `3 OSDs × 100 PGs/OSD ÷ replication 3` rounds up to **128**. Autoscaler isn't applying the bulk hint — a known issue tracked under the `pg_autoscaler returns empty status` TODO; `ceph osd pool autoscale-status` returns `[]` even with `bulk: true` set. Likely a Squid 19.2.3 quirk; not chasing it down today.

Pragmatic fix: floor `pg_num_min` to the textbook target. Change:

```diff
 # components/storage/ceph-storage-classes/values.yaml
 blockPools:
   nvme-replicated:
     parameters:
       bulk: "true"
-      pg_num_min: "32"
+      pg_num_min: "128"
```

Validation:

```
$ helm lint components/storage/ceph-storage-classes/   # OK
$ helm template … | oc diff -f -
   parameters:
     bulk: "true"
-    pg_num_min: "32"
+    pg_num_min: "128"
```

Single-field diff, no other resource churn. Committed as `nvme-replicated: bump pg_num_min to 128`. Argo will reconcile, the `CephBlockPool` controller will re-write the pool config, and Ceph will start the PG split. **Expected impact:** background recovery while PGs split (96 new PGs created from 32 existing = roughly 3× the current PG count). Cluster stays HEALTH_OK throughout; clients see no IO impact because the split is incremental and copy-then-cut, not stop-the-world.

This doesn't unblock the autoscaler bug. Re-opening the original `pg_num=32` TODO (closed prematurely earlier today) and leaving the autoscaler-empty-status TODO open in parallel.

### `ceph mgr fail b` — refreshed orchestrator host inventory

The Ceph dashboard's "Service Instances" column for **node4** showed empty, while node5/node6 showed full badge sets (`crashcollector`, `ceph-exporter`, `mgr`, `mon`, `osd`). The pods were actually up:

```
$ oc -n rook-ceph get pods -o wide | awk '$7 ~ /node4/'
rook-ceph-crashcollector-node4...     Running   node4.okd.sudops.pl
rook-ceph-exporter-node4...           Running   node4.okd.sudops.pl
rook-ceph-mon-a...                    Running   node4.okd.sudops.pl
rook-ceph-osd-0...                    Running   node4.okd.sudops.pl
```

And `ceph -s` agreed: `mon: 3 daemons, quorum a,b,c`, `osd: 3 osds: 3 up`. So the daemons were healthy — the orchestrator's view was stale. `ceph orch ls` confirmed:

```
NAME   PORTS  RUNNING  REFRESHED  AGE  PLACEMENT
crash             2/3  ...                       *      <- target 3, only seeing 2
mon               2/3  ...                       count:3
```

Orchestrator inventory in a Rook deployment lives in the active mgr's state. Failing the active mgr forces the standby to promote and rebuild the inventory from scratch.

```
$ ceph mgr fail b
$ ceph -s | grep mgr
    mgr: a(active, since 8s), standbys: b
$ ceph orch ls
crash             3/3  ...
mon               3/3  ...
$ ceph orch ps --hostname=node4.okd.sudops.pl
ceph-exporter.exporter  node4   running (13h)
crashcollector.crash    node4   running (13h)
mon.a                   node4   running (13h)
osd.0                   node4   running (12h)
```

All four node4 daemons now visible to the orchestrator; dashboard refreshes and shows the full badge set for node4. Cosmetic-only fix — no impact on data, IO, or quorum — but worth knowing as a recipe: any time `ceph orch ls/ps` looks stale relative to the actual pod state in a Rook cluster, fail the active mgr to force a full inventory rebuild.

Why the inventory drifted in the first place is unanswered. Active mgr `b` had been running 28h; it's possible Rook's host-list refresh logic missed an event, or there was an mgr restart somewhere in the chain that left node4's host record half-populated. Not chasing root cause unless it recurs.

## 2026-05-01 — RBD trash purge schedule

Closing the long-running "periodic `rbd trash purge` schedule" TODO. Backstory: RBD CSI doesn't actually delete the image when a PVC is removed — it calls `rbd trash mv` (deferred delete). Trashed images keep their pool space until something explicitly purges them. We hit this in 04/2026 when a one-shot `rbd trash purge` reclaimed ~600 GiB of orphaned images. Without a schedule, the same orphan-and-grow cycle would repeat.

Pre-state:

```
$ rbd trash purge schedule status
POOL  NAMESPACE  SCHEDULE TIME
                              <- empty, no schedule

$ rbd trash ls --pool nvme-replicated
                              <- empty, the manual purge cleared everything
```

Add the schedule:

```
$ rbd trash purge schedule add --pool nvme-replicated 1d
$ rbd trash purge schedule list --pool nvme-replicated
every 1d

$ rbd trash purge schedule status --pool nvme-replicated
POOL             NAMESPACE  SCHEDULE TIME
nvme-replicated             2026-05-02 00:00:00
```

Schedule is "every 1 day", fires at the next 00:00 cluster-local. Lives in **mgr config state**, persists across mgr restarts. Caveat: it does *not* live in git, so a full cluster rebuild needs the command re-run during bootstrap. Acceptable for now; if we ever do a clean rebuild, capture it as a Kubernetes Job under `components/storage/`.

A few CLI gotchas worth recording for next time:

- `rbd trash purge schedule list` (no flags) returns nothing useful — shows only the pool-less default, which we never set. Always pass `--pool <name>` or, for the global view, `--recursive` (only valid on `list`, **not** `status`).
- `rbd trash purge schedule status --recursive` returns `unrecognised option`. Use `--pool <name>` for status; `--recursive` is list-only.
- `add`, `list`, `status` all return clean exit 0 when scoped correctly.

What this changes for ops: PVC deletes still go to trash first (CSI behavior, unchanged), but stale images get reaped automatically the next midnight. Any image with `image has watchers` will still refuse removal — those need investigation, not a schedule. The "image has watchers" stuck image at `csi-vol-3af138f8-1b96-41e4-a05d-108896d26954` from 04/2026 stays as its own TODO; the schedule won't unstick it.

No data movement, no degraded window, no client impact. Pure metadata operation.
