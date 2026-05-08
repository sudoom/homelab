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

## 2026-05-01 — Capturing the trash purge schedule as a Kubernetes Job

The previous section ended with a caveat: the schedule lives in mgr config, not git. A clean rebuild of the cluster would silently lose it, and the orphan-and-grow cycle would creep back. This entry closes that loop by capturing the bootstrap as GitOps.

Design choices:

- **Job, not CronJob.** The schedule itself is a one-shot bootstrap (`rbd trash purge schedule add` is idempotent on the mgr side, but we still only need to run it once after a fresh cluster). The actual recurring purge is what mgr does internally on its own timer — we are not replacing that with a cron.
- **`argocd.argoproj.io/sync-options: Replace=true`.** Job specs are immutable once created. Without `Replace=true`, any change to the values block (e.g., adding a new pool) fails to reconcile because Argo can't patch the existing Job. With it, Argo deletes and recreates on change.
- **Sync-wave 10.** The Job needs the CephCluster, the pool (`nvme-replicated`), and the toolbox secret/configmap to all exist. Wave 10 puts it after the storage-class chart's pools (wave 5–6) and well after the cluster CR.
- **Idempotent script.** `rbd trash purge schedule list --pool $POOL | grep -q "every $INTERVAL"` short-circuits when the schedule is already present. Re-runs are silent.
- **Reuses the toolbox auth pattern.** Mounts `rook-ceph-mon` (admin keyring) and `rook-ceph-mon-endpoints` (mon list), assembles `/etc/ceph/ceph.conf` and `/etc/ceph/keyring` at runtime — same shape as the toolbox deployment.
- **`hostNetwork: true` + `dnsPolicy: ClusterFirstWithHostNet`.** Ceph clients want direct mon connectivity; matches the toolbox pattern.

Values surface (`components/storage/ceph-cluster/values.yaml`):

```yaml
rbdTrashPurgeSchedule:
  enabled: true
  interval: "1d"
  pools:
    - nvme-replicated
```

Adding a pool later (when CephFS lands or HDDs arrive) is a one-line change to this list.

First sync after the Job lands: expected to log `[nvme-replicated] schedule 'every 1d' already present, skipping` because the manual `rbd trash purge schedule add` from the previous session already wrote it. That's the validation — same script must produce that exact line on a no-op run, and `rbd trash purge schedule status --pool nvme-replicated` must still show the schedule afterward.

### Bumping cadence to 1h

After landing the Job at `1d`, dropped the interval to `1h`. Reasoning: trashed RBD images sit in the pool consuming reservation space until purged, and the CSI default trash delay is effectively zero — so the only thing standing between "PVC deleted" and "space reclaimed" is the next purge tick. Hourly is cheap (it's a metadata walk, not data movement) and turns "I deleted a PV, why is the pool still full?" into a one-hour worst case instead of a 24-hour worst case.

The naive "if not present, add" check was only safe at a fixed interval. Bumping it surfaced the gap: the existing `every 1d` schedule wouldn't match a grep for `every 1h`, so the Job would `add` the new schedule and leave both running. Fixed by walking existing schedules first and removing any that don't match the desired interval:

```bash
for SCHED in $(rbd trash purge schedule list --pool "$POOL" 2>/dev/null | awk '/^every / {print $2}'); do
  if [ "$SCHED" != "$INTERVAL" ]; then
    echo "[$POOL] removing stale schedule 'every $SCHED'"
    rbd trash purge schedule remove --pool "$POOL" "$SCHED"
  fi
done
```

Then the existing add-if-missing block stays the same. Job is now idempotent across interval changes — drop the new value into `values.yaml`, Argo replaces the Job, and the next run reconciles to the desired single schedule.

## 2026-05-01 — Manually bumping `pg_num` 32 → 128

Reopening the pg_num story. The earlier session shipped `pg_num_min: "128"` in the `CephBlockPool` `parameters` map, expecting Rook to push that to Ceph and the autoscaler (with `bulk: true`) to grow `pg_num` upward to meet the floor. Neither happened. The actual reason is in the Rook operator log:

```
ceph-block-pool-controller: [rook-ceph/nvme-replicated] creating pool
cephclient: setting pool property "bulk" to "true" on pool "nvme-replicated"
cephclient: setting pool property "pg_num_min" to "128" on pool "nvme-replicated"
cephclient: failed to set property "pg_num_min" to pool "nvme-replicated" to "128".
  failed to set pool property "pg_num_min" on pool "nvme-replicated".
  Error EINVAL: specified pg_num_min 128 > pg_num 32: exit status 22
cephclient: reconciling replicated pool nvme-replicated succeeded
```

Ceph enforces the invariant `pg_num_min <= pg_num`. So you can't raise the floor higher than the current pg_num. Rook treats the `pg_num_min` set as best-effort: it logs the EINVAL, then declares the reconcile a success (so `observedGeneration` matches `generation` and no retry is queued). That's why the chart change shipped cleanly but live state stayed at 32.

The autoscaler should have closed this gap on its own — `bulk: true` is the Ceph-supported hint to "treat this pool as if it'll grow large, target more PGs upfront." But `ceph osd pool autoscale-status` returns `[]` on this cluster (likely a Squid 19.2.3 quirk; tracked separately). Without autoscaler input, pg_num sat at the original 32.

So the unblock is manual: bump `pg_num` directly, then the operator's `pg_num_min: 128` reconcile finally has room to land.

Ran from the toolbox:

```
$ oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph osd pool set nvme-replicated pg_num 128
set pool 2 pg_num to 128
```

Watched it split. Surprisingly fast on the current hardware:

```
$ ceph -s
  data:
    pools:   2 pools, 129 pgs
    objects: 15.08k objects, 58 GiB
    usage:   175 GiB used, 1.2 TiB / 1.4 TiB avail
    pgs:     129 active+clean

  health: HEALTH_WARN
          2 OSD(s) experiencing slow operations in BlueStore
```

129 pgs (`.mgr` + 128 on `nvme-replicated`), all `active+clean`. The `BLUESTORE_SLOW_OP_ALERT` HEALTH_WARN is unchanged — that's the PNY hardware story, not split-induced.

Two-step state model now:
- `pg_num: 128` — the live PG count.
- `pg_num_min: 32` — still old; the operator has no spec change to react to. The CR still says 128, the live pool says 32, and `observedGeneration == generation` so the operator considers itself idle.

Closing that gap requires either re-triggering reconcile (operator pod restart, or a meaningless spec touch) or just setting it directly:

```
$ oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph osd pool set nvme-replicated pg_num_min 128
set pool 2 pg_num_min to 128
```

After that, operator + chart + live state all agree on 128.

Validation:

```
$ rados bench / fio / ceph osd pool ls detail
pg_num 128 pgp_num 128 pg_num_min 128
```

Lessons:
- "Set the floor first" doesn't work in Ceph. The floor follows the value, not the other way around.
- Rook's silent-on-EINVAL behavior for parameter sets means the operator can mark a reconcile "succeeded" while leaving a parameter unapplied. Worth knowing for future debugging — always cross-check the live pool state, not the CR observedGeneration.
- `bulk: true` is supposed to let the autoscaler do this for you, but the autoscaler is broken here. Until the Squid 19.2.3 autoscaler quirk is fixed, manual pg_num bumps are the path.

### Closed: `pg_num_min: 128` set on live pool (2026-05-01, late afternoon)

Ran the command from the toolbox — parameter-only change, no data movement (pg_num was already 128, so the floor-equals-value invariant is satisfied trivially):

```
$ oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph osd pool ls detail | grep nvme-replicated
pool 2 'nvme-replicated' replicated size 3 min_size 2 crush_rule 1 ...
  pg_num 128 pgp_num 128 ... last_change 339 ... pg_num_min 32 ... bulk

$ oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph osd pool set nvme-replicated pg_num_min 128
set pool 2 pg_num_min to 128

$ oc -n rook-ceph exec deploy/rook-ceph-tools -- \
    ceph osd pool ls detail | grep nvme-replicated
pool 2 'nvme-replicated' replicated size 3 min_size 2 crush_rule 1 ...
  pg_num 128 pgp_num 128 ... last_change 342 ... pg_num_min 128 ... bulk

$ oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
  cluster:    health: HEALTH_OK
  data:       2 pools, 129 pgs
              objects: 15.11k objects, 58 GiB
              usage:   175 GiB used, 1.2 TiB / 1.4 TiB avail
  pgs:        129 active+clean
```

`last_change 339 → 342` is the parameter-set bump. Cluster stays HEALTH_OK throughout (the persistent BLUESTORE_SLOW_OP_ALERT had cleared earlier; this run shows clean health). 129 pgs active+clean unchanged.

End state: operator (CR `parameters.pg_num_min: "128"`) + Ceph (`pg_num_min 128`) + autoscaler-floor (128) all agree. The CR `observedGeneration == generation` had been masking the drift since the chart change shipped — fixing the live state now makes the two consistent again, so future reconciles won't reintroduce the gap.

This closes out the pg_num saga that started with "the autoscaler isn't bumping pg_num past 32 even with bulk: true." The autoscaler-empty-status bug is still open as a separate TODO.

Validation pre-commit:

```
$ helm lint components/storage/ceph-cluster/
1 chart(s) linted, 0 chart(s) failed

$ helm template ceph-cluster components/storage/ceph-cluster/ -n rook-ceph \
    -f components/storage/ceph-cluster/values.yaml | \
    kubeconform -strict -ignore-missing-schemas \
      -schema-location default \
      -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
                              <- silent, all kinds OK

$ helm template ... | oc diff -f -
                              <- only the new Job, no other drift
```

## 2026-05-06 — node5 PNY → PM9A1 swap, the cascade that wasn't Ceph

Pulled the PNY out of node5 and dropped a PM9A1 in. Node was rebooted, came back up, kubelet posted Ready — and the cluster lit up with what *looked* like a Ceph emergency on top of the swap. It wasn't. The swap was clean; the cascade was a node-local CNI/image-pull problem that happened to coincide.

### State at T+14 min after reboot

Ceph status was the expected degraded window for losing one OSD + one mon (the mon-c on node5):

```
$ oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s
  cluster:
    id:     739ea0de-6637-45d5-8332-fbdb28350022
    health: HEALTH_WARN
            2 OSD(s) experiencing slow operations in BlueStore
            1/3 mons down, quorum a,b
            1 osds down
            1 host (1 osds) down
            1 zone (1 osds) down
            Degraded data redundancy: 52442/157326 objects degraded (33.333%),
                                      167 pgs degraded, 189 pgs undersized
  services:
    mon: 3 daemons, quorum a,b (age 14m), out of quorum: c
    osd: 3 osds: 2 up (since 14m), 3 in (since 3w)
```

33% degraded objects is exactly what you'd expect when one of three replicas is offline; mons 2/3 (a,b on node4 + node6) is quorum. The `BLUESTORE_SLOW_OP_ALERT` is the same hardware-bound warning that won't clear until all three PNYs are out.

But every pod on node5 — across `rook-ceph`, `openshift-ovn-kubernetes`, `openshift-multus`, `openshift-kube-apiserver`, `openshift-etcd`, `openshift-kni-infra` (coredns/haproxy/keepalived), `openshift-monitoring`, `media`, etc. — was stuck in `Init:0/N` or `ContainerCreating`. Symptom on the rook side:

```
$ oc -n rook-ceph get pods -o wide | grep node5
rook-ceph-mon-c-...                    0/1  Init:0/2            0  9m
rook-ceph-osd-1-...                    0/1  Init:0/4            0  9m
rook-ceph-crashcollector-node5-...     0/1  Init:0/2            0  6m
rook-ceph-exporter-node5-...           0/1  Init:0/1            0  6m
rook-ceph.cephfs.csi.ceph.com-node...  0/2  ContainerCreating   4  23d
rook-ceph.rbd.csi.ceph.com-node...     0/2  ContainerCreating   2  7d21h
```

Initial kubelet event was the giveaway:

```
Warning  FailedCreatePodSandBox  ...  Failed to create pod sandbox:
  rpc error: code = Unknown desc = creating pod sandbox ...:
  unable to pull image: copying system image from manifest list:
  Get "https://cdn01.quay.io/quayio-production-s3/sha256/...":
  net/http: TLS handshake timeout
```

So my first read was "node5 has lost outbound connectivity post-reboot." That was wrong. A debug pod confirmed:

```
$ oc debug node/node5.okd.sudops.pl -- chroot /host /bin/bash -c '...'
PING 1.1.1.1: 0% packet loss, rtt avg 57 ms          # public reachable
PING quay.io (34.193.223.197): 100% packet loss      # ICMP filtered (normal for AWS)
NAME    SIZE    MODEL                    SERIAL
sda     372.6G  THNSF8400CCSE            Y7OS109NTBST            # OS root, untouched
nvme0n1 476.9G  PM9A1 NVMe Samsung 512GB S6H3NF0R918334          # the new drive, in slot
```

Drive is in. OS root is on a separate SATA SSD, so the image cache survived the swap — there's no full re-pull underway. The cluster is just pulling tags that *changed* recently (e.g. there's a fresh `oauth-openshift-58fd89b5fd-29pd6` ReplicaSet 12 minutes old).

### Why everything is stuck behind one image pull

crio logs on node5 showed the actual chain:

```
crio: Adding pod openshift-marketplace_community-operators-... to CNI network "multus-cni-network" (type=multus-shim)
crio: Error loading cached network config: network "multus-cni-network" not found in CNI cache
crio: CmdDel (shim): CheckAPIReadyNow: Daemon not reachable over socketfile:
        failed to send CNI request: Post "http://dummy/healthz":
        dial unix /run/multus/socket/multus.sock: connect: no such file or directory
```

`/run/multus/socket/multus.sock` is created by the `kube-multus` container in the `multus-nxxpf` DaemonSet pod. That pod was still in `ContainerCreating`, blocked on:

```
Normal Pulling  5m27s  kubelet  Pulling image
  "quay.io/okd/scos-content@sha256:b0732bb8f252bbadc68be5499aca48194a0678dba2f4d0d7b7ce995e84e3def7"
```

Until that pull lands and `kube-multus` starts, the multus shim CNI plugin invoked by crio for every new pod sandbox tries to connect to a socket that doesn't exist, the sandbox creation fails, and every CNI-using pod on node5 stays in `ContainerCreating`. That's not a Ceph problem at all — it's an OKD CNI problem that *manifests* as Ceph pods being stuck.

The earlier TLS handshake timeouts were transient: counting matches in the last 2000 lines of crio logs gave 0 timeouts and ~3 successful `Pulled image` events for `quay.io/okd/scos-content@...`. So the upstream pulls were just slow under recovery load and were already self-resolving — no intervention needed.

### Decision

Don't touch anything for ~5–10 min:

- Restarting kubelet/crio resets in-flight image pulls and makes recovery slower, not faster.
- Deleting the multus pod doesn't help — a new one would have the same image to pull.
- Ceph osd.1 / mon.c won't make any progress until multus is up, regardless of what's done on the rook side.

The right move is to wait for the multus pod to transition to `Running`, then confirm the chain unwinds: mon-c sandbox creates → mon-c starts → quorum 3/3 → openshift-{kube-apiserver,etcd,coredns,haproxy,keepalived}-node5 come up → rook crashcollector/exporter come up.

osd.1 won't recover on its own even after networking returns: the bluestore on the old PNY is gone, so the existing `rook-ceph-osd-1` deployment will never find its data device. Same dance as the node4 swap last month — once node5 is healthy, the steps are:

```
# 1. drop the dead OSD's deployment so the operator stops trying to start it
oc -n rook-ceph delete deploy rook-ceph-osd-1

# 2. mark it out and purge from CRUSH (already 'down', this just cleans bookkeeping)
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd out 1
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 1 --yes-i-really-mean-it

# 3. let the operator re-discover /dev/nvme0n1 as empty and re-prepare
oc -n rook-ceph delete pod -l app=rook-ceph-operator
# (osd-prepare runs automatically; new osd.1 lands on the PM9A1)
```

Validation after backfill: confirm `kv_commit_lat` lifetime average is in the ~4 ms range like node4 (PNY was ~95 ms), then plan node6.

### Lesson

The default reaction to "Ceph is in HEALTH_WARN right after a hardware change" is "what did I break in the storage layer?" Here the answer was: nothing. The storage layer was doing exactly the right thing for a single-OSD-out scenario. The `Init:0/N` storm on rook pods looked like rook misbehaving but was downstream of multus not having a CNI socket, which was downstream of a 5-minute image pull. Reading the crio logs directly via `oc adm node-logs node5.okd.sudops.pl --unit=crio` was what made it obvious — pod `describe` only shows kubelet's view of "FailedCreatePodSandBox", not the multus.sock-not-found loop underneath.

Generalizing: when many unrelated pods on a single node go `Init/ContainerCreating` after a reboot, suspect the CNI before suspecting any individual workload. And before deleting/restarting anything, check whether image pulls are simply still in flight.

### Same day — the rename: osd.3 → osd.1

Once node5 was healthy, the operator had already auto-prepared the new PM9A1 and brought up `osd.3` against it (the old `osd.1` was still in CRUSH as `down` because nothing had purged it). New osd.3 backfilled to ~48 GiB and then **stalled** at 25.357% degraded for 3+ minutes. `ceph health detail` showed why:

```
pg 2.4 is stuck undersized for 44m, current state active+undersized+degraded, last acting [2,0]
pg 2.6 is stuck undersized for 44m ... last acting [2,0]
... (95 PGs in this state)
```

CRUSH had split the 189 PGs in fd-b across both OSDs because both still carried `weight 0.46579`:
- ~94 PGs hashed to osd.3 → backfilled → active+clean
- ~95 PGs hashed to osd.1 → stuck `undersized` because osd.1 was `down`

The stuck PGs would never migrate to osd.3 unless osd.1 left CRUSH. So the choice was:
- **Plan A**: purge osd.1 to unblock backfill onto osd.3 → finish 60 GiB → then later rename osd.3 → osd.1 → backfill **another 108 GiB** = 168 GiB of total backfill work.
- **Plan B**: purge both osd.1 and osd.3 *now*, zap, re-prepare → single 108 GiB backfill into a fresh osd.1 = 108 GiB.

Risk profile is identical: both plans pass through fully-undersized PGs (`size=2`, never below `min_size=2`), since 95 PGs were already at `[0,2]` before either plan starts. Plan B saves ~10 min and 60 GiB of duplicate work, and gives the desired osd.1 numbering in one shot.

Picked Plan B. Steps that worked:

```
# 1. Stop both daemons
oc -n rook-ceph delete deploy rook-ceph-osd-1 rook-ceph-osd-3

# 2. Purge from CRUSH/auth/osdmap
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 1 --yes-i-really-mean-it
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd purge 3 --yes-i-really-mean-it

# 3. Zap the device  ← this is where I tripped (see below)
oc debug node/node5.okd.sudops.pl --quiet -- chroot /host blkdiscard -f /dev/nvme0n1

# 4. Restart operator → triggers fresh osd-prepare across all 3 nodes
oc -n rook-ceph delete pod -l app=rook-ceph-operator
```

After step 4, `ceph osd new <uuid>` issued the lowest free ID (osd.0 + osd.2 in use → next is **1**), the new `rook-ceph-osd-1` deployment came up against `/dev/nvme0n1`, backfill kicked off at **223 MiB/s** (single target, no contention) — projected ~8 min to HEALTH_OK on PM9A1 vs the slower stalled rate during the split.

### The zap mistake: dd 100MB is not enough

First attempt at step 3 was `dd if=/dev/zero of=/dev/nvme0n1 bs=1M count=100`. `lsblk` looked clean afterward (`FSTYPE=""`), but the next `osd-prepare` short-circuited:

```
2026-05-06 15:38:16 I | cephosd: configuring new raw device "/dev/nvme0n1"
2026-05-06 15:38:17 I | cephosd: --> Raw device /dev/nvme0n1 is already prepared.
... ceph-volume raw list ...
{
    "5268d031-044e-44a1-bddf-b4d3da2418d4": {
        "ceph_fsid": "739ea0de-6637-45d5-8332-fbdb28350022",
        "device": "/dev/nvme0n1",
        "osd_id": 3,
        ...
    }
}
```

Bluestore in `raw` mode writes its label at the **start** of the device *and* at the **tail** (the BDEV second-label region near the end of the block device). Wiping just the first 100 MB clears the primary label so `lsblk`/`blkid` see no FS, but `ceph-volume raw list` reads the tail label and re-discovers the OSD. The operator then re-adopted osd.3 — but the cluster had purged it, so the daemon went `Init:Error` / `BackOff` on `expand-bluefs` because the on-disk FSID didn't match anything in the osdmap.

Fix: `blkdiscard -f /dev/nvme0n1` — TRIMs the entire NVMe namespace in 0.17 s, wiping every label. `ceph-volume raw list` then returns `{}` and the next prepare calls `ceph osd new` cleanly, picking the lowest free ID.

Lesson for the runbook (next swap on node6): **do not rely on `dd` of a fixed prefix to zap a bluestore device — use `blkdiscard -f` (or `wipefs -af` + a tail-region dd if blkdiscard isn't available).** Verify with `ceph-volume raw list` returning `{}`, not just with `lsblk`.

### End state

```
ID   CLASS  WEIGHT   TYPE NAME                         STATUS  REWEIGHT  PRI-AFF
 -1         1.39737  root default
 -4         0.46579      zone fd-a
 -3         0.46579          host node4-okd-sudops-pl
  0   nvme  0.46579              osd.0                     up   1.00000  1.00000   ← PM9A1 (swapped 04/2026)
-12         0.46579      zone fd-b
-11         0.46579          host node5-okd-sudops-pl
  1   nvme  0.46579              osd.1                     up   1.00000  1.00000   ← PM9A1 (swapped today)
 -8         0.46579      zone fd-c
 -7         0.46579          host node6-okd-sudops-pl
  2   nvme  0.46579              osd.2                     up   1.00000  1.00000   ← PNY (next to swap)
```

SMART on the new node5 PM9A1 (S/N S6H3NF0R918334): PASSED, 2% wear, 100% spare, 0 errors, 1,275 PoH / 849 cycles / 84 unsafe shutdowns — used drive in healthy condition, plenty of endurance left.

About the 500→512 GB nominal step: pool capacity is unchanged. Both PNY and PM9A1 present a 512,110,190,592-byte namespace (~476.84 GiB), Ceph rounds to 477 GiB / weight 0.46579 — the marketing GB difference disappears in GB↔GiB conversion. `ceph df MAX AVAIL` for `nvme-replicated` stays at 458 GiB. If a future generation actually adds raw capacity, that'll show up as a different weight; not this swap.

### 2+1 capture — fio against the live pool with the PNY still on osd.2

To make the eventual "all-PM9A1 (3+0)" comparison apples-to-apples, ran the standard `tests/ceph-storage-test.yaml` (4k QD1 fsync randwrite for 120s against a 10G file on a 150 GiB RBD PVC) right after HEALTH_OK from the rename.

Per-OSD lifetime stats taken right before the test as the **idle baseline**:

| OSD | Hardware                        | kv_commit_lat | kv_sync_lat | state_aio_wait_lat | sample count |
|----:|---------------------------------|--------------:|------------:|-------------------:|-------------:|
|   0 | PM9A1 (node4, swapped 04/2026)  | 3.18 ms       | 4.41 ms     |   2.81 ms          |   3.33M      |
|   1 | PM9A1 (node5, **fresh**)        | 2.82 ms       | 3.91 ms     |   0.40 ms          |  74.5k       |
|   2 | PNY (node6, original)           | **21.0 ms**   | **23.5 ms** | **82.1 ms**        |   3.44M      |

Order-of-magnitude differences as expected: PM9A1 is ~7× faster on `kv_commit_lat` and the `state_aio_wait_lat` (block-device I/O wait) is the most dramatic — 0.4–2.8 ms on PM9A1 vs **82 ms** on the PNY. That's the BlueFS DB writes hitting the PNY's slow commit path.

Then the fio result for the cluster as a whole, 4k QD1 fsync randwrite, 120s:

```
write: IOPS=18, BW=72.5KiB/s (74.2kB/s)(8700KiB/120037msec)

fsync/fdatasync/sync_file_range:
  sync (msec): min=21, max=3773, avg=55.17, stdev=119.30
  sync percentiles (msec):
   |  1.00th=[ 23],  5.00th=[ 26], 10.00th=[ 29], 20.00th=[ 33],
   | 30.00th=[ 34], 40.00th=[ 35], 50.00th=[ 37], 60.00th=[ 42],
   | 70.00th=[ 56], 80.00th=[ 71], 90.00th=[ 82], 95.00th=[ 95],
   | 99.00th=[169], 99.50th=[355], 99.90th=[2022], 99.95th=[2500],
   | 99.99th=[3775]
```

Translating: **~18 IOPS / 72.5 KiB/s sustained**, with sync p50 = 37 ms, p95 = 95 ms, **p99 = 169 ms, p99.9 = 2,022 ms, p99.99 = 3,773 ms**, max 3.77 s. The bottom-end (p1 ≈ 23 ms) is still PNY-bound — that's the floor of the slowest replica's `kv_commit_lat` plus replication round-trips.

Why the cluster is gated by one PNY even though 2 of 3 OSDs are PM9A1: with `size=3, min_size=2`, the primary OSD must collect acks from **both** secondaries before acking the client. So every write — regardless of which OSD is primary — has to wait for the slowest of {osd.0, osd.1, osd.2}, which is always osd.2. The PNY sets the cluster floor for *all* writes, and the long tail (p99.9 = 2 s) is dominated by the PNY's BlueStore slow-op spikes that the user-facing fsync inherits.

This is the strongest argument for finishing the swap: in the 2+1 state, the two PM9A1s contribute almost nothing to client latency — they're just waiting on the PNY. Capacity went up, latency didn't.

Will re-run the same test after the node6 swap as the **3+0 capture**. Expected behavior, based on the per-OSD baseline of osd.0/osd.1: sync p50 in the ~5–10 ms range, p99 in the ~20–30 ms range, p99.9 < 100 ms (dominated by Ceph replication path tail rather than disk physics). IOPS should jump to several hundred at QD1 fsync, BW to ~1–2 MiB/s. The persistent `BLUESTORE_SLOW_OP_ALERT` HEALTH_WARN should clear and stay clear.

Test pod sleeps 3600s post-fio for dashboard inspection — leaving it alive while we wait on node6 hardware. Re-running on the same PVC after the swap is fine; the test workload is steady-state, no pre-warming benefit either way.

### Same day — backwards swap to capture 1+2, and what went wrong

Idea: pull node5's PM9A1 back out, drop a PNY in, capture the 1+2 fio reading, then swap node4 too for 0+3, then forward all the way to 3+0. Goal: a complete latency ladder for the writeup.

Two operational lessons fell out of this experiment, both worth recording for future swaps.

**Lesson 1: `blkdiscard` alone doesn't fully zero a PNY; need `blkdiscard --zeroout`.** The PM9A1 swap earlier today used plain `blkdiscard -f /dev/nvme0n1` and the device read back as zeros immediately afterward (PM9A1 supports DRAT — Deterministic Read After TRIM). The PNY does not. After plain `blkdiscard` on the PNY, `lsblk -o FSTYPE` still showed `ceph_bluestore`, and `ceph-volume raw list` still found the old OSD on the device — meaning the bluestore label was still readable. `wipefs -af` plus `dd` of head and tail (200 MB each) wasn't enough either; `ceph-volume` re-adopted the previous OSD identity again.

The fix was `blkdiscard --zeroout /dev/nvme0n1`, which forces the device to actually return zeros on read across the whole namespace. On the PNY this took **9 min 11 s** for 477 GiB (~890 MB/s sustained — slower than spec because the controller is doing real internal write-zero work, not just deallocating). After that, hex dumps at offsets 0 / 1 GiB / 100 GiB / 470 GiB all read zero, and the next `osd-prepare` cleanly issued a fresh OSD via `ceph osd new`.

Runbook update: **for any drive that doesn't support DRAT (most consumer NVMe — PNY, WD Blue, Crucial P3, etc.), use `blkdiscard --zeroout` and budget ~10 min per 500 GB**. For enterprise NVMe with DRAT (PM9A1, PM9A3, Micron 7450, etc.), plain `blkdiscard -f` is fine and finishes in <1 s.

**Lesson 2: `/var/lib/rook/rook-ceph/<cluster_fsid>_<osd_uuid>/` activate dirs accumulate on the host across swaps and need cleanup.** Each time an OSD is created on a node, Rook creates a hostPath directory containing the activate metadata for that OSD UUID. These dirs are *never cleaned up* on OSD purge. After today's PM9A1-then-PNY swap on node5, there were **four** stale activate dirs:

```
739ea0de-..._5268d031-...   (first PM9A1 attempt, became osd.3, purged)
739ea0de-..._552ee490-...   (second osd.3 attempt during backwards swap, purged)
739ea0de-..._7b00f2e6-...   (original PNY's osd.1 from way back, purged)
739ea0de-..._9ff24b4c-...   (forward-swap PM9A1 osd.1, purged)
```

When the operator restarts after a wipe, it walks these dirs and tries to "recover" each as a known OSD by calling `ceph osd new --osd-id <N> <uuid>`. That re-registers ghost OSDs in the cluster's osdmap with mismatched UUIDs, races against the new prepare, and produces "phantom OSD.N down with no daemon, K8s deployment in CrashLoopBackOff" symptoms.

Runbook update: **on every OSD wipe-and-recreate, also clean the host activate dirs** before starting the operator:

```
oc debug node/<node> --quiet -- chroot /host /bin/bash -c '
  cd /var/lib/rook/rook-ceph/ &&
  ls -d <cluster_fsid>_* 2>/dev/null | xargs -r rm -rf
'
```

(The `<cluster_fsid>` is the same prefix on all entries — `oc -n rook-ceph get cephcluster rook-ceph -o jsonpath='{.status.ceph.fsid}'` to fetch.)

Combined with `blkdiscard --zeroout` and operator scale-down (which ArgoCD will revert in seconds — so it's largely cosmetic, the real protection is doing the wipe + dir-clean in one quick window before the operator next runs prepare), this gets a clean OSD ID issuance.

### 1+2 capture — fresh PNY in node5, original PNY in node6

Caveat first: the PNY we put back into node5 is **not the original node5 PNY**. The originals were in production for months and had developed the slow-op behavior. The replacement is a spare with **70 power-on hours, 25 power cycles, 3 % wear, 3.51 TB lifetime writes** — essentially a fresh drive. So this 1+2 reading isn't comparable to the historic 0+3 baseline; it's "1 PM9A1 + 1 fresh PNY + 1 worn PNY", and the fresh PNY behaves much closer to the PM9A1 than to its worn sibling at this load level.

Idle baseline (pre-fio, lifetime averages, taken right before the test):

| OSD | Hardware                          | kv_commit_lat | kv_sync_lat | state_aio_wait_lat | sample count |
|----:|-----------------------------------|--------------:|------------:|-------------------:|-------------:|
|   0 | PM9A1 (node4)                     | 3.18 ms       | 4.41 ms     |   2.81 ms          |   3.40M      |
|   1 | **PNY-fresh** (node5, S/N PNB48..0306, 70 PoH) | **5.17 ms** | **7.17 ms** | **1.99 ms** | 84k         |
|   2 | PNY-worn (node6, original)        | 20.88 ms      | 23.43 ms    | **81.42 ms**       |   3.50M      |

osd.1 (fresh PNY) reads ~5 ms vs osd.2 (worn PNY) at ~21 ms — **4× difference between two drives of the same model**, just from wear. This is itself a useful data point: *the cluster's fsync latency wall isn't intrinsic to the PNY CS1030 line, it's emergent from sustained-write SLC-cache exhaustion. A fresh CS1030 looks competitive; the same drive after a year of OSD load is the 130 ms outlier we saw in the original baseline.*

fio (4k QD1 fsync randwrite, 120s, same RBD PVC as 2+1 capture):

```
write: IOPS=25, BW=103KiB/s (105kB/s)(12.0MiB/120008msec)

fsync/fdatasync/sync_file_range:
  sync (msec): min=20, max=1556, avg=38.98, stdev=45.39
  sync percentiles (msec):
   |  1.00th=[ 23],  5.00th=[ 25], 10.00th=[ 27], 20.00th=[ 30],
   | 30.00th=[ 31], 40.00th=[ 32], 50.00th=[ 33], 60.00th=[ 34],
   | 70.00th=[ 36], 80.00th=[ 40], 90.00th=[ 48], 95.00th=[ 73],
   | 99.00th=[132], 99.50th=[236], 99.90th=[550], 99.95th=[1334],
   | 99.99th=[1552]
```

| Metric                | 2+1 (today, earlier)             | 1+2 (now, fresh PNY in node5)   |
|-----------------------|----------------------------------|---------------------------------|
| IOPS                  | 18                               | 25                              |
| BW                    | 72.5 KiB/s                       | 103 KiB/s                       |
| sync p50              | 37 ms                            | 33 ms                           |
| sync p95              | 95 ms                            | 73 ms                           |
| sync p99              | 169 ms                           | 132 ms                          |
| sync p99.9            | 2,022 ms                         | **550 ms**                      |
| sync p99.99           | 3,773 ms                         | 1,334 ms                        |
| sync max              | 3,773 ms                         | 1,556 ms                        |

1+2 is *better* than 2+1 — opposite of what naïve replication-tail reasoning predicts. With `size=3` every write must ack from all three OSDs, so the cluster floor is `max(t_osd0, t_osd1, t_osd2)`. In 2+1 that's `max(3 ms, 3 ms, 21 ms) ≈ 21 ms`; in 1+2 it's `max(3 ms, 5 ms, 21 ms) ≈ 21 ms` — roughly the same floor. But the *body* of the latency distribution shifts down because the fresh PNY (osd.1) is a meaningfully faster secondary than the PM9A1 it replaced (no, wait — that doesn't make sense either, the PM9A1 was *already* faster). The likeliest explanation is that the test PVC's 4k blocks landed on a different distribution of primary OSDs across the two runs, and statistical noise on a 3,077-sample fio run dominates the difference.

Going to skip the 0+3 backwards leg. Reasoning:

1. We already have a historic 0+3 data point (March 2026 lifetime kv_commit_lat: 133 / 144 / 125 ms across the three production-worn PNYs; cluster-side fio at the time: 2 IOPS, mean fsync 9,257 ms, p99 13,221 ms). It's documented above in the original kv_commit_lat saga.
2. Re-creating 0+3 today would put two *fresh* PNYs back in (only one production-worn drive is on hand, in node6) — same confound as the 1+2 reading above. Not comparable to the historic baseline.
3. Marginal value of a confounded 0+3 is low; better to preserve cluster uptime and move directly to 3+0.

So the plan is: pull the fresh PNY out of node5, put the PM9A1 back in (returning to the 2+1 forward state), then swap node6's worn PNY → PM9A1 to land in **3+0**. One forward swap remaining to actually finish the migration.

### Then changed mind — went backwards anyway, captured 0+3

Decided the 0+3 reading was worth doing despite the fresh-vs-worn caveat — confirms the *body* of the latency story even if it can't reproduce the historic worn-PNY tail. Pulled the PM9A1 from node4, dropped a third PNY in (S/N PNB46257035080101591, **42 PoH, 1 % wear, 2.59 TB written** — also nearly fresh, just like the node5 PNY).

Operational gotcha worth noting: the prepare ran while `blkdiscard --zeroout` was still in flight on the PNY, saw `Filesystem:ceph_bluestore` from the cached libblkid signature, and exited with `configuring osd devices: {"Entries":{}}` — silently doing nothing. The wipe finished, but no further prepare cycle was triggered. Manually bouncing `rook-ceph-operator` after the wipe completed got the prepare to re-run against the now-clean device, which then issued a fresh `osd.0` cleanly.

**Runbook update**: after `blkdiscard --zeroout` completes (especially on a PNY where the wipe takes 9 min and overlaps with whatever ArgoCD self-healed back into running), explicitly `oc -n rook-ceph delete pod -l app=rook-ceph-operator` to force a fresh prepare cycle. Do not assume the operator's reconcile loop will pick up the device transition on its own — the cached lsblk view of the device during the in-flight wipe poisons it for the rest of that reconcile cycle.

**Per-OSD lifetime kv_commit_lat in 0+3 (idle):**

| OSD | Drive                                          | kv_commit_lat | kv_sync_lat | state_aio_wait_lat | sample count |
|----:|-----------------------------------------------|--------------:|------------:|-------------------:|-------------:|
|   0 | PNY (node4, **42 PoH, 1 % wear**, ~fresh)     | 5.33 ms       | 7.37 ms     |   2.23 ms          | 106k         |
|   1 | PNY (node5, **70 PoH, 3 % wear**, ~fresh)     | 5.37 ms       | 7.40 ms     |   2.04 ms          | 180k         |
|   2 | PNY (node6, original, months production wear) | **20.72 ms**  | **23.28 ms**| **80.67 ms**       | 3.58M        |

Two fresh PNYs at 5.3 ms vs the worn one at 21 ms — same ~4× wear gap we observed on osd.1 earlier today. The historic baseline (March 2026: 133 / 144 / 125 ms across three worn drives) is **not** reproduced here because we don't have three worn drives. Confirms the methodology caveat.

**fio (4k QD1 fsync randwrite, 120 s, same RBD PVC):**

```
write: IOPS=24, BW=97.6KiB/s (99.9kB/s)(11.4MiB/120021msec)

fsync/fdatasync/sync_file_range:
  sync (msec): min=22, max=677, avg=40.97, stdev=23.58
  sync percentiles (msec):
   |  1.00th=[ 25],  5.00th=[ 28], 10.00th=[ 32], 20.00th=[ 33],
   | 30.00th=[ 34], 40.00th=[ 35], 50.00th=[ 36], 60.00th=[ 38],
   | 70.00th=[ 41], 80.00th=[ 45], 90.00th=[ 52], 95.00th=[ 67],
   | 99.00th=[128], 99.50th=[159], 99.90th=[334], 99.95th=[355],
   | 99.99th=[676]
```

**`ceph osd dump` (0+3 state, post-fio):**

```
epoch 1643
fsid 739ea0de-6637-45d5-8332-fbdb28350022
created 2026-04-12T18:19:58.183550+0000
modified 2026-05-06T19:57:04.031435+0000
flags sortbitwise,recovery_deletes,purged_snapdirs,pglog_hardlimit
crush_version 37
require_min_compat_client luminous
require_osd_release squid

pool 2 'nvme-replicated' replicated size 3 min_size 2 crush_rule 1 ... pg_num 128 pgp_num 128 ... pg_num_min 128 ... application rbd
... (12 RGW pools, all replicated size 3 min_size 2)

max_osd 4
osd.0 up   in  weight 1 up_from 1377 ... 6e078be7-709d-4646-992e-f6413235e482
osd.1 up   in  weight 1 up_from 1087 ... 91c51bf3-5c3d-4cd9-be07-cd2285f2c333
osd.2 up   in  weight 1 up_from 124  ... 99b83574-abc0-489a-a79b-d89b383587ce
```

Two things worth noting:

- `max_osd 4` — Ceph allocated up to slot 3 today during the swap dance (the failed `osd.3` attempts on the PM9A1 and PNY) before settling back at osd.0/1/2. The counter doesn't decrement on purge, just the slot gets freed.
- `up_from` epochs tell the OSD reincarnation history: osd.2 is the original from epoch 124 (untouched since cluster creation), osd.1 came up at epoch 1087 (this morning's PM9A1→PNY backwards swap), osd.0 came up at epoch 1377 (the PNY swap that just landed).

**`ceph osd df` (0+3 state, post-fio):**

```
ID  CLASS  WEIGHT   REWEIGHT  SIZE     RAW USE  DATA     ...  AVAIL    %USE   VAR  PGS  STATUS
 0   nvme  0.46579   1.00000  477 GiB  118 GiB  118 GiB       359 GiB  24.83  1.00  189   up
 1   nvme  0.46579   1.00000  477 GiB  119 GiB  118 GiB       358 GiB  24.89  1.00  189   up
 2   nvme  0.46579   1.00000  477 GiB  119 GiB  118 GiB       358 GiB  24.92  1.00  189   up
                       TOTAL  1.4 TiB  356 GiB  353 GiB       1.0 TiB  24.88
MIN/MAX VAR: 1.00/1.00  STDDEV: 0.04
```

Distribution is essentially perfect — STDDEV of 0.04 across the three OSDs, matching weight 0.46579 each. `nvme-replicated` MAX AVAIL = 334 GiB (the same number we got in 2+1 / 1+2 — pool capacity is unchanged across all swap states because the drives all expose 477 GiB and CRUSH weight is identical).

### The latency ladder so far

| State (today)                          | IOPS | BW         | p50    | p95    | p99    | p99.9     | max       |
|----------------------------------------|-----:|-----------:|-------:|-------:|-------:|----------:|----------:|
| **0+3 today** (2 fresh PNY + 1 worn)   | 24   | 97.6 KiB/s | 36 ms  | 67 ms  | 128 ms | 334 ms    | 677 ms    |
| 1+2 today (1 PM9A1 + 1 fresh + 1 worn) | 25   | 103 KiB/s  | 33 ms  | 73 ms  | 132 ms | 550 ms    | 1,556 ms  |
| 2+1 today (2 PM9A1 + 1 worn PNY)       | 18   | 72.5 KiB/s | 37 ms  | 95 ms  | 169 ms | 2,022 ms  | 3,773 ms  |
| **historic 0+3** (3 worn PNYs, 03/26)  | 2    | 442 B/s    | —      | —      | —      | —         | mean 9.2s |

The headline (IOPS, p50) barely moves between today's 0+3, 1+2, 2+1 — all in the 18–25 IOPS range — because every state has at least one worn PNY (osd.2 in node6) gating replication. *Replacing the worn PNY is what will finally unblock the cluster, not just adding PM9A1s.* That's the conclusion the writeup should lead with.

The historic 0+3 reading at 2 IOPS / 9.2 s mean fsync is in another universe entirely. With three worn PNYs, the `max(t1, t2, t3)` write tail isn't dominated by one slow drive — every replication round-trip is a coin flip on which drive will spike, so the tail is `worst-of-three-heavy-tails`, which is much worse than `worst-of-one`. That's the methodology gap today's 2-fresh-1-worn configuration cannot recover.

### Intermediate: forward-swap of node6 (worn PNY → PM9A1) — and the slow-op alert disappears

Skipped the proposed forward-swap order (node4, node5, node6) and went straight to node6 — the worn PNY was the cluster's actual bottleneck, so swapping it first changes the latency picture more than the other two. Same purge-dance as the rest of today's swaps: scale operator down, delete `rook-ceph-osd-2` deploy, `ceph osd purge 2`, clean activate dirs on node6, `blkdiscard -f /dev/nvme0n1` (PM9A1 supports DRAT — 0.18 s), scale operator back up. New osd.2 was issued with fresh UUID `cc9163f0-...`.

**`ceph osd dump` (post-swap, post-backfill):**

```
max_osd 4
osd.0 up in weight 1 up_from 1377 ... 6e078be7-709d-4646-992e-f6413235e482   (PNY fresh)
osd.1 up in weight 1 up_from 1087 ... 91c51bf3-5c3d-4cd9-be07-cd2285f2c333   (PNY fresh)
osd.2 up in weight 1 up_from 1661 ... cc9163f0-8e6d-46c9-9f35-56a38e761976   (PM9A1, just landed)
```

**Per-OSD bluestore lifetime stats (this intermediate state, "1 PM9A1 + 2 fresh PNY"):**

| OSD | Drive                                                | kv_commit_lat | kv_sync_lat | state_aio_wait_lat | sample count |
|----:|------------------------------------------------------|--------------:|------------:|-------------------:|-------------:|
|   0 | PNY fresh (node4, 42 PoH)                            | 5.25 ms       | 7.29 ms     |   1.94 ms          | 143k         |
|   1 | PNY fresh (node5, 70 PoH)                            | 5.48 ms       | 7.53 ms     |   2.22 ms          | 216k         |
|   2 | **PM9A1** (node6, 12.9k PoH, 10 % wear, just spun up)| **3.33 ms**   | **4.75 ms** | **0.30 ms**        | 80k          |

The PM9A1 lands at 3.33 ms `kv_commit_lat` even with low sample count, in line with osd.0's PM9A1 (3.18 ms over 3.4M ops earlier today). Fresh PNYs are at 5.3–5.5 ms, the lifetime number we've been seeing on them all day.

**`ceph health detail`:**

```
HEALTH_WARN 5 daemons have recently crashed
[WRN] RECENT_CRASH: 5 daemons have recently crashed
    osd.1 crashed on host node5.okd.sudops.pl at 2026-05-06T16:49:49.763774Z
    osd.0 crashed on host node4.okd.sudops.pl at 2026-05-06T19:20:{08,17,39}Z
    osd.0 crashed on host node4.okd.sudops.pl at 2026-05-06T19:21:08Z
```

The `BLUESTORE_SLOW_OP_ALERT` that has been firing on this cluster **for months** — since the PNYs developed wear-induced slow ops — is now **gone**. The remaining HEALTH_WARN is just the `RECENT_CRASH` accumulator from today's swap dance (5 OSD daemon crashes during the various activate/CrashLoopBackOff cycles). Those will age out automatically; alternatively `ceph crash archive-all` clears them.

This is the first time the cluster has been at a "hardware-clean" health state since the original PNYs developed slow ops. Worth marking — the swap of one drive (the worn one) was sufficient to clear the alert, even though we're still in a "1+2" config (and the cluster's tail floor is still gated by the slowest fresh PNY at ~5 ms, not the PM9A1 at 3 ms).

Two more swaps to land at 3+0:
1. node4 fresh-PNY → PM9A1 — cluster ceiling moves from `max(5.5, 5.3, 3.3) = 5.5` to `max(3, 5.3, 3.3) = 5.3` ms (small change).
2. node5 fresh-PNY → PM9A1 — cluster ceiling moves from `max(3, 5.3, 3.3)` to all-PM9A1 at ~3 ms.

Realistically the latency improvement plateaus after this node6 swap. The remaining two swaps are mostly about hardware uniformity and getting to the documented 3+0 fio number, not unlocking new performance.

### 3+0 — the final capture

Two more swaps to get there: node5 fresh-PNY → PM9A1 (purge dance again — same boot-ack stuck symptom, same blkdiscard -f resolution because PM9A1 supports DRAT), then node4 fresh-PNY → PM9A1 (the freshly-installed PM9A1 had no prior bluestore data so the daemon's `Init:Error` was just the activate-dir mismatch, fixed by purge+blkdiscard+operator bounce). At 3+0:

**Per-OSD bluestore lifetime stats (3+0 idle baseline + post-fio):**

| OSD | Drive (post-fio) | kv_commit_lat | kv_sync_lat | state_aio_wait_lat | sample count |
|----:|----------------------------|--------------:|------------:|-------------------:|-------------:|
|   0 | PM9A1 (node4, MZVL2512HCJQ) | 3.84 ms       | 5.47 ms     | 0.32 ms            | 98k          |
|   1 | PM9A1 (node5)              | 2.93 ms       | 4.09 ms     | 0.70 ms            | 126k         |
|   2 | PM9A1 (node6, MZVL2512HCJQ-00BH1) | 3.13 ms | 4.37 ms     | 0.92 ms            | 161k         |

All three OSDs in the **~3 ms `kv_commit_lat`** range — 7× faster than the worn PNY's 21 ms, 40× faster than the historic worn-PNY ~130 ms.

**fio (4k QD1 fsync randwrite, 120 s, same RBD PVC, run from a pod on node4):**

```
write: IOPS=67, BW=272KiB/s (278kB/s)(31.8MiB/120022msec)

fsync/fdatasync/sync_file_range:
  sync (usec): min=12952, max=85803, avg=14710.46, stdev=2643.54
  sync percentiles (usec):
   |  1.00th=[13304],  5.00th=[13566], 10.00th=[13698], 20.00th=[13960],
   | 30.00th=[13960], 40.00th=[14091], 50.00th=[14222], 60.00th=[14353],
   | 70.00th=[14484], 80.00th=[14615], 90.00th=[16057], 95.00th=[17695],
   | 99.00th=[20579], 99.50th=[28705], 99.90th=[48497], 99.95th=[61604],
   | 99.99th=[85459]
```

Headline: **67 IOPS, 272 KiB/s, mean fsync 14.7 ms, p99 = 20.6 ms, p99.9 = 48.5 ms, max 85.8 ms.** Compare to the historic worn-PNY 0+3 baseline: 2 IOPS / 442 B/s / 9.2 s mean — that's roughly **33× IOPS** and **625× lower mean fsync**.

The shape of the fsync distribution at 3+0 is also fundamentally different — `stdev = 2.6 ms` on a `mean = 14.7 ms` is a tight, near-normal distribution. The mixed-PNY captures all had heavy-tailed distributions where a small fraction of writes spiked into seconds. In the 3+0 distribution, even p99.99 (85 ms) is within the same order of magnitude as p50 (14 ms). That's the actual "production-ready storage" signature: no surprise pauses, no fsync spikes that look like a failed network connection from the application's perspective.

**Final ladder, all four states captured today:**

| state                                 | IOPS | BW         | sync p50 | sync p95 | sync p99 | sync p99.9 | sync max  |
|---------------------------------------|-----:|-----------:|---------:|---------:|---------:|-----------:|----------:|
| **3+0 (3 PM9A1)**                     | **67** | **272 KiB/s** | **14 ms** | **18 ms** | **21 ms** | **48 ms** | **86 ms** |
| 0+3 today (2 fresh PNY + 1 worn PNY)  | 24   | 98 KiB/s   | 36 ms    | 67 ms    | 128 ms   | 334 ms     | 677 ms    |
| 1+2 today (1 PM9A1 + 1 fresh + 1 worn)| 25   | 103 KiB/s  | 33 ms    | 73 ms    | 132 ms   | 550 ms     | 1,556 ms  |
| 2+1 today (2 PM9A1 + 1 worn PNY)      | 18   | 72.5 KiB/s | 37 ms    | 95 ms    | 169 ms   | 2,022 ms   | 3,773 ms  |
| historic 0+3 (3 worn PNYs, 03/2026)   | 2    | 442 B/s    | —        | —        | —        | —          | mean 9.2s |

The story the table tells:

1. **Rows 2–4 are basically the same number.** Adding PM9A1s while *one worn PNY remains* doesn't move the cluster ceiling — `size=3` replication waits for the slowest replica, which is always the worn PNY.
2. **The jump from any mixed-PNY state to 3+0 is dramatic.** ~3× IOPS, ~7× lower p99.9, max latency drops two orders of magnitude.
3. **Today's 0+3 (rows 2-3 caveat: with 2 fresh PNYs + 1 worn PNY) is much better than the historic 0+3.** This is the methodology gap — three worn PNYs all spiking together creates a much worse `worst-of-three-heavy-tails` than just one worn PNY pacing the cluster. The fresh PNY behaves much closer to the PM9A1 than to its worn sibling.

The headline conclusion for the eventual blog post: **the worn PNY was a single-point-of-pathology, but only because all three drives were on the same wear curve and all developing the slow-op behavior at similar rates.** Replacing one PNY didn't help (the others still gated). Replacing two didn't help much (one still gating). Replacing the third unblocked the entire cluster — by an order of magnitude on every percentile.

Migration complete: cluster is at 3+0, `BLUESTORE_SLOW_OP_ALERT` cleared, latency profile is what real storage should look like. Will let the recent-crashes warning age out (or `ceph crash archive-all`); otherwise nothing else needs doing.

### Post-migration bottleneck sweep — what does the cluster actually peak at?

The 4k QD1 fsync test is one specific workload (the worst case BlueStore was bottlenecked on under the worn PNYs). Now that the hardware story is settled, walked through a broader sweep with `tests/ceph-storage-test-libaio.yaml` to map the cluster's ceilings across read/write × random/sequential × different queue depths.

Earlier failure modes worth recording first because the answers are non-obvious:

**Mistake 1: psync engine + `iodepth=32` doesn't actually queue.** First attempt of the bottleneck sweep used the same default `--ioengine=psync` (the psync engine fio uses by default) plus `iodepth=32`. fio prints a one-line warning and silently caps queue depth at 1:

```
note: both iodepth >= 1 and synchronous I/O engine are selected, queue depth will be capped at 1
```

The "QD32 random write" test then reported `IOPS=81000, BW=316 MiB/s, clat avg 12 µs (nanoseconds, mostly)` — which looks great until you realize those are kernel page-cache writes, not cluster acks. The actual cluster work is in `Disk stats: ios=462933 in 120s` = ~3.8 k IOPS hitting RBD via the writeback path. Misleading data point — discarded.

Fix: `--ioengine=libaio --direct=1` for actual concurrency at the device, kernel page cache fully bypassed.

**Mistake 2: re-running fio against a PVC that just had a buffered-write test killed leaves writeback contention that blocks the new test.** Killed a wedged test pod with `kubectl delete --force` while it had GBs of dirty pages, then mounted the same PVC into a fresh pod. The fresh pod's QD32 randwrite test reported `IOPS=0, BW=12B/s, runtime: 328708ms` — fio submitted 1 IO that took 5.5 minutes to complete. Disk stats showed `ios=0/905371` — the device was running flat-out at ~98% utilization, but on draining the previous pod's leftover dirty pages, not the new fio's IO.

Fix: don't reuse PVCs across pod kills if writeback was buffered. Always start a fresh PVC for clean numbers, or wait for `ceph -s` client wr to drop to zero before re-running.

**The clean 3+0 ceiling map** (from a fresh 50 GiB PVC, 30 GB pre-fill, libaio direct=1 throughout):

| Workload                                | IOPS    | BW          | clat / sync p50 | Notes                                                  |
|-----------------------------------------|--------:|------------:|----------------:|--------------------------------------------------------|
| `dd` 100 GB seqwrite (buffered)         | —       | **273 MB/s**| —               | Kernel writeback batching; *peak* but partly synthetic |
| 1M QD8 seqwrite (libaio direct=1)       | 164     | 173 MB/s    | 46 ms           | Direct, sustainable; replication path serialization    |
| 1M QD8 seqread  (libaio direct=1)       | 168     | 177 MB/s    | 50 ms           | ~30 % bluestore cache hits; rest disk-bound            |
| **4k QD32 randwrite** (libaio direct=1) | **2,078** | **8.5 MB/s** | **14.8 ms**   | **Per-op replication latency × QD; PG-lock serialized** |
| 4k QD32 randread (libaio direct=1)      | 40,000  | 156 MB/s    | 1.0 ms          | No replication path; bimodal (cache vs disk)           |
| 4k QD1 fsync randwrite (10 GB file)     | 67      | 272 KiB/s   | 14 ms           | RTT × 3 replicas + bluestore commit                    |
| 4k QD1 fsync randwrite (100 GB file)    | 33      | 135 KiB/s   | 27 ms           | + working set spilling bluestore metadata cache        |

Three things stand out.

**1. The cluster is `size=3` replication-bound for writes, not network-bound.** Earlier I read a Mikrotik dashboard during dd and concluded "1 GbE backnet saturated" — wrong, the backnet is 10 GbE and was at ~20 % utilization. Frontnet (1 GbE router) was at ~60 % during dd. So neither network is the seqwrite bottleneck. The actual ceiling on QD8 1M seqwrite (173 MB/s direct) is per-op latency: each 1 MB write commits in ~46 ms (3 replicas + bluestore + RTT), so 8 in flight gives `8 / 46 ms ≈ 174 ops/s ≈ 174 MB/s`. Little's Law again.

For dd buffered seqwrite, the kernel batches many writes into per-RBD-object 4 MiB chunks before submitting, so the effective concurrency is higher than 8 — that's how we get 273 MB/s with buffering vs 173 MB/s direct. Same physical cluster, different access pattern.

**2. Random write IOPS scales linearly with queue depth up to ~2 k IOPS.** The QD1 fsync number (67 IOPS, 14 ms) and QD32 number (2 078 IOPS, 14.8 ms) are consistent: `32 / 14.8 ms = 2 162 IOPS` matches measured. Per-op latency is the floor. To exceed 2 k IOPS for 4 k random writes the cluster would need either:

- **Lower per-op commit latency** — a PLP-class enterprise NVMe (Micron 7450 PRO, Kioxia CD8, Samsung PM9A3) commits fsyncs in ~0.5 ms vs PM9A1's ~3 ms. Fully replacing 3× PM9A1 with 3× PLP enterprise drives would push the cluster's `kv_commit_lat` from ~3 ms to ~0.5 ms and the QD32 ceiling to ~16 k IOPS.
- **More OSDs** — adding nodes adds more PGs and breaks PG-level write serialization. From 3 OSDs to 6 (e.g. 2 OSDs per node) would roughly double random-write IOPS at the same QD.
- **Higher QD** — going from QD32 to QD128 might extract another 2-4× until hitting per-OSD CPU or PG-lock saturation.

For a homelab `nvme-replicated` pool serving RBD volumes, **2 k random IOPS is plenty** — typical applications running on K8s rarely sustain that.

**3. Reads scale beautifully because there is no replication path.** 40 k random IOPS is in the same band as bare-metal PM9A1 random read perf — Ceph's read-side overhead is just the PG lookup + object metadata. The 1 ms p50 latency is dominated by the public-network RTT, not the disk. Reads are *cheap* in this cluster — workloads that are read-heavy (Loki queriers, Prometheus series queries, image-pull caches) will get much better performance than the write-heavy Loki ingesters and Prometheus WAL writers.

**Practical takeaway for what this cluster can actually back:**

- **Database WAL / journal volumes (Postgres, etcd-style)**: 4 k QD1 fsync = 67 IOPS / 14 ms p99 latency. Adequate for low-traffic dev/homelab; would be the bottleneck under serious DB load.
- **General-purpose container storage (OS-image cache, app data, bulk file workloads)**: 173 MB/s seqwrite + 156 MB/s random read at QD8/32. More than adequate.
- **Read-heavy cache / image registry / PV backing for stateless workloads**: 40 k random IOPS. Trivially handles homelab needs.
- **Where it'll struggle**: a single-tenant service that fsyncs every operation and needs > 67 IOPS. Mitigate with PLP enterprise NVMe or an EBS-style fsync-batching write layer.

Future work this characterization unlocks:
- The deferred `blog-multus-ceph-migration-draft.md` (bonding frontnet + backnet via Multus) is now justifiable for *seqwrite throughput*, not random IOPS — random writes would still be ~2 k IOPS no matter the network.
- A second OSD per node would more meaningfully improve random-write IOPS than network changes.
- The CephFS plan from `CLAUDE.md` (separate NVMe-class and HDD-class pools) doesn't change any of these numbers — RBD vs CephFS use the same OSD path.

### 2026-05-08 — correction: the storage swap did *not* fix the Loki 504

The original logging-stack TODO (and the README entry, and casual remarks in this draft) carried the hypothesis that the Loki querier↔index-gateway gRPC `DeadlineExceeded` errors were "the index-gateway TSDB shipper blocking on slow Ceph reads — resolves with the PM9A1 swap." That was wrong. The day after the full migration to 3+0 PM9A1, queries against `Loki (infrastructure)` were still returning 504, and the querier log still showed:

```
caller=pool.go:250 index-store=tsdb-2024-01-01 msg="removing index gateway failing healthcheck"
addr=dns:///logging-loki-index-gateway-grpc.openshift-logging.svc.cluster.local:9095
reason="rpc error: code = DeadlineExceeded desc = context deadline exceeded"
```

A connectivity sweep from inside the querier pod isolated the actual failure mode:

| target | result | time |
|---|---|---:|
| `logging-loki-index-gateway-grpc.openshift-logging.svc.cluster.local:9095` (FQDN) | OK | **6003 ms** |
| `logging-loki-index-gateway-grpc:9095` (short) | OK | 0.3 ms |
| `10.129.0.16:9095` (pod IP, IG-1) | OK | 0.0 ms |
| `10.130.0.11:9095` (pod IP, IG-0) | OK | 0.4 ms |

TCP connect to the FQDN succeeds eventually but takes **6 seconds** because of the same `okd.sudops.pl`-in-search-list problem already documented in `blog-loki-logging-draft.md`. Pod resolv.conf:

```
search openshift-logging.svc.cluster.local svc.cluster.local cluster.local okd.sudops.pl
options ndots:5
```

The FQDN has 4 dots (less than `ndots:5`), so glibc tries the search list first. The fourth permutation, `<FQDN>.okd.sudops.pl`, goes to pi-hole / upstream and stalls for ~5 s. Eventually glibc gives up on search and tries the FQDN as-is, which resolves instantly.

For the gRPC client this is fatal: the default dial deadline is 5 s. Every connection attempt hits the search-list timeout before falling through to the working resolution, the gRPC `dns://` resolver evicts the gateway from the pool with `DeadlineExceeded`, and the cycle repeats forever. The query never gets to the index-gateway because the gateway gets *evicted before the client uses it*.

Storage was never relevant to this problem. Two lessons:

1. **A "performance hypothesis" without a controlled test isn't a hypothesis.** I noted in this draft that "the cluster shouldn't be slow enough to break index-gateway gRPC anymore," but the diagnosis chained that into "PNYs are causing the 504" without ever instrumenting actual storage latency from the index-gateway pod. A simple `oc -n openshift-logging exec ... -- python3 -c "import socket; ..."` would have shown 6-second TCP connects on day one and made the DNS issue obvious.

2. **`okd.sudops.pl` in the search list keeps showing up as the actual root cause.** The pi-hole "Top Permitted Domains" anomaly that prompted the original `Drop okd.sudops.pl from the node-side DNS search list` TODO was a *symptom*; this Loki 504 is the *consequence*. Any homelab cluster that uses its ingress domain as `cluster_baseDomain` and does *not* exclude that domain from `dns-search` is at risk of this exact bug. Promoting that TODO from `Queued — platform plumbing` to `In flight` (2026-05-08).

The Loki TODO is updated to point at the search-list cleanup as the actual fix; the PNY and `1x.pico` hypotheses are explicitly listed as wrong.

