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

**A job method must be called with `--job`, or its failure is invisible
(found 2026-09-11).** Some middleware methods run as jobs, and
`core.get_methods` marks them `job: true`. Without `--job`, `midclt call`
returns the job id immediately with rc 0; the job then fails where nothing
reads it, and the task reports `changed` with no error. `pool.update` did
exactly that on every run — rejecting `{"autotrim": true}` in the middleware
job log while every play reported `failed=0`. Audited the same day against
`core.get_methods`: of the mutating methods this topic calls, it was the only
job method missing `--job`. Check the flag before adding a mutating call:

```bash
midclt call core.get_methods | python3 -c 'import sys,json; print(json.load(sys.stdin)["pool.update"]["job"])'
```

**Corollary for anything OUTSIDE this topic that wants to drive the box
(added 2026-09-09).** The same wall stops a cluster-side caller. A CronJob in
`components/` — the natural shape for a `truenas-cert-sync` ported from
`synology-cert-sync` — cannot speak JSON-RPC over websocket from a shell
script either, and its three exits are all worse than they look: the
deprecated REST is a rewrite scheduled for TrueNAS 26; SSH-plus-`midclt` from
a pod puts a private key in the cluster and makes the cluster an administrator
of the NAS, inverting the dependency direction this split exists to preserve;
and a websocket client is more machinery than the chart it would be copying.
So "just write a CronJob for it" is not the cheap option it appears to be —
check `blog/blog-truenas-migration-draft.md` (2026-09-09) before assuming it.

## What this manages

| Area | Role | Idempotency |
|---|---|---|
| Datasets + `recordsize` | `truenas-storage` | query → create missing → reconcile drift |
| Timezone, NTP, alert email | `truenas-system` | singletons (`.config`/`.update`) |
| NFS exports to the OKD nodes | `truenas-shares` | matched on export path |
| SMB Time Machine targets for the Macs | `truenas-smb` | global flag + groups/users/shares matched on name; dataset ACLs on owner/acltype/ACE drift |
| Scrub, SMART cron jobs, periodic snapshots | `truenas-tasks` | scrub/snapshots on pool+dataset, SMART on cron `description` |
| garage S3 app (backs the Velero BSL) | `truenas-apps` | app name; ports/bindings reconciled; layout+key+bucket bootstrapped over the admin API |
| node_exporter custom app | `truenas-apps` | app name; compose payload reconciled on image drift (nothing on the box flags a custom app as outdated — see below) |
| Syncthing catalog app (Mac ↔ Mac sync of `~/Projects`) | `truenas-apps` | app name; declared values reconciled against `app.config`; the pre-catalog custom app is deleted once, only while it is still custom |

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
- **Syncthing's folder and device pairing.** The app, its dataset, its
  ownership and its snapshot task are all converged; the *folder* definition
  and the three device pairings are not. Syncthing rewrites `config.xml` at
  runtime, so a templated file would fight the container. They are recorded as
  documented state under "Syncthing" below instead. Phase 2 could converge them
  over Syncthing's own REST API with `ansible.builtin.uri` — legitimate here
  even though this topic avoids `uri` for TrueNAS itself, because that
  avoidance was about TrueNAS's REST API being removed in 26, and Syncthing's
  is stable. It needs an API key in the vault.
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

`tank/sync` (2026-09-09) is the counter-example: it was created `SENSITIVE`
deliberately, and it could be decided precisely because nothing will ever mount
it over SMB. Its only writer is Syncthing on the Linux side, receiving from two
case-**insensitive** APFS volumes, so a pair of names differing only by case
cannot arrive and `SENSITIVE` has nothing to collide. Note what this did *not*
do: the Syncthing work deliberately landed on its own dataset rather than in
`tank/work`, so it did not force the open decision above.

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

## Syncthing

Replaces Synology Drive Client, which was doing exactly one job here: two-way
sync of `~/Projects` between the Mac mini and the MacBook Air.

| | |
|---|---|
| app | `syncthing` — **catalog** app, stable train, `1.3.13` (a custom compose app from 2026-09-09 to 09-11) |
| GUI | `http://192.168.1.25:8384/` — a password is required, set at first login |
| sync | `tcp://192.168.1.25:22000`, `quic://192.168.1.25:22000` |
| data | `tank/sync` → `/data/projects` in the container |
| state | `tank/apps/syncthing` → `/var/syncthing` (Syncthing keeps it under `config/`) |
| snapshots | every 2 h, kept 30 days |
| this node's folder type | **Receive Only** |

**The two Macs peer directly; this box is not load-bearing for the sync
itself.** It earns its place twice — as the always-on third node, so a change
on the MacBook lands somewhere while the mini is asleep, and as the snapshot
host. Two-way sync propagates a deletion to every peer within seconds, so the
ZFS task on `tank/sync` is the entirety of the recycle bin Drive Client used to
provide. That is the reason this node exists in the mesh at all.

**Why a catalog app.** This topic's rule is custom only when no TrueNAS train
ships the app — node_exporter is custom for exactly that reason, garage is not.
Syncthing is in the stable train. It was first built as a custom compose app
without checking, and both defects its first run found came from that: pinning
the GUI inside Syncthing broke the image's own loopback healthcheck, and the
custom app only reconciled on image drift. iX now maintains the compose and the
healthcheck, and TrueNAS tracks upgrades. **The one cost:** iX's template
hardcodes `SYS_ADMIN` and sets `PCAP` so the syncthing binary holds
`cap_sys_admin`, for ownership-sync features this mirror does not use. No value
turns it off.

**Published ports on all interfaces, not host networking.** The template
publishes ports only when `host_network` is false. Binding them to the frontnet
alone is not possible: `app.ip_choices` here offers `0.0.0.0`, `::` and
`192.168.10.10` — the mgmt address `192.168.1.25` is not among them, the same
limit garage hit. So the GUI and sync port also answer on the storage backnet,
whose only members are the three OKD nodes' host stacks (pods cannot route
there); the GUI password is what closes that. And local discovery cannot find
this node — the broadcast does not cross the docker bridge and 21027 is not
published — so each Mac adds it **by address**.

**Upgrades** work the way garage's do: TrueNAS shows `upgrade_available` and
the Apps screen applies it. `truenas_syncthing.version` is read only at create,
so after an upgrade the declaration goes stale — garage declares `1.2.5` while
`1.2.8` runs (2026-09-11).

**Migrating from the custom app** happens on the first playbook run after the
switch: `truenas-apps` deletes the app only while it is still a custom app, then
creates the catalog one. Nothing had been paired, so nothing is lost, and both
datasets and their snapshots are untouched. The device ID regenerates, because
the catalog app mounts the dataset at `/var/syncthing` and Syncthing keeps its
state under `config/`; the `config.xml`, keys and database at the dataset root
are left over from the custom app and unused.

### One-time pairing

Not converged by Ansible (see "What it deliberately does NOT manage"). Do this
once, then record the device IDs in the table below.

0. **Let Drive Client finish first, then stop it.** If the two Macs' trees are
   not already identical when Syncthing pairs them, you get the *union* of both
   plus a scattering of `.sync-conflict-*` files. Confirm Drive Client shows
   both Macs in sync, then remove its sync task before continuing.
1. **This box first**, at `http://192.168.1.25:8384/`: set a GUI user and
   password, then under Settings → Connections turn **off** global discovery,
   relaying and NAT traversal.
2. **Both Macs:** `brew install --cask syncthing-app` — the Syncthing project's
   macOS app, not the Homebrew formula. On 2026-09-11 this laptop blocked
   ad-hoc-signed binaries, which Homebrew-built formulae are, from every LAN
   address; a Syncthing that cannot reach `192.168.1.x` pairs with nothing. The
   app asks for local network access like any Mac app — allow it. Then turn
   the same three settings off in each Mac's GUI.
3. On each Mac, add this box as a device with addresses
   `tcp://192.168.1.25:22000, quic://192.168.1.25:22000`. Left as `dynamic` it
   is never found, because it cannot be discovered.
4. On the Mac holding the canonical tree, add `~/Projects` as a folder, type
   **Send & Receive**, and share it with the other Mac and with this box.
5. On this box's GUI, accept the shared folder, set its path to
   `/data/projects`, and set folder type to **Receive Only**. This is the step
   that keeps the NAS from becoming a third writer — it is not a default.
6. On the second Mac, accept the same folder at `~/Projects`, type
   **Send & Receive**.
7. Ignore list: copy `files/projects-stignore-shared` to
   `~/Projects/.stignore-shared`, then set each of the three peers' `.stignore`
   to the single line `#include .stignore-shared`. Syncthing does not sync
   `.stignore` itself, which is exactly why the real list lives in an included
   file that *is* synced — otherwise the three nodes drift on what they ignore.

| node | device ID |
|---|---|
| mac mini | _fill in once paired_ |
| macbook air | _fill in once paired_ |
| truenas | _fill in once paired_ |

### Rules nothing enforces

- **Never write into `/mnt/tank/sync` by hand.** Receive-only reverts it on the
  next scan. It is not a share and is deliberately not exported over NFS or SMB.
- **Do not have the same repo open and being written on both Macs at once.**
  Syncthing writes `.sync-conflict-*` files, and inside `.git` those are
  genuinely unpleasant to unpick. This is the same rule Drive Client silently
  needed; it is behavioural, and no setting substitutes for it.
- **`.git` is synced on purpose.** Ignoring it would leave the peers sharing a
  working tree with no branch and no history, and would make this node useless
  as a restore source.
- **LAN-only.** Global discovery and relays stay off: the MacBook does not sync
  while away, and `git push` covers tracked work in the meantime. Turning them
  on would route traffic through third-party relays; the alternative is a real
  overlay network, which the homelab does not have.
- **No offsite.** Tracked content is on GitHub; the untracked half lives on two
  Macs and this box, all one site.

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
| `roles/truenas-apps/` | garage (Velero BSL) and Syncthing as catalog apps, node_exporter as a custom app: deploy/update, and garage's layout/key/bucket bootstrap |
| `files/projects-stignore-shared` | Syncthing ignore list for `~/Projects`. Copied to `~/Projects/.stignore-shared` on every peer; not applied by Ansible |
| `bootstrap-pool.sh` | One-shot gated pool creation (deliberately NOT in the playbook) |
| `destroy-empty-dataset.sh` | One-shot gated destroy of an **empty** dataset — the only remedy for create-time-only property drift (deliberately NOT in the playbook) |

Full chronology, decisions and the gaps found in the original plan:
`blog/blog-truenas-migration-draft.md`.

## Updating a custom app (node_exporter)

`garage` is a **catalog** app: TrueNAS tracks the upstream version, sets
`upgrade_available`, and the UI offers a button.

`node-exporter` is a **custom (compose)** app, and that button will never
appear for it. (`syncthing` was one too, from 2026-09-09 to 09-11; it is now a
catalog app and upgrades the way garage does.) There is no catalog entry to compare against, so `app.query` reports
`upgrade_available: false` permanently and `version` is a synthetic `1.0.0` that
never moves. `app.outdated_docker_images` does not help either — it only detects
a **mutable** tag (`:latest`) whose digest changed upstream; against a pinned tag
it returns `[]` forever.

So nothing on the box will ever tell you the image is old. The update path is:

1. **Renovate opens a PR.** `renovate.json` has a `customManagers` entry
   watching every pinned `image:` line in `group_vars/all.yml`, using the
   `docker` datasource — the same treatment every other image in this repo
   gets. It matches on the field name rather than on a variable name, so a
   future custom app is covered without a second manager.
2. **Merge it.**
3. **Run the playbook.** `truenas-apps` compares the declared image against
   `app.query`'s `active_workloads.images` and calls `app.update` with the new
   compose when they differ.

```bash
cd ansible/truenas && ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass
```

Step 3 is not optional and is easy to forget: the role was **create-only** when
first written, which meant editing the tag changed nothing on the box while the
play still reported converged — the same "declared but never applied" trap as the
auto-created scrub task and the un-applied dataset quota. The reconcile task now
closes it.

**On `node-exporter` that closes it for the image only.** Any other change to its
compose — an argument, a mount, a label — is still declared-but-never-applied.
`syncthing` hit exactly this on its first change (the healthcheck override,
2026-09-11); a hash of the whole compose stamped into a `pl.sudops.compose-sha`
label fixed it and was verified live before Syncthing moved to the catalog app.
`node-exporter` should get the same before its compose next changes for any
reason other than a tag bump.

**Proven end to end on 2026-09-08**: the customManagers entry was committed, Renovate opened
[#175](https://github.com/sudoom/homelab/pull/175) (`v1.9.1` -> `v1.12.1`) within minutes against that very commit,
and one playbook run moved the box. Verify with `node_exporter_build_info` rather than the tag — the tag proves
what was requested, `build_info` proves what is running.

To check what is actually running:

```bash
midclt call app.query | python3 -c "
import json,sys
for a in json.load(sys.stdin):
    print(a['name'], a.get('custom_app'), a.get('active_workloads',{}).get('images'))"
```
