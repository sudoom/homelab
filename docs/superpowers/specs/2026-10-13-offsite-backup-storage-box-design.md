# Offsite backup — TrueNAS to a Hetzner Storage Box

Status: design approved by the operator 2026-10-14 (the six points in `blog/blog-offsite-backup-draft.md`,
"Decision (2026-10-13)", including weekly snapshots). This spec awaits review. Nothing is built and the box is
not ordered.

## Why

The Immich library lives on TrueNAS (`tank/immich`) since 2026-10-11. Its only other copy is the nightly Cloud
Sync task to the Synology (`photo/backups/immich`, `COPY` mode), in the same house. The Hyper Backup task
`Synology_C2_immich_photos_task` still reports green, but it backs up the old PVC directory on the Synology, so
nothing uploaded since the move has an offsite copy. The family archive (~350 GB, +~100 GB a year) is being
imported into the same dataset, so the gap grows with every import step.

Goal: a nightly offsite copy of `tank/immich` that survives a deleted photo, a mass delete in Immich, and a stolen
TrueNAS credential; an alert when it stops; a restore proven before C2 is retired.

## Decisions (agreed 2026-10-13 / 2026-10-14)

| Decision | Choice | Note |
|---|---|---|
| Provider | Hetzner Storage Box **BX11** (1 TB), location Germany | €3.20 net a month, ~17 zł with VAT (German invoice, VAT not recovered — accepted). Hourly billing, no minimum term. Comparison: blog draft, 2026-10-13 sections. |
| Login stored on TrueNAS | A **sub-account** with its own base directory | Its password reaches that directory only. The main account stays in the password manager, behind two-factor login. |
| Transfer mode | **`SYNC`** (mirror) | A delete in Immich is deleted on the box at the next run. History comes from snapshots. The Synology leg stays `COPY`, so while the DS418 exists it still keeps everything ever uploaded. |
| History | One **automatic snapshot a week, 10 kept** (~ten weeks) | Set once in Hetzner's console. Replaces the OVH design's 90-day versions and 30-day Object Lock. |
| Encryption | None on our side | A restore is a plain file copy; Hetzner can read the photos. Carried over from the OVH design. |
| Schedule | Daily **06:00** Europe/Warsaw | An hour after the 05:00 Synology run, from its own temporary snapshot. |
| Parallelism | **`transfers: 2`** | The box allows 10 simultaneous connections per account; rclone's defaults are 4 transfers + 8 checkers. Checkers are not exposed by TrueNAS. |
| Monitoring | TrueNAS's failure email + collector metrics + alerts, **for both tasks** | Also closes the Synology leg's open "nothing alerts on a task that stops running". |
| Restore test | Pull the whole box back into a directory in **`tank/backup`** and compare by sha256 | `tank/backup` exists and is empty. Using it avoids creating a scratch dataset, which the roles cannot remove. |
| Review point | Alert when `tank/immich` passes **800 GB** | Then choose the 5 TB plan (BX21, ~58 zł) or a bucket. |

## Design

### The box (operator, in Hetzner's console)

The box is not an Ansible-managed host. Everything here is set once, by hand, and recorded in the blog draft.

- Order a BX11 in Germany. Turn on two-factor login for the Hetzner account, because that account (console or
  API) is the only thing that can delete a snapshot.
- Create one sub-account with:
  - base directory `truenas`, which leaves room for other datasets later;
  - SSH/SFTP on and external reachability on, because TrueNAS is outside Hetzner's network;
  - not read-only;
  - Samba and WebDAV off;
  - a generated password.
- Snapshot plan: automatic, **weekly, Sunday 03:00 UTC**, keep 10. That time is before the 06:00 Warsaw run
  (04:00 or 05:00 UTC), so a snapshot never lands mid-run unless a run lasts nearly a day.
- "Display snapshot directory" on, so the main account can browse `/.zfs/snapshot` for single-file restores.
- Three vault variables in `ansible/truenas/vars/vault.yml`: `truenas_backup_hetzner_host`,
  `truenas_backup_hetzner_user`, `truenas_backup_hetzner_password`. The host name contains the account number, so
  it goes in the vault too. None of the three appear in chat or git.

Facts this relies on, from Hetzner's docs (sources in the blog draft):
- `/.zfs` cannot be written to.
- A sub-account has "access to their own sub-directory only".
- Snapshots are created and deleted only from the console or API.
- A new snapshot takes no space until files it holds change.
- The oldest automatic snapshot goes when the slots are full.

So the TrueNAS login can empty the backup directory, but it cannot touch the last ten weekly states.

### Credential and task (`ansible/truenas/group_vars/all.yml`)

Two new entries, modelled on `synology-sftp`. The comment header of the Cloud Sync section is updated to describe
both legs.

```yaml
truenas_cloudsync_credentials:
  # ... synology-sftp unchanged ...
  - name: hetzner-storagebox
    provider:
      type: SFTP
      port: 22                 # SFTP is always on at 22; 23 is the box's interactive SSH
    secrets:
      host: truenas_backup_hetzner_host
      user: truenas_backup_hetzner_user
      pass: truenas_backup_hetzner_password

truenas_cloudsync_tasks:
  # ... the synology task unchanged ...
  - description: "offsite: tank/immich -> hetzner storage box /immich (managed by ansible/truenas)"
    dataset: immich
    credentials: hetzner-storagebox
    attributes:
      folder: /immich          # inside the sub-account's base directory; confirmed with list_directory first
    transfer_mode: SYNC
    snapshot: true
    transfers: 2
    schedule: { minute: "0", hour: "6", dom: "*", month: "*", dow: "*" }
    exclude:
      - "/thumbs/**"
      - "/encoded-video/**"
```

`vars/vault.yml.example` gains the three variable names with `CHANGEME`. Without them in the vault, the role
creates neither the credential nor the task and reports it, as it does for the Synology one.
`cloudsync_tasks_without_secrets` in the playbook's convergence check lists it, and nothing fails.

### Role change: pass `transfers` (`roles/truenas-tasks/tasks/main.yml`)

`transfers` is a top-level `cloudsync.create` field (integer > 0, or `null` for rclone's default), not an
attribute. The middleware turns it into `--transfers N` (read on the box 2026-10-14 in
`middlewared/plugins/cloud_sync.py`). The role's payload today omits it. Two additions:

- payload: `'transfers': item.transfers | default(none)`
- drift check: `and _cur.transfers == (item.transfers | default(none))`

The Synology task declares no `transfers`, so both sides are `null` and it stays in sync with no update. Tested
the way the 2026-10-11 change was: the role section runs on localhost against the stand-in `midclt`, extended to
accept and store `transfers`. Cases:
- empty box: the task is created with `transfers` 2;
- second run: `changed=0`;
- drift from 2 to 4: an update brings it back;
- Synology task: untouched.

### Monitoring

**Collector** (`roles/truenas-tasks/files/node-exporter-textfile.py`). A new `collect_cloudsync(out)` reads
`midclt call cloudsync.query` and writes, per task, with label `task` = the task's description:

| Metric | Value |
|---|---|
| `truenas_cloudsync_enabled` | 1 or 0 |
| `truenas_cloudsync_running` | 1 while the task's job is `RUNNING` or `WAITING` |
| `truenas_cloudsync_last_job_success` | 1 if the last finished job is `SUCCESS`, 0 if `FAILED`/`ABORTED`; absent if the task never ran |
| `truenas_cloudsync_last_job_finished_timestamp_seconds` | end of the last finished job |
| `truenas_cloudsync_last_success_timestamp_seconds` | end of the last job, only when that job succeeded |

`cloudsync.query` nests the full credential, passwords included. The collector reads only `description`,
`enabled` and `job` from each row and writes nothing else.

The last job survives a reboot: the middleware writes it to the task's database row when the job completes
(`persist_task_state_on_job_complete`, read on the box 2026-10-14). `cloudsync.query` returns that row unless a
newer job is still in memory. The collector holds no state. When the last job failed, the time of the last
success comes from Prometheus history (`max_over_time`, below).

**Alerts** (`components/cluster-config/truenas-exporter/templates/prometheusrule.yaml`, user-workload Prometheus,
15 d retention):

| Alert | Expression (abridged) | for | Severity |
|---|---|---|---|
| `TrueNASCloudSyncStale` | `time() - max_over_time(truenas_cloudsync_last_success_timestamp_seconds[7d]) > 36h`, enabled tasks only | 15m | warning |
| `TrueNASCloudSyncStale` | same, `> 72h` | 15m | critical |
| `TrueNASCloudSyncStale` | `truenas_cloudsync_enabled == 1 unless on(task) max_over_time(truenas_cloudsync_last_success_timestamp_seconds[7d])`: an enabled task with no success in 7 days, or never | 1h | critical |
| `TrueNASCloudSyncDisabled` | `truenas_cloudsync_enabled == 0` | 1h | warning |
| `TrueNASOffsiteReviewDue` | `truenas_dataset_used_bytes{dataset="tank/immich"} > 800e9` | 6h | warning |

- The third Stale rule covers a task that never succeeded, and the gap after a success drops out of the 7-day
  window.
- The review alert reads the whole dataset, including the excluded `thumbs/` and `encoded-video/` and local
  snapshots. It fires early, which is the safe side.
- Box usage, including snapshots, is visible only in Hetzner's console.
- The rules can be pushed before the collector is deployed: with no `truenas_cloudsync_*` series, none of them can
  fire.

## Rollout

Each step waits for the previous one.

1. **Operator:** order the box, enable two-factor login, create the sub-account, set the snapshot plan, and put
   the three vault variables in place.
2. **Me, in git (direct to `master`):**
   - the role change and its stand-in tests;
   - the two `group_vars` entries and `vault.yml.example`;
   - the collector, tested against a fake `midclt` that returns tasks in every job state (never ran, running,
     success, failed) and carries a password that must not reach the output;
   - the alert rules (`helm lint` / `template` / `kubeconform`, rendered rules read back);
   - docs.

   Validation: `ansible-playbook --syntax-check`, then `check.yml`.
3. **Operator:** run `playbook.yml` (vault password). Expected: the credential and the task are created, and the
   collector file is updated. Step 4 should follow within the hour. Otherwise the third `TrueNASCloudSyncStale`
   rule fires for a task that has not run yet, which is harmless but noisy.
4. **Me, with your go-ahead:**
   - `cloudsync.list_directory` on the new credential. Expect the sub-account root to be empty, with no `.zfs`
     entry; if the layout differs from `/immich`, fix the folder in code and converge again before any run.
   - First run by hand: `midclt call --job cloudsync.sync <id>`.
   - Read the job log for refused connections or SSH handshake errors (the 10-connection limit). If there are
     any, drop to `transfers: 1` and run again.
   - Check the metrics on the next collector run (5 min).
5. **Me, with your go-ahead — full pull-back:**
   - Run `midclt call --job cloudsync.sync_onetime` with direction `PULL`, mode `COPY`, the same credential and
     folder, into `/mnt/tank/backup/restore-test-<date>` (directory created for the test).
   - Compare sha256 of every file against `tank/immich` minus the two excludes. Pass: identical file count, zero
     differences, nothing missing.
   - Then delete the directory.
6. **Operator:**
   - take one manual snapshot in the console;
   - fetch one photo over SFTP with the main account from `/.zfs/snapshot/<name>/…`, from the Mac;
   - I compare its sha256 with the original on TrueNAS.

   This proves the single-file path the weekly snapshots exist for.
7. **Operator, after 5 and 6 pass:** retire `Synology_C2_immich_photos_task`. Cancel the C2 plan if nothing else
   uses it; whether anything does is not recorded in this repo. `photo/backups` no longer needs adding to Hyper
   Backup.
8. **After the archive import finishes:** repeat step 5 at full size. That is the real restore drill, and its
   duration is the restore time to record.

## Verification

- The task exists with the declared fields, and a second `playbook.yml` run shows `changed=0` for Cloud Sync.
- The first run reads `SUCCESS` in `cloudsync.query`, with no connection errors in its log.
- Pull-back: identical file count, zero sha256 differences.
- One snapshot file is byte-identical to the original.
- `truenas_cloudsync_last_success_timestamp_seconds` is present for both tasks and no `TrueNASCloudSync*` alert is
  firing.
- Optional, the operator's call: one alert seen to fire and clear. Set `enabled: false` on the Hetzner task in
  code and converge between two nightly runs; `TrueNASCloudSyncDisabled` should fire after 1 h. Revert and
  converge, and it should clear. This costs two playbook runs and no backup run.

## Docs

Same commits as the changes they describe:
- `blog/blog-offsite-backup-draft.md`: rollout chronology with the real commands and outputs.
- `ansible/truenas/README.md`: Cloud Sync section, both legs, the `transfers` field.
- `components/cluster-config/truenas-exporter/README.md`: the new alerts.
- `CLAUDE.md`: the offsite line under Non-cluster infrastructure.
- `README.md` TODO: "Immich library: preserve offsite coverage" is removed when step 7 is done.
- Memory and the vault note: closed out.

## Limits and accepted risks

- **No host-key pinning.** TrueNAS's SFTP credential has host, port, user, password and private key, and nothing
  for a known host key. So rclone does not verify the box's key. Someone in the network path could capture the
  sub-account password and the photos. The password reaches the backup directory only, and the snapshots cannot
  be changed through it. A property of the platform, not of this design.
- **History is weekly.** A photo added and deleted within one week is in no snapshot. While the DS418 exists, the
  Synology `COPY` leg still has it.
- **A mass delete propagates** at the next 06:00 run. Recovery is from the newest weekly snapshot, up to seven
  days old, plus the Synology copy.
- **Snapshots use box capacity.** Deleted or changed data stays for up to ten weeks and counts against the 1 TB.
- **One host.** The box is a RAID array on a single server; it is not replicated across sites.
- **No ownership or mode.** rclone over SFTP carries contents and modification times only. A full restore needs a
  `chown` to the Immich UID, the same as the Synology leg.
- **Not encrypted.** Hetzner can read the photos.

## Open, to confirm on the way

- The sub-account's path layout on port 22, and whether a `.zfs` entry is visible to it (step 4 checks both).
- Whether the 10-connection limit applies per sub-account or to the box as a whole.
- Whether a BX11 can be enlarged to BX21 in place. Needed before the review point, not now.
- Whether Hetzner asks a new account for ID verification or a deposit.

## Out of scope

- Other datasets marked offsite, starting with `tank/backup` ("pg_dumps, Immich DB dump, configs, docs.
  OFFSITE = YES"). Later, as further tasks into further folders on the same sub-account.
- Encryption on our side, and restic/borg.
- The Synology's other Hyper Backup tasks and the DS418's own future.
