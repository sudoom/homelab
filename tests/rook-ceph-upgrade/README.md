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

The other 17 PVCs are Ceph RBD and in scope: grafana-pvc; homebox-data, homebox-postgres-1, homebox-postgres-2;
immich-postgres-1, immich-postgres-2; transmission-config-pvc, webtlo-data-pvc (keepers); bazarr, jellyfin, prowlarr,
radarr, sonarr, transmission and transmission-slave config PVCs plus media-postgres-1 and media-postgres-3 (media);
data-zot-0. The expected DataUpload count is 17 (re-count with the command below before applying).
`grafana-pvc` is backed up but mounted by no pod (Grafana uses an emptyDir), so it is not the restore check.
`immich-library` (nfs-csi, 192.168.1.2) is a leftover dynamic PVC; it is skipped like the rest.

```bash
KUBECONFIG=~/.kube/config-readonly oc get pvc -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\t"}{.spec.storageClassName}{"\n"}{end}' | grep -E '^(grafana|homebox|immich|keepers|media|zot)/' | grep -c ceph-nvme-block   # 17
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
6. `checker-pod.yaml` -> Pod `restore-checker` (mounts the two restored Ceph PVCs read-only);
   `oc -n rook-upgrade-restore logs restore-checker > restored.txt` prints `sha256  size  mtime  path` per file in
   sections `CHECK begin webtlo|transmission` ... `CHECK end ...`. Any `ERROR` line is a FAIL (a file could not be
   read; the list is never silently shortened).
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
- One DataUpload `Completed` per Ceph PVC in scope (17), none for an NFS PVC.
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
KUBECONFIG=~/.kube/config-readonly oc get pods -A -l cnpg.io/cluster -o custom-columns=NS:.metadata.namespace,POD:.metadata.name,RESTARTS:.status.containerStatuses[*].restartCount,START:.status.startTime   # save to compare
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
# then, after the next rook-ceph-operator sync has finished (its operationState.finishedAt later than the annotate):
KUBECONFIG=~/.kube/config-readonly oc -n rook-ceph get drivers.csi.ceph.io rook-ceph.rbd.csi.ceph.com \
  -o jsonpath='{.metadata.annotations.argocd\.argoproj\.io/sync-options}{"\n"}{range .metadata.managedFields[*]}{.manager}{" "}{end}{"\n"}'
```

Expected: `Delete=false,Prune=false`, and `kubectl-annotate` among the managers. Without the annotation, any later
commit that takes the Driver out of the operator render (a revert, a chart change) prunes it with foreground
propagation, which deletes the plugin Deployment and DaemonSet it owns and livelocks the deletion
(`bugs/upstream-ceph-csi-operator-reconciles-terminating-driver.md`). `--overwrite` keeps the command working if the
old annotation is still there; it is an annotation the Driver should carry either way.

c4 goes only after c2 and c3 pass items 1-9 and the lasting protection is confirmed; after it, rerun
`csi-state.sh --expect stage1` and the smoke sequence.

**Recovery.** Only if CSI mounts break and do not recover within 30 minutes of focused work. Never a plain revert of
c2 or c3: a revert takes the Driver, the new service accounts, their RBAC and their SCC grant out of the operator render
while plugin pods still run under them, and PruneLast then deletes them (the Driver with foreground propagation, which
also deletes the plugin Deployment and DaemonSet). The recovery is a forward commit, `s1-recovery.patch`, made for the
post-c3 state (c1a..c3 on master; after c4 it does not apply, so stop and re-dispatch). It puts both Rook charts back to
v1.19.5 with master's values (c1a's pins stay), brings `csi-driver-config` back without `FailOnSharedResource` (after the
rollback the Driver still carries rook-ceph-operator's tracking id, which that app never releases, so
`csi-driver-config` must take the Driver over to restore ctrlplugin hostNetwork), and adds a temporary
`templates/csi-rollback-rbac.yaml` that keeps the new pair `rook-ceph-rbd-csi-ceph-com-{ctrl,node}plugin-sa`, its RBAC
and its SCC grant until the plugins have rolled back to the old pair. Render evidence:
`work/renders/s1-recovery-checks.txt`.

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

Then `git apply --check` and apply `s1-recovery.patch`, commit, push. The operator downgrade rolls every mon, mgr and
OSD again (the pod templates carry the Rook version), one OSD at a time, so treat it as another degraded window.
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

(empty)
