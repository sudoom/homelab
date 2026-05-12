# Ansible playbook — technitium DNS server

Configures and maintains the home DNS server (replacing pi-hole). Runs against a Raspberry Pi 3B+ (primary) at `192.168.1.12`, and eventually a Raspberry Pi Zero 2W (secondary). See `blog/blog-technitium-dns-migration-draft.md` at the repo root for the design rationale.

## Why this lives outside ArgoCD

The box runs **outside** the OKD cluster. ArgoCD can't reach it, but more importantly: **DNS shouldn't be circularly dependent on the cluster being up.** If the cluster's storage hangs (as happened 2026-05-12), the dashboards go dark — losing DNS at the same time would compound the outage. Ansible-pull / push from a workstation keeps the failure domains separate.

## Repo layout

```
ansible/technitium/
├── inventory.yml                          # technitium-primary; secondary commented out (not procured yet)
├── playbook.yml                           # top-level entrypoint, applies all roles
├── group_vars/all.yml                     # shared config: zone records, blocklist policy, rate limits
├── vars/vault.yml.example                 # template for the (gitignored) vault file
├── files/
│   └── blocked.urls                       # blocklist URLs, one per line
├── roles/
│   ├── base/                              # OS hygiene (hostname, timezone, packages, unattended-upgrades)
│   ├── technitium-install/                # idempotent Technitium install/upgrade via upstream installer
│   ├── technitium-config/                 # zones + settings + blocklists via Technitium HTTP API
│   └── technitium-cluster/                # primary/secondary replication (placeholder until secondary lands)
└── .gitignore                             # vars/vault.yml stays out of Git
```

## First-time setup (operator, manual)

1. **Spare SD card** for the new box. Use Raspberry Pi Imager and pre-configure:
   - **OS**: Raspberry Pi OS Lite, 64-bit (Bookworm). Same kernel family as the current pi-hole (`6.12.x`, `aarch64`).
   - **Hostname**: `technitium`
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
  --limit technitium-primary
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
  --limit technitium-primary
```

What it does:
1. `apt update` + `apt full-upgrade --autoremove --autoclean` (OS layer)
2. If `/var/run/reboot-required` exists after the upgrades: reboot, wait up to 5 min for the box to come back, and verify `dns.service` is active before continuing
3. Re-run Technitium's upstream installer (in-place upgrade; preserves `/etc/dns/config/`)
4. Post-checks: `dns.service` active + Technitium API responding

Expected DNS downtime: **~30 s if a reboot fires**, **~10 s if not** (the Technitium installer restarts the service). Once the RPi Zero 2W secondary is in service, run `upgrade.yml` against the secondary first, verify it's healthy, then the primary — keeps the LAN's DNS answered throughout.

Cadence suggestion: **monthly**, or on demand when a CVE for Technitium / glibc / kernel lands. Cron-it later if drift becomes a concern.

## What's NOT done yet

See the `TODO` markers in the role tasks files. The skeleton works for install + base OS, but the config role has placeholder `debug:` tasks where the Technitium HTTP API body shapes need to be confirmed against a live box (Technitium's API param names evolve across releases — pin them once we know).

See also the open-items checklist in `blog/blog-technitium-dns-migration-draft.md`.
