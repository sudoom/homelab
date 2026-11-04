# Rook v1.19.5 -> v1.21.1 and Ceph Squid -> Tentacle: upgrade runbook

Staged upgrade of the storage stack (Rook v1.19.5 -> v1.20.9 -> v1.21.1, Ceph Squid 19.2.4 -> Tentacle 20.2.5,
msgr2 required in its own stage). This directory holds the read-only instruments every stage uses to decide whether
it went well, plus the CSI smoke test. The design record goes to `blog/blog-rook-ceph-draft.md`; every storage
action is logged there with the exact command and the output that drove the decision.

Stages: B (backup), M (baseline measurements), 1 (Rook v1.20.9), 2 (Rook v1.21.1), 3 (msgr2), 4 (Ceph Tentacle).

## Gates (before Stage B and before every stage commit)

- [ ] OADP and descheduler soaks finished
- [ ] Freeze holding since the baseline: no in-cluster builds, no MachineConfig reroll, no logging removal, no power-tuning change
- [ ] Ceph HEALTH_WARN with only `BLUESTORE_SLOW_OP_ALERT`
- [ ] PGs active+clean
- [ ] No MCP updating; no node cordoned
- [ ] CNPG `ContinuousArchiving=True` on media, immich and homebox
- [ ] Not Monday 19:00-23:00Z (descheduler operand roll; next Monday is 2026-11-09)
- [ ] 2 h headroom; quiet IO
- [ ] The stage's images `IMAGE OK` through zot, and zot's free space read after

## Scripts (`verify/`)

| Script | Who runs it | What it does |
|---|---|---|
| `csi-state.sh --expect stage0..stage4` | controller, readonly kubeconfig | One `CHECK PASS\|FAIL <name> <observed>` line per check, an `INFO driver-uid=... driver-generation=... cephx=...` line, exit 0 only if all pass. `KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage0` |
| `ceph-reads.sh <label>` | the operator (it needs `oc exec` into `deploy/rook-ceph-tools`) | Captures versions, health, df, osd tree, mon dump, cipher, osd flags, msgr config, the CSI user's caps and entity/type list. CephX keys are stripped by jq; if anything key-shaped remains the file is deleted and the script exits 2. |
| `images-check.sh <image>...` | controller (needs `zot.apps.okd.sudops.pl`) | Maps each ref onto zot by dropping the registry host and runs `skopeo inspect --raw`. Prints `IMAGE OK\|MISSING <ref>`, exit non-zero on any MISSING. A manifest request makes zot fetch the image, so it also pre-pulls: measure zot's free space after. |

`ceph-latency.sh` (operator-run, `metrics/`) writes `-` in the `p99` column for every row: all its metrics are per-OSD
latency counters or gauges without histogram buckets, so there is no honest p99; read the `avg` column.

Evidence goes to `.superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/` and is never committed (gitignored
tree); result rows are copied into the blog draft instead.

## CSI smoke test (`smoke/`)

Run before and after each stage. Apply and delete are the controller's, one permission prompt per command.

1. `namespace.yaml` -> namespace `rook-upgrade-smoke`
2. `pvc.yaml` -> PVC `smoke` (1Gi, `ceph-nvme-block`)
3. `pod.yaml` -> Pod `smoke-writer`: writes 64 MiB random data plus its sha256, prints `SMOKE written sha256=...`
4. `snapshot.yaml` -> VolumeSnapshot `smoke-snap` (class `ceph-rbd-snapshot`); wait for `readyToUse`
5. `restore-pvc.yaml` -> PVC `smoke-restore` from the snapshot
6. `restore-pod.yaml` -> Pod `smoke-reader`: prints `SMOKE restored sha256=<recomputed> stored=<stored>`

Pass = the writer's sum, the reader's recomputed sum and the reader's stored sum are all equal. Then delete the
namespace (`oc delete namespace rook-upgrade-smoke`) and confirm the PVs and RBD images are gone.

## Stage B: backup

One-off OADP 1.6 (Velero v1.18.4, Kopia data mover) backup of the app PVCs to the garage bucket (BSL
`truenas-garage`), proven by one restore. Manifests in `backup/`. Apply and delete are the controller's, one
permission prompt per command; the `!` lines are the operator's. Read the Velero kinds in full:
`backups.velero.io`, `restores.velero.io`, `datauploads.velero.io`, `datadownloads.velero.io` (`oc get backup`
resolves to CNPG's kind).

**Gates.** The list above, except that Stage B waits for the OADP soak and drill cleanup, not for the descheduler
soak (that one gates the stage commits and the baseline). Also: Schedule `daily` stays paused; do it in quiet hours
(the Kopia upload reads every Ceph PVC in scope).

**Scope** (2026-11-03): `grafana`, `homebox`, `immich`, `keepers`, `media`, `zot`; about 166 GiB of PVC requests
(grafana 1, homebox 5, immich 20, keepers 2, media 88, zot 50). CNPG volumes ride along in `homebox`, `immich` and
`media`. Snapshots are crash-consistent and the apps are not quiesced (accepted).

**Free space (operator).** Read the garage dataset's free space on the NAS and compare it with the 166 GiB scope:
`ssh truenas_admin@192.168.1.25 'zfs list -o name,used,avail tank/s3'`. Kopia compresses and dedups, so 166 GiB is the
ceiling; stop if avail is under it.

### Volume policy: every non-Ceph PV is skipped

`volume-policy.yaml` carries two `skip` rules (`nfs: {}` and `csi: {driver: nfs.csi.k8s.io}`), `version: v1`. Read
2026-11-03 from the PVs bound in the six namespaces (readonly kubeconfig): the four non-Ceph volumes are all CSI NFS
PVs (none uses the in-tree `nfs` source, so only the second rule matches them); every other bound PVC is
`rook-ceph.rbd.csi.ceph.com` / `ceph-nvme-block` and is backed up.

| ns/pvc | csi.driver | nfs.server (csi volumeAttributes) | storageClassName | matched by |
|---|---|---|---|---|
| immich/immich-library | nfs.csi.k8s.io | 192.168.1.2 | nfs-csi | csi rule |
| immich/immich-library-nfs | nfs.csi.k8s.io | 192.168.10.10 | (empty, static PV) | csi rule |
| keepers/keepers-data-nfs | nfs.csi.k8s.io | 192.168.10.10 | (empty, static PV) | csi rule |
| media/media-data-nfs-pvc | nfs.csi.k8s.io | 192.168.10.10 | (empty, static PV) | csi rule |

The other 18 PVCs are Ceph RBD and in scope: grafana-pvc; homebox-data, homebox-postgres-1, homebox-postgres-2;
immich-postgres-1, immich-postgres-2; transmission-config-pvc, webtlo-data-pvc (keepers); bazarr, jellyfin, prowlarr,
radarr, sonarr, transmission and transmission-slave config PVCs plus media-postgres-1 and media-postgres-3 (media);
data-zot-0. The expected DataUpload count is 18 (re-count with the command below before applying; the 2026-11-03 text said 17,
a miscount of this same list, corrected 2026-11-04).
`grafana-pvc` is backed up but mounted by no pod (Grafana uses an emptyDir), so it is not the restore check.
`immich-library` (nfs-csi, 192.168.1.2) is a leftover dynamic PVC; it is skipped like the rest.

```bash
KUBECONFIG=~/.kube/config-readonly oc get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.storageClassName}{"\n"}{end}' | grep -E '^(grafana|homebox|immich|keepers|media|zot)/' | grep -c ceph-nvme-block   # 18
```

**Velero docs checked (v1.18).** Volume policy syntax (`version: v1`, `nfs: {}`, `csi: {driver: ...}`, actions
`skip|snapshot|fs-backup`, Backup `spec.resourcePolicy: {kind: configmap, name: ...}`):
https://velero.io/docs/v1.18/resource-filtering/ (that page shows the CLI flag `--resource-policies-configmap` and
names no ConfigMap data key; `policy.yaml` is our choice, the doc's example creates it from a file). The page does
not say that `skip` also covers the CSI-snapshot / data-mover path; that it does is from the Velero 1.14+ release
notes, not shown in a 1.18 page. The table above is therefore also what you verify after the Backup: no DataUpload
may exist for an NFS PVC.
Data-mover restore: https://velero.io/docs/v1.18/csi-snapshot-data-movement/ says the CSI plugin, per PVC, "checks the
backup information, if a data movement was involved, it creates a `DataDownload` CR". The page does not address a
PVC-only restore explicitly, but the trigger is the PVC item plus the backup's data-movement record, so
`includedResources: [persistentvolumeclaims]` should run the DataDownload; the pass criteria below confirm it
(if the PVC stays Pending with no DataDownload, read the Restore's `status.warnings` first, then add only the
kinds the logs name, still mapped into `rook-upgrade-restore`).

### Order

1. Baseline bucket size (operator, `tests/oadp-1.6-drill/README.md` "Bucket size"); note bytes and objects.
2. `volume-policy.yaml` -> ConfigMap `pre-rook-upgrade-policy` (ns `openshift-adp`).
3. `backup.yaml` -> Backup `pre-rook-upgrade`. Watch:
   `oc -n openshift-adp get backups.velero.io pre-rook-upgrade -o jsonpath='{.status.phase} errors={.status.errors} warnings={.status.warnings}{"\n"}'`
   and `oc -n openshift-adp get datauploads.velero.io -l velero.io/backup-name=pre-rook-upgrade`. Note
   `.status.startTimestamp`.
4. Bucket size again about a minute after `Completed`: it must have grown.
5. `restore-namespace.yaml`, then `restore-check.yaml` -> Restore `pre-rook-upgrade-check` (keepers PVCs only);
   watch `restores.velero.io` and `datadownloads.velero.io` until `Completed`. `webtlo-data-pvc` and
   `transmission-config-pvc` are Bound in `rook-upgrade-restore`. The restore also creates `keepers-data-nfs` there;
   it **stays Pending by design** (its PV `truenas-keepers-data` is a static NFS PV bound to the live claim, and the
   volume policy skipped it). Ignore it, never mount it; it is deleted with the namespace. A Restore that ends
   `PartiallyFailed` only because of that claim: read `status.warnings`/`errors` and report, do not retry.
6. `checker-pod.yaml` -> Pod `restore-checker` (mounts the two restored Ceph PVCs read-write and writes nothing: the
   live pods run as root, so the files are root-owned, and kubelet grants the pod's `fsGroup` only on writable mounts;
   the first run, read-only, got `cd: /mnt/webtlo: Permission denied`, 2026-11-04);
   `oc -n rook-upgrade-restore logs restore-checker > restored.txt` prints `sha256  size  mtime  path` per file in
   sections `CHECK begin webtlo|transmission` ... `CHECK end ...`. Any `ERROR` line is a FAIL (a file or a volume
   root could not be read). A subdirectory that cannot be entered is skipped by globstar without an `ERROR` line; the
   equal-line-count criterion against the live list (Pass criteria) is what catches that.
7. Operator, the same list inside the live pods (read-only `oc exec`). Mounts read 2026-11-03: pod `webtlo-*`,
   container `webtlo`, `webtlo-data-pvc` at `/data`; pod `transmission-*`, container `transmission`,
   `transmission-config-pvc` at `/config` (`keepers-data-nfs` is also mounted at `/data` there; do not list it).

```bash
# OPERATOR
live_list() { oc -n keepers exec "$1" -c "$2" -- sh -c "cd $3 && find . -type f | sed 's|^\./||' | LC_ALL=C sort | while IFS= read -r f; do sum=\$(sha256sum \"\$f\") || { echo \"ERROR \$f\"; continue; }; echo \"\${sum%% *}  \$(stat -c '%s  %Y' \"\$f\")  \$f\"; done"; }
live_list "$(oc -n keepers get pods -o name | grep '/webtlo-')" webtlo /data > webtlo-live.txt
live_list "$(oc -n keepers get pods -o name | grep '/transmission-')" transmission /config > transmission-live.txt
```

   If a live image lacks `find`/`stat`/`sha256sum`, say so and the controller adapts the one-liner.
8. Compare only files whose mtime predates the Backup's `status.startTimestamp` (apps write after the snapshot, and
   those files differ legitimately). `START` = the startTimestamp in epoch seconds
   (`date -u -j -f %Y-%m-%dT%H:%M:%SZ <ts> +%s` on macOS). Per PVC (`vol` = `webtlo` or `transmission`; the
   restored section is the lines between `CHECK begin vol` and `CHECK end vol`):
   `awk -v s="$START" '$3 < s' vol-live.txt > vol-live.cmp`, the same on the restored section into
   `vol-restored.cmp`, then `wc -l vol-live.cmp vol-restored.cmp` and `diff vol-live.cmp vol-restored.cmp`.
9. Cleanup (controller): delete the Restore, then `oc delete namespace rook-upgrade-restore` and confirm both PVs
   and RBD images are gone. The Backup stays (ttl 720h) as the pre-upgrade fallback.

### Pass criteria

- Backup `Completed`, `status.errors` 0 (note warnings).
- One DataUpload `Completed` per Ceph PVC in scope (18), none for an NFS PVC.
- Bucket bytes and objects grew.
- Restore: DataDownloads `Completed` for `webtlo-data-pvc` and `transmission-config-pvc`; no `ERROR` line in the
  checker log.
- Compare counts: per PVC the live and restored `.cmp` line counts are equal, and the total over both PVCs is at
  least 1. A diff of two empty files is not a pass.
- `diff` is empty for both PVCs (every sha256, size and mtime equal).

**Stop rules.** Any mismatch on a file older than the Backup's `status.startTimestamp` is a FAIL: Stage B stops and is
reported to the operator (no retry, no pass). An empty compare set (total 0) is also a stop-and-report; there is no
automatic fallback PVC.

## Stage M: baseline

(empty)

## Stage 1: Rook v1.20.9

Operator and cluster wrapper go to v1.20.9 and the CSI driver config moves to `ceph-csi-drivers` 1.0.4 (new service
accounts, Driver `rook-ceph.rbd.csi.ceph.com`). Ceph stays Squid, `requireMsgr2: false` stays explicit. Patches are in
`.superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/patches/`; the controller applies, commits and pushes each one
in the operator's window. Run the gates (list above) first.

**Commit order** (one patch, one commit, in this order):

| # | Patch | Content |
|---|---|---|
| 1 | `s1-c1a-pins` | explicit `cephClusterSpec.network.connections.requireMsgr2: false` and `upgradeOSDRequiresHealthyPGs: true` in the cluster `values.yaml`; expected to roll no daemon |
| 2 | `s1-c1b-driver-protect` | `argocd.argoproj.io/sync-options: Delete=false,Prune=false` on the Driver in `csi-driver-config` |
| 3 | `s1-c1c-prunelast` | root-app `extraSyncOptions`: `PruneLast=true` on `rook-ceph-operator`, `FailOnSharedResource=true` on `csi-driver-config` |
| 4 | `s1-c2-operator-hop` | operator chart to v1.20.9 (the hop) |
| 5 | `s1-c3-cluster-chart` | cluster wrapper to v1.20.9 |
| 6 | `s1-c4-legacy-cleanup` | remove the legacy CSI resources, only after c2 and c3 verify |

Before each push the controller runs `git apply --check` on the patch, re-renders the chart from the applied patch
(`helm dependency build`, `helm template`, kubeconform) and runs `oc diff` against live; a diff that differs from the
render evidence stops the push. Every render passes `--api-versions security.openshift.io/v1` (without it the charts
drop their SCCs), and the diff runs with `-n rook-ceph`: the `ceph-csi-drivers` Roles and RoleBindings render with no
namespace, and ArgoCD puts them in `rook-ceph`.

```bash
# CONTROLLER, from the applied patch (operator wrapper shown; the cluster wrapper is the same with its own path)
find components/operators/rook-ceph/charts -name '*.tgz' -delete
helm dependency build components/operators/rook-ceph
helm template rook-ceph-operator components/operators/rook-ceph/ -n rook-ceph \
  -f components/operators/rook-ceph/values.yaml --api-versions security.openshift.io/v1 --kube-version 1.35.5 \
  | oc diff -n rook-ceph -f -
```

**Window start.** At the start of every window (c2, c3 and each stage-2 commit) the controller records the UTC time
before pushing, in the evidence tree (never committed), and every "newer than the window start" check below reads it:

```bash
# CONTROLLER, immediately before the push
date -u +%Y-%m-%dT%H:%M:%SZ | tee .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/window-start.txt
# in each later check:
WINDOW_START="$(cat .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/window-start.txt)"
```

**Pre-hop state (c1a-c1c done).** Record before c2:

```bash
# CONTROLLER (readonly)
KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage0   # RESULT PASS stage0
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get pods -l app=rook-ceph-osd-prepare   # note state/age
KUBECONFIG=~/.kube/config-readonly oc get pods -A -l cnpg.io/cluster -o custom-columns='NS:.metadata.namespace,POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,START:.status.startTime'   # save to compare
```

Run the smoke sequence (above) once and the Events command below; keep both outputs as the baseline.
(c1a should roll no daemon; if any mon, mgr or OSD pod restarts after it, stop and report before c2.)

The v1.20.9 chart sets `ROOK_DELETE_UNUSED_CRUSH_RULES=true` in `rook-ceph-operator-config`, so the new operator deletes
CRUSH rules no pool uses once its mgr is up. The operator records the rules and each pool's rule before c2:

```bash
# OPERATOR (exec), before the c2 push; repeat after c2 (verify item 9)
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd crush rule ls
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool ls detail | grep -o "^pool [0-9]* '[^']*'.*crush_rule [0-9]*"
```

**Verify after c2 and again after c3** (every item must hold):

1. `KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage1` -> every
   line `CHECK PASS`, last line `RESULT PASS stage1`, exit 0. Note `driver-generation` on the `INFO` line.
2. The same command ten minutes later: `RESULT PASS stage1` again and `driver-generation` unchanged (a moving
   generation means something keeps rewriting the Driver spec).
3. Smoke sequence PASS (writer, reader recomputed and reader stored sums equal), then delete the namespace and
   confirm the PV and RBD image are gone.
4. No `FailedMount` or `FailedAttachVolume` event anywhere with a `lastTimestamp` at or after the window start.
   Expected: both counts `0`.

```bash
# CONTROLLER (readonly)
WINDOW_START="$(cat .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/window-start.txt)"
for reason in FailedMount FailedAttachVolume; do
  echo "$reason since $WINDOW_START: $(KUBECONFIG=~/.kube/config-readonly oc get events -A --field-selector reason=$reason -o json \
    | jq --arg s "$WINDOW_START" '[.items[] | select((.series.lastObservedTime // .lastTimestamp // .eventTime // .metadata.creationTimestamp) >= $s)] | length')"
done
```

5. CNPG pods not restarted by the hop: rerun the pre-hop CNPG command; `RESTARTS` equal to the saved values and no
   `START` after the window start.
6. OSD prepare pods are `Completed` on node4, node5 and node6 and were started after the window start (at v1.20.8+
   they run on the host network; a `Completed` pod from before the hop proves nothing):

```bash
# CONTROLLER (readonly)
WINDOW_START="$(cat .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/window-start.txt)"
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get pods -l app=rook-ceph-osd-prepare \
  -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.phase}{"\t"}{.spec.nodeName}{"\t"}{.status.startTime}{"\n"}{end}' \
  | awk -F'\t' -v s="$WINDOW_START" '{print $0 "\t" ($4 >= s ? "NEW" : "STALE")}'
```

   Expected: three rows, phase `Succeeded` (shown as `Completed`), nodes node4, node5, node6, last column `NEW` on all
   three. Any `STALE` row means the prepare job has not re-run since the push: wait and re-read, and do not pass the
   item until all three are `NEW`.
7. Operator: `bash tests/rook-ceph-upgrade/verify/ceph-reads.sh s1` (after c3). Expected: `0 reads failed`; in the
   `ceph auth get client.csi-rbd-provisioner.1` section the caps equal the caps-fix Job's set
   (`components/storage/rook-ceph-cluster/templates/csi-rbd-provisioner-caps-fix.yaml`): `mgr` = `allow rw`,
   `mon` = `profile rbd, allow command 'osd blocklist'`, `osd` = `profile rbd`. Compare:
   `grep -A12 'ceph auth get client.csi-rbd-provisioner.1' "$(ls -t .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/ceph-reads-s1-*.txt | head -1)"`
   (the newest `s1` capture; in zsh the glob has a match once the script has run).
   Any other set (for example no `osd` cap) is a FAIL.
8. Exactly one Driver: `KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get drivers.csi.ceph.io` lists only
   `rook-ceph.rbd.csi.ceph.com` (the drivers chart has cephfs, nfs and nvmeof off; a second Driver means a value did
   not take).
9. Operator: rerun the two CRUSH reads from the pre-hop state. Every pool keeps its `crush_rule` number, and any rule
   missing from `ceph osd crush rule ls` is one no pool referenced before c2. Anything else is a FAIL.

Between the c2 push and root-app deleting it, the `csi-driver-config` Application can show a failed sync
(`FailOnSharedResource`: the Driver already carries rook-ceph-operator's tracking id). That is expected and is what
stops it re-applying a hostNetwork-only Driver over the drivers chart's. It must disappear once root-app has synced;
if the Application is still there after that, stop and report.

**Lasting protection (after c2 verifies).** ArgoCD's adoption of the Driver by rook-ceph-operator drops the
`Delete=false,Prune=false` annotation that `csi-driver-config` had set (one field manager, `argocd-controller`, for every
app, and the drivers chart has no annotations hook). Put it back by hand so it is owned by a different field manager
(`kubectl-annotate`) and survives ArgoCD's applies:

```bash
# CONTROLLER (prompted), once items 1-9 pass after c2
oc -n rook-ceph annotate drivers.csi.ceph.io rook-ceph.rbd.csi.ceph.com argocd.argoproj.io/sync-options=Delete=false,Prune=false --overwrite
# right after the annotate, and again once c4 has synced (c4 changes the operator chart, so it is a real ArgoCD
# apply over the Driver; rook-ceph-operator does not sync again until its manifests change):
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get drivers.csi.ceph.io rook-ceph.rbd.csi.ceph.com \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}{"\n"}{range .metadata.managedFields[*]}{.manager}{" "}{end}{"\n"}'
```

Expected, both times: `Delete=false,Prune=false`, and `kubectl-annotate` among the managers. Without the annotation,
any later commit that takes the Driver out of the operator render (a revert, a chart change) prunes it with foreground
propagation, which deletes the plugin Deployment and DaemonSet it owns and livelocks the deletion
(`bugs/upstream-ceph-csi-operator-reconciles-terminating-driver.md`). `--overwrite` keeps the command working if the
old annotation is still there; it is an annotation the Driver should carry either way.

c4 goes only after c2 and c3 pass items 1-9 and the read right after the annotate shows the lasting protection; after
c4 has synced, rerun that read (the annotation must survive c4's apply), `csi-state.sh --expect stage1` and the smoke
sequence.

**Recovery.** Only if CSI mounts break and do not recover within 30 minutes of focused work. Never a plain revert of
c2 or c3: a revert takes the Driver, the new service accounts, their RBAC and their SCC grant out of the operator render
while plugin pods still run under them, and PruneLast then deletes them (the Driver with foreground propagation, which
also deletes the plugin Deployment and DaemonSet). The recovery is a forward commit, `s1-recovery.patch`, for two
states. Post-c3 (c1a..c3 on master): a plain apply. Post-c2 with c3 not pushed: apply it with
`--exclude='components/storage/*'`, because c3 only touches `components/storage/` and the cluster chart is still
v1.19.5 with c1a's pins (the result renders byte-identical to the post-c3 recovery). After c4 it does not apply: stop
and re-dispatch. It puts both Rook charts back to v1.19.5 with master's values (c1a's pins stay), brings
`csi-driver-config` back without `FailOnSharedResource` (after the rollback the Driver still carries
rook-ceph-operator's tracking id, which that app never releases, so `csi-driver-config` must take the Driver over to
restore ctrlplugin hostNetwork), and adds a temporary `templates/csi-rollback-rbac.yaml` that keeps the new pair
`rook-ceph-rbd-csi-ceph-com-{ctrl,node}plugin-sa`, its RBAC and its SCC grant until the plugins have rolled back to the
old pair. Render evidence: `work/renders/s1-recovery-checks.txt` (R9 for the post-c2 apply).

Before the push (controller):

```bash
# 1. The Driver must carry the hand-applied protection (lasting-protection read above). If it does not
#    (recovery before c2 verified), run the prompted annotate from "Lasting protection" first: the recovery
#    takes the Driver out of the operator render, and only Prune=false on the live object stops the prune.
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get drivers.csi.ceph.io rook-ceph.rbd.csi.ceph.com \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}{"\n"}'          # Delete=false,Prune=false
# 2. The recovery also prunes the OperatorConfig and the image-set ConfigMap (the v1.19.5 chart does not render
#    them; Rook v1.19.5 recreates both at runtime). A missing OperatorConfig makes ceph-csi-operator reconcile the
#    Driver without defaults (built-in images, no priority classes: an extra plugin roll); a missing image-set
#    ConfigMap stalls the reconcile. Hold both (prompted):
oc -n rook-ceph annotate operatorconfigs.csi.ceph.io/ceph-csi-operator-config configmap/rook-csi-operator-image-set-configmap argocd.argoproj.io/sync-options=Prune=false --overwrite
# 3. The recovery prunes CRD cephobjectstoreaccounts.ceph.rook.io (new in the v1.20.9 render). Expect no resources:
KUBECONFIG=~/.kube/config-readonly oc get cephobjectstoreaccounts.ceph.rook.io -A
```

Then, post-c3: `git apply --check s1-recovery.patch` and `git apply s1-recovery.patch`; post-c2 with c3 not pushed:
`git apply --check --exclude='components/storage/*' s1-recovery.patch` and the same apply with the exclude. Commit,
push. The operator downgrade rolls the Ceph daemons again, one OSD at a time, so treat it as another degraded window.
That holds even if a v1.20.9 cluster chart never ran: Rook's upgrade guide says an operator version change updates all
Ceph daemons, and the OSD pod template runs an init container from the operator's own image (`osd/spec.go@v1.19.5`), so
a different operator image changes it. The 2026-06-12 revert v1.20.0 -> v1.19.5 (both charts, `49406f5`) rolled all
OSDs (`blog/blog-rook-ceph-draft.md`, 2026-06-12).
rook-ceph-operator then stays OutOfSync for the objects held by `Prune=false`; that is expected until the follow-up.

Verify after the recovery (all must hold):

1. `KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage0` -> `RESULT PASS
   stage0` once the plugins have rolled back (old service accounts on every plugin pod, no service account names on the
   Driver, ctrlplugin hostNetwork, csi-snapshotter present, cephcsi v3.16.2, operator v1.19.5).
2. Smoke sequence PASS.
3. No plugin pod under the new pair:
   `KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get pods -o jsonpath='{range .items[*]}{.spec.serviceAccountName}{"\n"}{end}' | grep -c rook-ceph-rbd-csi-ceph-com`
   -> `0`.

Follow-up, once item 3 reads `0`: one commit that deletes
`components/operators/rook-ceph/templates/csi-rollback-rbac.yaml`; then (prompted) drop rook-ceph-operator's tracking id
from the two held objects so that app returns to Synced:
`oc -n rook-ceph annotate operatorconfigs.csi.ceph.io/ceph-csi-operator-config configmap/rook-csi-operator-image-set-configmap argocd.argoproj.io/tracking-id-`.
The Driver keeps its annotation; `csi-driver-config` tracks it again.

## Stage 2: Rook v1.21.1

Operator and cluster wrapper go to v1.21.1 with `ceph-csi-drivers` 1.1.0; Rook now creates the CephConnection and
ClientProfile (`ROOK_CREATE_CSI_OPERATOR_RESOURCES=true`). Ceph still Squid, `requireMsgr2: false` still explicit.
Patches `s2-c2-operator` then `s2-c3-cluster`, same shape as stage 1: the controller re-renders from the applied
patch and runs `oc diff` before each push. Gates first, and stage 1 verified and settled.

**Verify after c2 and again after c3:**

1. `KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage2` -> all
   `CHECK PASS`, `RESULT PASS stage2`, exit 0. This includes `rook-operator-image` `docker.io/rook/ceph:v1.21.1`,
   cephcsi `v3.18.1`, `operator-config-CREATE_CSI_OPERATOR_RESOURCES` `true`, and `cephconnection-exists` and
   `clientprofile-exists` both `rook-ceph`. Note `driver-generation`.
2. The same command ten minutes later: `RESULT PASS stage2`, `driver-generation` unchanged.
3. CephConnection and ClientProfile present:
   `KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get cephconnections.csi.ceph.io,clientprofiles.csi.ceph.io`
   -> one `rook-ceph` row in each.
4. Smoke sequence PASS, then delete the namespace and confirm the PV and RBD image are gone.
5. No `FailedMount` or `FailedAttachVolume` since the window start (record `window-start.txt` before each push; Events
   command in Stage 1 item 4; both counts `0`).
6. CNPG pods not restarted (Stage 1 pre-hop CNPG command: `RESTARTS` unchanged, no `START` at or after
   `$WINDOW_START`).
7. OSD prepare pods `Completed` on node4, node5, node6, all `NEW` against `$WINDOW_START` (Stage 1 item 6 command).
8. Operator: `bash tests/rook-ceph-upgrade/verify/ceph-reads.sh s2` -> `0 reads failed`, the provisioner caps still
   `mgr allow rw` / `mon profile rbd, allow command 'osd blocklist'` / `osd profile rbd`.

**Recovery.** After the 30-minute cap, revert c2 and c3 together to the stage-1 end state (v1.20.9, `ceph-csi-drivers`
1.0.4). Never revert only one.

## Stage 3: msgr2

Sets `cephClusterSpec.network.connections.requireMsgr2: true` (CRC mode, no encryption, CSI keys stay `aes`). Mons
and OSDs roll, and the CSI config moves from `:6789` to `:3300`. Gates first, and stage 2 settled. This is a full
roll of the three-OSD cluster: a degraded window, one OSD-impacting change at a time.

**Pre-reads (before the change):**

```bash
# OPERATOR
bash tests/rook-ceph-upgrade/verify/ceph-reads.sh pre-s3
# per node: list the nodeplugin pods, then read the RBD devices each one has mapped
oc -n rook-ceph get pods -l app=rook-ceph.rbd.csi.ceph.com-nodeplugin -o wide
oc -n rook-ceph exec <nodeplugin pod> -c csi-rbdplugin -- sh -c 'cat /sys/bus/rbd/devices/*/config_info'
```

Run the `exec` once per nodeplugin pod (three pods, one per node; a node with no mapped RBD prints a `No such file`
error from the glob, which is expected there). Save the output (one line per mapped
device; it holds the mon addresses and the pool, no key). Before the change the mons read `:6789` (v1) and there is no
`ms_mode`.

```bash
# CONTROLLER (readonly): CSI config before the change (informational baseline)
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get cm ceph-csi-config -o jsonpath='{.data.config\.json}' | jq -c '[.[]?.monitors[]?]'
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get cephconnections.csi.ceph.io rook-ceph -o jsonpath='{.spec.monitors}{"\n"}'
```

`ceph-csi-config` `config.json` (owned by the Driver) and the CephConnection are the sources of truth;
`rook-ceph-mon-endpoints` keeps `:6789` for existing mons and is INFO only.

**Verify after the roll completes:**

1. `KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage3` -> all
   `CHECK PASS`, `RESULT PASS stage3`; in particular `cephconnection-monitors-3300` and
   `ceph-csi-config-monitors-3300` both read `all:3300 (3)` (every monitor ends in `:3300`). The `INFO
   rook-ceph-mon-endpoints-csi-monitors` line may still show `:6789`; that is expected.
2. Operator: `bash tests/rook-ceph-upgrade/verify/ceph-reads.sh s3`. In the `ceph config dump | grep ...` section
   `rbd_default_map_options` reads `ms_mode=prefer-crc`:
   `grep rbd_default_map_options "$(ls -t .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/ceph-reads-s3-*.txt | head -1)"`.
3. A freshly mapped volume uses msgr2: run the smoke sequence (new PVC and pod), then the operator reads the
   mapping on the node that runs `smoke-writer` (find it with `oc -n rook-upgrade-smoke get pod smoke-writer -o wide`
   and the nodeplugin pod on that node):
   `oc -n rook-ceph exec <nodeplugin pod> -c csi-rbdplugin -- sh -c 'cat /sys/bus/rbd/devices/*/config_info'`
   -> the smoke volume's line shows `:3300` and `ms_mode=prefer-crc`. Volumes mapped before the roll keep their old
   mapping until the pod is rescheduled; that is not a failure.
4. No `FailedMount` or `FailedAttachVolume` since the window start (record `window-start.txt` before the push; Events
   command in Stage 1 item 4; both counts `0`).
5. Health is back to the standing WARN (only `BLUESTORE_SLOW_OP_ALERT`) and PGs are `active+clean`, both in the
   `ceph health detail` and `ceph -s` sections of the `s3` capture.
6. Delete the smoke namespace and confirm the PV and RBD image are gone.

**Recovery.** After the 30-minute cap set `requireMsgr2: false` again in git; that is another full roll of mons and
OSDs, so allow the same degraded window.

## Stage 4: Ceph Tentacle 20.2.5

Ceph goes from Squid 19.2.4 to Tentacle 20.2.5 (`quay.io/ceph/ceph:v20.2.5-20261028`, five pins) with the CephX daemon
key rotation in the same commit. Rook is already v1.21.1 and msgr2 is required (stages 2 and 3 settled). Patches come
from Task 13: `work/patches/s4-c1-rook-module-off.patch` (c1) and `work/patches/s4-c2-tentacle.patch` (c2). The
controller applies, renders, runs `oc diff` and pushes each one after the operator says go; the `!` lines are the
operator's.

### Step 1: point of no return

**The c2 push is the point of no return.** Once the first mon restarts on 20.2.5 there is no documented downgrade from
Tentacle; recovery is fix forward only. Everything before c2 is reversible (c1 by reverting it, `noautoscale` by
unsetting it); nothing after the first mon restart is. Do not start without 2 h headroom and the operator's explicit go
for c2.

**Order.**

1. Gates (top of this file), plus Step 2's extra gates.
2. c1 push (`rook` mgr module disabled). Verify, operator read:
   `oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph mgr module ls -f json | jq -r '.enabled_modules[]'` prints
   no `rook` line (the 20-line cut of the `ceph-reads.sh` section is not the check), and health is the standing WARN
   (only `BLUESTORE_SLOW_OP_ALERT`).
3. Step 2: pre-commit checks, written to `work/evidence/s4-pre.txt`.
4. Step 3: operator sets `noautoscale`.
5. The operator's explicit go for c2.
6. c2 push (record `window-start.txt` first), then Steps 5 and 6 (watch; Step 4 is what you will see). Step 7 only if
   the roll stalls. No commit to master from the c2 push until the Step 5 end condition.
7. Step 8 items 1-5 (capture, versions, keys, `require_osd_release`, health).
8. Operator unsets `noautoscale` (Step 3), confirmed first. Then Step 8 items 6-9 and 11-13.
9. The first master commit after the end condition (the stage-4 evidence and blog commit) re-syncs
   `rook-ceph-cluster`; then Step 8 item 10 and the Synced/Healthy check (Step 8 item 14).

### Step 2: pre-commit checks

All of these hold immediately before the c2 push. The controller writes the results, one line each, into
`.superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/s4-pre.txt`; a single failure means no push.

1. Second restore check, controller (each apply prompts). It is the same spec as Stage B's, under a new name, so the
   first Restore (deleted in Stage B step 9) cannot collide. Derive the manifest from `backup/restore-check.yaml`; the
   `sed` matches only the `metadata.name` line (`backupName: pre-rook-upgrade` is untouched):

```bash
# CONTROLLER (prompted): Stage B step 9 deleted the namespace, so recreate it
oc apply -f tests/rook-ceph-upgrade/backup/restore-namespace.yaml
# CONTROLLER (prompted)
sed 's/name: pre-rook-upgrade-check$/name: pre-rook-upgrade-check2/' tests/rook-ceph-upgrade/backup/restore-check.yaml | oc apply -f -
```

   Then repeat Stage B steps 5-9 by number (from step 5 only the watch; do not re-apply the original
   `restore-check.yaml`), with these changes: the Restore is `pre-rook-upgrade-check2`; step 5
   waits for its DataDownloads (`webtlo-data-pvc`, `transmission-config-pvc`) to reach `Completed`; the compare in
   step 8 uses the live pods as they are now, and `START` is still the Backup `pre-rook-upgrade`'s
   `status.startTimestamp` (same Backup); step 9 deletes `pre-rook-upgrade-check2` and the namespace again. Pass
   criteria are Stage B's (empty `diff`, total compare lines at least 1, no `ERROR`). A FAIL stops the stage: this backup is the only copy of the data a failed Tentacle roll could cost.
2. CNPG archiving on all three clusters, `ContinuousArchiving=True` (command from the `cluster-health` skill):

```bash
# CONTROLLER (readonly)
for nc in media:media-postgres immich:immich-postgres homebox:homebox-postgres; do
  KUBECONFIG=~/.kube/config-readonly oc -n "${nc%%:*}" get cluster "${nc##*:}" -o jsonpath='{.metadata.name} ready={.status.readyInstances}/{.status.instances} {range .status.conditions[?(@.type=="ContinuousArchiving")]}archiving={.status}/{.reason}{end}{"\n"}'
done
```

   Expected: three lines, each `archiving=True`, ready equal to instances.
3. The image through zot, and zot's free space after (it pre-pulls):

```bash
# CONTROLLER
bash tests/rook-ceph-upgrade/verify/images-check.sh quay.io/ceph/ceph:v20.2.5-20261028   # IMAGE OK
```

4. Gates (top of this file) hold, plus these Stage 4 gates: every node `Ready` and schedulable; no MCP updating; PGs
   active+clean; all three OSDs `up` and `in`; no `ceph.rook.io/do-not-reconcile` label on any Deployment:

```bash
# CONTROLLER (readonly)
KUBECONFIG=~/.kube/config-readonly oc get nodes -o custom-columns=NAME:.metadata.name,UNSCHEDULABLE:.spec.unschedulable,READY:'.status.conditions[?(@.type=="Ready")].status'   # three rows: <none>, True
KUBECONFIG=~/.kube/config-readonly oc get mcp   # UPDATING False on every pool
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get deploy -l ceph.rook.io/do-not-reconcile -o name   # empty
```

   The OSD state comes from the operator's capture: `bash tests/rook-ceph-upgrade/verify/ceph-reads.sh s4-pre`. In its
   `ceph osd tree` section `osd.0`, `osd.1` and `osd.2` read `up` with REWEIGHT `1.00000` (`in`); its `ceph health detail`
   section shows only `BLUESTORE_SLOW_OP_ALERT`; `ceph -s` shows PGs `active+clean`. The exit code must be `0`.
5. Smoke sequence PASS and `KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage3`
   -> `RESULT PASS stage3`, so a failure after c2 cannot be blamed on a state that was already broken.
6. Not Monday 19:00-23:00Z (next: 2026-11-09), quiet IO.

### Step 3: `noautoscale`

Ceph-internal mutation: the operator runs both lines, flagged and confirmed first. It stops the PG autoscaler from
changing `pg_num` while OSDs restart.

```bash
# OPERATOR, before the c2 push (confirm first)
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool set noautoscale
# OPERATOR, once Step 8 items 1-5 pass (confirm first)
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool unset noautoscale
```

The unset waits for the roll to be finished and verified: all daemons on 20.2.5, `require_osd_release tentacle`, cipher
`aes256k`, standing WARN (Step 8 items 1-5). Check each with a direct read, not the `s4` capture (that one is taken
before the unset, so its `flags` line still shows `noautoscale`):
`oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool get noautoscale` reads `noautoscale is on` (then `off`), or
`oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd dump | grep flags` lists `noautoscale` (then does not).
If the roll is abandoned or stalls for good, the unset still happens: do not leave the flag on.

### Step 4: expected during the roll

None of this is the incident:

- `HEALTH_ERR` from `AUTH_INSECURE_SERVICE_KEY_TYPE` and `AUTH_INSECURE_SERVICE_TICKETS`, until the cipher is `aes256k`.
- `rook-ceph-cluster` reads **Degraded** (our ArgoCD health check maps Ceph `HEALTH_ERR` to Degraded). Its multi-wave
  sync fails and retries 5 times (5 s, factor 2, max 3 m; `bootstrap/root-app/templates/applications.yaml`). Then ArgoCD
  does not re-attempt that revision, even with selfHeal. So the chart's four Jobs, `csi-rbd-provisioner-caps-fix-bootstrap`,
  `pg-num-floor-bootstrap`, `mgr-pool-crush-rule-bootstrap` and `rbd-trash-purge-schedule-bootstrap` (waves 10, 10, 10, 11;
  `ttlSecondsAfterFinished` 3600, `Replace=true`), are recreated only when `rook-ceph-cluster` syncs again, and that
  happens on the next new master commit (there is no `manifest-generate-paths`, so any commit triggers it). Step 5 forbids
  commits until the roll is done; the first commit after that (the stage-4 evidence and blog commit) is the re-sync.
  `root-app` reads Degraded too.
- The four muted `AUTH_INSECURE_*` warnings (`AUTH_INSECURE_ROTATING_SERVICE_KEY_TYPE`, `AUTH_INSECURE_CLIENT_KEY_TYPE`,
  `AUTH_INSECURE_KEYS_ALLOWED`, `AUTH_INSECURE_KEYS_CREATABLE`; c2 sets them through `healthCheck.muteHealthWarning`).
  Whether and how `ceph health detail` lists a muted warning is read in the window.

### Step 5: no-touch rule

From the c2 push until `ceph versions` shows every daemon on 20.2.5 **and** `ceph mon dump -f json | jq -r
.auth_service_cipher.name` reads `aes256k` (a monmap field Rook sets with `ceph mon set`): **no commit to master at all** (stricter than
"either storage app" on purpose: any commit re-syncs `rook-ceph-cluster`, and a sync mid-roll can restart the
operator's reconcile), no operator pod restart, no node event (no cordon, drain or reboot). A reconcile
restart mid-roll re-runs Rook's health check and stalls the upgrade with mons on 20.2.5 and OSDs on 19.2.4. The
operator reads the cipher: `ceph-reads.sh s4-roll` (section `ceph mon dump -f json | jq auth_service_cipher.name`).

### Step 6: watch

```bash
# CONTROLLER (readonly), repeat every few minutes
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph logs deploy/rook-ceph-operator --since=10m | grep -E 'refusing to upgrade|upgrad'
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get cephcluster -o jsonpath='{.items[0].status.ceph.versions}{"\n"}{.items[0].status.phase} {.items[0].status.ceph.health}{"\n"}'
```

Progress = the daemons on 20.2.5 grow in `status.ceph.versions` (mons first). `refusing to upgrade` with the daemon
versions split is Step 7; a slow but moving roll is not.

### Step 7: contingency (stall)

Only if the operator log shows `refusing to upgrade` with the daemon versions split. The operator runs, flagged and
confirmed first:

```bash
# OPERATOR (confirm first)
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph health mute AUTH_INSECURE_SERVICE_KEY_TYPE 4h
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph health mute AUTH_INSECURE_SERVICE_TICKETS 4h
oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph health
```

`ceph health` must read `HEALTH_WARN` before relying on it; then wait for Rook's next reconcile (do not trigger one).
That a mute lets Rook proceed is inferred from Ceph's mute semantics, not documented by Rook, so the `HEALTH_WARN` read
is the check. Never `skipUpgradeChecks: true`: it also drops the `ok-to-stop` gate, which on three OSDs is what stops
two OSDs being down at once. The mutes expire after 4 h: if the roll is still running then, re-mute (operator, confirmed first, same
commands) and report. If the toolbox shows auth errors during this step (the admin key rotates mid-roll), wait 60 s,
or restart it (Step 8 item 1), before reading anything into the output.

### Step 8: verify

Record `window-start.txt` before the c2 push (Stage 1 "Window start"). After the admin key rotates, the toolbox may
hold the old key.

1. Wait 60 s first. If the toolbox still shows auth errors, restart it (controller, prompted: a mutation):
   `oc -n rook-ceph rollout restart deploy/rook-ceph-tools`. Then operator:
   `bash tests/rook-ceph-upgrade/verify/ceph-reads.sh s4` -> `0 reads failed` (exit 0). The items below read that
   capture, taken before the `noautoscale` unset
   (`ls -t .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/ceph-reads-s4-2*.txt | head -1`; the `2` skips
   the `s4-pre` and `s4-roll` captures).
2. `ceph versions` section -> every mon, mgr and OSD on `20.2.5`, none on `19.2.4`.
3. `ceph auth dump-keys` section (filtered to entity and `type_str`; the key fields are deleted by `ceph-reads.sh`) ->
   `aes256k` for the mon, mgr and OSD entities. The section must not read `READ-SKIPPED`; the script skips it only when every
   daemon is still on 19.x, so a mixed or finished roll reads it. Controller: `csi-state.sh` prints `INFO ... cephx=`
   with the CephCluster `status.cephx`; expected key generation 2 on the daemon entries (c2 sets `keyGeneration: 2`),
   exact form read in the window.
4. `ceph osd dump` section -> `require_osd_release tentacle`; `ceph mon dump` section -> `min_mon_release 20 (tentacle)`;
   the cipher section reads `aes256k`.
5. `ceph health detail` section -> the standing WARN only: `BLUESTORE_SLOW_OP_ALERT` plus the muted `AUTH_INSECURE_*`
   warnings (`AUTH_INSECURE_CLIENT_KEY_TYPE` is one of the four c2 mutes); `AUTH_INSECURE_SERVICE_KEY_TYPE` and
   `AUTH_INSECURE_SERVICE_TICKETS` are gone, not merely muted, even if Step 7 ran. Exact text read in the window.
6. `noautoscale` unset, a direct read after Step 3's unset (not the `s4` capture): operator,
   `oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool get noautoscale` -> `noautoscale is off`, or
   `oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd dump | grep flags` shows no `noautoscale`.
7. Controller: `KUBECONFIG=~/.kube/config-readonly bash tests/rook-ceph-upgrade/verify/csi-state.sh --expect stage4` ->
   every line `CHECK PASS` (including `cephcluster-version` `20.2.5*`), `RESULT PASS stage4`, exit 0.
8. Smoke sequence PASS (writer, reader recomputed and reader stored sums equal). Before deleting its namespace, take
   the OADP check: `backup/backup-smoke.yaml` -> Backup `post-tentacle-smoke`:

```bash
# CONTROLLER (prompted)
oc apply -f tests/rook-ceph-upgrade/backup/backup-smoke.yaml
# CONTROLLER (readonly), repeat until Completed
KUBECONFIG=~/.kube/config-readonly oc -n openshift-adp get backups.velero.io post-tentacle-smoke -o jsonpath='{.status.phase} errors={.status.errors} warnings={.status.warnings}{"\n"}'
KUBECONFIG=~/.kube/config-readonly oc -n openshift-adp get datauploads.velero.io -l velero.io/backup-name=post-tentacle-smoke
```

   Expected: Backup `Completed`, `errors=0`, a DataUpload `Completed` for each smoke PVC (`smoke`, `smoke-restore`).
   Then delete the smoke namespace and confirm the PVs and RBD images are gone. The Backup expires with its 72 h ttl.
9. The next CNPG scheduled VolumeSnapshots are `readyToUse: true`. Schedules (UTC): media 04:00, immich 04:30, homebox
   05:00. Run this after 05:00Z on the day after the window:

```bash
# CONTROLLER (readonly)
WINDOW_START="$(cat .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/window-start.txt)"
KUBECONFIG=~/.kube/config-readonly oc get volumesnapshots.snapshot.storage.k8s.io -A -l cnpg.io/cluster -o json \
  | jq -r --arg s "$WINDOW_START" '.items[] | select(.metadata.creationTimestamp >= $s) | "\(.metadata.namespace)/\(.metadata.name) cluster=\(.metadata.labels["cnpg.io/cluster"]) readyToUse=\(.status.readyToUse)"'
```

   Expected: at least one row each for `media-postgres`, `immich-postgres` and `homebox-postgres`, all
   `readyToUse=true`.

10. The four Jobs' first runs after the rotation are `Complete` (they read the admin keyring). They exist again only
    after `rook-ceph-cluster` has synced (Step 4): the first master commit after the Step 5 end condition triggers it, so
    make that commit before this item and wait for the sync to finish. Each of `csi-rbd-provisioner-caps-fix-bootstrap`, `pg-num-floor-bootstrap`,
    `mgr-pool-crush-rule-bootstrap` and `rbd-trash-purge-schedule-bootstrap` is `Complete` and started after the
    window start:

```bash
# CONTROLLER (readonly)
WINDOW_START="$(cat .superpowers/sdd/2026-11-03-rook-ceph-upgrade/work/evidence/window-start.txt)"
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get jobs -o json \
  | jq -r --arg s "$WINDOW_START" '.items[] | select(.metadata.name | test("caps-fix-bootstrap|pg-num-floor-bootstrap|mgr-pool-crush-rule-bootstrap|rbd-trash-purge-schedule-bootstrap")) | "\(.metadata.name) succeeded=\(.status.succeeded // 0) started=\(.status.startTime) \(if .status.startTime >= $s then "NEW" else "STALE" end)"'
```

    Four rows, `succeeded=1`, `NEW`. A missing row counts the same as `STALE`: the re-sync has not finished yet.
11. Caps equal the caps-fix Job's set: in the `ceph auth get client.csi-rbd-provisioner.1` section of the `s4` capture,
    `mgr allow rw`, `mon profile rbd, allow command 'osd blocklist'`, `osd profile rbd`.
12. No `FailedMount` or `FailedAttachVolume` since the window start (Events command in Stage 1 item 4; both counts
    `0`), and CNPG pods not restarted by the roll (Stage 1 pre-hop CNPG command; no `START` at or after
    `$WINDOW_START`).
13. Recorded only, not a pass criterion: whether `nvme-replicated` shows a PG target in the operator's
    `oc -n rook-ceph exec deploy/rook-ceph-tools -- ceph osd pool autoscale-status` (the Squid `bulk` bug behind the
    `pg_num` floor Job). Copy the row into the blog draft either way.

14. After that re-sync: `rook-ceph-cluster` and `root-app` read Synced/Healthy:

```bash
# CONTROLLER (readonly)
for app in rook-ceph-cluster root-app; do
  KUBECONFIG=~/.kube/config-readonly oc -n openshift-gitops get application "$app" -o jsonpath='{.metadata.name} {.status.sync.status} {.status.health.status}{"\n"}'
done
```

    Expected: `Synced Healthy` on both.

When Step 8 passes the standing WARN definition changes in the `cluster-health` skill, CLAUDE.md and the design
together (the skill edit is the operator's): it now also carries the muted `AUTH_INSECURE_*` warnings (including
`AUTH_INSECURE_CLIENT_KEY_TYPE`; until CSI keys move to AES256K, which needs kernel 7.0).

**Recovery.** There is none back to Squid. Never revert c2 in git: that would be a downgrade attempt. Fix forward: read the operator log, keep the no-touch rule, use Step 7 for a
stall. If CSI mounts break and do not recover within 30 minutes of focused work, stop and report; no teardown.
