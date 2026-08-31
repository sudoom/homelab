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
| SMB Time Machine targets for the Macs | `truenas-smb` | global flag + groups/users/shares matched on name; dataset ACLs on owner/acltype/ACE drift |
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
- **SMB shares for `personal` / `work`.** The Time Machine half of SMB **is**
  managed now (`truenas-smb`, 2026-08-31), including the global
  `aapl_extensions` flag, per-Mac users/groups, NFSv4 dataset ACLs and the
  service. What is still open is the *human* file shares: they need a user and
  group model for people rather than machines, and `tank/work` has an
  undecided `casesensitivity` (see the create-time-only note below).
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

## Create-time-only dataset properties

Three ZFS properties are fixed when a dataset is created and can never be
changed: **`casesensitivity`** above all, plus the practical starting state of
`acltype` / `aclmode`. There is no `zfs set`, no rename-in-place, no workaround.

Everything else in this repo reconciles. These cannot, and pretending otherwise
is the dangerous option: `pool.dataset.update` **accepts** `casesensitivity`,
silently does nothing, and returns success — so a "reconcile" task would report
`ok` forever while the property stayed wrong. `truenas-storage` therefore
**asserts** them and fails the run, naming the drifted datasets.

The only remedy is destroy + re-create, which is a separate gated one-shot
because it is irreversible:

```bash
cd ansible/truenas
./destroy-empty-dataset.sh timemachine              # dry run: prints the gate
./destroy-empty-dataset.sh timemachine --destroy    # actually destroy
ansible-playbook -i inventory.yml playbook.yml      # re-create from group_vars
```

The script only ever **destroys**; re-creation belongs to the playbook, which
already knows every declared property. A script that also created would be a
second definition of the same datasets, free to drift from `group_vars`.

Its gate is re-derived on the box at execution time and refuses a dataset that
is not empty, has any snapshot, has any child dataset, is referenced by an SMB
or NFS share, does not exist, or is appliance-owned (`.system`, `ix-apps`). It
reports *every* reason it refused, not just the first.

**The deadline is not a date, it is the first byte written.** While a dataset is
empty this costs nothing; once data lands the fix is copy-out / destroy /
re-create / copy-back. `tank/work` is currently empty with an undecided
`casesensitivity` — decide before anything mounts it.

## Time Machine

Two Macs, one dataset each, one SMB share each, one account each:

| | `tank/timemachine/macmini` | `tank/timemachine/mba` |
|---|---|---|
| share | `macmini-tm` | `mba-tm` |
| account | `tm-macmini` (uid 3001) | `tm-mba` (uid 3002) |
| quota | 1000 GiB | 500 GiB |

with `tank/timemachine` itself carrying a 1500 GiB parent quota — the exact sum,
so it caps the tree without ever binding before a child's own quota does.

Three things about this that are not obvious:

- **`aapl_extensions` must be enabled globally before any share is created.**
  `sharing.smb.create` with `purpose: TIMEMACHINE_SHARE` is rejected while it is
  false, and the error names the share rather than the missing global. The role
  orders itself around this.
- **TrueNAS 25.10 replaced the per-share feature booleans** (`timemachine: true`,
  `vfsobjects`, …) with a single `purpose` enum plus a discriminated `options`
  object. Every pre-25.10 guide sets fields that no longer exist here. `purpose`
  must additionally appear *inside* `options` — it is the union discriminator
  and is `required` there, and the branch is `additionalProperties: false`.
- **`vuid` is pinned, not generated.** It is the Time Machine volume UUID
  advertised over mDNS; passing null makes the middleware mint a new one, which
  would hand the Mac a different volume identity after any future run and invite
  "Time Machine must create a new backup". The literal UUIDs in `group_vars` are
  identifiers, not secrets.

Deliberate non-defaults: `auto_snapshot: false` (Time Machine already keeps its
own version history, and snapshots would pin the rewritten 8 MiB bands against a
hard quota), `auto_dataset_creation: false` (auto-created children inherit no
quota, so one Mac could eat the other's space), `timemachine_quota: 0` (the ZFS
quota is the real ceiling; the SMB value only lies to the client about disk size,
and two ceilings that can disagree is worse than one).

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
| `vars/vault.yml` | **Gitignored**, vault-encrypted; SMTP credentials + the two SMB Time Machine passwords |
| `playbook.yml` | Full convergence (vault OPTIONAL since 2026-08-28 — only the SMTP alert-email vars need it) |
| `check.yml` | Read-only state report (no vault) |
| `roles/truenas-storage/` | Assert pool, converge datasets |
| `roles/truenas-system/` | Timezone, NTP, alert email |
| `roles/truenas-shares/` | NFS exports + service enablement |
| `roles/truenas-smb/` | SMB Time Machine targets: `aapl_extensions`, per-Mac users/groups, dataset ACLs, shares, service |
| `roles/truenas-tasks/` | Scrub, SMART cron jobs, periodic snapshots |
| `roles/truenas-apps/` | garage S3 server (Velero BSL): app deploy/update + layout/key/bucket bootstrap |
| `bootstrap-pool.sh` | One-shot gated pool creation (deliberately NOT in the playbook) |
| `destroy-empty-dataset.sh` | One-shot gated destroy of an **empty** dataset — the only remedy for create-time-only property drift (deliberately NOT in the playbook) |

Full chronology, decisions and the gaps found in the original plan:
`blog/blog-truenas-migration-draft.md`.
