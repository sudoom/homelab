# Graceful cluster shutdown — vacation procedure

Working draft. Captures the pre-shutdown sequence and the return runbook for a hyperconverged 3-node Ceph+OKD cluster, where the standard `oc adm drain` doesn't apply (no headroom for pods to land elsewhere). Tested 2026-05-29.

## Framing

`oc adm drain` is the wrong tool for this cluster. Every node is both a control-plane master AND a worker AND a Ceph OSD host. There's nowhere for evicted workloads to go. The right procedure is to put the cluster into a maintenance posture, cordon nodes (informational only, since nothing can move), and shut down the OS on each.

The two state mutations that matter are:

1. **Ceph maintenance flags** — `noout`, `nobackfill`, `norecover`, `norebalance`. Without `noout`, the first node down triggers Ceph's 10-min OSD-out timer → CRUSH starts trying to rebalance against 0 available targets → bad state on power-up.
2. **ArgoCD auto-sync paused** — so it doesn't fight any drift while the cluster is being brought back up.

Everything else (cordon, schedule pause, etcd order) is hygiene.

## Pre-shutdown sequence (2026-05-29 run)

```bash
# 1. Fresh OADP backup so last-known-good state lives in RGW (which also goes down,
#    but the metadata is captured for if anything fails to come back).
cat <<EOF | oc apply -f -
apiVersion: velero.io/v1
kind: Backup
metadata:
  name: pre-shutdown-$(date -u +%Y%m%d-%H%M%S)
  namespace: openshift-adp
spec:
  storageLocation: default
  ttl: 720h0m0s          # 30 days
  snapshotMoveData: false
  includeClusterResources: true
EOF

# 2. Pause the OADP daily Schedule (else it fires at 02:00 UTC while the cluster
#    is down → cron-backoff cascade on first power-up).
oc -n openshift-adp patch schedule daily --type=merge -p '{"spec":{"paused":true}}'

# 3. Set Ceph maintenance flags.
for f in noout nobackfill norecover norebalance; do
  oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd set $f
done
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s   # verify "flags noout,nobackfill,norebalance,norecover"

# 4. Pause ArgoCD root-app auto-sync.
oc -n openshift-gitops patch application root-app \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":null}}}'

# 5. Cordon all 3 nodes (informational — pods can't move anyway).
for n in node4 node5 node6; do oc adm cordon ${n}.okd.sudops.pl; done
```

## OS-level shutdown (must be done from a workstation with SSH access)

```bash
ssh core@node6.okd.sudops.pl 'sudo systemctl poweroff'
sleep 30
ssh core@node5.okd.sudops.pl 'sudo systemctl poweroff'
sleep 30
ssh core@node4.okd.sudops.pl 'sudo systemctl poweroff'
```

Order is `node6 → node5 → node4`. Etcd quorum stays at 3 → 2 → 1 → 0 with ~30s between transitions; cleaner than all three losing the API simultaneously. node4 last because the API VIP usually lands there.

Wait ~2 min after the last `poweroff` returns before pulling wall power — OS needs to flush + sync.

## Return-from-vacation runbook

**Critical sequencing**: steps 3–6 below MUST run before `oc login` is even possible. The cluster comes up with expired kubelet client certs (machine-approver doesn't auto-approve `node-bootstrapper` CSRs on bare-metal-without-Machine-API) AND broken pod→service-IP egress on at least one node. Both must be fixed via the on-node `localhost-recovery.kubeconfig` channel before OAuth pods are reachable.

```bash
# 1. Power on all 3 nodes (any order — etcd forms quorum once 2 are up).

# 2. Wait for SSH on node4.
until ssh core@node4.okd.sudops.pl true; do sleep 10; done

# 3. Verify nodes Ready via readonly kubeconfig (no oc login yet).
KUBECONFIG=~/.kube/config-readonly oc get nodes
# expect: 3 × Ready,SchedulingDisabled

# 4. Approve kubelet client CSR backlog (multiple rounds — kubelets keep rotating).
#    Uses the per-node localhost-recovery kubeconfig (cert-based admin, no oauth dependency).
ssh core@node4.okd.sudops.pl 'sudo bash -c "
  export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
  for i in 1 2 3 4 5 6; do
    n=\$(oc get csr -o name | wc -l)
    oc get csr -o name | xargs -r oc adm certificate approve >/dev/null 2>&1
    echo \"round \$i: approved \$n\"
    sleep 15
  done
"'
# expect: rounds 1-2 approve hundreds, later rounds taper to ~0

# 5. Second pass — approves the kubelet-SERVING CSRs that appeared after step 4
#    (kubelet can only request serving cert renewal once it has a valid client cert).
ssh core@node4.okd.sudops.pl 'sudo bash -c "
  export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
  oc get csr -o name | xargs -r oc adm certificate approve
"'
# Verify: no Pending CSRs remain.
KUBECONFIG=~/.kube/config-readonly oc get csr | awk 'NR>1 && $NF=="Pending"' | wc -l   # expect 0

# 6. Verify apps VIP is now claimable (keepalived's health probe needs kubelet:10250 TLS).
ping -c 2 192.168.1.241          # expect 0% loss
curl -sk -o /dev/null -w 'http=%{http_code}\n' https://console-openshift-console.apps.okd.sudops.pl/   # expect 200

# 7. Restart ovnkube-node pods to fix pod→service-IP egress (cascade-runbook fallout).
#    Without this, freshly-scheduled pods fail to reach 172.30.0.1:443 → OAuth pods crashloop.
ssh core@node4.okd.sudops.pl 'sudo bash -c "
  export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
  for p in \$(oc -n openshift-ovn-kubernetes get pods -l app=ovnkube-node -o name); do
    oc -n openshift-ovn-kubernetes delete \$p
    sleep 45
  done
  # Delete any oauth pods still in CrashLoopBackOff after ovnkube-node restart.
  oc -n openshift-authentication get pods --field-selector=status.phase!=Running -o name | xargs -r oc -n openshift-authentication delete
"'

# 8. Re-login via the web console "Copy login command" — works now that OAuth is healthy.
oc login --token=<new-token> --server=https://api.okd.sudops.pl:6443

# 9. Uncordon.
for n in node4 node5 node6; do oc adm uncordon ${n}.okd.sudops.pl; done

# 10. Clear Ceph maintenance flags.
for f in noout nobackfill norecover norebalance; do
  oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd unset $f
done

# 11. Wait for Ceph HEALTH_OK or HEALTH_WARN with only BLUESTORE_SLOW_OP_ALERT (+
#     OSD_BACKFILLFULL until the HDD tier ships).
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph -s

# 12. Re-enable ArgoCD auto-sync.
oc -n openshift-gitops patch application root-app \
  --type=merge -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'

# 13. Un-pause OADP Schedule.
oc -n openshift-adp patch schedule daily --type=merge -p '{"spec":{"paused":false}}'

# 14. Standard start-of-session sweep per CLAUDE.md to confirm clean recovery.
#     Expect 3 transient Degraded OLM-backed apps (BundleUnpackFailed) — self-heal
#     once the community-operators catalog pod finishes rolling.
```

## What we learned this run (shutdown — 2026-05-29)

- **`PartiallyFailed` on the pre-shutdown backup is expected** because of the NFS-CSI snapshot mismatch. Velero tries to take a CSI snapshot of `media/media-data-pvc` (provisioned by `nfs.csi.k8s.io`), fails because there's no `VolumeSnapshotClass` labelled `velero.io/csi-volumesnapshot-class` for the NFS-CSI driver. NFS is a file-share, not a block device — no native snapshot support. All 29 actual Ceph-RBD CSI snapshots completed. The error is logged, the rest of the backup succeeds.
- **Recoverable from RGW for 30 days.** The `ttl: 720h` on the pre-shutdown backup keeps it well past any reasonable vacation length.
- **`automated: null` is the SSA-safe way to pause sync.** `automated: {}` doesn't disable it (empty struct still means "automated enabled with defaults"); `null` removes the field entirely.

## What we learned this run (return — 2026-06-08, 10-day vacation)

The runbook as originally written was incomplete. Step 3 said "Re-login (oc token will be expired)" — but `oc login` itself isn't possible until OAuth is healthy, and OAuth wasn't healthy. Two unplanned recovery passes were required before the runbook's "normal" steps could even start:

- **Kubelet client cert backlog (~270 Pending CSRs).** All from `system:serviceaccount:openshift-machine-config-operator:node-bootstrapper`. Machine-approver auto-approves CSRs from machine-controller-managed nodes; on this bare-metal cluster the BMHs are `unmanaged`/`externallyProvisioned` so there are no Machine objects, and these CSRs sit Pending forever. Before vacation the cluster had been up 65+ days continuously — cert rotation never needed to happen mid-uptime; the very first boot-time rotation hit this gotcha. Recovery: SSH into a control-plane node, use the static `localhost-recovery.kubeconfig`, run `oc adm certificate approve` in a 6-round loop because new CSRs keep being generated as each kubelet rotates client + serving certs separately. Once stable, no Pending CSRs remain.
- **Apps VIP `192.168.1.241` unclaimed until kubelet TLS recovers.** Keepalived's health probe hits `:10250` on kubelet over TLS. When the kubelet serving cert was unrenewable (chicken-and-egg: serving cert renewal needs valid client cert), every probe returned `tls: internal error`, no node entered MASTER state for VRRP, VIP was unowned, console was unreachable. The fix was the CSR approval loop above — VIP claimed itself within ~10s of kubelet TLS recovery (visible in keepalived log as `Sending gratuitous ARP on br-ex for 192.168.1.241`).
- **OAuth crashloop from broken pod→service-IP egress.** One of three `oauth-openshift` pods (the one on node4) crashlooped with `dial tcp 172.30.0.1:443: i/o timeout` trying to fetch the `extension-apiserver-authentication` ConfigMap. This is exactly the cascade-runbook scenario from CLAUDE.md: post-MCO-or-power-event, ovnkube-node pods need a serial restart to restore pod→host-network egress. Same recovery: SSH into node4, use `localhost-recovery.kubeconfig`, restart all 3 ovnkube-node pods with 45s gaps, then delete the crashing oauth pod so it reschedules with clean OVN plumbing. After that, web console served logins, normal `oc login --token=...` worked.
- **Pod RESTARTS counter in `oc get pods` is misleading after a power cycle.** Many pods showed `RESTARTS=0` and `AGE=10d` despite a clean OS shutdown. The pod's `creationTimestamp` survives in etcd; whether the container restart counter increments depends on kubelet's container-state reconciliation logic on boot. Don't use RESTARTS=0 as evidence that a shutdown didn't happen — check kubelet log timestamps or `journalctl -u kubelet` on a node.
- **`BLUESTORE_SLOW_OP_ALERT` returned on osd.1.** Previously cleared after the PM9A1 swap (per CLAUDE.md). Worth a follow-up — maybe replication amplification at 93% capacity is enough to re-trip the threshold, in which case it'll clear when the HDD tier offloads bulk data.
- **3 OLM-backed apps go Degraded with `BundleUnpackFailed` mid-recovery.** `cluster-logging-operator`, `cnpg-operator`, `loki-operator` all hit the same race: OLM Subscription tries to resolve before the `community-operators` catalog pod has finished initializing. Self-heals once the catalog pod is Running. Not a blocker, just expected transient.

## Open items (post-vacation)

- Either ship a `VolumeSnapshotClass` for `nfs.csi.k8s.io` (probably with `csi.storage.k8s.io/snapshotter-secret-name` pointing at the Synology DSM creds, since DSM does support snapshots for shares) OR exclude NFS-backed PVCs from CSI snapshot consideration in the Schedule spec via `snapshotVolumes: false` for those PVCs. Lower priority — the data lives on Synology and is durable independent of Ceph.
- Document the BMC/IPMI auto-power-on settings (if any) — current shutdown requires SSH + `systemctl poweroff`; if BMC could auto-resume on AC restore, that's a simpler "kick the breaker" model for power-cut scenarios.
- **Pre-stage a CSR auto-approver for `node-bootstrapper` CSRs on cluster boot.** The 6-round CSR loop is reliable but manual. Options: (a) a one-shot Job that runs at boot via an OLM operator like `kubelet-serving-cert-approver`, (b) a Helm chart that ships an MCO unit/script to handle this on the node side. Caveat: any auto-approver has security implications — `node-bootstrapper` CSRs being auto-approved means anyone with the bootstrap token can join arbitrary nodes. Today's manual approval is actually a security feature.
- **Investigate why `BLUESTORE_SLOW_OP_ALERT` came back on osd.1.** Was clear post-PM9A1 swap; reappeared after vacation. Capacity (93% full) is the likely trigger but worth confirming with `ceph daemon osd.1 dump_blocked_ops` and `ceph daemon osd.1 perf dump` once cluster settles.
