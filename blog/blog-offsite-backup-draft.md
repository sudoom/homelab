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

## 2026-10-13 — OVH still blocked: a second pass over the providers

Eleven days on, the OVH support case has no answer, and the operator reports that the 40 zł
route does not work either (what exactly fails is not recorded). So: what else, Polish vendors
first, and then the operator's own question — Hetzner's S3. Read-only research today (web search
and the vendors' pages); nothing was ordered or created. Currency at roughly 4.3 zł/€ and
3.85 zł/$, the rates the 10-01 table implies, not re-read today.

**One line of the 10-01 table was already stale when I wrote it.** Hetzner Object Storage is
listed there at €4.99. The base price has been **€6.49 net since 2026-04-01** (announced
2026-02-19); storage beyond the included 1 TB is €0.0087 per TB-hour (about €6.47 per TB-month),
egress beyond the included 1 TB is €1.00 per TB. With 23% VAT that is ~34 zł a month flat to
1 TB, not ~26 zł. Hetzner's product pages fill the prices in by script, so the figure comes from
third-party write-ups of the price adjustment, which agree with each other. The Storage Box price
after the same adjustment I could not confirm either way.

Polish vendors, per month:

| Provider | Price | Notes |
|---|---|---|
| Cloudorama Sp. z o.o. | from 69 zł per 1 TB package | One-month notice; versioning and Object Lock stated. Net or gross, and the data-centre location, not stated |
| k.pl | 50 zł net for 500 GB, 90 zł net for 1 TB | Unchanged: 24-month contract |
| Atman | 0.09–0.11 zł/GB → ~90–110 zł per TB | The price page is more than two years old |
| CloudFerro | €0.020/GB → ~86 zł per TB | Standard tier on the CF2 price table; the cold tier in the 10-01 table is half that |
| Aruba Cloud (arubacloud.pl) | pay-per-use 2.50 zł net per 10 GB block → 250 zł per TB; packages start at 4 TB for 285 zł net | The headline "from 0.051 zł/GB" is the 64 TB package. An account top-up in the menu suggests prepayment |
| Remote Admin (Gdańsk) | 390 zł per TB | |

None of them is near OVH's ~16 zł, and none beats the C2 licence (~27 zł net flat). Cloudsy
advertises €7.69 per TB in Polish, but the seller is an Estonian company (Virtuaalinfra OÜ), so
that is a foreign invoice.

**A Polish invoice from a hyperscaler.** Google's support page says accounts of customers with a
legal address in Poland are billed by Google Cloud Poland Sp. z o.o., all accounts including
card-paying ones, with VAT as a separate line and the VAT ID entered in the payments profile.
Cloud Storage has a Warsaw region (`europe-central2`). The per-GB prices I have for it are $0.023
Standard, $0.013 Nearline, $0.006 Coldline and $0.0025 Archive; they match a 2022 capture of
Google's table, and I could not read the live table today. If they hold, 1 TB is ~10 zł (Archive)
or ~23 zł (Coldline) net a month. The cost moves to the restore: internet egress is about
$0.12/GB plus a retrieval fee ($0.02/GB Coldline, $0.05/GB Archive) — roughly 540–650 zł net to
pull 1 TB back — and the minimum storage duration is 90 days (Coldline) or 365 (Archive). The
egress, retrieval and duration figures are from memory, not from today's page. That would turn the
agreed "cancel C2 only after a full restore matches" gate into a paid drill, and the lock design
would need redoing, because Google's retention features are not S3 Object Lock.

**Hetzner Object Storage against the agreed design.** From Hetzner's documentation: S3-compatible,
object versioning, Object Lock with governance and compliance modes and a default bucket retention
in days or years — and, as on OVH, Object Lock can only be switched on when the bucket is created.
`NoncurrentVersionExpiration` is supported with `NoncurrentDays`, which is what the 90-day expiry
of old versions needs. Ingress and API calls are free, 1 TB of egress a month is included, billing
is by the hour with a monthly cap, and an empty bucket is still billed the base price. Locations:
Falkenstein, Nuremberg, Helsinki. So sections 1–3 of the design carry over unchanged; only the
endpoint and the price differ. Hetzner invoices EU customers who have a valid VAT ID under reverse
charge, without tax, and everyone else at their own country's rate.

Not checked: TrueNAS Cloud Sync against Hetzner's endpoint; whether a compliance lock survives
deleting the Hetzner project; the Storage Box price; Google's live Warsaw prices and how a new
Google billing account is charged; who issues AWS's invoices for direct services in Poland (a
Polish branch exists for Marketplace sales).

No decision yet — the provider is the operator's call.

Sources: [Hetzner Object Storage](https://www.hetzner.com/storage/object-storage/),
[Hetzner supported S3 actions](https://docs.hetzner.com/storage/object-storage/supported-actions/),
[Hetzner Object Lock retention](https://docs.hetzner.com/storage/object-storage/howto-protect-objects/protect-object-lock-retention),
[Hetzner VAT](https://docs.hetzner.com/general/billing-and-account-management/billing-at-hetzner/value-added-tax),
[Hetzner price write-up](https://european-alternatives.eu/product/hetzner-object-storage),
[Google Cloud Poland billing FAQ](https://support.google.com/cloud/answer/10119385?hl=en),
[Cloud Storage pricing](https://cloud.google.com/storage/pricing),
[Cloudorama](https://cloudorama.pl/2026/07/15/s3-storage-backup-archiwum-firmy/),
[k.pl](https://k.pl/pl/s3-object-storage/),
[Atman](https://atman.pl/en/services/complementary-services/object-storage/),
[CloudFerro](https://cloudferro.com/pricing/pricing-tables/cf2-cloud/object-storage),
[Aruba Cloud](https://www.arubacloud.pl/object-storage-oferta.aspx),
[Remote Admin](https://remoteadmin.store/store/storage-s3?language=english),
[Cloudsy](https://cloudsy.partners/przechowywanieobiektws3).
