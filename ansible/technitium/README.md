# Ansible playbook — technitium DNS server

Configures and maintains the home DNS server (replacing pi-hole). Runs against a Raspberry Pi 3B+ (primary) at `192.168.1.12`, and eventually a Raspberry Pi Zero 2W (secondary). See `blog/blog-technitium-dns-migration-draft.md` at the repo root for the design rationale.

## Why this lives outside ArgoCD

The box runs **outside** the OKD cluster. ArgoCD can't reach it, but more importantly: **DNS shouldn't be circularly dependent on the cluster being up.** If the cluster's storage hangs (as happened 2026-05-12), the dashboards go dark — losing DNS at the same time would compound the outage. Ansible-pull / push from a workstation keeps the failure domains separate.

## Repo layout

```
ansible/technitium/
├── inventory.yml                          # dns-master; dns-secondary commented out (not procured yet)
├── playbook.yml                           # top-level entrypoint, applies all roles
├── group_vars/all.yml                     # shared config: zone records, blocklist policy, rate limits
├── vars/vault.yml.example                 # template for the (gitignored) vault file
├── files/
│   └── blocked.urls                       # blocklist URLs, one per line
├── roles/
│   ├── base/                              # OS hygiene (hostname, timezone, NTP, packages, unattended-upgrades, pi-hole purge)
│   │   ├── tasks/main.yml
│   │   ├── handlers/main.yml              # restart systemd-timesyncd
│   │   └── templates/10-ntp.conf.j2       # timesyncd drop-in — ALL servers in NTP=, never FallbackNTP=
│   ├── technitium-install/                # idempotent Technitium install/upgrade via upstream installer
│   ├── technitium-config/                 # zones + settings + blocklists via Technitium HTTP API
│   └── technitium-cluster/                # primary/secondary replication (placeholder until secondary lands)
└── .gitignore                             # vars/vault.yml stays out of Git
```

## First-time setup (operator, manual)

1. **Spare SD card** for the new box. Use Raspberry Pi Imager and pre-configure:
   - **OS**: Raspberry Pi OS Lite, 64-bit (Bookworm). Same kernel family as the current pi-hole (`6.12.x`, `aarch64`).
   - **Hostname**: `dns-master` (matches the inventory key; web UI reachable at `http://dns-master:5380` from anywhere on the LAN that resolves it)
   - **Username**: `admin` (not the default `pi` — matches the inventory's `ansible_user`)
   - **SSH**: enable, with public-key authentication. Paste `~/.ssh/vadz_key.pub` from the workstation as the authorized key.
   - **Locale/timezone**: as needed; the playbook sets `Europe/Warsaw` regardless.
2. **First boot**: SSH should work directly with `ssh admin@<box-ip> -i ~/.ssh/vadz_key`. Sanity-check with `sudo -n true` (passwordless sudo expected on RPi imager's default; if not, store `ansible_become_password` in the vault — see step 7).
3. **Static IP**: reserve the box's MAC at `192.168.1.12` on `gw.home.lab` (or whatever final IP it gets). For initial validation, bring it up on a temporary IP — the swap to `.12` happens at cutover.
4. **Install Technitium** manually:
   ```
   curl -sSL https://download.technitium.com/dns/install.sh | sudo bash
   ```
5. **Browse to `http://<box-ip>:5380`** and set the admin password (Technitium forces this on first visit).
6. **Workstation**: install Ansible (`brew install ansible` / `apt install ansible`). All tasks use `ansible.builtin.*` modules only — no external collections required.
7. **Vault**: create the encrypted secrets file:
   ```
   cd ansible/technitium
   ansible-vault create vars/vault.yml
   ```
   Paste the template from `vars/vault.yml.example` and set `technitium_admin_password` to whatever you set in step 5. Add `ansible_become_password` too if sudo on the box is password-protected (skip if passwordless).

## Day-2: apply config

```bash
cd ansible/technitium
ansible-playbook -i inventory.yml playbook.yml \
  --ask-vault-pass \
  --limit dns-master
```

The playbook is idempotent — re-run after every config change. Day-2 flow:

1. Edit `group_vars/all.yml` (e.g. add a record to `okd_nodes`, change `technitium_rate_limit_per_client_per_minute`).
2. Or edit `files/blocked.urls` to add a blocklist.
3. Commit to Git.
4. Re-run the playbook.

## Upgrading the host (OS + Technitium)

A separate playbook `upgrade.yml` handles periodic maintenance — OS package upgrades and Technitium DNS Server in-place upgrade together:

```
ansible-playbook -i inventory.yml upgrade.yml \
  --ask-vault-pass \
  --limit dns-master
```

What it does:
1. `apt update` + `apt full-upgrade --autoremove --autoclean` (OS layer)
2. If `/var/run/reboot-required` exists after the upgrades: reboot, wait up to 5 min for the box to come back, and verify `dns.service` is active before continuing
3. Re-run Technitium's upstream installer (in-place upgrade; preserves `/etc/dns/config/`)
4. Post-checks: `dns.service` active + Technitium API responding

Expected DNS downtime: **~30 s if a reboot fires**, **~10 s if not** (the Technitium installer restarts the service). Once the secondary is in service (RPi 3B+, decided 2026-08-19 — see the README TODO), run `upgrade.yml` against the secondary first, verify it's healthy, then the primary — keeps the LAN's DNS answered throughout.

Cadence suggestion: **monthly**, or on demand when a CVE for Technitium / glibc / kernel lands. Cron-it later if drift becomes a concern.

## What the playbook configures

The `technitium-config` role applies the following via Technitium's HTTP API (`/api/...`). Param names verified 2026-05-12 against [`APIDOCS.md` on master](https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md).

**Server-level settings** (`/api/settings/set`):
| Param | Set to | Configurable via |
|---|---|---|
| `recursion` | `AllowOnlyForPrivateNetworks` (not an open resolver) | `technitium_recursion_mode` in `group_vars/all.yml` |
| `dnssecValidation` | `true` | `technitium_dnssec_validation` |
| `qpmLimitBypassList` | `192.168.1.0/24` (the LAN — bypasses per-subnet rate limits) | `technitium_qpm_bypass_list` |
| `blockListUrls` | comma-joined list from `files/blocked.urls` | edit the file |
| `blockListUpdateIntervalHours` | `24` | `technitium_blocklist_update_interval_hours` |

**Authoritative zone for `okd.sudops.pl`** (`/api/zones/create` + `/api/zones/records/add`, idempotent via `overwrite=true`):
| Domain | A → | Driven by |
|---|---|---|
| `api.okd.sudops.pl` | `192.168.1.240` | `okd_api_vip` |
| `api-int.okd.sudops.pl` | `192.168.1.240` | `okd_api_vip` |
| `*.apps.okd.sudops.pl` | `192.168.1.241` | `okd_ingress_vip` |
| `node4.okd.sudops.pl` | `192.168.1.7` | `okd_nodes` list |
| `node5.okd.sudops.pl` | `192.168.1.8` | `okd_nodes` list |
| `node6.okd.sudops.pl` | `192.168.1.9` | `okd_nodes` list |

**Blocked zones** (authoritative empty zones → NXDOMAIN by default):
- `cluster.local` (carry-over from pi-hole `local=/cluster.local/`)
- `svc.cluster.local.okd.sudops.pl` (search-suffix-leak shape from cluster pods)

**Blocklist refresh**: after settings + zones are applied, the role triggers `/api/settings/forceUpdateBlockLists` so the block list cache populates immediately rather than waiting for the 24-h schedule.

## Day-2: editing config

Every config knob lives in `group_vars/all.yml` (or `files/blocked.urls` for the blocklist sources). After editing:

```bash
cd ansible/technitium
ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass --limit dns-master
```

Common edits and the file they live in:
| Want to… | Edit |
|---|---|
| Add a node IP | `okd_nodes` in `group_vars/all.yml` |
| Change `*.apps` ingress VIP | `okd_ingress_vip` |
| Add a blocklist URL | append to `files/blocked.urls` (comments OK) |
| Narrow the rate-limit bypass | `technitium_qpm_bypass_list` (CIDR; default whole `192.168.1.0/24`) |
| Add a new "block this zone" rule | `technitium_blocked_zones` list |

## What's NOT done yet

- **Operator-manual bootstrap steps 1-5** above (SD flash + Technitium install + admin password) — playbook expects an already-installed Technitium and a populated `vars/vault.yml`.
- **End-to-end run against a live Technitium API** still needs to happen — the param names are pinned to the docs but haven't been validated against the running instance yet.
- **Primary/secondary cluster role** is still a placeholder pending the RPi Zero 2W.

See the open-items checklist in `blog/blog-technitium-dns-migration-draft.md` for the full punch list.
