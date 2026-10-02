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
