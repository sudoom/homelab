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
│   ├── technitium-cluster/                # Technitium NATIVE Cluster (v14+): settings/blocklists/apps/users sync
│   └── technitium-replication/            # Classic AXFR/IXFR zone transfer for the authoritative zones
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

## Two mechanisms, one job each

This topic uses **both** Technitium's native Cluster feature and classic DNS
zone transfer, for different things. They do not fight, and the reason they
don't is worth stating precisely.

| | `roles/technitium-cluster` | `roles/technitium-replication` |
|---|---|---|
| What | Technitium's **native** Cluster (v14+) | Classic AXFR/IXFR zone transfer |
| Syncs | settings, Allowed/Blocked, Apps, Users/Groups/Permissions, API tokens | the two authoritative zones' records |
| Direction | Primary → Secondary | Primary → Slave |
| Transport | HTTPS between nodes (DANE-EE, self-signed cert, port 53443) | DNS/53, TSIG-free, restricted by IP ACL |

**Why no collision:** under clustering, zones sync *only if explicitly added* as
members of the auto-created `cluster-catalog.<cluster-domain>` zone. We do not
add them. Zone data therefore stays entirely on the classic mechanism, which was
already verified working, and the cluster handles everything that is not a zone.

If you ever add a zone to the cluster-catalog, **remove it from
`technitium_replicated_zones` in the same change** — otherwise two mechanisms
would be replicating the same zone.

### Cluster specifics

- **`technitium_cluster_domain` is IMMUTABLE** — set to **`homelab.sudops.pl`**
  (2026-08-26), so node names read `dns-master.homelab.sudops.pl` /
  `dns-slave.homelab.sudops.pl`. It becomes a real zone: Primary on the primary
  node, Secondary on each other node. Changing it means deleting the cluster
  (`api/admin/cluster/primary/delete`) and re-forming it.

  **This is an EXISTING zone** — `technitium-config` creates
  `homelab.sudops.pl` as a Primary zone holding the LAN appliance records
  (`nas`, `dns`). Two things follow:
  - It is deliberately **absent from `technitium_replicated_zones`**. The
    cluster replicates it natively; listing it there too would have
    `technitium-replication` create a competing Secondary zone on the slave.
    One zone, one mechanism.
  - **Unverified:** whether `init` adopts a pre-existing zone of that name or
    refuses it. `technitium-config` runs first, so the zone exists before init
    is attempted — which is the safer order, but watch the first run. If init
    fails on a zone conflict, the options are a dedicated subdomain
    (`cluster.homelab.sudops.pl`) or deleting the zone and letting the cluster
    recreate it (which would need the `nas`/`dns` records re-added — they are in
    `group_vars`, so a re-run restores them).
- **Init auto-enables HTTPS** with a self-signed cert on port 53443 and restarts
  the admin web service ~2 s after responding. The role waits this out with a
  `retries`/`until` loop rather than assuming.
- **Neither `init` nor `initJoin` is idempotent** — Technitium refuses with
  "Cluster is already initialized". Both tasks gate on `clusterInitialized` from
  `api/admin/cluster/state`.
- **Ordering is guaranteed by Ansible's `linear` strategy**: the primary's init
  task completes on all hosts before the secondary's join task starts. A
  secondary cannot join a cluster that does not exist yet.
- **The primary's URL is read from its own state**, not constructed. It embeds
  the cluster domain and TLS port, and guessing that format is unnecessary risk.
- **Passwords: the join uses the PRIMARY's admin credentials**, not the joining
  node's. And because clustering syncs Users/Groups, **after a successful join
  both nodes share the primary's admin password** — the per-host
  `technitium_admin_passwords` dict is what bootstraps each box *before* it
  joins. Update `dns-slave`'s entry to match `dns-master`'s once clustered, or
  the next run's login will fail and fall through to the adopt path.

### Where the API contract came from

`APIDOCS.md` is large enough that summarising fetchers truncate before reaching
the cluster section — twice during this work a fetch reported the endpoints
"do not exist", which was a truncation artifact, not absence. The endpoint paths
and parameter names in this role were therefore read from the shipping UI source
at `DnsServerCore/www/js/cluster.js`, which is what actually calls them.

```
GET  api/admin/cluster/state[?includeServerIpAddresses=true][&node=]
GET  api/admin/cluster/init?clusterDomain=&primaryNodeIpAddresses=
POST api/admin/cluster/initJoin   (form body)
       secondaryNodeIpAddresses, primaryNodeUrl, primaryNodeIpAddress,
       ignoreCertificateErrors, primaryNodeUsername, primaryNodePassword,
       primaryNodeTotp
     api/admin/cluster/secondary/resync?node=
     api/admin/cluster/secondary/leave?forceLeave=&node=
     api/admin/cluster/secondary/promote?forceDeletePrimary=&node=
     api/admin/cluster/primary/delete?forceDelete=&node=
     api/admin/cluster/primary/removeSecondary?secondaryNodeId=&node=
     api/admin/cluster/primary/setOptions?heartbeatRefreshIntervalSeconds=&...
     api/admin/cluster/updateIpAddress?ipAddresses=&node=
```

Only `state`, `init` and `initJoin` are used by the role. The rest are recorded
because they are the recovery paths: `primary/delete` tears the cluster down,
`secondary/leave` detaches a node, `secondary/promote` takes over when the
primary is gone for good.

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
