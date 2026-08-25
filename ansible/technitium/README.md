# Ansible playbook — technitium DNS server

Configures and maintains the home DNS server (replacing pi-hole). Runs against a Raspberry Pi 3B+ (primary) at `192.168.1.12`, and a second box as secondary (RPi 3B+, decided 2026-08-19 — the Zero 2W was rejected: WiFi-only, 512 MB, and a December ship date on a SPOF). See `blog/blog-technitium-dns-migration-draft.md` at the repo root for the design rationale.

## Why this lives outside ArgoCD

The box runs **outside** the OKD cluster. ArgoCD can't reach it, but more importantly: **DNS shouldn't be circularly dependent on the cluster being up.** If the cluster's storage hangs (as happened 2026-05-12), the dashboards go dark — losing DNS at the same time would compound the outage. Ansible-pull / push from a workstation keeps the failure domains separate.

## Repo layout

```
ansible/technitium/
├── inventory.yml                          # dns-master; dns-slave commented out (not procured yet)
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
│   └── technitium-replication/                # primary/slave zone replication (WRITTEN 2026-08-25; slave half idle until the RPi 3B+ lands)
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
5. **Admin password — nothing to do by hand (changed 2026-08-25).** A fresh
   Technitium install carries the documented default `admin`/`admin`. The
   `technitium-config` role now **adopts** the box: it tries the managed
   password, and on failure logs in with the default, calls
   `/api/user/changePassword`, and continues. So the admin password is set from
   the vault on first run and survives an SD reimage. Previously this was a
   manual web-UI step, which meant the box's most important credential lived
   only on the box — the same class of drift as the hand-written NTP drop-in
   behind the 2026-07-25 outage.

   Both boxes share one `technitium_admin_password`. If a box is set to some
   *third* password by hand, neither the managed value nor the default works and
   the role fails with an explicit message — reset the box rather than editing
   the vault to match it.
6. **Workstation**: install Ansible (`brew install ansible` / `apt install ansible`). All tasks use `ansible.builtin.*` modules only — no external collections required.
7. **Vault**: create the encrypted secrets file:
   ```
   cd ansible/technitium
   ansible-vault create vars/vault.yml
   ```
   Paste the template from `vars/vault.yml.example`. Passwords are **per host**
   — Technitium accounts are local to each server, so the vault holds a dict
   keyed by `inventory_hostname`:

   ```yaml
   technitium_admin_passwords:
     dns-master: "..."
     dns-slave:  "..."
   ```

   You choose these values; the role applies them, so they need not match
   anything pre-existing. A missing key fails with an explicit message rather
   than a Jinja error. `ansible_become_password` is no longer needed —
   `roles/base` grants the ansible user passwordless sudo (validated with
   `visudo -cf` before install).

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
- **Primary/slave replication** is implemented (`roles/technitium-replication`, 2026-08-25). The **primary half applies today**: it sets each replicated zone's transfer ACL and NOTIFY target to `technitium_slave_ip` (`192.168.1.13`). The **slave half is idle** until the RPi 3B+ arrives — uncomment the `dns-slave` block in `inventory.yml` and it runs.

## Why we do NOT use Technitium's built-in Cluster feature

Technitium v14 added **Administration → Cluster**. It is a genuine feature and it
*is* automatable — `/api/admin/cluster/…` endpoints (`init`, `initJoin`) are
documented in `APIDOCS.md`. We deliberately leave it uninitialized. "Cluster Not
Initialized" is the intended end state here, not unfinished work.

What it syncs: server settings, Allowed/Blocked lists, Apps, **Users/Groups/
Permissions**, API tokens, and — opt-in, via an auto-created
`cluster-catalog.<cluster-domain>` zone — selected zones. What it does not sync:
zones by default, cache, logs, DHCP scopes.

Five reasons it is the wrong fit for this repo:

1. **Source of truth moves from git to the primary's runtime state.** Today
   `technitium-config` pushes settings and blocklists to BOTH boxes from the
   repo, and each converges independently. Under clustering, the secondary's
   config becomes a copy of whatever the primary currently holds — which is the
   opposite of this repo's whole premise.
2. **It would fight `technitium-config`, with undefined results.** Technitium
   publishes no field-level list of which Settings keys are cluster-common vs
   per-node, so `/api/settings/set` against a clustered secondary is either
   silently overwritten on the next config refresh or in contention with the
   primary. That is a drift generator.
3. **Cluster state is unreproducible runtime data** — node IDs, the TSIG key
   minted at init, the auto-generated self-signed cert, the cluster-catalog
   zone. The documented bring-up path for these RPis is an SD-card rebuild,
   which restores none of it; the cluster would have to be town down and
   re-formed. Everything else here survives a reimage.
4. **It forces same-version lockstep upgrades**, which kills `upgrade.yml`'s
   deliberate staggered design (slave first, verify, then primary, so DNS keeps
   answering throughout).
5. **It syncs Users/Groups**, so joining would overwrite dns-slave's local admin
   account with dns-master's — breaking the per-host
   `technitium_admin_passwords` this repo now relies on.

Clustering also auto-enables HTTPS with a self-signed cert, uses DANE-EE for
node-to-node TLS, moves the admin panel to port 53443, and forbids terminating
TLS at an HTTPS reverse proxy by design.

**Revisit if** a third or fourth node appears, or if the Allowed/Blocked/Apps
lists start changing faster than a playbook run. At two boxes driven from one
repo, Ansible already delivers what clustering would, and reproducibly.

Note the naming: `roles/technitium-replication` (renamed from
`technitium-cluster`, 2026-08-25) does classic DNS zone replication. It is not
related to the vendor's Cluster feature, and the old name implied otherwise.

## Primary/slave replication

Two boxes is **resilience, not HA**: stub resolvers try nameservers in order and only fail over after a timeout (seconds per query), so a dead primary degrades rather than disappears. A shared keepalived VIP is the only way to get clean failover, if that turns out to matter.

| | Primary (`dns-master`, `.12`) | Slave (`dns-slave`, `.13`) |
|---|---|---|
| Zone type | `Primary` (created by `technitium-config`) | `Secondary` (created by `technitium-replication`) |
| Replicated zones | `technitium_replicated_zones` — `okd.sudops.pl`, `homelab.sudops.pl` | pulled by AXFR/IXFR from `technitium_primary_host` |
| Zone transfer | `zoneTransfer=UseSpecifiedNetworkACL`, ACL = `technitium_slave_ip` | — |
| Change propagation | `notify=SpecifiedNameServers` → slave pulls within seconds | `/api/zones/resync` forces an immediate pull on first run |
| Blocked + forwarder zones | created locally | **created locally, NOT replicated** — config, not data |
| Blocklists | applied locally | applied locally from the same `files/blocked.urls` |

**Only record-bearing authoritative zones are replicated.** The blocked zones (`cluster.local`, `svc.cluster.local.okd.sudops.pl`) and the conditional forwarders (`home.lab`, `homelab.net`) are configuration; each box creates its own, so no transfer is involved.

Because of that split, every task in `technitium-config` tagged `[config, zones]` is guarded on `technitium_role == 'primary'`. Without that guard the slave would create the authoritative zones as **Primary**, colliding with the `Secondary` zones this role creates.

Verification is built in: creating a Secondary zone proves nothing, because a zone whose transfer the primary *refuses* still appears in the zone list — just empty. The role reads each zone back and asserts it carries records beyond `SOA`/`NS`. By hand:

```bash
dig @192.168.1.13 AXFR okd.sudops.pl
dig @192.168.1.13 api.okd.sudops.pl +short     # expect 192.168.1.240
```

Terminology note: Technitium's zone **type** is `Secondary` (that string is the API value and must stay). The host and `technitium_role` are named `slave` per the operator's preference.

See the open-items checklist in `blog/blog-technitium-dns-migration-draft.md` for the full punch list.
