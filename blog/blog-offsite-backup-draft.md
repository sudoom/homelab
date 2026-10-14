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

### Same day — the cheapest in the EU, and the cheapest anywhere

The operator's follow-up: forget the Polish invoice for a moment — what is the cheapest in the EU,
and the cheapest in the world? They turn out to be the same answer. The price floor is the archive
class at the big clouds, about $1–1.2 per TB a month, and those classes exist in EU regions.
Nothing outside the EU is cheaper than what is inside it; the cheap "ordinary" storage (Backblaze,
IDrive) has EU regions too.

Per month, foreign invoices with 23% VAT added as before, at ~350 GB (the archive today) and 1 TB:

| Option | ~350 GB | 1 TB | Getting 1 TB back | Catches |
|---|---|---|---|---|
| Google Cloud Storage Archive, Belgium or Finland ($0.0012/GB) | ~1.6 zł net | ~4.6 zł net | ~650 zł net ($0.05/GB retrieval + ~$0.12/GB egress); no wait | Polish invoice. 365-day minimum per object. Lock design needs redoing |
| AWS S3 Glacier Deep Archive ($0.00099/GB, US East figure) | ~1.6 zł | ~4.7 zł | ~400–500 zł, after a 12–48 h thaw requested per object | 180-day minimum. A plain Cloud Sync task cannot restore from it |
| Scaleway Glacier, Paris (€0.00254/GB) | ~4.7 zł | ~13 zł | ~100 zł (€0.009/GB restore + €0.01/GB egress past 75 GB), after a thaw | Same thaw problem |
| Backblaze B2, Amsterdam ($6.95/TB, billed per GB) | ~11.5 zł | ~33 zł | free (egress up to 3× stored) | US company. Versioning and Object Lock, no minimum duration |
| Hetzner Storage Box, 1 TB (€3.20 in an October 2025 listing) | ~17 zł | ~17 zł | free | Flat; hard stop at 1 TB, next size is 5 TB. Snapshots, no Object Lock. Price since April not confirmed |
| IDrive e2, 1 TB plan ($59.50 a year, $29.75 the first) | ~23.5 zł | ~23.5 zł | free (up to 3× stored) | Prepaid per year, 1 TB minimum |
| Hetzner Object Storage (€6.49) | ~34 zł | ~34 zł | free (1 TB a month) | Flat base price |

Five years at the planning sizes (600 GB + 100 GB a year): Google Archive ~240 zł net, Deep
Archive ~240 zł, Scaleway Glacier ~690 zł, OVH Infrequent Access ~820 zł net (blocked), IDrive
~1,270–1,550 zł, Storage Box ~1,000–1,500 zł, Backblaze ~1,680 zł, C2 licence ~1,975 zł net,
Hetzner Object Storage ~2,050 zł.

Two things the table hides. First, Backblaze bills per GB and Hetzner Object Storage bills a flat
base, so at this archive's size Backblaze costs a third of Hetzner and only catches up at 1 TB.
Second, the archive classes charge for the calls a nightly mirror makes: on Google a bucket
listing is billed at the bucket's default class ($0.50 per 10,000 calls for Archive, from memory),
so the task needs `fast_list` on — one call per 1,000 objects instead of one per folder — or the
listing can cost more than the storage.

What the box supports, read from it rather than remembered:

```bash
ssh truenas_admin@192.168.1.25 "midclt call cloudsync.providers"   # names and task options only
#  S3: bucket, folder, fast_list, region, encryption, storage_class
#  B2: bucket, folder, fast_list, b2_chunk_size
#  GOOGLE_CLOUD_STORAGE: bucket, folder, fast_list, bucket_policy_only
#  AZUREBLOB, SFTP, WEBDAV, PCLOUD, STORJ_IX, ... (18 in all)
```

So Backblaze and Google Cloud Storage are native task types on 25.10.6, and only the S3 type lets
the task choose a storage class — on Google the class has to come from the bucket.

Not confirmed from a vendor's own live page today: the Google prices (they match Google's table as
quoted by search and a 2022 capture; the egress figure is from memory), the Deep Archive price in
an EU region and its egress, the Storage Box price, IDrive's European regions.

Sources: [Scaleway storage pricing](https://www.scaleway.com/en/pricing/storage/),
[Backblaze B2 pricing](https://www.backblaze.com/cloud-storage/pricing),
[Backblaze lifecycle rules](https://www.backblaze.com/docs/cloud-storage-enable-and-manage-lifecycle-rules),
[IDrive e2 pricing](https://www.idrive.com/s3-storage-e2/pricing),
[Cloud Storage pricing](https://cloud.google.com/storage/pricing),
[Google Cloud Storage pricing guide](https://www.nops.io/blog/google-cloud-storage-pricing/),
[AWS S3 pricing explained](https://upstash.com/blog/aws-s3-pricing-explained-2026),
[objectstorageprices.com](https://objectstorageprices.com/).

### Same day — the operator doubts the archive tier, and is right

I had picked Google's Archive class as "cheapest to hold". The operator's reply: cheapest *for this
use case*, and is deep archive even the right tier? It is not. An archive class is priced for data
that is written once and read about never; this job is a nightly mirror that lists the bucket
every night, expires old versions after 90 days and has to pass a restore test before C2 is
cancelled. Against that:

- the minimum billing period is 180 days (AWS) or 365 (Google), longer than the 90-day expiry of
  old versions, so every expired version is paid for well past its deletion;
- AWS and Scaleway need each object requested back and waited for, which a Cloud Sync task
  cannot do;
- on Google the class itself is usable (no wait), but the money comes back on the way out. Even
  the milder Coldline class in Belgium (about $0.004/GB, ~550 zł net over five years, Polish
  invoice) costs ~540 zł per TB restored — $0.02/GB retrieval plus about $0.12/GB egress — so one
  full restore test cancels the saving.

The class that fits is ordinary or infrequent-access storage with cheap or free download — what
OVH's Infrequent Access was. With OVH out, measured against the archive as it now is (~350 GB,
+100 GB a year, so ~850 GB in year five; 23% VAT added):

| Option | Now | Year five | Five years | Notes |
|---|---|---|---|---|
| Backblaze B2, EU Central (Amsterdam) | ~11.5 zł | ~28 zł | ~1,200 zł | Per GB, no minimum size or duration, first 10 GB free, download free up to 3× what is stored. Versioning always on, Object Lock (governance or compliance, default retention in days), "keep prior versions for N days" lifecycle rule. Native task type |
| Hetzner Storage Box, 1 TB | ~17 zł | ~17 zł | ~1,000 zł | If the price is still €3.20 and the data stays under 1 TB. SFTP, snapshots instead of Object Lock |
| IDrive e2, 1 TB plan | ~11.7 zł | ~23.5 zł | ~1,270 zł | Prepaid per year |
| Hetzner Object Storage | ~34 zł | ~34 zł | ~2,050 zł | Flat |

Read from Backblaze's own pages today: $6.95 per TB a month, the region is chosen when the
account is created and cannot be changed afterwards, the price is the same in every region, and
Object Lock can be enabled at creation or later but never disabled. Not read anywhere: how
Backblaze invoices a Polish customer.

Sources: [Backblaze Object Lock](https://www.backblaze.com/docs/cloud-storage-object-lock),
[Backblaze data regions](https://www.backblaze.com/docs/cloud-storage-data-regions),
[Backblaze B2 pricing](https://www.backblaze.com/cloud-storage/pricing).

### Same day — the Storage Box price, confirmed by the operator

The one price I could not read came back as a screenshot of Hetzner's order page (2026-10-13,
21:28): BX11 €3.20, BX21 €10.90, BX31 €20.80, BX41 €40.60 a month at most, billed by the hour
(BX11 €0.0051/h), excluding VAT, setup fee €0.00. So the April adjustment left the Storage Box
alone and the ~17 zł flat line stands.

That makes it the cheapest of the options that fit: ~1,000 zł over five years against ~1,200 zł
for Backblaze. Backblaze is cheaper only while the data is under ~515 GB, which on +100 GB a year
is the first year and a half or so.

What choosing it would change in the design. No Object Lock and no per-object versions: history
is the box's snapshots — on BX11 10 manual and 10 automatic slots, the oldest automatic one
dropped when a new one is taken at the limit, and snapshots use the box's own capacity. The task
type is SFTP (port 22, SSH keys supported), the same as the Synology leg, so the role code already
running nightly serves it with a second credential. The box stops at 1 TB; the next size is 5 TB.

Not confirmed: that a snapshot cannot be removed with the SFTP login (my recollection is a
read-only directory, deletable only from Hetzner's console or API), and how a full box behaves.
With hourly billing and no setup fee, both can be tested on a real box for cents.

Sources: [Hetzner Storage Box](https://www.hetzner.com/storage/storage-box/),
[Storage Box general docs](https://docs.hetzner.com/storage/storage-box/general/),
[Storage Box snapshots](https://docs.hetzner.com/robot/storage-box/snapshots).

### Same day — Storage Box against Backblaze, by size

The operator asked where each one wins. Both with 23% VAT: Backblaze is $6.95 per TB billed per
GB with the first 10 GB free, so ~0.033 zł per GB a month; the Storage Box is a step function,
~16.90 zł up to 1 TB (BX11) and ~57.70 zł up to 5 TB (BX21).

| Data stored | Backblaze | Storage Box | Cheaper |
|---|---|---|---|
| 350 GB (now) | ~11 zł | ~17 zł | Backblaze by ~6 zł |
| ~520 GB | ~17 zł | ~17 zł | equal |
| 850 GB | ~28 zł | ~17 zł | Storage Box by ~11 zł |
| 1 TB | ~33 zł | ~17 zł | Storage Box by ~16 zł |
| just over 1 TB | ~33 zł | ~58 zł | Backblaze by ~25 zł |
| ~1.76 TB | ~58 zł | ~58 zł | equal |
| 3 TB | ~98 zł | ~58 zł | Storage Box by ~40 zł |

On the measured path (350 GB, +100 GB a year) the crossings fall at about 1.7 years (520 GB) and
6.5 years (1 TB). Five-year totals: ~1,160 zł for Backblaze, ~1,015 zł for the Storage Box. At
+50 GB a year Backblaze wins the five years by ~100 zł; at +200 GB a year the box fills in a
little over three years. So over five years the two stay within about 150 zł of each other
whatever the growth, and the price does not decide it. What does:

- **The ceiling.** The box's snapshots use its own 1 TB, and rclone re-uploads a file that
  moved. A large reorganisation in Immich therefore needs room for both copies until the
  snapshots rotate; on Backblaze the same event is a few weeks of a higher bill, on the box it can
  fill the disk.
- **The history.** Backblaze keeps every changed or deleted file by itself for the 90 days the
  design asks for, under a lock; the box keeps ten whole-box snapshots.
- **The moving parts.** The box is the SFTP task type already running to the Synology and a
  restore is a plain file copy; Backblaze is a new task type plus bucket settings made once in
  its console.

### Same day — Hetzner Object Storage in the same table, and what a move costs

A second screenshot from the operator, Hetzner's own page: Object Storage €6.49 a month with
1 TB, additional storage €6.26 per TB, excluding VAT. That confirms the third-party figure above
(€0.0087 per TB-hour is €6.26 over a 30-day month). With 23% VAT: ~34.30 zł up to 1 TB, then
~33.10 zł per further TB.

| Data stored | Backblaze | Storage Box | Hetzner Object Storage | Cheapest |
|---|---|---|---|---|
| 350 GB (now) | ~11 zł | ~17 zł | ~34 zł | Backblaze |
| ~520 GB | ~17 zł | ~17 zł | ~34 zł | Backblaze = Storage Box |
| 850 GB | ~28 zł | ~17 zł | ~34 zł | Storage Box |
| 1 TB | ~33 zł | ~17 zł | ~34 zł | Storage Box |
| just over 1 TB | ~33 zł | ~58 zł | ~34 zł | Backblaze, Hetzner within ~2 zł |
| ~1.7 TB | ~56 zł | ~58 zł | ~58 zł | all three about equal |
| 3 TB | ~98 zł | ~58 zł | ~101 zł | Storage Box |

Hetzner Object Storage is never the cheapest of the three: below 1 TB it costs two to three times
the others, above it tracks Backblaze within a couple of złoty. Five years on the measured path:
~2,060 zł. Its case is not price — it is the same vendor and account as the Storage Box, with the
lock and versions the box lacks.

**Moving between a Storage Box and a bucket, either way.** The copy on TrueNAS is the original
and the cloud is a mirror, so a move is not a transfer between providers: the new destination is
filled from TrueNAS and the old one is dropped.

- *In the repo.* `truenas-tasks` is generic over the provider: a credential is a `provider` block
  plus a `secrets` map of field name to vault variable, a task passes its `attributes` through.
  A new destination is one entry in `truenas_cloudsync_credentials`, one in
  `truenas_cloudsync_tasks`, the vault variables, and a playbook run — the same in both
  directions. The role never deletes; the old task gets `enabled: false`, which it does support.
  An S3-type credential has not been through the real middleware yet.
- *The upload.* Ingress is free at all three. ~350 GB is about 39 h at 20 Mbit/s, 16 h at
  50 Mbit/s, 8 h at 100 Mbit/s of uplink; the home uplink is not measured.
- *What does not move.* History. Snapshots stay on the box and old versions stay in the bucket,
  so the new destination's history starts on the day of the move. Keeping the old one through
  one retention period covers the gap.
- *Leaving the box* is immediate: no minimum term, cancellation takes effect at once.
- *Leaving a bucket* with a compliance lock is not: locked objects cannot be deleted until the
  lock runs out, 30 days in the design, so the old bucket is paid for up to a month longer.

So starting on the Storage Box and moving to a bucket near 1 TB is a re-upload and at most a
month of paying for both. Not confirmed: whether a BX11 can be enlarged to BX21 in place.

### Same day — the same three, out to 25 TB

Asked for by the operator. Same rates and VAT as above; the Storage Box column is the smallest
plan that holds the data (BX11 1 TB, BX21 5 TB, BX31 10 TB, BX41 20 TB at €3.20 / €10.90 /
€20.80 / €40.60). The largest plan is 20 TB, so the 25 TB row is two boxes, BX41 + BX21.

| Data stored | Backblaze | Storage Box | Hetzner Object Storage | Cheapest |
|---|---|---|---|---|
| 350 GB | ~11 zł | ~17 zł (BX11) | ~34 zł | Backblaze |
| ~520 GB | ~17 zł | ~17 zł | ~34 zł | Backblaze = Storage Box |
| 1 TB | ~33 zł | ~17 zł | ~34 zł | Storage Box |
| just over 1 TB | ~33 zł | ~58 zł (BX21) | ~34 zł | Backblaze |
| ~1.76 TB | ~58 zł | ~58 zł | ~59 zł | all three about equal |
| 2 TB | ~65 zł | ~58 zł | ~67 zł | Storage Box |
| 3 TB | ~98 zł | ~58 zł | ~101 zł | Storage Box |
| 5 TB | ~164 zł | ~58 zł | ~167 zł | Storage Box |
| just over 5 TB | ~165 zł | ~110 zł (BX31) | ~167 zł | Storage Box |
| 10 TB | ~329 zł | ~110 zł | ~332 zł | Storage Box |
| just over 10 TB | ~329 zł | ~215 zł (BX41) | ~333 zł | Storage Box |
| 15 TB | ~493 zł | ~215 zł | ~498 zł | Storage Box |
| 20 TB | ~658 zł | ~215 zł | ~663 zł | Storage Box |
| 25 TB | ~822 zł | ~272 zł (BX41 + BX21) | ~829 zł | Storage Box |

Backblaze wins in two windows only: below ~520 GB, and from 1 TB to ~1.76 TB. Everywhere else up
to 25 TB the Storage Box is cheapest, and from 5 TB up by about three times — both buckets cost
~33 zł per TB at any size, a full box ~11 zł per TB. Hetzner Object Storage is never the
cheapest. Two caveats on the box at these sizes: snapshots use the same space, so the usable
figure is lower than the plan's; and past 20 TB the data has to be split over two boxes and two
tasks.

## Decision (2026-10-13): a Hetzner Storage Box

The operator, after the tables above: "Ok, let's move to storage box". This replaces the
2026-10-02 decision. OVH never got past onboarding — the prepaid-credit order, a support case
unanswered after eleven days, and the 40 zł route not working either — and among everything else
that fits a nightly mirror the Storage Box is the cheapest at this archive's size over the next
six years: BX11, 1 TB, €3.20 net a month (~17 zł with VAT), billed by the hour, no setup fee, no
minimum term. The VAT is not recovered; that was accepted with the choice.

What carries over from the OVH design: TrueNAS Cloud Sync declared in `truenas-tasks`, a nightly
push of `tank/immich` from a snapshot, mirror mode, not encrypted on our side, the staleness
alerts, and "C2 is cancelled only after a full restore matches". What changes: SFTP instead of
S3, and the box's snapshots instead of bucket versioning and Object Lock.

Read in Hetzner's documentation before adapting the design:

- Snapshots appear under `/.zfs/snapshot`, one folder per snapshot showing the box as it was.
  "It is not possible to write to the `/.zfs` directory or its subfolder." Single files and
  whole directories can be copied out of it; restoring a snapshot from the console reverts the
  whole box and removes any newer snapshot.
- A new snapshot takes no space; space is used when a file it holds is later changed or
  deleted. BX11 has 10 manual and 10 automatic slots; when the automatic slots are full the
  oldest goes; manual ones stay until deleted.
- A sub-account has its own login and "access to their own sub-directory only", and can be made
  read-only. Up to 100 per box.
- Up to 10 simultaneous connections per account. Traffic is unlimited. SFTP on port 22 is always
  on. The data sits on a RAID array on a single host server.

The design as adapted, put to the operator and not yet approved:

1. **Target.** BX11 in Germany. TrueNAS logs in as a sub-account confined to one directory, so
   the login stored on TrueNAS cannot reach the snapshot directory or anything else on the box;
   the main account stays in the password manager.
2. **Task.** A second credential (`type: SFTP`; host, user and password all from the vault,
   because the host name contains the account number) and a second task: `tank/immich`, `SYNC`,
   from a snapshot, nightly after the 05:00 Synology run, the same two excludes.
3. **History.** One automatic snapshot a week, 10 slots, so about ten weeks back at weekly
   steps — against the 90 days of versions and 30-day lock of the OVH design. Set once in
   Hetzner's console; the box is not an Ansible-managed host.
4. **Monitoring.** Unchanged: TrueNAS's failure email, plus the staleness metric and the
   `TrueNASCloudSyncStale` / `TrueNASCloudSyncDisabled` alerts, now covering both tasks.
5. **Rollout.** Order the box and make the sub-account; three vault variables; the two entries
   in `group_vars`; a playbook run; the first run started by hand and checked against the source
   by checksum; one file restored from a snapshot folder and a full restore to a scratch dataset
   compared; only then is C2 cancelled. `photo/backups` no longer needs adding to Hyper Backup.
6. **Review point.** At about 800 GB on the box: the 5 TB plan, or a bucket.

To watch on the first run: rclone's defaults (4 transfers, 8 checkers) against the box's limit of
10 connections.

Sources: [Storage Box snapshots](https://docs.hetzner.com/robot/storage-box/snapshots),
[creating snapshots](https://docs.hetzner.com/storage/storage-box/getting-started/creating-snapshots),
[Storage Box general docs](https://docs.hetzner.com/storage/storage-box/general/).

### 2026-10-14 — design approved; what the box said before the spec was written

The operator approved the six points above as written, weekly snapshots included. Three things the
spec depends on were read on TrueNAS rather than assumed. The reads were done over SSH, with nothing
printed from the credentials:

```bash
midclt call core.get_methods cloudsync      # cloudsync.create top-level fields
grep -n transfers /usr/lib/python3/dist-packages/middlewared/plugins/cloud_sync.py
sed -n 33,55p /usr/lib/python3/dist-packages/middlewared/utils/service/task_state.py
```

- **Connection count.** `cloudsync.create` has a top-level `transfers` field (an integer above 0, or
  `null` for rclone's default). The middleware turns it into `--transfers N`. Checkers are not
  exposed (only the `args` string, marked "slated for removal"). The role's payload does not pass
  `transfers` yet. The spec sets 2: up to 8 checkers + 2 transfers stays within the box's 10
  connections. rclone on the box is v1.70.2.
- **The last job survives a reboot.** `persist_task_state_on_job_complete` writes each finished job
  into the task's database row, and `cloudsync.query` returns that row unless a newer job is in
  memory. So the collector can stay stateless.
  - The Synology task's last job: `SUCCESS`, 5 s.
  - `core.get_jobs` holds four `SUCCESS` runs of it since 10-11.
- **A restore needs no saved task.** `cloudsync.sync_onetime` exists (a job method), so the full
  pull-back runs as a one-off `PULL`.

Also measured:
- `tank/immich` is 2 GB today; the archive import has only started, so the first upload is small and
  the bulk follows the import nightly.
- `tank/backup` is empty with 6.8 TB free. The restore test goes into a directory there rather than
  a new dataset, because the roles never remove one.

Added in the spec beyond the six approved points, for review:
- `transfers: 2`.
- A third stale rule for a task with no success in seven days.
- A `TrueNASOffsiteReviewDue` alert at 800 GB in place of a calendar note.
- An accepted risk: TrueNAS's SFTP credential has no field for a known host key, so rclone does not
  verify the box's key.

Spec: `docs/superpowers/specs/2026-10-13-offsite-backup-storage-box-design.md`.

### 2026-10-14 — box ordered; what the console looks like

The box was ordered the same afternoon, in Hetzner's Cloud Console (Storage Boxes moved there from Robot). No ID
check or deposit held it up.

The creation form asks for:
- location and plan;
- **Access:** an SSH key from the Cloud project or a password. With a key, a random password is generated and can be
  changed later; a typed or generated password is shown once;
- **Additional settings:** four toggles, SMB, WebDAV, SSH and External Reachability. Without External Reachability
  only Hetzner's own network can connect;
- labels and a name.

Main account as created: SSH on, External Reachability on, SMB and WebDAV off. Its login is in the password
manager and nowhere else; Ansible never uses it.

What the box page shows afterwards:
- tabs Overview, Snapshots, Subaccounts, Rescale, Delete;
- Overview: server name, username, **SSH port 23** (port 22 also serves SFTP), and four counters — disk usage,
  "Snapshots 0/10", "Auto snapshots 0/10", "Subaccounts 0/100";
- Snapshots: a **"Display snapshot directory"** checkbox, off by default, and two buttons, "Take manual snapshot"
  and "Enable automatic snapshots". The page warns that restoring an earlier snapshot deletes every newer one, so
  a console restore is the last resort; single files come out of `/.zfs/snapshot` over SFTP;
- Subaccounts: one user per directory, which "will only be able to access the files that are saved in this
  directory".

Two things for the spec:
- It is not clear whether manual and automatic snapshots share the 10 slots, since they are counted separately.
  So the manual snapshot taken in rollout step 6 is deleted afterwards, and the question is listed as open.
- The "Rescale" tab suggests a BX11 can be enlarged in place. Not tried.

Later the same day the operator reported the rest done: the snapshot plan, the sub-account and the three vault
variables. Checked from the repo without decrypting anything:

```
$ head -1 vars/vault.yml | cut -c1-40
$ANSIBLE_VAULT;1.1;AES256
$ git check-ignore -q vars/vault.yml && echo ignored
ignored
```

The file is still encrypted, was modified at 16:55, and is not tracked. Whether the three names are in it shows
only when the playbook runs: `cloudsync_tasks_without_secrets` reports a task whose vault variables are missing.

### 2026-10-14 — spec approved; implementation plan written

The operator approved the written spec. The plan is in
`docs/superpowers/plans/2026-10-14-offsite-backup-storage-box.md`:
- **Part A, in git:** four code tasks, each tested against a stand-in before it is committed. The role's `transfers`
  and the offsite declarations are tested against the fake `midclt` harness from 2026-10-11, extended to store
  `transfers`. The collector is tested against a fake `cloudsync.query` with every job state and a password that
  must not leak. The alert rules are tested with `promtool test rules`.
- **Part B, on the box:** the operator-gated rollout steps.

Read while writing it, on the box (filtered to job keys and types, no credential fields):
`cloudsync.query` returns `transfers: null` for the Synology task, and the job's `time_finished` is
`{"$date": <epoch ms>}`, the same shape the scrub collector already handles.

One thing the spec did not see: `tank/backup` has a snapshot task every 6 hours with 90-day retention. A restore-test
directory there is pinned for 90 days if a snapshot runs while it exists. That doesn't matter at today's ~2 GB, but
it will at full size, so the full-size drill (rollout step 8) starts by choosing where the restore lands.

### 2026-10-14 — built in git, tested against stand-ins

The code for the offsite leg is in git, five commits on master, and nothing has run against the real box's Cloud Sync
config yet. Every piece was tested against a stand-in first, RED before GREEN.

- `9ec39a2` truenas: let Cloud Sync tasks declare rclone transfers
- `3080263` truenas: no_log the Cloud Sync task create and update calls (not in the plan, see finding 1)
- `9baf988` truenas: declare the offsite Cloud Sync leg to the Hetzner Storage Box
- `97fbeb1` truenas: export Cloud Sync task state from the textfile collector
- `f19827c` truenas-exporter: alert on stale or disabled Cloud Sync tasks and the offsite review point

**The role harness.** A fake `midclt` on `PATH` that keeps credentials and Cloud Sync tasks in a JSON file, validates
the payload fields the way the real middleware does, and logs every call. The playbook runs against localhost with the
fake and obviously fake vault values (a test host, user and two passwords). `check.py <case>` asserts on the stored
state and the call log. `ansible-playbook` does not start inside the sandbox (multiprocessing socket), so these runs
were unsandboxed; the fake never touches the NAS.

| Case | What it proves | Result |
|---|---|---|
| `t1-create`, unchanged role (RED) | test task created with `transfers: 2` | FAIL, stored `null`; the role never sent it |
| `t1-create`, after the change | both tasks created, `transfers` 2 on the test task, `null` on Synology, one credential and two tasks | 0 failed |
| `t1-rerun` | second run changes nothing, no new calls | PASS |
| `t1-drift` (after `drift-transfers`) | exactly one update, `transfers` back to 2 | PASS |
| `t1-oldrow` (task row with no `transfers` key) | no update, no change (live-side `default(none)`) | PASS |
| `t1-check` (`--check`, empty box) | no middleware calls | PASS |
| `t2-create`, before the declarations (RED) | two credentials, offsite fields, folder, credential link | 5 failed |
| `t2-create`, after | all of the above, Synology task unchanged | 8 PASS, 0 failed |
| `t2-rerun` | idempotent | PASS |
| `t2-nosecret` | only the Synology leg is created; the offsite task is reported as lacking secrets, not as missing; the run names the three missing vault variables | PASS |
| `t2-addsecret` | adds exactly the offsite credential and task, updates nothing | PASS |
| leak | none of the fake secrets in any log, `-v` on | 0 hits each |

`check.yml` against the real NAS afterwards: `ok=5 changed=0 failed=0`, read-only.

**The collector test.** A fake `cloudsync.query` with seven fixture states: never run, running, waiting, success,
failed, aborted-and-disabled, and a task name containing a quote and a backslash. Planted `LEAK-*` strings sit in the
credential, the job log excerpt and the error field. RED against the unchanged collector: 3 failed (series missing,
and the two malformed-input cases not counted as a collector error). GREEN: 13 PASS, 0 failed, including "every sample
line parses", "one TYPE line per metric" and "no credential or job-log field reaches the output". Only `description`,
`enabled`, `job.state` and `job.time_finished` are read. The same function was then run read-only against the real box
(code over stdin, nothing written): it returned the Synology task's five series (enabled, running, last job success,
last finished, last success) and `errors 0`, and no host, user or password anywhere in the output.

**The promtool tests.** Four scenarios in `promtool test rules`: the stale ladder (silent at 35 h, warning at 36 h,
critical at 72 h, the 7-day rule at 171 h), a task that never succeeded, a disabled task, and the offsite review point.
RED on the unchanged chart: `rules: 11`, FAILED, every firing case reporting `exp:[...] got:[]`. GREEN: `16 rules`,
SUCCESS. `helm lint` clean, kubeconform 5 valid, 0 invalid, and a read-only comparison against the live cluster (`oc -n truenas-exporter get prometheusrule truenas -o json | jq -S .spec`,
diffed against the rendered `.spec`) showed
one hunk, all additions, all inside the new `truenas-backups` group.

**Finding 1: the role has leaked the Cloud Sync secret under `-v` since 2026-10-11.** The harness leak check was the
only thing that looked. With `-v`, "Create missing Cloud Sync tasks" printed the middleware's reply, and
`cloudsync.create` returns the task with its credential nested, password included. "Reconcile Cloud Sync tasks that
drifted" had the same gap. Fix: `no_log: true` on both, and the header comment now says why. The leak count went from
4 hits to 0 on the identical run. Without `-v` nothing printed, which is why it went unnoticed.

**Finding 2: the plan's alert rules collided.** The 72 h critical rule and the "no success in 7 days" rule were both
`TrueNASCloudSyncStale{severity=critical}` with the same label set. promtool's lint reported a duplicate rule, and the
unit test hit a duplicate sample at 170 h. The two rules are mutually exclusive and hand over at the 7-day edge, and at that instant the outgoing alert's staleness marker and the incoming alert's first sample had the same label set. A live Prometheus would have collided the same
way. The third rule got an extra label, `window: no-success-7d`; the only test change was that label in two expected
label sets, no time or value was loosened.

**What the stand-ins cannot prove.** The Storage Box's real SFTP path layout (where `/immich` lands relative to the
sub-account's root), its connection limit against the `transfers` value, and real rclone behaviour on the first big
upload. The fake validates field names, not what the middleware or the box accepts. Those wait for the operator's
playbook run and Part B of the plan.

## Final review, 2026-10-14

A whole-branch review of the offsite-backup commits came back "ready to push, with fixes", and the fixes went in as one wave.
Job errors printed by the alert runbooks and the README are now piped through a `sed` that replaces the Storage Box
host with `<box>`, since rclone errors can name it. A sixth rule, `TrueNASCloudSyncUnmonitored`, fires when a task's
`truenas_cloudsync_enabled` series was there in the last 7 days and is not now: every other Cloud Sync alert needs that
series, so a failing `cloudsync.query` would have silenced all of them. The probe also found a one-hour gap at the 7-day
handoff, where the 36 h and 72 h rules lose their window before the 7-day rule's `for: 1h` has elapsed, sending a
RESOLVED mail mid-outage; `keep_firing_for: 2h` on those two rules closes it, after `oc explain` on the cluster's
PrometheusRule CRD confirmed the field. The Stale descriptions now say to check `truenas_cloudsync_running` first, since
the first full upload can outlast 72 h. Corrections: "visible only in Hetzner's console" is wrong, the Hetzner API
reports the box's usage and a follow-up will export it, and the plan's Task 6 now warns that its first run is
unattended unless Task 7 follows within the hour.

### 2026-10-14 — pushed; where the rules actually run

Pushed `0fa3f23..94ae0da`. ArgoCD synced `truenas-exporter` to `94ae0da`, and the PrometheusRule now has a fourth
group, `truenas-backups`.

The rules are not in user-workload Prometheus. Its `/api/v1/rules` has no `truenas-*` group at all. They live in
**Thanos Ruler**, because OKD sends a PrometheusRule in a user namespace there unless the rule is scoped to
Prometheus:

```bash
KUBECONFIG=~/.kube/config-breakglass oc -n openshift-user-workload-monitoring exec thanos-ruler-user-workload-0 -c thanos-ruler -- \
  wget -qO- 'http://localhost:10902/api/v1/rules?type=alert' | jq -c '.data.groups[] | select(.name=="truenas-backups") | .rules[] | {name, health, state}'
```

On the first read, all six showed `health: unknown`. About a minute later all six read `ok` / `inactive`, as
expected before the collector is on the box. Two consequences:
- The plan's Part B alert checks queried `ALERTS` on Prometheus. They would have answered `[]` whatever was firing,
  so they now query the ruler.
- The platform Prometheus (`prometheus-k8s`) has no `truenas-*` groups either. So the session-start alert sweep,
  which reads `prometheus-k8s` `/api/v1/alerts`, cannot see any alert from a user-namespace PrometheusRule.
  Alertmanager (`alertmanager-main` `/api/v2/alerts?active=true`) sees everything that is firing.

### 2026-10-14 evening — converged, first run, full pull-back (plan Part B, Tasks 6–8)

The operator ran `playbook.yml`: `ok=74 changed=3 failed=0`. The three changes were the Hetzner credential, the
offsite task and the new collector. Read back with field-filtered queries:

```bash
ssh truenas_admin@192.168.1.25 "midclt call cloudsync.query" | jq -c '.[] | {id, description, enabled, transfers, transfer_mode, snapshot, path, folder: .attributes.folder, cred: .credentials.name, state: .job.state}'
```

The result: task 2 has `transfers: 2`, `SYNC`, snapshot on, `/mnt/tank/immich` → `/immich`, 06:00, both excludes, and
no job yet. The Synology task is unchanged, with `transfers: null`.

**The sub-account's view**, before any run:

```bash
ssh truenas_admin@192.168.1.25 "midclt call cloudsync.list_directory '{\"credentials\": 2, \"attributes\": {\"folder\": \"/\"}}'" | jq -c '[.[] | {Name, IsDir}]'
[]
```

That is an empty root with no `.zfs`. The login works, and the sub-account's root really is its base directory, so
`/immich` is right. This answers the spec's open question on the path layout over port 22.

**First run, by hand** (`midclt call --job cloudsync.sync 2`, output through the host-redaction `sed`):
- `SUCCESS` in 96 s: 231 of 231 files, 1.305 GiB, 12–18 MiB/s.
- Not one error, refused-connection or handshake line, so `transfers: 2` stays inside the box's 10-connection
  limit at this size.
- The job's `logs_excerpt` is the head of the log. The full log under `logs_path` is root-only, so the progress
  output that `--job` prints is the better witness here.

**Pull-back.** `cloudsync.sync_onetime` accepts the task fields; it requires `path`, `credentials`, `attributes`,
`direction` and `transfer_mode` (read with `midclt call core.get_methods cloudsync`). The steps:
1. A fresh push: 5 s, nothing changed.
2. `midclt call filesystem.mkdir '{"path": "/mnt/tank/backup/restore-test-20261014"}'`. The middleware creates the
   directory, so no sudo is needed.
3. The pull-back itself:

```bash
ssh truenas_admin@192.168.1.25 "midclt call --job cloudsync.sync_onetime '{\"path\": \"/mnt/tank/backup/restore-test-20261014\", \"credentials\": 2, \"attributes\": {\"folder\": \"/immich\"}, \"direction\": \"PULL\", \"transfer_mode\": \"COPY\", \"transfers\": 2}'"
```

It took 65 s for 231 of 231 files, 1.305 GiB, at about 18 MiB/s down, with no errors. Then `sha256sum` over every file
on both sides: `tank/immich` without `thumbs/` and `encoded-video/` against the restore directory.

| | files | read errors |
|---|---|---|
| source | 231 | 0 |
| restored | 231 | 0 |
| differing lines | 0 | |

The whole library comes back byte for byte from the box. At this size the restore time is about a minute; the
full-size drill (rollout step 8) gives the real number. The restore directory is deleted next. It was created after
the 18:00 `tank/backup` snapshot, so if it goes before 00:00, no snapshot pins it.

## 2026-10-14 — the backup warnings are emailed

The `truenas-backups` alerts shipped earlier today, but the Alertmanager routing only emails `severity = critical`
plus two allowlist routes. `TrueNASCloudSyncStale` fires as a warning at 36 h and `TrueNASCloudSyncDisabled` is a
warning, so a disabled offsite task would have sent nothing; both would only have shown in the console.

Two changes in `components/cluster-config/monitoring-config/templates/alertmanager-config.yaml`:

1. A new allowlist route, next to the `CNPGWALArchiveFailing` one: `alertname =~ TrueNASCloudSync.*` to `Critical`.
   These are the only alerts for the offsite photo backup. `TrueNASOffsiteReviewDue` is deliberately not matched. It
   stays console-only by the owner's choice: once it fires it stays firing until the plan changes, so it would
   re-send at every 12 h `repeat_interval`.
2. `task` added to `equal` in both inhibit rules. Without it a critical Stale for one Cloud Sync task would inhibit
   another task's warning (same namespace and alertname). A label missing on both sides counts as equal, so alerts
   without `task` inhibit as before.

Test first, with `amtool` v0.34.1 (checksum verified against the release `sha256sums.txt`). Rendered the Alertmanager
YAML from the Secret with `helm template ... --show-only templates/alertmanager-config.yaml | yq`, then ran
`amtool config routes test --config.file=<rendered> <labels>` for seven cases.

RED, unchanged config: `TrueNASCloudSyncDisabled` (warning) and `TrueNASCloudSyncStale` (warning) both went to
`Default`. The other five cases passed (Stale critical to Critical, ReviewDue to Default, CNPGWALArchiveFailing to
Critical, Watchdog to Watchdog, an unknown warning to Default).

GREEN, after the change: all seven pass, and `amtool check-config` reports SUCCESS. amtool cannot test inhibition,
so I compared the rendered `inhibit_rules` with `yq` before and after: only `equal` changed, to
`["namespace", "alertname", "task"]` in both rules.

### 2026-10-14 evening — one file back from a box snapshot (plan Part B, Task 9)

The operator took a manual snapshot in the console (`2026-10-14T16-42-57`) and connected with the **main** account over
SFTP from the Mac. The layout:
- snapshots sit at the main account's root, under `/.zfs/snapshot/<name>/`;
- the sub-account's base directory is a plain folder inside each snapshot, so the TrueNAS upload sits at
  `/.zfs/snapshot/<name>/truenas/immich/…`.

That answers the spec's last path question. Fetching a single photo:

```
sftp> get "/.zfs/snapshot/2026-10-14T16-42-57/truenas/immich/library/<path>.jpg" /Users/<me>/Downloads/
```

One trap: `sftp` does not expand `~` in the local path (`open local "~/Downloads/": No such file or directory`), so
the local path has to be absolute. `shasum -a 256` of the fetched file equals the `sha256sum` of the original on
TrueNAS, taken earlier for the pull-back. The snapshot path works for single-file restores, which is the job the
weekly snapshots are there for. The manual snapshot is deleted afterwards, so it does not hold one of the 10 slots.

2026-10-14: specs and plans are no longer kept in the repo; the design record is this draft.


## 2026-10-14 — the box itself in Prometheus: hcloud-exporter, built in git

The follow-up agreed in the Monitoring design above: the box's own fill, snapshots included, its access settings
and the health of the API feed, in Prometheus, with the alerts that matter emailed. The operator made a read-only
API token, proved it against `GET /v1/storage_boxes` (safe fields only) and sealed it; everything else is in git,
tested against stand-ins first, RED before GREEN.

The design spec and the plan are local working files and are deleted after implementation, so this section is the
design record. Nothing here is pushed or live yet: the build is six commits on `master`, and the rollout checks
(Part B) come after the push.

### Why

The box holds the only offsite copy of `tank/immich`, and nothing watched it. Its snapshots keep deleted photos for
up to ten weeks, and they count against the 1 TB. Its access settings can change in the console unseen.
`TrueNASOffsiteReviewDue` was only a proxy: it read the dataset, including data that is never uploaded.

### Decisions

| Decision | Choice | Note |
|---|---|---|
| Chart | `components/cluster-config/hcloud-exporter`, namespace `hcloud-exporter`, sync wave 5 | The same wave as the other exporters. |
| Image | `ghcr.io/promhippie/hcloud-exporter`, tag `3.30.0` pinned with its index digest | Renovate's `helm-values` manager replaces version and digest together. Reviewed PR. |
| Collectors | Storage Box only | Every other collector is set `false` explicitly. |
| Labels | `id`, `name`, `location` | Never `server` or `username`. |
| Token | Read-only. SealedSecret `hcloud-exporter`, key `token`, read through `file://` | The exporter reads it once, at start. |
| Email | The critical route, plus one allowlist route | See Email and egress. |

The chart follows `truenas-exporter`'s layout and `mikrotik-exporter`'s SealedSecret:
- Deployment: 1 replica, `maxSurge: 0`, `automountServiceAccountToken: false`; `runAsNonRoot` with seccomp
  `RuntimeDefault` and no `runAsUser` (restricted-v2 assigns the UID, which `runAsNonRoot` needs because the image's
  `USER` is a name); read-only root filesystem, no privilege escalation, all capabilities dropped; probes on
  `/healthz` and `/readyz`, port 9501; requests 10m / 32Mi, limits 100m / 64Mi.
- Environment: the token from `file:///etc/hcloud-exporter/token`; `HCLOUD_EXPORTER_REQUEST_TIMEOUT=5s`, under the
  10 s scrape timeout; the Storage Box collector on, the other eight collectors off; labels `id,name,location`.
- Service: ClusterIP, not headless, so the API server's service proxy can read `/metrics`.
- ServiceMonitor: every 60 s, `instance: hcloud-exporter`, `labeldrop pod|container`. Two Prometheus replicas scrape
  it, about 120 API calls an hour.

### Alerts

PrometheusRule group `hetzner-storagebox`, ten rules:

| Alert | Expression | for | Severity |
|---|---|---|---|
| `HetznerStorageBoxFilling` | `hcloud_storagebox_general_size / hcloud_storagebox_quota > 0.80` | 1h | warning |
| `HetznerStorageBoxFilling` | same, `> 0.90` | 15m | critical |
| `HetznerStorageBoxExposed` | `hcloud_storagebox_samba == 1` (label `setting: samba`), and the same for `webdav` | 15m | critical |
| `HetznerStorageBoxAccessClosed` | `hcloud_storagebox_ssh == 0` (label `setting: ssh`), and the same for `external` | 15m | warning |
| `HetznerStorageBoxSnapshotDirHidden` | `hcloud_storagebox_zfs == 0` | 15m | warning |
| `HetznerStorageBoxExporterDown` | `up{job="hcloud-exporter"} == 0` | 10m | warning |
| `HetznerStorageBoxApiFailing` | `increase(hcloud_request_failures_total{collector="storagebox"}[30m]) / increase(hcloud_request_duration_seconds_count{collector="storagebox"}[30m]) > 0.1` | 15m | warning |
| `HetznerStorageBoxUnmonitored` | `absent(hcloud_storagebox_general_size)` | 30m | warning |

- **Fill.** `general_size` is the API's usage with snapshots, and `quota` is the plan size; both HELP strings
  mislead. The two levels share one name, so the existing inhibit rule mutes the 80 % one once 90 % fires.
- **Drift.** The expected state is SSH on, external on, Samba off, WebDAV off, snapshot directory on. These are the
  main account's settings (see Limits). `AccessClosed` therefore means the single-file restore path is shut. A
  change the operator did not make means someone else is in the account.
- **Failures.** On an API error the exporter emits no box series, and `up` stays 1. The ratio ignores one failed
  call in about 60. `absent()` also catches a box that is missing from the list.
- **`keep_firing_for: 30m`** on the fill and drift rules, so a short API outage does not resolve them. A long one
  does: after 30 minutes without series they resolve, and `Unmonitored` takes over.

### Email and egress

- The critical route emails `Filling` at 90 % and `Exposed`.
- A new allowlist route in `monitoring-config`, `alertname =~ "HetznerStorageBox(Filling|AccessClosed|SnapshotDirHidden)"`,
  emails the warnings. They are actionable when they arrive, and none is standing.
- Console-only: `ExporterDown`, `ApiFailing`, `Unmonitored`. The session-start triage sees them. The backstop is the
  upload failing on a full box, which `TrueNASCloudSyncStale` emails.
- Egress to `api.hetzner.com:443` is open. The repo has no NetworkPolicy, the cluster has no EgressFirewall or
  AdminNetworkPolicy, and its 68 NetworkPolicies sit in platform namespaces.

### Dashboard

A new row, **Backup**, at the bottom of the TrueNAS single pane, using the dashboard's `${datasource}`:

| Panel | Query | Shows |
|---|---|---|
| Last successful run, per task | `time() - max_over_time(truenas_cloudsync_last_success_timestamp_seconds[7d])` | Hours since the last success. Green under 26 h, yellow to 36 h, red beyond, matching `TrueNASCloudSyncStale` |
| Task state | `truenas_cloudsync_enabled`, `_running`, `_last_job_success` | One line per task: enabled, running now, last job OK or failed |
| Storage Box fill | `hcloud_storagebox_general_size / hcloud_storagebox_quota` | Gauge with 80 % / 90 % marks, matching `HetznerStorageBoxFilling` |
| Box usage over time | `hcloud_storagebox_data_size` and `_snapshot_size` stacked, `hcloud_storagebox_quota` as a line | Data against snapshot overhead, against the plan size |
| Box access settings | `hcloud_storagebox_{ssh,external,samba,webdav,zfs}` | Five tiles, green in the expected state |

The Cloud Sync panels have data today. The box panels need the exporter, so the row ships in the same rollout.

### TrueNAS additions

Two small collector additions ship in the same rollout: snapshot space per dataset (a Capacity-row panel, no alert)
and an update-available metric (a Health tile and an info alert). Their design and build are in
`blog/blog-truenas-migration-draft.md` ("2026-10-14 — snapshot space per dataset and update-available, in the
collector").

### Limits

- **Sub-account settings are invisible.** The exporter calls `StorageBox.All` only, so it reads the box's access
  settings, not the upload sub-account's own. `TrueNASCloudSyncStale` still catches a broken upload.
- **No snapshot plan and no snapshot count**, only `snapshot_size` in bytes.
- **No success metric.** A failure looks like missing data.

### Open items

1. **`TrueNASOffsiteReviewDue`.** Decided 2026-10-14: replace it with the 80 % rule. That rule reads the box itself,
   snapshots included, follows a rescale, and is emailed; the dataset rule counted data that is never uploaded. It
   is removed in the commit that adds `HetznerStorageBoxFilling`.
2. **Whether the main account's SSH and external settings gate sub-accounts.** Hetzner's docs do not say, so the
   premise that turning them off breaks the upload is unconfirmed.
3. **Whether `stats.size` equals data plus snapshots.** Checked on the first scrape.

### Rulings 3–8 (from the plan)

3. **`HCLOUD_EXPORTER_WEB_ADDRESS` is set from `.Values.port`.** The spec's env list leaves it at the default
   (`0.0.0.0:9501`). Setting it keeps one source for the port that the Service and probes use.
4. **A `checksum/token` pod annotation over the sealed file.** The exporter reads the token once, at start
   (`config.Value` in `pkg/action/server.go`). Without the annotation a re-sealed token would need a manual restart,
   which is a mutating command; with it, ArgoCD rolls the pod when the file changes.
5. **`hcloud_request_duration_seconds_count{collector="storagebox"}` exists** (verified below). Unlike the failure
   counter, the histogram is not pre-initialised, so its series appears from the first scrape.
6. **The task-state panel's three queries are wrapped in `max by (task)`**, so the table joins on `task` alone.
7. **`update.status` edge cases** follow from "missing keys must not raise": a reply without a `status` object
   exports nothing, because unknown is not "up to date"; a `status` without `new_version` exports
   `truenas_update_available 0`; `truenas_update_downloaded` carries the offered `version` and exists only while an
   update is offered.
8. **The spec's "Out of scope: a dashboard" is superseded** by its Dashboard section, approved the same day.

### The build

Six commits on `master`, in order (base `f196d32`), then a docs commit for the README:

```
e6c125c hcloud-exporter: add promhippie/hcloud_exporter for the Storage Box at sync wave 5
f289109 hcloud-exporter: alert on Storage Box fill, access drift and API health; replace TrueNASOffsiteReviewDue
d87253b monitoring-config: email the Storage Box warnings
83549fa truenas: export dataset snapshot space and the offered TrueNAS update
ef76661 truenas-exporter: alert when a TrueNAS update is available
c451fcb grafana-config: add the Backup row, snapshot space and the update tile to the TrueNAS single pane
```

Plus a controller docs commit, `c802dcb` (the README's note that C2 retirement is expected within a week).

**Final-review fix wave.** The whole-branch review found that ruling 7's "a `status` without `new_version` exports
0" was wrong: the middleware model makes `new_version` required and `null` when nothing is offered, so only an
explicit `null` now means 0 and any other shape exports nothing and counts an error; the new tiles' no-data states
no longer render green; the exporter Deployment waits for the SealedSecret (sync wave) and sets
`enableServiceLinks: false`.

**The one unverified metric, now verified.** The ApiFailing ratio divides by
`hcloud_request_duration_seconds_count{collector="storagebox"}`, which I had read about but not seen. At v3.30.0,
`pkg/exporter/storagebox.go` observes the histogram right after the API call and before the error check:

```go
storageboxes, err := c.client.StorageBox.All(ctx)
c.duration.WithLabelValues("storagebox").Observe(time.Since(now).Seconds())
```

So `_count` counts failed calls too, and the ratio is sound. (`pkg/config/config.go` reads `file://` with
`os.ReadFile` and does not trim, which is why the token file must hold the bare token.)

**The image.** The tag's index digest was re-resolved against ghcr on 2026-10-14: an OCI image index
(`oci.image.index.v1+json`) with 386, amd64, arm/v6 and arm64 manifests, digest
`sha256:f1dba83dfd23dc553f05c8693b6a9648d3602ab267b0d81270bbaf07b4ddd3de`, the value already in the values file.

**The chart check** (a scratch script that renders the chart and asserts on the objects; not committed). RED with no
chart: 1 failed (`helm template renders`). GREEN: 25 PASS, 0 failed. It includes the `checksum/token` assertion: the
pod template must carry a 64-character checksum of the sealed file, so a re-sealed token rolls the pod. Lint passed,
kubeconform found 5 valid resources, and a read-only comparison with live showed the namespace and Application
absent, as they should be before the push. The root-app render goes from 47 to 48 Applications; the new one is at
wave 5 with prune and selfHeal.

**The rules.** `promtool test rules` against a scratch render. RED: `rules: 0` with 14 failing expectations (every
case that expects an alert). GREEN: 10 rules, `promtool check rules` SUCCESS, and the eight cases pass:
1. fill, warning at 85 % after an hour and critical at 95 % after 15 minutes, both firing together;
2. `keep_firing_for` bridges a short API outage;
3. and does not bridge a long one: the series stop at 29 minutes, the critical is held to about 65 minutes, then resolves;
4. access settings: the expected state fires nothing; then Samba on, SSH off and the snapshot directory hidden at 30 minutes, WebDAV on and external off at 60, one alert per setting;
5. API failures below the 10 % line stay quiet;
6. and above it, fire;
7. the exporter answers but reports no box: `Unmonitored` fires;
8. a box is reported, then the scrape fails from 10 minutes on: `ExporterDown` fires 10 minutes later, `Unmonitored` stays quiet.

A second script checks the alert table in this section against the rendered rules (22 PASS). Two mutations proved
the tests bite: removing every `keep_firing_for` fails cases 2 and 3, and replacing the ApiFailing ratio with
`increase(failures[30m]) > 0` fails case 5. A read-only comparison against live Thanos-evaluated rules showed only
`TrueNASOffsiteReviewDue` as the difference after the removal.

**`TrueNASOffsiteReviewDue` removed in the same commit** (Open 1), with its test case. The truenas-exporter rules go
17 to 16, and `truenas-backups` from 6 rules to 5.

**The route.** An amtool script feeds label sets to the rendered Alertmanager config and checks the receiver. RED on
the unchanged config: 3 FAIL (the three warnings reached `Default`, wanted `Critical`), 10 PASS. GREEN: 13 PASS,
`amtool check-config` SUCCESS, and the earlier 7-case script still passes. The inhibit rules are unchanged (diffed
before and after). The live config is a Secret and was not read; the route is checked on the live pods in Part B.

**The dashboard.** The single pane goes from 27 to 35 panels. RED: 11 failed checks (the missing row and panels).
GREEN: 18 PASS, 0 failed. The Backup row sits at y 55, directly under the last existing panel; nothing below the
edited rows moved. An expression test (`promtool`) pins the update tile's PromQL. Lint passed, kubeconform found 32
valid resources, and the live dashboard still reads 27 panels with `DashboardSynchronized=True` until the push.

**Real-box facts, read 2026-10-14** (the console and API, safe fields only): the API answered the box name
`homelab-offsite` in location `fsn1`; 1.40 GB of data, 0 snapshot bytes, quota 1 TiB (1,099,511,627,776 bytes);
access settings as designed.

The TrueNAS additions are in `blog/blog-truenas-migration-draft.md` ("2026-10-14 — snapshot space per dataset and
update-available, in the collector").

### Still to come (Part B)

Nothing is pushed or live. After the push: the Application syncs; ten rules `ok` in Thanos Ruler;
`general_size / quota` matches the console; the route is live on both Alertmanager pods; and the new `truenas_*`
series appear once the operator runs `playbook.yml`, which deploys the collector.

## 2026-10-14 — hcloud-exporter live: what the checks showed

Pushed `f196d32..8c75dd0` (19 commits). Everything below is read-only.

- **ArgoCD:** `hcloud-exporter`, `monitoring-config`, `grafana-config`, `truenas-exporter` and `root-app` all
  `Synced Healthy` at `8c75dd0`.
- **Pod:** `hcloud-exporter-…` runs under SCC `restricted-v2`, Running, 0 restarts, Ready. The SealedSecret condition
  is `Synced=True`.
- **Metrics,** read with the readonly kubeconfig through the API server's service proxy:
  `oc get --raw /api/v1/namespaces/hcloud-exporter/services/http:hcloud-exporter:9501/proxy/metrics`.
  - 13 `hcloud_storagebox_*` series. Their label keys are only `id`, `location` and `name`; a grep for `server=` or
    `username=` gives 0, and a grep for an account-number shape gives 0.
  - `general_size` = `data_size` = 1.398800384e+09, `snapshot_size` 0, `quota` 1.099511627776e+12.
  - Access: `ssh` 1, `external` 1, `samba` 0, `webdav` 0, `zfs` 1.
  - `hcloud_request_failures_total{collector="storagebox"}` 0; `hcloud_request_duration_seconds_count{collector="storagebox"}`
    present.
- **Scrape:** user-workload Prometheus target `serviceMonitor/hcloud-exporter/hcloud-exporter/0` is `up`, and
  `up{job="hcloud-exporter"}` = 1. `general_size / quota` = 0.00127 for `homelab-offsite`. The first query, right after
  the sync, returned nothing: the single API call counted at that point was my own proxy read, so the first real
  scrape came a minute or two later.
- **Rules in Thanos Ruler** (`thanos-ruler-user-workload-0`, port 10902, read via the break-glass kubeconfig the
  operator authorised for alert checks): `hetzner-storagebox` has 10 rules, health ok, inactive. The truenas-exporter
  groups are `truenas-availability` 3, `truenas-backups` 5, `truenas-disks` 3, `truenas-pools` 5 and
  `truenas-updates` 1: 17 rules, all ok and inactive.
- **Alertmanager:** `alertmanager-main-0` and `-1` both carry the route
  `HetznerStorageBox(Filling|AccessClosed|SnapshotDirHidden|Unmonitored)` → Critical. No Hetzner or TrueNAS alert is
  firing.
- **Dashboards:** `grafana/truenas-single-pane` is `DashboardSynchronized=True`, 35 panels.
- **Open question 3** (does `stats.size` equal data plus snapshots?) is still open: the box has 0 snapshot bytes. It
  gets checked once a weekly snapshot holds changed data.
- **Collector additions:** the operator then ran `playbook.yml` (`ok=72 changed=1 failed=0`; the one change is the
  collector file). The check of the new `truenas_*` metrics follows.

The collector check that followed the operator's `playbook.yml` run: the next 5-minute cron run wrote the new series,
with `truenas_textfile_collector_errors 0`.
- 18 `truenas_dataset_snapshots_used_bytes` series, among them `tank/media` at 48,599,816,496 bytes, `tank/immich`
  at 91,988,160 and `tank/backup` at 130,944. So the deleted restore-test directory never made it into a
  `tank/backup` snapshot.
- `truenas_update_available{version="25.10.7"} 1` and `truenas_update_downloaded{version="25.10.7"} 1`, also visible
  in user-workload Prometheus. `TrueNASUpdateAvailable` (info, console only) is due an hour later. It stays until
  the 25.10.7 upgrade, which is a README TODO.

The operator checked the TrueNAS single pane by eye the same evening:
- the update tile reads "25.10.7" in blue;
- the snapshot-space table is populated, with `tank/media` at 45.3 GiB;
- the Backup row shows the last success per task (16.0 h Synology, 2.6 h offsite), both tasks idle and OK, the box at
  0.127 %, and all five access tiles green, Samba and WebDAV "off" included. So the per-tile overrides render as
  designed.

The exporter work is done. Its spec and plan were local working files and are deleted; this draft is the design
record.
