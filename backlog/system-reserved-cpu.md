# Reserve CPU for system processes

Measurement and design for a CPU `systemReserved` on the kubelet config; not built. The README TODO keeps a short summary of the item and links here.

**Reserve CPU for system processes: `systemReserved` covers memory only (found 2026-11-02).** `components/cluster-config/kubelet-config/` sets `systemReserved.memory: 3Gi` and no CPU, so CPU stays at the 500m default (allocatable 15.5 of 16). Measured from kubelet stats on 2026-11-02 at 21:12Z, at minimum clock: non-pod CPU 2.29 / 1.69 / 1.62 cores on node4/5/6, non-pod memory 1.9 / 0.9 / 3.0 GiB, so memory is covered and CPU is not.

**Costs:** requests on node4/5 are 13.8 and 13.7 cores, so reserving 2 cores leaves 14 allocatable at about 98 %, with `KubeCPUOvercommit` already firing and no drain headroom; removing logging first frees about 3.4 cores each on those two. It is a KubeletConfig, so a full MCO reroll: run it together with step 2 of "Stop the catalog image churn" so both cost one reroll, never during an OADP build or soak.

**What it does not do:** as I read kubelet's cgroup setup (not measured), a reservation changes scheduler accounting and barely moves CPU weight under contention, so it does not stop one busy pod; a pod's own CPU limit does (`okd-build`'s is 14 of 16). Validate: `network-change` pre-flight; allocatable reads as set; no Pending pods after the reroll; etcd WAL fsync p99 and API read p99 on each node before and after. `node_pressure_cpu_waiting_seconds_total` returned no series on 2026-11-02, so CPU pressure is not available as a check.
