# Offsite backup after the Synology: picking a provider (draft)

The Immich library has one offsite copy today: Hyper Backup task `Synology_C2_immich_photos_task` on the
DS418, pushing to Synology C2. That task points at a path on the Synology, so the planned move of the library
to TrueNAS would silently drop it out of backup while the task kept reporting green (README TODO "Immich
library: preserve offsite coverage across the TrueNAS migration"). Two older plans for the replacement
disagreed — the README proposed `rclone`/`restic` to Cloudflare R2, the vault's 2026-06-22 migration plan
proposed borg to an offsite SSD — and neither had been priced against current offers. These notes are that
comparison and the decision it led to.

## 2026-10-01 — requirements

- **Size:** ~600 GB to start, ~100 GB a year after that, so ~1.1 TB by year five. Scope for now is the Immich
  library only (photos plus Immich's own DB dumps under `backups/`); other datasets may follow.
- **Invoice:** only a Polish VAT invoice lets the 23% VAT be recovered, so Polish vendors compare at their net
  price and everyone else at net + 23%.
- **Simplicity:** how easy it is to configure, maintain and, above all, restore.

## Price comparison (2026-10-01/02, net per month, 600 GB → 1 TB)

Polish invoice:

| Provider | Price | Notes |
|---|---|---|
| OVHcloud Warsaw (WAW, 1-AZ), Infrequent Access | 0.0172791 zł/GiB/month → **~9.70 → ~16 zł** | OVH Sp. z o.o., Wrocław. Retrieval 0.01728 zł/GiB, 30-day minimum billing. Ingress, egress and API calls free |
| OVHcloud Warsaw, Standard | 0.0354853 zł/GiB/month → ~19.80 → ~33 zł | No retrieval fee, no minimum |
| Synology C2 OneStorage licence via a Polish shop | 404.99 zł gross/year (Serverico) = ~27.40 zł net flat up to 1 TB | Covers C2 Object Storage (S3, no Synology needed), Frankfurt, versioning + Object Lock, egress up to the bought capacity per month. Needs a second 1 TB licence above 1 TB |
| CloudFerro (Warsaw), cold tier | €0.010/GB → ~26 → ~43 zł | Retrieval and minimum duration not published |
| k.pl (Wrocław) | 90 zł for the 1 TB package | 24-month contract |
| Oktawave | from 0.07 zł/GB + 0.015 zł/GB **in and out** | Ingress is charged |

Foreign invoice (gross, +23%):

| Provider | Price | Notes |
|---|---|---|
| Hetzner Storage Box BX11 | €3.20 net → ~17 zł flat to 1 TB, then BX21 ~57 zł | borg/restic/rclone over SSH, snapshots |
| Backblaze B2 | $6.95/TB → ~20 → ~33 zł | US company, Amsterdam region |
| Hetzner Object Storage | €4.99 incl. 1 TB → ~26 zł | |
| Scaleway pl-waw | €0.00803/GB one-zone → ~25 → ~42 zł | No Glacier class in Warsaw |
| Cloudflare R2 | $0.015/GB → ~42 → ~70 zł | Free egress |

Five-year totals at 600 GB + 100 GB/year (net): OVH Infrequent Access ~820 zł, OVH Standard ~1,685 zł, C2
licence ~1,975 zł.

## How the copy leaves TrueNAS

The tool mattered more than the vendor:

- **TrueNAS Cloud Sync** (rclone underneath) is built in and drivable through `midclt` from the
  `truenas-tasks` role, so it stays code-only. It mirrors files as plain objects; versioning and Object Lock
  on the bucket supply the history.
- **TrueCloud Backup** (restic underneath, versioned) targets **Storj only** on 25.10, so it is not an option.
- **restic or borg** would need a custom app container, a repository password to keep safe, and prune/check
  schedules — more to maintain, and a restore needs the tool plus the password.

## Decision (2026-10-02)

OVH Object Storage, Warsaw, Infrequent Access, **not encrypted on our side**, pushed nightly by a TrueNAS
Cloud Sync task declared in `ansible/truenas/roles/truenas-tasks`. Unencrypted keeps a restore as simple as
downloading from the OVH console; the cost is that OVH can read the photos. Design agreed so far:

- **Bucket:** versioning on, older versions expire after 90 days, Object Lock in Compliance mode for 30 days
  (it can only be enabled when the bucket is created). Versioning only adds what changed in the last 90 days,
  not a multiple of the library.
- **Mirror mode** (`SYNC`), so deletions propagate as delete markers instead of keeping deleted photos forever.
- **Monitoring:** TrueNAS's own failure email, plus a staleness metric from the textfile collector and
  `TrueNASCloudSyncStale` (warning 36 h, critical 72 h) / `TrueNASCloudSyncDisabled` alerts.
- **Sequencing:** build now and test on a small `dd`-generated test folder in `tank/backup`; the real 600 GB
  goes up right after the Immich move; C2 is cancelled only after a full restore from OVH matches.

## 2026-10-02 — OVH onboarding: the prepaid credit trap

Creating the first Public Cloud project led straight to an order for 400 zł net of "Cloud Credit
Provisionning" (40,000 × 0.01 zł, 492 zł gross). OVH's terms: credit not used within 13 months of purchase
is lost and cannot be refunded. With only a test folder until the Immich move, most of it would have expired.

The project wizard also offers a plain payment method (credit card or PayPal) instead of "Add credits", and
credit amounts from 40 zł upwards. The `FREETRIAL` promo code added 1,000 zł of free trial credit. A support
case was opened with OVH on 2026-10-02 to confirm whether the project can run on a card with no prepayment;
waiting on the answer.

## 2026-10-11 — scope correction: the family archive is inside the Immich library

While designing the rollout I had listed "family photos" as out of scope. The Immich account design
agreed today (`blog/blog-immich-draft.md`, 2026-10-11) imports the old archive into Immich as a
`family` account, so it lands in `library/family/` on `tank/immich` and the same Cloud Sync task
uploads it. Consequences: the size to plan for is the library plus the archive, and the archive has
never been measured (bounded at < ~2.2 TiB on 2026-08-29; ~18 zł net per TiB per month on
Infrequent Access, so up to ~39 zł); the first upload is the existing library, and the archive
follows when it is imported after the Immich move.

## 2026-10-11 — the Synology leg: Cloud Sync over SFTP, in COPY mode

The order changed today. The Immich library moved to TrueNAS ahead of any offsite job
(`blog/blog-truenas-migration-draft.md`, same date), and the operator wants a TrueNAS → Synology
copy in the `photo` share's `backups` folder before the archive import, with OVH after. "Backup,
not sync": a photo deleted in Immich must stay on the Synology.

I proposed an rsync task and built a Cloud Sync task instead. Both exist on 25.10.6 (0 of each
were configured). Reasons: Cloud Sync is what the OVH design already uses, so the role code
written now serves both legs; its `COPY` transfer mode is exactly the no-deletions behaviour; and
SFTP takes a plain DSM account and password, where rsync over SSH for a non-admin DSM account
needs key material in its home directory. What Cloud Sync gives up is Unix ownership and mode —
rclone over SFTP carries contents and mtimes only — which a restore has to put back with a chown.

The API, read from the box rather than remembered:

```bash
midclt call cloudsync.providers                       # 18 providers, SFTP and S3 among them
midclt call core.get_methods cloudsync.credentials    # create: name + provider{type,host,port,user,pass|private_key}
midclt call core.get_methods cloudsync                # create: path, credentials(id), attributes{folder}, schedule,
                                                      #   direction PUSH|PULL, transfer_mode SYNC|COPY|MOVE, snapshot, exclude, enabled
```

`job=false` for every create and update; only `cloudsync.sync` is a job method, which matters
because of the `--job` trap this role has already fallen into once.

Declared in `ansible/truenas/group_vars/all.yml`: credential `synology-sftp` (host
`192.168.1.2`, user and password named as vault variables), and one task — `tank/immich` →
`/photo/backups/immich`, `COPY`, from a snapshot, daily 05:00 Europe/Warsaw (after the 02:00
snapshot and after Immich's database dump, which runs at 02:00 UTC), excluding `thumbs/` and
`encoded-video/`.

### Testing a role that needs a vault I cannot open

`playbook.yml` wants the vault password, so I cannot run it. Instead I ran the new section of
`truenas-tasks` on localhost against a stand-in `midclt`: a small script that keeps credentials
and tasks in a JSON file and rejects payloads the way the 25.10 schema does (unknown keys,
`credentials` not an integer, flags not booleans). Against it:

| case | result |
|---|---|
| vault variables absent | nothing created; the role names the two missing variables |
| variables present, empty box | `cloudsync.credentials.create`, `cloudsync.create`; types correct |
| second run | `changed=0`, no calls — although the box adds `private_key: null` and `fast_list: false` |
| box drifted (password, hour 6, mode SYNC, exclude emptied) | `credentials.update` + `cloudsync.update`; all four back |
| `--check` on an empty box | no calls |
| `-v` output searched for the test password | 0 occurrences |

The convergence block in `playbook.yml` gained `cloudsync_tasks_missing` (asserted) and
`cloudsync_tasks_without_secrets` (reported, not asserted), checked in three states the same
way. `ansible-playbook --syntax-check` passes. What the stand-in cannot prove is the real
middleware's behaviour — in particular whether `snapshot: true` is accepted for this dataset and
what DSM's SFTP root looks like — so the first real run is still a test.

Not on the box yet. The DS418 refused a connection on port 22 today, so SFTP is off; it needs
enabling, an account, two vault variables, a playbook run, and a first run that I then check
against the original files.

### Same evening — on the box, first run, checked against the source

The operator enabled SFTP on the DS418, put the account in the vault and converged:
`ok=74 changed=2 failed=0` — the two changes being the credential and the task. Read back:

```
credential  id 1  synology-sftp  SFTP 192.168.1.2:22  (user and password set)
task        id 1  /mnt/tank/immich -> /photo/backups/immich  PUSH COPY snapshot=true enabled
            exclude [/thumbs/**, /encoded-video/**]   schedule 0 5 * * *
```

The two things the stand-in could not prove both held: the middleware accepted `snapshot: true`
for this dataset, and DSM's SFTP root is the list of shares —

```bash
midclt call cloudsync.list_directory '{"credentials": 1, "attributes": {"folder": "/"}}'
#  Logs/ downloads/ home/ homes/ kubenfs/ music/ photo/
```

First run, started by hand rather than waiting for 05:00:

```bash
ssh truenas_admin@192.168.1.25 "midclt call --job cloudsync.sync 1"
#  164 / 164, 1.241 GiB / 1.241 GiB    -> job state SUCCESS, error null, 78 s
```

164 is the 487 files of the library minus `thumbs/` (321) and `encoded-video/` (2), so the
exclude list did what it says. Then the copy against the source, by content: sha256 of every
file on TrueNAS over SSH, sha256 of every file under `photo/backups/immich` over SMB from the
workstation, compared by relative path.

```bash
ssh truenas_admin@192.168.1.25 "cd /mnt/tank/immich && find . -type f -not -path './thumbs/*' \
    -not -path './encoded-video/*' -print0 | xargs -0 sha256sum"
(cd /Volumes/photo/backups/immich && find . -type f -not -name '.DS_Store' -print0 | xargs -0 shasum -a 256)
```

```
source files: 164   backup files: 164
identical: 164   different content: 0   missing from backup: 0   only in backup: 0
source by folder: library 145, backups 15, upload 3, profile 1
```

Still open for this leg: `photo/backups` is not yet in the Hyper Backup task, so nothing new
reaches C2; and nothing alerts on a task that stops running.
