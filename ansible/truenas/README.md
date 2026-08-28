# TrueNAS SCALE — Ansible-managed configuration

Configuration-as-code for the TrueNAS SCALE box that replaces the Synology
DS418. Applied manually from a workstation; **not** wired into ArgoCD (the NAS
must not depend on the cluster being up).

Hardware: Supermicro X11SCH-F / Xeon E-2146G / 32 GB DDR4 ECC / 6× HGST 4 TB
(`HUS726040ALA610`) + Intel DC S3510 boot. TrueNAS 25.10.6 "Goldeye" Community.

## Why `midclt`, not the REST API

This is the load-bearing design decision, so it is stated here rather than
buried in a comment.

TrueNAS exposes two management APIs:

| | Status on 25.10 | Reachable from `ansible.builtin.uri`? |
|---|---|---|
| REST `/api/v2.0/` | **Deprecated in 25.04, REMOVED in TrueNAS 26** | Yes |
| JSON-RPC 2.0 over WebSocket | Current | **No** — `uri` is HTTP-only |

REST still answers on our box (verified: `GET /api/v2.0/system/info` → `401`,
i.e. present but unauthenticated; `/api/current` → `404`), and from 25.10.1
TrueNAS raises a **daily alert** every time it is used. TrueNAS 26 is already at
BETA.3. So an `ansible.builtin.uri`-against-REST role would work today and need
a full rewrite at the next major upgrade.

`midclt` is the middleware's local CLI — the same interface the web UI drives,
over a local UNIX socket. It is indifferent to the HTTP/WebSocket transition,
it keeps us inside the repo's **all-builtin invariant** (only
`ansible.builtin.command`/`assert`/`set_fact`/`debug` are used here), and it
needs no API key at all: **SSH access is the credential.**

Rejected alternatives:

- **`arensb.truenas` collection** — actively maintained, but a third-party
  collection violates the all-builtin invariant.
- **Terraform** (`PjSalty/truenas` is the only maintained JSON-RPC provider,
  and the only one covering NUT) — introduces a new tool and a state file to a
  repo with no Terraform, and models `zpool` only as a raw `topology_json`
  escape hatch. Not worth it for one appliance.

## What this manages

| Area | Role | Idempotency |
|---|---|---|
| Datasets + `recordsize` | `truenas-storage` | query → create missing → reconcile drift |
| Timezone, NTP, alert email | `truenas-system` | singletons (`.config`/`.update`) |
| NFS exports to the OKD nodes | `truenas-shares` | matched on export path |
| Scrub, SMART cron jobs, periodic snapshots | `truenas-tasks` | scrub/snapshots on pool+dataset, SMART on cron `description` |
| garage S3 app (backs the Velero BSL) | `truenas-apps` | app name; ports/bindings reconciled; layout+key+bucket bootstrapped over the admin API |

## What it deliberately does NOT manage

Declared explicitly, because once a box is under Ansible the "code-only" rule
applies — anything not listed here is a manual action that the playbook will
not fight, and anything **added** here must never again be changed in the UI.

- **`--check` is BLIND on `playbook.yml` — do not trust `changed=0`.** Every
  mutation here is an `ansible.builtin.command` (midclt) call, and the command
  module does not support check mode, so `--check` skips all of them regardless
  of their `when:`. A when-false skip and a check-mode skip render identically.
  Verified 2026-08-28: `--check` reported `changed=0` against a fresh pool that
  was missing 8 datasets, 3 NFS exports, 3 cron jobs and 3 snapshot tasks. The
  play's `post_tasks` drift report is the answer `--check` should have given —
  read that block, not the recap.
- **Pool / vdev creation.** `pool.create` is a one-shot destructive job: run
  twice it either errors, or — against wiped disks — silently builds a new
  empty pool where the old one was. The storage role **asserts** the pool
  exists and fails loudly if not. See bootstrap below.
- **`ashift`.** Create-time-only per vdev and immutable afterwards. Note it is
  **not a `pool.create` parameter at all** — the middleware derives it from the
  disks' reported sector size, so it can only be *verified* after creation, not
  requested. 12 is correct for these 512e drives; 9 would mean rebuilding the
  pool is the only fix.
- **Network interfaces, IP, MTU.** Automating the network config of a box you
  reach *over* that network is how you lock yourself out, and TrueNAS's
  commit-then-confirm rollback does not survive an Ansible run whose connection
  has already dropped.
- **SSH hardening / 2FA / root login.** 25.10 ships root login disabled and an
  admin account already; re-asserting risks locking out the account this
  playbook connects as. `check.yml` reports it instead.
- **SMB shares, users, groups, dataset ACLs.** Needs its own decision set
  (users, groups, ACL model). Out of scope rather than half-done.
- **`config.save`.** TrueNAS's config export is DR, not IaC: a SQLite DB inside
  a tar that cannot be diffed, reviewed, or partially applied, and restoring it
  reboots the box. With `secretseed: true` it decrypts every stored credential,
  so it can never live in this repo; without the seed it silently resets every
  password. It belongs as a scheduled **off-box** artifact — the complement to
  this topic for the things that cannot be expressed declaratively at all
  (`pwenc_secret`, API keys, SSH host keys). It does not carry the pool.
- **NUT / UPS.** Lands when the CyberPower CP1600 does. The tooling path is
  already reserved as the `apps` dataset — `/root` and `/etc` do **not** survive
  TrueNAS updates, so it has to live on the pool.

## Bootstrap (one-time)

0. **SMART is not a TrueNAS feature any more.** 25.10 "Goldeye" removed smartd,
   the `smart.*` API and the test scheduler. A fresh install tests nothing and
   reads nothing. `truenas-tasks` therefore creates three **cron jobs** (short
   weekly, long monthly, and a daily reader that mails only on trouble) — see
   `truenas_smart_cronjobs` in `group_vars/all.yml`. Do not go looking for the
   SMART page in the UI; it is gone.

1. **Burn in every drive before trusting it.** SMART baseline → destructive
   `badblocks -wsv -b 4096` → SMART long → diff against the baseline. Any growth
   in `Reallocated_Sector_Ct`, `Current_Pending_Sector` or
   `Offline_Uncorrectable` means the drive does not go in the pool. On used
   datacenter pulls also confirm no DDF firmware-RAID superblocks first
   (`wipefs -n /dev/sdX`, expect empty).

2. **Create the pool** — one 6-wide **RAIDZ2** vdev named `tank`, leaving 2
   bays free as `zfs send | recv` runway (a RAIDZ vdev's width can never
   shrink). Use the committed script, not the UI and not a pasted disk list:

   ```bash
   cd ansible/truenas
   ./bootstrap-pool.sh            # dry run: prints the gate result + payload
   ./bootstrap-pool.sh --create   # apply, then verify
   ```

   The member set is re-derived **at execution time** and gated on model, count,
   "not already in a pool", and "not in `boot.get_disks`" — because SATA
   enumeration is not stable across reboots and the boot device is also SATA, so
   a disk list captured today can name the boot disk tomorrow. Any mismatch
   aborts with exit 1 before `pool.create` is reached.

3. **Create the vault file** with SMTP credentials for alert email:
   ```bash
   cd ansible/truenas
   cp vars/vault.yml.example vars/vault.yml
   ansible-vault encrypt vars/vault.yml     # or: ansible-vault create vars/vault.yml
   ```

4. **Dry-run the read path** (no vault needed):
   ```bash
   ansible-playbook -i inventory.yml check.yml
   ```

5. **Converge:**
   ```bash
   ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass
   ```

6. **Send a test alert email from the UI** and confirm it arrives. An unverified
   alert path is the same as no alert path — and on a drive cohort where all
   six disks are within 1% of the same power-on hours, alerting is the control.

## Day-2

```bash
cd ansible/truenas
ansible-playbook -i inventory.yml check.yml                      # read-only, no vault
ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass  # converge
ansible-playbook -i inventory.yml playbook.yml --syntax-check    # lint only
```

A converged box reports `ok` for every task and `changed=0`. Any `changed` on a
re-run is drift — investigate it rather than accepting it as noise.

`--check` is a partial dry run only: the `.query` tasks carry `check_mode: false`
so they still run and the conditionals still evaluate, but `ansible.builtin.command`
skips the mutating tasks, so you see *which* calls would fire without seeing their
effects. Useful for "is anything drifted"; not a substitute for reading the diff.

## Files

| Path | Purpose |
|---|---|
| `inventory.yml` | Single host `truenas`, mgmt address, `truenas_admin` + sudo |
| `group_vars/all.yml` | All declarative inputs: pool name, datasets, NFS clients, NTP, schedules |
| `vars/vault.yml.example` | Committed template (no secrets) |
| `vars/vault.yml` | **Gitignored**, vault-encrypted; SMTP credentials only |
| `playbook.yml` | Full convergence (vault OPTIONAL since 2026-08-28 — only the SMTP alert-email vars need it) |
| `check.yml` | Read-only state report (no vault) |
| `roles/truenas-storage/` | Assert pool, converge datasets |
| `roles/truenas-system/` | Timezone, NTP, alert email |
| `roles/truenas-shares/` | NFS exports + service enablement |
| `roles/truenas-tasks/` | Scrub, SMART cron jobs, periodic snapshots |
| `roles/truenas-apps/` | garage S3 server (Velero BSL): app deploy/update + layout/key/bucket bootstrap |
| `bootstrap-pool.sh` | One-shot gated pool creation (deliberately NOT in the playbook) |

Full chronology, decisions and the gaps found in the original plan:
`blog/blog-truenas-migration-draft.md`.
