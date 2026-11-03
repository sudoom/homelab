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

(empty)

## Stage M: baseline

(empty)

## Stage 1: Rook v1.20.9

(empty)

## Stage 2: Rook v1.21.1

(empty)

## Stage 3: msgr2

(empty)

## Stage 4: Ceph Tentacle 20.2.5

(empty)
