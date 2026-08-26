# technitium: DNS migration from pi-hole — planning notes

Working notes for replacing the home pi-hole (RPi 3B+ at `192.168.1.12`) with **Technitium DNS Server** on the same physical RPi 3B+, host name `dns-master` (matches the existing `pi-hole-master` convention). Later: add a secondary on an RPi Zero 2W for HA — `dns-slave`, primary/secondary pair clustered via Technitium's built-in replication. Web UI reachable at `http://dns-master:5380` once the LAN resolves the new hostname. **Plan, not implementation.**

## Why we're doing this

Current pi-hole has multiple latent issues, two of which bit the cluster in real ways:

1. **2026-04-30** — pi-hole's default per-client `RATE_LIMIT` was REFUSING all queries from `node6` once it crossed the threshold. Workaround was a temporary bump on the running pi-hole; the box is being decommissioned anyway so a permanent fix on `.12` wasn't worth it.
2. **2026-05-12** (this morning) — cluster pods inheriting `okd.sudops.pl` in resolv.conf search + `ndots:5` generated a search-suffix leak storm; pi-hole conditional-forwarded `<...>.svc.cluster.local.okd.sudops.pl` to `gw.home.lab`, which doesn't have those records and times out. ~700 k queries / 18 h, sustained ~11 qps, on-host CoreDNS spamming `i/o timeout` errors against pi-hole. Decision: don't tweak the dying box, let technitium handle it correctly from the start.

Plus, pi-hole's conditional-forwarding chain for `okd.sudops.pl` is fundamentally a hack — pi-hole isn't authoritative for the cluster's own domain, so it has to round-trip to gw.home.lab (which itself has to either be authoritative or forward to a cluster node). Technitium's **authoritative-with-split-horizon** support lets us cut that chain entirely: technitium IS authoritative for `okd.sudops.pl` from the LAN's point of view, answers `api.okd.sudops.pl` and `*.apps.okd.sudops.pl` directly from local records, never forwards them.

## Decisions made (2026-05-12 session)

| Decision | Choice | Rationale |
|---|---|---|
| Hardware (primary) | RPi 3B+ | Same as current pi-hole; reuse the box once pi-hole is decommissioned. |
| Hardware (secondary) | RPi Zero 2W | Future addition; small, low-power, sufficient for hot-standby DNS. |
| Topology | Technitium primary/secondary cluster | Built-in feature of Technitium DNS Server; trivial to set up. |
| Primary IP | `192.168.1.12` (same as pi-hole) | Transparent cutover. No DHCP option change. LAN clients keep working without reconfiguration. |
| Secondary IP | **`192.168.1.13`, confirmed 2026-08-25** | Allocated to `dns-slave`. Hardware is an **RPi 3B+** (decided 2026-08-19 — the Zero 2W was rejected: no Ethernet, 512 MB, ~2026-12-04 ship date on what is currently a SPOF). Needs a MikroTik DHCP reservation. |
| Software | Technitium DNS Server | Authoritative + recursive + forwarding + split-horizon + clustering + web UI + ARM-supported. Native config in JSON files, can be Git-tracked. |
| Upstream resolution | Recursive (built-in) with DNSSEC | Technitium's recursive resolver bypasses upstream dependence. Optional fallback forward to 1.1.1.1 via DoT for the cases where recursion is slow. |
| Authoritative zones served | `okd.sudops.pl` (split-horizon, see below) | Eliminates the conditional-forwarding chain to gw.home.lab. |

## Architecture

```
LAN clients (laptops, IoT, OKD nodes, etc.)
    ↓ DNS via DHCP-assigned nameserver (192.168.1.12)
    ↓
technitium (RPi 3B+ @ 192.168.1.12) — Technitium DNS Server
    │
    ├── Authoritative zone: okd.sudops.pl  ← split-horizon view for LAN
    │     api.okd.sudops.pl       → 192.168.1.240 (API VIP)
    │     api-int.okd.sudops.pl   → 192.168.1.240
    │     *.apps.okd.sudops.pl    → 192.168.1.241 (Ingress VIP)
    │     node4.okd.sudops.pl     → 192.168.1.7
    │     node5.okd.sudops.pl     → 192.168.1.8
    │     node6.okd.sudops.pl     → 192.168.1.9
    │
    ├── Authoritative-NXDOMAIN zones (block escaped cluster names from leaking out):
    │     cluster.local                       → NXDOMAIN
    │     svc.cluster.local.okd.sudops.pl     → NXDOMAIN (handles the ndots:5 search leak)
    │
    ├── Block lists (carry over from pi-hole): same lists, same shape.
    │
    ├── Recursive resolver (built-in, DNSSEC-validating) — for everything else.
    │
    └── (future) replication to secondary on 192.168.1.13 (RPi 3B+)

Cluster's on-host CoreDNS:
    DNSUpstreams = 192.168.1.12  ← keeps pointing at technitium (because same IP)
    → for okd.sudops.pl queries that escape the cluster: technitium answers
      authoritatively (split-horizon), no round-trip to gw.home.lab.
```

## Split-horizon for `okd.sudops.pl` — the key feature

This is the design choice that resolves the "pi-hole conditional-forwards okd.sudops.pl to gw.home.lab and times out" loop permanently.

**Today's chain (broken):**

```
LAN client asks pi-hole for argocd.apps.okd.sudops.pl
  → pi-hole conditional-forwards okd.sudops.pl to gw.home.lab (192.168.1.1)
  → gw.home.lab... either has a record statically, or forwards to a cluster node's CoreDNS
  → eventually returns 192.168.1.241
```

**Technitium chain:**

```
LAN client asks technitium for argocd.apps.okd.sudops.pl
  → technitium is AUTHORITATIVE for okd.sudops.pl on the LAN view
  → returns 192.168.1.241 directly from local zone records
  → no forwarding, no timeout, no loop.
```

The on-host CoreDNS on the cluster nodes stays internally authoritative for `okd.sudops.pl` too (Corefile templates for `api.*`, `*.apps.*`, etc.). The two are independent: cluster-internal queries hit the on-host CoreDNS via the local nameserver; LAN-side queries hit technitium. Same answers, different authoritative servers — that's the split-horizon shape.

Zone records to populate on technitium (initial set; extend as needed):

```
$ORIGIN okd.sudops.pl.
@                IN  SOA  ns1.okd.sudops.pl. admin.sudops.pl. ( 1 3600 600 86400 60 )
@                IN  NS   ns1.okd.sudops.pl.
ns1              IN  A    192.168.1.12
api              IN  A    192.168.1.240
api-int          IN  A    192.168.1.240
*.apps           IN  A    192.168.1.241
node4            IN  A    192.168.1.7
node5            IN  A    192.168.1.8
node6            IN  A    192.168.1.9
```

(Technitium's UI / API will populate this from a JSON config file; the BIND-style notation above is just for clarity.)

## The two NXDOMAIN local-zones — carry-over from pi-hole

These were on pi-hole as `local=/zone/` dnsmasq directives. On Technitium, the equivalent is **"Blocked Zones"** or an authoritative zone with no records (returns NXDOMAIN).

1. **`cluster.local`** — anything ending in `cluster.local` that *escapes* the cluster (e.g. a host application accidentally trying to resolve a `*.svc.cluster.local` name) should NXDOMAIN locally rather than recurse and reveal cluster topology to the public.
2. **`svc.cluster.local.okd.sudops.pl`** — the search-suffix leak shape that bit pi-hole this morning. Cluster pods with `ndots:5` and `okd.sudops.pl` in their search list generate `<svc>.<ns>.svc.cluster.local.okd.sudops.pl` queries on every lookup. If `okd.sudops.pl` is authoritative on technitium (above), an unmatched subzone falls through to NXDOMAIN by default — but making this explicit avoids any subtle interaction with the wildcard `*.apps`.

If Track B (the MachineConfig that strips `okd.sudops.pl` from host resolv.conf — drafted at `tests/mc-nm-strip-okd-search.yaml`) lands first, rule #2 becomes unnecessary (pods stop generating those queries). Ship both anyway — belt + suspenders.

## RATE_LIMIT — carry-over

Pi-hole's per-client query rate limit was set very low by default (1000 queries / 60 seconds), and the cluster nodes legitimately exceeded it. The bump on pi-hole was temporary.

Technitium's equivalent: review default rate-limiting in its Settings (it has per-client rate limits in newer versions). Set generously — the LAN's heaviest clients are the OKD nodes during peak DNS-query periods (post-restart memberlist re-resolution), and we'd rather they NOT be REFUSED.

Recommended starting point: **10 000 queries / 60 s per client**. Validate by checking the busiest hour's traffic from the OKD nodes against this ceiling.

## Block lists — carry-over

Pi-hole's blocked-domain lists should carry to technitium more or less unchanged. Lists in use today (extract from pi-hole admin → `Group Management → Lists`):

- **Decided 2026-05-12**: StevenBlack/hosts as the single source of truth (meta-list that already merges AdAway, MVPS, Disconnect, etc.). ~82.6k blocked domains, validated reachable, parses natively in Technitium. The pi-hole's actual adlist was never extracted — we went with the canonical meta-list directly. Add more lists later via `ansible/technitium/files/blocked.urls` if a specific gap shows up.

## Recursive resolution + DNSSEC

Pi-hole today is a *forwarder* (forwards to gw.home.lab or public DNS). Technitium can run **recursive resolution** locally — it queries root NS, then TLD NS, then authoritative NS for the target. Pros: no upstream dependence, no single point of failure on the gateway, full DNSSEC validation.

Pros of switching to recursive:
- Privacy (no upstream sees the full query stream)
- Faster after cache warms (avoids the gateway hop)
- Native DNSSEC (Technitium validates the chain)

Cons:
- Cold cache misses are slower than forwarding (have to walk the root → TLD → authoritative chain)
- Some misbehaving authoritative servers don't respond to direct queries from non-recursive resolvers (rare)

Decision: **start with recursive + DNSSEC** as the primary mode. If cold-cache latency is noticeably bad, add a forwarder fallback to 1.1.1.1 over DoT.

## Primary/secondary cluster — the Zero 2W addition

Technitium's built-in zone-replication makes this almost free. Future shape when the Zero 2W lands:

- **Primary** (`192.168.1.12`, RPi 3B+): writable, accepts admin changes, holds authoritative zones.
- **Secondary** (`192.168.1.13`, RPi 3B+ — not the Zero 2W, see 2026-08-19): read-only replica, polls primary for zone transfers (NOTIFY+IXFR), serves the same answers.
- **LAN DHCP option**: advertise both nameservers (`192.168.1.12, 192.168.1.13`). Clients fall over to the secondary if the primary is unreachable.

Open question for the secondary build: same OS image (presumably Raspberry Pi OS Lite)? Same Technitium version? Bootstrap with an Ansible playbook so primary + secondary stay in sync.

## OS + install method

**OS confirmed (2026-05-12)** via `uname -a` on the running pi-hole box: `Raspberry Pi OS Lite`, kernel `6.12.75+rpt-rpi-v8` (Bookworm-based, build 2026-03-11), `aarch64`. The same image goes on the spare SD card for technitium — no OS migration concern.

**Install method: native via Technitium's installer script.** Not Docker. Reasons:

- The future secondary lives on an RPi Zero 2W (512 MB RAM). Docker's resident overhead (~50-100 MB plus daemon) is meaningful on that box; native runs leaner.
- Homogeneous install across primary + secondary simplifies the Ansible playbook (see below). One set of steps, not two.
- Technitium ships a portable single-process binary bundled with its own .NET runtime — no separate `apt install dotnet` step.

If Docker becomes preferred later (snapshot/rollback ergonomics), swapping is reversible — Technitium's config lives under `/etc/dns/config/` and can map straight into a Docker volume.

**Install steps on a fresh RPi OS Lite SD card:**

```bash
# 1. Standard first-boot setup: SSH on, locale, change pi password.
#    Set hostname `dns-master`. Static IP via DHCP reservation on gw.home.lab.
sudo raspi-config
sudo hostnamectl set-hostname dns-master

# 2. Technitium installer (downloads portable build + creates systemd unit `dns.service`):
curl -sSL https://download.technitium.com/dns/install.sh | sudo bash

# 3. Verify it's up:
systemctl status dns
ss -tnlp | grep -E ':(53|5380|853|443)\b'

# 4. Web UI: http://<rpi-ip>:5380 — set admin password on first visit.
```

**Upgrades:** re-run the installer (`sudo bash -c "$(curl -sSL https://download.technitium.com/dns/install.sh)"`). It does an in-place upgrade and preserves `/etc/dns/config/`.

## Config management — Ansible

Config + day-2 maintenance go through an Ansible playbook in the homelab repo under a new `ansible/technitium/` directory. The OKD GitOps content stays in `components/` and `bootstrap/`; non-cluster home infra lives alongside but isn't ArgoCD-managed.

Playbook responsibilities (sketch — refine when building):

```
ansible/technitium/
├── inventory.yml          # dns-master (RPi 3B+), dns-slave (RPi Zero 2W, future)
├── playbook.yml           # main entrypoint
├── roles/
│   ├── base/              # RPi OS hardening: unattended-upgrades, fail2ban, ssh-key auth, timezone
│   ├── technitium-install/  # idempotent Technitium install (skip if already present at expected version)
│   ├── technitium-config/   # render dns.config from a Jinja template; copy zones/, blocked.config etc.
│   └── technitium-cluster/  # configure primary/secondary replication (when secondary lands)
└── files/
    ├── zones/okd.sudops.pl.zone       # authoritative split-horizon zone records
    ├── blocked.urls                   # block-list URLs (carry-over from pi-hole + curated)
    └── allowed.exceptions             # allowlist overrides
```

The playbook is **idempotent and pull-based** — running it against either node converges that node to the desired state. Primary and secondary differ only in role-level params (replication mode, peer address). The user runs `ansible-playbook -i inventory.yml playbook.yml --limit dns-master` (or `--limit dns-slave`) from a workstation.

Day-2 changes (new block list, new zone record, rate-limit tweak) → edit the files in `ansible/technitium/files/`, commit to Git, re-run the playbook. Same flow as everything else, just outside ArgoCD's purview.

Why not put Technitium under ArgoCD too? Because:
- Technitium runs outside the OKD cluster (on an RPi 3B+ on the LAN), so ArgoCD can't reach it
- DNS being the bootstrap dependency for everything else means it should NOT have a circular dependency on the cluster being up
- Ansible-pull from the box (via cron or systemd-timer) is an option later if "must SSH from workstation to apply" becomes annoying — for now the manual `ansible-playbook` invocation is fine and explicit

## Cutover plan — sequence

Goal: replace the running pi-hole on `.12` with Technitium on `.12` with minimal LAN-wide downtime.

1. **Build a clone box**. Use a spare SD card, install Raspberry Pi OS Lite, install Technitium DNS Server, configure as described above. Don't connect to LAN yet (or connect on a different temporary IP).
2. **Mirror the active block lists** from the running pi-hole onto the clone — same URLs, same update schedule.
3. **Populate the authoritative `okd.sudops.pl` zone** on the clone. Test from a single client (e.g. laptop) by manually pointing its resolver at the clone's temporary IP and verifying `dig @<clone-ip> api.okd.sudops.pl`, `dig @<clone-ip> argocd.apps.okd.sudops.pl`, `dig @<clone-ip> google.com`, etc.
4. **Schedule the swap.** Pick a window of ~5-10 min where LAN DNS downtime is acceptable. Stop pi-hole on the old box, change its IP to something temporary (or just shut it down). Move the new box's IP to `.12`. Plug it into the same switch port. Verify clients are getting answers from the new box (`dig +short version.bind chaos txt @192.168.1.12` should return a Technitium version string, not pi-hole's).
5. **Watch for ~24 h** with the old pi-hole box turned off but kept physically around. If everything's clean, factory-reset the old SD card and either (a) reuse the box for the secondary if the Zero 2W isn't here yet, or (b) shelve it.

## Interaction with Track B (`tests/mc-nm-strip-okd-search.yaml`)

The MachineConfig that strips `okd.sudops.pl` from host resolv.conf is a parallel — and arguably bigger-leverage — fix. If it lands first:

- The cluster nodes stop emitting `<...>.svc.cluster.local.okd.sudops.pl` queries entirely (no more search-suffix expansion through `okd.sudops.pl`).
- Technitium's `svc.cluster.local.okd.sudops.pl` NXDOMAIN block becomes academic — no clients hit it.
- The pi-hole rate-limit pain that bit node6 in April becomes nearly impossible to reproduce (most of the volume was the search-suffix leak).

If technitium lands first: pi-hole's failure modes are resolved (Technitium answers authoritatively for `okd.sudops.pl`, no timeouts, no rate-limit refusals at 10 k/min). Track B is still desirable for cluster cleanliness — pods shouldn't be emitting bogus queries even if the downstream resolver handles them gracefully — but it stops being urgent.

Recommended sequencing: **technitium first, Track B when there's a quiet day for an MCO master reboot**. Today's incident proved we don't have appetite for a reboot cycle right now.

## Technitium API param verification (2026-05-12)

Pinned the Ansible `technitium-config` role's HTTP API param names against [APIDOCS.md on master](https://github.com/TechnitiumSoftware/DnsServer/blob/master/APIDOCS.md). Key params and gotchas:

- **Auth**: `Authorization: Bearer <token>` header (preferred); login response returns `{"token": "..."}` in JSON body. Old-style `?token=` query/form param still works but is deprecated.
- **Recursion mode**: param `recursion`, values `Deny | Allow | AllowOnlyForPrivateNetworks | UseSpecifiedNetworkACL`. We use `AllowOnlyForPrivateNetworks` so technitium isn't an open resolver.
- **Rate limit**: Technitium does **per-subnet QPM (Queries Per Minute) prefix limits**, not pi-hole's per-client REFUSE. The right knobs are `qpmPrefixLimitsIPv4/IPv6` (formatted `prefix,udpLimit,tcpLimit`, pipe-separated rows) and `qpmLimitBypassList` (comma-separated CIDRs that bypass entirely). Simplest correct config for the home LAN: bypass the whole `192.168.1.0/24` so the cluster never gets REFUSED during memberlist bursts. Narrow later if specific noisy clients show up.
- **Block lists**: `blockListUrls` on `/api/settings/set` accepts a **comma-separated** list of URLs. Refresh cadence via `blockListUpdateIntervalHours` (default 24). Force an immediate fetch via `/api/settings/forceUpdateBlockLists`. Technitium auto-detects the upstream format (hosts file, ABP, plain domain list).
- **Add record**: `/api/zones/records/add` with `domain` + `zone` + `type=A` + `ipAddress` + `ttl` + `overwrite=true`. The `overwrite=true` is what makes the Ansible loop idempotent — re-running converges values without piling up duplicates.

These are now hard-coded into `ansible/technitium/roles/technitium-config/tasks/main.yml`; the role's `debug:` placeholder TODOs are gone. End-to-end run against the live API still needs to happen (with the vault password) — the param names are docs-pinned but not yet observed-correct.

## Cutover + post-cutover bugs (2026-05-12 evening)

Cutover happened during the same session. Sequence on `dns-master`:

```
sudo systemctl stop pihole-FTL
sudo systemctl disable pihole-FTL
sudo systemctl restart dns          # Technitium grabs :53 once pi-hole releases it
sudo ss -tulnp 'sport = :53'        # confirms dns-server now binds :53 on all interfaces
```

LAN DNS gap was sub-second — Technitium re-bound :53 immediately on restart.

**MikroTik discovery (gw.home.lab → IP/DNS/Static):** the router holds *authoritative static entries* for `okd.sudops.pl` (not a conditional forwarder as I'd assumed). Live entries: `api`, `api-int` → `192.168.1.240`; regex `*.apps.okd.sudops.pl` → `192.168.1.241`. Today's chain was: client → pi-hole → forwards `okd.sudops.pl` → gw.home.lab static answer. Post-cutover, technitium is authoritative on the LAN view and answers locally — the MikroTik entries are dead code. **Don't remove them yet** — keep them through the 24h soak as a safety net; remove after.

### Three bugs caught post-cutover

**1. Blocklist URLs pushed as empty string** (silent). `dig doubleclick.net` returned a real IP, `/etc/dns/blocklists/` was empty. Web UI showed "Allow / Block List URLs" field empty. Root cause: `lookup('ansible.builtin.file', 'blocked.urls').split('\n')` — in a YAML scalar, `'\n'` is the literal two-char sequence, not a newline, so `.split('\n')` returned the whole file as one element, the first-line `# Block-list URLs ...` comment matched `reject('match', '^#')` and the list emptied. `join(',')` of empty list = `''`. Pushed to `/api/settings/set` as `blockListUrls=`, accepted as "no URLs configured". Fix: `splitlines()` instead. Added a follow-up `assert` so this silent-empty pattern can't recur.

**2. `enableBlocking` defaults to false** on a fresh Technitium install — even with `blockListUrls` populated, blocking is gated off. Added `enableBlocking: "true"` to the settings.set call so re-runs flip it explicitly.

**3. Hostname kept reverting from `dns-master` back to `pi-hole-master`.** The base role's `Set hostname` task ran cleanly (`ok` not `changed`), but dhcpcd's `30-hostname` hook fired on every lease renewal, did a reverse-DNS lookup on the leased IP (the MikroTik lease record still says `pi-hole-master`), and reset `/etc/hostname` + `/etc/hosts` + the kernel value. Fix: base role now adds `nohook hostname` to `/etc/dhcpcd.conf` BEFORE the hostname-set task, so renewals stop touching it. Validated: `ok=8, changed=3`.

### Coverage gap caught right after I'd called the session done: home.lab / homelab.net

Old-cluster `node1` started reporting `NotReady` shortly after the cutover. Kubelet's kubeconfig points at `https://kube-cp.homelab.net:8443`, and that name suddenly returned NXDOMAIN. Pre-cutover, pi-hole forwarded `homelab.net` → `gw.home.lab` (192.168.1.1) where MikroTik holds static A records (`kube-cp.homelab.net → 192.168.1.200`, the old-cluster API VIP). Technitium does recursive resolution by default — without explicit Forwarder zones for those LAN-local domains, queries hit public Cloudflare and got NXDOMAIN. My fault for not auditing the full MikroTik static-DNS table when scoping today's migration; I focused on `okd.sudops.pl` and missed the rest.

Fix: add `technitium_forwarder_zones` list to `group_vars/all.yml` and a corresponding role task that calls `/api/zones/create` with `type=Forwarder` for each (`home.lab` and `homelab.net`, both → `192.168.1.1`).

### Three bugs fixed iterating that fix

**1. Silent zone-create failures.** First playbook re-run reported `ok=N changed=0 failed=0` but the Forwarder zones weren't actually on disk and the SOA query for `homelab.net` returned Cloudflare's nameservers (proof Technitium was still recursing publicly). Root cause: Technitium returns **HTTP 200** with `{"status": "error", "errorMessage": "..."}` in the body when zone-create has a problem. The role was checking only the HTTP status code, so silent failures passed through unflagged. Fix: `return_content: true` + `register: response` + `failed_when: response.json.status != "ok"` (with an allowlist for the already-exists case to keep re-runs idempotent).

**2. `--tags forwarders` skipped the login.** Second re-run failed at the Forwarder zone task with `technitium_auth_headers is undefined`. The Login + token-extract tasks were tagged only `[config]`, so Ansible's tag filter skipped them when the operator scoped to `--tags forwarders`. Fix: tag auth-setup tasks (login, token extract, blocklist URL set_fact, blocklist assert) with `always` — special Ansible tag that runs the task regardless of which other `--tags` filter is used. Now narrow re-runs bring the auth setup along automatically.

**3. The initial role didn't include Forwarder zones at all.** Pure design omission — I structured the role around what was on my mental model of "the pi-hole's job" (authoritative zones for okd, blocklist, blocked-zones for cluster.local) and missed that pi-hole was also implicitly carrying `homelab.net` queries via its conditional forwarder chain. Lesson: when migrating a resolver, **audit every static + forwarded zone the old box was implicitly serving** — not just the ones in active mental model.

End-to-end DNS chain verified working after `f0bb5e1`:
- `okd.sudops.pl` → authoritative on Technitium (api/api-int/`*.apps`/node names) ✓
- `homelab.net` → Forwarder → MikroTik (kube-cp etc.) ✓
- `home.lab` → Forwarder → MikroTik (gw etc.) ✓
- `cluster.local` + `svc.cluster.local.okd.sudops.pl` → NXDOMAIN locally ✓
- Everything else → recursive resolution + DNSSEC + StevenBlack blocklist ✓

## Open items / TODOs

Closed during 2026-05-12 session:

- ✅ OS confirmed — RPi OS Lite aarch64 (kernel 6.12.75, Bookworm/Trixie-based).
- ✅ Install method — native via Technitium installer (not Docker).
- ✅ Config management — Ansible playbook under `ansible/technitium/`; manual run from workstation; not ArgoCD-managed.
- ✅ Hostname / inventory key — `dns-master`; future secondary `dns-slave`.
- ✅ SSH shape — `ssh admin@192.168.1.12 -i ~/.ssh/vadz_key`, passwordless sudo.
- ✅ Ansible scaffold — `playbook.yml`, `base-only.yml`, `upgrade.yml`; all `ansible.builtin.*` only.
- ✅ Base role validated end-to-end (multiple runs through the day; idempotent).
- ✅ Block list URL set — StevenBlack/hosts (single source of truth).
- ✅ Technitium HTTP API param names pinned to upstream APIDOCS.md.
- ✅ End-to-end `playbook.yml` run against live API (`ok=21` first run, then iterated three fixes).
- ✅ MikroTik forwarder check — confirmed it's static entries, not a forwarder; will become dead code after soak.
- ✅ **Cutover** — Technitium owns `:53`; pi-hole stopped + disabled; authoritative zones answering; blocklist active after the splitlines fix; hostname locked via `nohook hostname`.
- ✅ **Forwarder zones for `home.lab` + `homelab.net`** added to role + applied — restored kube-cp.homelab.net resolution for the old cluster (broke node1's kubelet temporarily until this landed).
- ✅ **Role hardening** — `failed_when` on Forwarder zone task surfaces silent status="error" responses; `always` tag on auth-setup tasks makes `--tags X` re-runs work.
- ✅ **SOA primary-NS field on all three zones** — yesterday's planned fix turned out to be a no-op: by 2026-05-13 soak, `dig SOA @192.168.1.12 …` returned `dns-master.` as `mname` on all three Primary zones (`okd.sudops.pl`, `cluster.local`, `svc.cluster.local.okd.sudops.pl`), and `dig NS …` returned the same. The on-disk `.zone` binary files at `/etc/dns/zones/` still contain `pi-hole-master` strings, but those are journal/history-revision blobs internal to Technitium's zone format — they don't affect the served record set. Mechanism (best guess): Technitium derives apex SOA `mname` and NS records from the *current* `hostname` at zone-reload / zone-edit time. The cutover sequence triggered enough reloads + edits *after* the hostname rename took effect that the active SOA settled on `dns-master.` without any explicit `/api/zones/records/update` call. **Practical implication for the role**: don't add a SOA-update task — the base role's hostname enforcement (`nohook hostname` + `hostnamectl` to `dns-master`) is the durable mechanism that keeps SOA/NS apex records correct transitively. If a future hostname change is ever needed, expect SOA mname to follow on the next zone-edit cycle (or force one by re-running `--tags zones`).
- ✅ **Pi-hole purge (codified)** — added a `pihole-cleanup` task block to the `base` role: `apt purge pihole-meta` + `file: state=absent` sweep across `/etc/pihole`, `/opt/pihole`, `/var/log/pihole`, `/var/www/html/admin`, `/etc/cron.d/pihole`, `/etc/systemd/system/pihole-FTL.service`, `/usr/local/bin/pihole`, then `daemon-reload`. First-run report: `changed=2` (apt + file sweep), 7 paths reported `changed`. Idempotent re-run: `changed=0`, daemon-reload skipped (gated on `pihole_files_removed.changed`). Post-cleanup verification: 0 pi-hole packages in `dpkg -l`, 9/9 tracked paths gone, `systemctl status pihole-FTL.service` → "Unit … could not be found", Technitium dns.service still `active`, all four DNS-path tests pass (auth / forwarder / blocklist / recursive). **Non-obvious quirk worth recording**: pi-hole v6's installer only registers `pihole-meta` (version 0.7) with apt; the actual CLI script, FTL binary, web admin, and systemd unit are dropped outside dpkg's tracking. `apt remove --purge pihole pihole-FTL` (the obvious incantation, even cited in yesterday's TODO) **doesn't match any installed package** on this box — the right command is `apt remove --purge pihole-meta`, and that only resolves the apt graph; the filesystem leftovers need a separate sweep. Codifying both halves into one role block means a future reimage that accidentally re-installs pi-hole gets re-cleaned on the next base-role run.
- ✅ **MikroTik static DNS audit** — pulled `/ip dns static print` from the router. Active entries (no `X` disabled flag): `gw.home.lab → 192.168.1.1` (under existing `home.lab` Forwarder zone) and `kube-cp.homelab.net → 192.168.1.200` (under existing `homelab.net` Forwarder zone). Both already resolve correctly through Technitium's forwarding. **No new Forwarder zones needed.** All okd.sudops.pl entries on MikroTik (`api`, `api-int`, `apps.sno.home.lab`, and the `.*\.apps\.okd\.sudops\.pl` regex) are already X-disabled — Technitium's authoritative zone now owns those names. Functional cleanup of the router is effectively already done; only cosmetic table-pruning remains.
- ✅ **`failed_when status != "ok"` extended to remaining zone-create tasks** — applied the same pattern as yesterday's Forwarder zone fix to the okd.sudops.pl Primary zone task and the blocked-zones loop in `roles/technitium-config/tasks/main.yml`. Both now: `register: <task>_response`, `return_content: true`, `failed_when: status != "ok"` with an `already exists` escape for idempotent re-runs. Defensive only — these zones already exist on the live box, so the runtime behavior on success is unchanged; the change just means a future regression (Technitium API rename, response-shape change, etc.) surfaces loudly instead of silently no-op'ing. Validated via `python yaml.safe_load_all` on the role file (full `ansible-playbook --syntax-check` against the parent `playbook.yml` requires vault unlock, which can't be driven from a non-interactive Bash session; will be exercised on the next vault-aware run).

Still open (queued for tomorrow / future):

- [ ] **Cosmetic: MikroTik DHCP lease record + DNS static entries.** The lease still labels `192.168.1.12` as `pi-hole-master` — change the lease's "Host Name" field to `dns-master`. Also delete the now-X-disabled static DNS entries on the router (`api.okd.sudops.pl`, `api-int.okd.sudops.pl`, `apps.sno.home.lab`, and the `.*\.apps\.okd\.sudops\.pl` regex) — functionally already cleaned up (the X flag means they're not serving), just clutter in the table.
- [ ] **Monitoring**: Technitium has a Prometheus exporter (community — pick one); scrape from the cluster's stack into a dashboard. Lower priority; defer.
- [ ] **Procurement**: RPi Zero 2W for the `dns-slave` secondary. Not blocking; primary works standalone.

## 2026-08-25 — primary/slave replication implemented

`roles/technitium-cluster` was a skeleton of `debug` tasks since the migration.
Written for real today, ahead of the RPi 3B+ arriving, so the box is a
plug-in-and-run when it does.

Naming: the operator's preference is **`dns-slave`** / `technitium_role: slave`.
Technitium's zone **type** stays `Secondary` — that string is the API value.

### The structural bug this exposed

`playbook.yml` runs `hosts: all`, so `technitium-config` would have executed
against the slave too — creating `okd.sudops.pl` and `homelab.sudops.pl` as
**Primary** zones there, colliding head-on with the `Secondary` zones the cluster
role needs. Nothing in the existing role guarded against it, and it would have
looked like a working run right up until the transfer silently did nothing.

Fixed by guarding all six tasks tagged `[config, zones]`:

```yaml
  when: technitium_role | default('primary') == 'primary'
```

The `default('primary')` matters: `dns-master` predates the `technitium_role`
variable being load-bearing, so an unset role must keep behaving as primary.

Deliberately **not** guarded: blocked zones, conditional forwarders, server
settings and blocklists. Those are *configuration*, not replicated *data* —
each box creates its own, and a transfer would buy nothing.

### API parameters — verified, not remembered

Checked against `APIDOCS.md` on master before writing anything, and one value I
was about to use does not exist:

```
zoneTransfer valid options:
  [Deny, Allow, AllowOnlyZoneNameServers, UseSpecifiedNetworkACL,
   AllowZoneNameServersAndUseSpecifiedNetworkACL]
```

There is **no `AllowOnlySpecifiedNameServers`** — that is a legacy name still
widely repeated in blog posts. Current Technitium pairs
`zoneTransfer=UseSpecifiedNetworkACL` with **`zoneTransferNetworkACL`** (comma
separated, `!` prefix to deny). The doc's own example URL still shows a
`zoneTransferNameServers=` parameter that is defined nowhere — a documentation
artifact. `notify=SpecifiedNameServers` + `notifyNameServers` are current.

### What the role does

**Primary** — one call per replicated zone:

```
POST /api/zones/options/set
  zone=<zone>
  zoneTransfer=UseSpecifiedNetworkACL
  zoneTransferNetworkACL=192.168.1.13
  notify=SpecifiedNameServers
  notifyNameServers=192.168.1.13
```

ACL-restricted rather than `Allow`, because an unrestricted transfer lets
anything on the LAN dump the entire internal zone — every node address, both
VIPs, every appliance in `homelab.sudops.pl`. NOTIFY makes propagation
event-driven instead of waiting out the SOA refresh.

**Slave** — create the `Secondary` zones, then force the first pull:

```
POST /api/zones/create   zone=<zone> type=Secondary
                         primaryNameServerAddresses=192.168.1.12
                         zoneTransferProtocol=Tcp
POST /api/zones/resync   zone=<zone>
```

`resync` is there so the playbook leaves behind zones that actually contain
records, rather than empty shells that fill in whenever the refresh timer next
fires. Transfer is plain TCP: `Tls`/`Quic` are supported but need a cert on the
primary, and an IP ACL between two boxes we own on a trusted segment is
proportionate.

### Verification is part of the role, because creation proves nothing

A Secondary zone whose transfer the primary **refuses** still appears in the zone
list — just empty. So the role reads each zone back and asserts it carries
records beyond `SOA`/`NS`, with a failure message that names the three likely
causes in order (ACL missing the slave IP / wrong `technitium_primary_host` /
zone accidentally created as Primary by an unguarded `technitium-config`).

Same trap as everywhere else in this topic and worth restating: **Technitium
returns HTTP 200 with `"status": "error"` in the body.** Every mutating call in
the role carries `failed_when` on `json.status`, tolerating `'already exists'`
as the idempotent re-run path.

### State

Primary half applies today and is safe to run — it only sets zone options on
`dns-master`. Slave half is inert until the `dns-slave` block in `inventory.yml`
is uncommented, which is the single change needed when the Pi arrives.

Untested end-to-end: there is no second box yet. Both YAML and the API parameter
names are verified, but the first real run is the first real test — treat any
surprise as a role defect to fix and record, not something to work around by hand.

### Passwordless sudo — codifying drift found on the primary

Setting up `dns-slave` surfaced an inconsistency:

```
$ ssh admin@192.168.1.12 -i ~/.ssh/vadz_key 'sudo -n true && echo PASSWORDLESS || echo NEEDS-PASSWORD'
PASSWORDLESS            # dns-master
                        # dns-slave prompts
```

`dns-master`'s passwordless sudo was created out of band — RPi Imager or by hand
— and recorded nowhere. **It would not survive an SD reimage.** Structurally the
same defect as the hand-written `10-router-ntp.conf` drop-in that caused the
2026-07-25 outage: working state living only on the box.

The initial instinct was the opposite fix — keep the password and put
`ansible_become_password` in the vault, which `vars/vault.yml.example` already
anticipates. That is the better *security* answer in the abstract. But it was
the wrong answer here, and the evidence inverted it: the primary is **already**
passwordless, so codifying it changes nothing about the real posture and fixes
the drift. Storing a become password instead would have left dns-master's
unmanaged sudoers file in place, unrecorded, still one reimage from vanishing.

Shipped in `roles/base` so both boxes converge:

```yaml
- name: Grant the ansible user passwordless sudo
  ansible.builtin.copy:
    dest: "/etc/sudoers.d/010_{{ ansible_user }}-nopasswd"
    content: "{{ ansible_user }} ALL=(ALL) NOPASSWD: ALL\n"
    owner: root
    group: root
    mode: "0440"          # sudo REFUSES to read a group/world-writable file
    validate: "visudo -cf %s"
```

`validate:` is not optional. Ansible writes to a temp file, runs `visudo -cf`
against it, and installs it only if it parses. A malformed sudoers file locks out
sudo entirely; recovery is physical console or an SD swap.

Applied to `dns-slave` by hand for now (the box is not in the inventory yet),
using the same validate-before-install property:

```bash
printf 'admin ALL=(ALL) NOPASSWD: ALL\n' | EDITOR='tee' visudo -f /etc/sudoers.d/010_admin-nopasswd
```

`visudo -f` copies to a temp file, runs `$EDITOR` on it (`tee` just dumps stdin
in), parses the result, and only then installs — and sets `0440` itself. The
naive `echo > /etc/sudoers.d/...` skips the parse and is how people lock
themselves out. Keep an existing root shell open until a *new* session confirms
`sudo -n true` succeeds.

Because the role task already exists, this is not drift: when `dns-slave` enters
the inventory the playbook asserts the same file and reports `ok`, not `changed`.

Accepted cost, stated rather than buried: an SSH key on these boxes is root on
these boxes, with no second factor. SSH is key-only with password auth off, and
this was already true of dns-master — the change records reality rather than
creating it.

### 2026-08-25 (late) — "clustering" meant the vendor feature, not zone transfer

The operator asked for "the technitium cluster playbook". I read that as classic
DNS primary/secondary and built AXFR/IXFR zone replication. They meant
**Administration → Cluster**, added in Technitium **v14** — a different and much
broader feature. Source: https://blog.technitium.com/2025/11/understanding-clustering-and-how-to.html

What it syncs: server settings, Allowed/Blocked lists, Apps and their config,
**Users/Groups/Permissions**, API tokens, and opt-in zones via an auto-created
`cluster-catalog.<cluster-domain>` zone. Not synced: zones by default, cache,
logs, DHCP scopes. One node is Primary; config can only be changed while it is
online. Init auto-enables HTTPS with a self-signed cert, uses DANE-EE for
node-to-node TLS, and moves the admin panel to 53443.

**A correction I owe the record.** I first concluded the Cluster feature had no
HTTP API and therefore could not be automated — and made that the centrepiece of
the recommendation. That was wrong. `initJoin` is present in `APIDOCS.md`,
`DnsServerCore/www/js/cluster.js` and `DnsServerCore/DnsWebService.cs`; the
endpoints live under `/api/admin/cluster/…`, which a grep for `/api/cluster`
misses. Two separate WebFetch calls told me the endpoints did not exist — both
were **truncation artifacts**: APIDOCS.md is large enough that the fetcher never
reached that section, and it even said so ("the document excerpt provided does
not continue far enough"), which I should have treated as "unknown" rather than
"absent". GitHub code search settled it. **Absence of evidence from a
summarising fetcher is not evidence of absence.**

The recommendation survives the correction, but for different reasons: not
"can't automate it" — it can be — but that it conflicts with git as the source
of truth. Five reasons, now recorded in `ansible/technitium/README.md`:
config ownership moves to the primary's runtime state; it would contend with
`technitium-config`'s `/api/settings/set` with no documented field-level split
of cluster-common vs per-node keys; cluster state (node IDs, the TSIG key minted
at init, the self-signed cert, the catalog zone) is unreproducible runtime data
that an SD rebuild does not restore; it forces same-version lockstep upgrades,
killing `upgrade.yml`'s staggered slave-then-primary window; and it syncs
Users/Groups, which would overwrite the per-host admin accounts.

Also renamed `roles/technitium-cluster` → **`roles/technitium-replication`**.
The old name read as if it drove the vendor feature, which is precisely the
ambiguity that caused this detour.

### Per-host admin passwords

Separately, the operator pointed out the vault held ONE
`technitium_admin_password` for two servers. Technitium accounts are local to
each server, so that was simply wrong. Now a dict keyed by `inventory_hostname`,
resolved in `group_vars/all.yml`, with an explicit assert giving a readable
message instead of a Jinja KeyError when a key is missing. Still one vault file,
so the operator types the vault password once.

## 2026-08-25 (final) — going WITH the vendor Cluster feature

Operator's call, having heard the trade-offs: use Technitium's native Cluster.
Recording the full arc because most of the cost here was in getting the
requirement and the API contract right, not in writing the tasks.

### How I got the requirement wrong

"Prepare the playbook for technitium cluster" → I read *cluster* as classic DNS
primary/secondary and built AXFR/IXFR zone replication. The operator meant
**Administration → Cluster**, a v14 feature that syncs the *server*, not zones.
The screenshot of "Cluster Not Initialized" was what finally made it obvious.
Lesson: a domain word that has a generic meaning ("cluster") and a
product-specific meaning in the same tool is worth disambiguating up front,
especially when a plausible implementation exists for the wrong reading.

### How I got the API contract wrong, twice

Worse than the requirement error, because it nearly drove the whole design.

I fetched `APIDOCS.md`, searched it for `/api/cluster`, found nothing, and told
the operator clustering **could not be automated** — making "it breaks your
code-only rule" the centrepiece of a recommendation *against* it. A second
targeted fetch agreed: endpoints "do not exist".

Both were wrong, and both were the same failure: **`APIDOCS.md` is large enough
that a summarising fetcher truncates before reaching the cluster section.** The
tool even said so — *"the document excerpt provided does not continue far
enough"* — which I should have read as **unknown**, not **absent**. A research
subagent contradicted me; I did not take it at face value, which was right, but
the resolution came from GitHub code search:

```
repo:TechnitiumSoftware/DnsServer initJoin
→ APIDOCS.md, DnsServerCore/www/js/cluster.js, DnsServerCore/DnsWebService.cs
```

The endpoints live under `/api/admin/cluster/…`. A grep for `/api/cluster`
misses them entirely.

**Absence of evidence from a summarising tool is not evidence of absence.** When
a fetcher hedges about truncation, treat its negative as no answer at all.

### Where the contract actually came from

Not from prose. From `DnsServerCore/www/js/cluster.js` — the UI code that calls
these endpoints, so it cannot be out of date with them:

```
GET  api/admin/cluster/state[?includeServerIpAddresses=true][&node=]
GET  api/admin/cluster/init?clusterDomain=&primaryNodeIpAddresses=
POST api/admin/cluster/initJoin   (form body; the UI forces POST on this one alone)
       secondaryNodeIpAddresses, primaryNodeUrl, primaryNodeIpAddress,
       ignoreCertificateErrors, primaryNodeUsername, primaryNodePassword,
       primaryNodeTotp
```

Reading the implementation also surfaced things no summary would have: the
`cleanTextList()` helper that turns the newline textarea into a **comma
separated** list (so that is the wire format for both IP-address params), the
UI's own `clusterInitialized` pre-check before offering Initialize (proving
neither call is idempotent), and the full set of recovery endpoints —
`secondary/leave`, `secondary/promote`, `primary/delete`,
`primary/removeSecondary`.

### The design: two mechanisms, deliberately

| | `technitium-cluster` | `technitium-replication` |
|---|---|---|
| Syncs | settings, Allowed/Blocked, Apps, Users/Groups, API tokens | the two authoritative zones |
| Transport | HTTPS node-to-node, DANE-EE, self-signed, :53443 | DNS/53, IP-ACL restricted |

They coexist without conflict for a specific reason: **under clustering, zones
sync only if explicitly added to the auto-created `cluster-catalog` zone, and we
do not add them.** So zone data stays on the classic mechanism (already verified
working) and the cluster owns everything that is not a zone. The README carries
the standing rule: if a zone is ever added to the cluster-catalog, remove it
from `technitium_replicated_zones` in the same change.

The earlier "don't use clustering" recommendation was therefore half right for
the wrong reason. Its real objection — config source-of-truth moving from git to
the primary's runtime state — turns out not to bite here, because
`technitium-config` pushes *identical* values from git to both boxes, so the
cluster re-syncing the secondary from the primary is a no-op on values that
already match.

### Implementation notes worth keeping

- **Neither `init` nor `initJoin` is idempotent.** Both gate on
  `clusterInitialized` from `state`.
- **Ordering** is guaranteed by Ansible's default `linear` strategy: the
  primary's init task finishes on all hosts before the secondary's join begins.
  A secondary cannot join a cluster that does not exist.
- **Init restarts the web service ~2 s after responding**, so the role waits
  with `until`/`retries` instead of assuming the next call lands.
- **The primary's URL is read from its own state**, not constructed — it embeds
  the cluster domain and TLS port, and this session has already paid for one
  guessed format too many.
- **The join authenticates with the PRIMARY's credentials**, not the joining
  node's.
- **Clustering syncs Users/Groups**, so after a successful join both nodes share
  the primary's admin password. The per-host `technitium_admin_passwords` dict
  bootstraps each box *before* it joins; `dns-slave`'s entry must be updated to
  match `dns-master`'s afterwards.
- `technitium_cluster_domain` (`cluster.homelab.sudops.pl`) is **immutable** —
  it becomes a real zone, Primary on one node and Secondary on the others, with
  a TSIG key minted at init.

Untested against the live pair as of writing: `dns-slave` has Technitium
installed but the playbook has not completed a full run. First run is the first
real test.

## 2026-08-26 — cluster domain set to `homelab.sudops.pl`

Operator's call, on the naming: with the cluster domain as `homelab.sudops.pl`
the nodes read `dns-master.homelab.sudops.pl` / `dns-slave.homelab.sudops.pl`,
where `cluster.homelab.sudops.pl` would have given the uglier
`dns-master.cluster.homelab.sudops.pl`.

The consequence is not cosmetic. **`homelab.sudops.pl` is already a live Primary
zone** — `technitium-config` creates it and populates the LAN appliance records
(`nas`, `dns`), and it exists precisely so LAN boxes can hold real public-CA
certs without publishing LAN IPs to Cloudflare. The cluster domain also becomes
a zone (Primary on the primary, Secondary on every other node). So this hands an
existing, load-bearing zone to the cluster.

Two changes fell out of that:

1. **`homelab.sudops.pl` removed from `technitium_replicated_zones`.** The
   cluster now replicates it natively; leaving it in the list would have
   `roles/technitium-replication` create a competing Secondary zone for it on
   the slave. That is exactly the two-mechanisms collision the design was built
   to avoid — the standing rule ("one zone, one mechanism") caught it
   immediately, which is the entire reason the rule was written down.
   `okd.sudops.pl` is now the only classically-replicated zone.
2. Documented as **immutable**, with the recovery path (`primary/delete` then
   re-form) recorded next to it.

**Open and unverified:** whether `api/admin/cluster/init` *adopts* a
pre-existing zone with the cluster-domain name, or refuses it. Nothing in the
UI source settles this, and I am not going to guess at it after this session's
record on guessing. Mitigating factors: `technitium-config` runs before
`technitium-cluster`, so the zone exists first, which is the safer of the two
orders; and if init does refuse, the fallbacks are a dedicated subdomain or
deleting the zone and letting the cluster recreate it — the `nas`/`dns` records
live in `group_vars`, so a playbook re-run restores them either way.

This is the kind of thing worth watching on the first run rather than
discovering later: the cluster domain cannot be changed afterwards.

## 2026-08-26 (later) — cluster domain lands on `.home`

Third and final answer on the cluster domain: **`home`**, so nodes read
`dns-master.home` / `dns-slave.home`. The operator's framing was "`*.home`;
let's encrypt; no public" — and one half of that is not possible, which is worth
recording rather than quietly working around.

### Let's Encrypt cannot issue for `.home`

`.home` is not a delegated TLD. ICANN rejected the gTLD application, so there is
no public DNS hierarchy for an ACME challenge to be validated against. No
configuration makes this work; it is structural.

**It also does not matter**, and the reason is the interesting part. Technitium's
clustering authenticates node-to-node TLS with **DANE-EE**: TLSA records in the
cluster zone pin the *exact end-entity certificate*. Trust is anchored in DNS,
not in a CA chain. So the self-signed certificate that `init` generates is the
designed mechanism, not a fallback — a publicly-trusted cert would add precisely
nothing to node-to-node trust, and would only remove a browser warning on an
admin UI.

And it removes a failure mode rather than adding one. Earlier the same day the
cert-manager `*.homelab.sudops.pl` wildcard was found **expired at the consumer**
(the Synology) while cert-manager itself reported healthy — the delivery CronJob
had been failing nightly for a month. A `.home` cluster with DANE-EE has no
renewal path that can break that way.

### The companion change, and a rule that survived flipping

Two turns earlier the cluster domain was `homelab.sudops.pl`, which forced
`homelab.sudops.pl` OUT of `technitium_replicated_zones` — the cluster
replicated it natively, so classic AXFR/IXFR would have been a second mechanism
on the same zone.

Moving the cluster domain to `.home` **reverses that**: `homelab.sudops.pl` is
no longer cluster-managed, so it goes back into `technitium_replicated_zones`.

Worth noting that the *rule* never changed even though the answer flipped twice:
**one zone, one mechanism.** A rule that produces different answers as the
context changes, without itself needing revision, is the kind worth writing
down — it caught the collision in one direction and the gap in the other.

### On the name itself

`.home` is unreserved. ICANN rejected it as a gTLD but did not protect it, and
it is among the most-leaked invalid TLDs at the root servers. The
standards-track alternatives are `home.arpa` (RFC 8375, IANA special-use,
guaranteed never delegated) and `.internal` (ICANN-reserved for private use,
2024). Both are safer; both are longer.

Flagged, operator chose `.home`, recorded. Technitium is authoritative for the
zone so nothing leaks upstream in practice, and the risk is theoretical. But the
domain is **immutable** — switching later means deleting and re-forming the
cluster, so this is the moment the choice is cheap.

No collision with the existing `home.lab` / `homelab.net` conditional-forwarder
zones.

## 2026-08-26 — both mechanisms live, DNS is no longer a single point of failure

`failed=0` on both hosts. `dns-master ok=45`, `dns-slave ok=41`.

```
TASK [technitium-cluster : Assert this node is in a cluster with every expected member]
ok: [dns-master] => "dns-master: 2 nodes, domain home."
ok: [dns-slave]  => "dns-slave: 2 nodes, domain home."

TASK [technitium-cluster : Report cluster membership]
dns-master.home | type=Primary   | state=Self      | url=https://dns-master.home:53443/
dns-slave.home  | type=Secondary | state=Connected | url=https://dns-slave.home:53443/

TASK [technitium-replication : SLAVE | Assert each replicated zone carries more than just its SOA/NS]
ok: okd.sudops.pl: 8 records replicated.
ok: homelab.sudops.pl: 4 records replicated.
```

Verified at the DNS layer, which is what actually matters — the API reporting
records is not the same as the resolver answering with them:

```
$ dig +short @192.168.1.13 api.okd.sudops.pl      -> 192.168.1.240
$ dig +short @192.168.1.13 nas.homelab.sudops.pl  -> 192.168.1.2
$ dig +short @192.168.1.13 dns-slave.home         -> 192.168.1.13
```

Twelve hours earlier the same queries against `.13` returned **Cloudflare
addresses** (`172.67.173.34`, `104.21.72.4`) because the box held no zones and
was recursing to the public internet. Those are correct *public* answers and
completely wrong for LAN use — `api.okd.sudops.pl` pointing anywhere but
`192.168.1.240` is the shape that broke kubelet discovery on 2026-05-12.

### What init created on its own

The zone list on the primary now shows what clustering built without being asked:

| Zone | Type | Note |
|---|---|---|
| `cluster-catalog.home` | Catalog | auto-created; the opt-in mechanism for zone sync |
| `home` | Primary | **DNSSEC-signed**, and a member of `cluster-catalog.home` |

So the cluster domain zone is signed and catalog-managed automatically. Neither
`okd.sudops.pl` nor `homelab.sudops.pl` is a catalog member — which is exactly
the design: they stay on classic AXFR/IXFR via `technitium-replication`, and the
cluster owns everything that is not a zone. **One zone, one mechanism**, holding.

### The failure model, now that there is one

Worth writing down precisely, because "we have a second DNS server" invites
wrong assumptions.

| `dns-master` down for | Result |
|---|---|
| minutes–hours | Slave serves zones, blocklists and recursion. Clients stall one resolver timeout per query before failing over. **Resilience, not HA.** |
| days | Still resolving. But cluster config is **primary-only** — secondaries are read-only — so no settings/blocklist/zone changes, and Ansible runs fail. |
| **> 7 days** | **Zones expire on the slave.** |

That last row comes from the SOA, not from guesswork:

```
$ dig @192.168.1.13 okd.sudops.pl SOA
okd.sudops.pl. 900 IN SOA dns-master.home. hostadmin.okd.sudops.pl. 59 900 300 604800 900
                                                                       ^^^ ^^^ ^^^^^^
                                                              refresh 15m  retry 5m  EXPIRE 1w
```

A Secondary that cannot reach its primary for `expire` seconds stops being
authoritative and falls back to recursion — at which point `api.okd.sudops.pl`
resolves to Cloudflare again and the cluster breaks in the documented way. The
7-day window is generous, but it is a cliff, not a slope.

For a permanent primary loss the recovery is **Promote To Primary** on the
secondary (`api/admin/cluster/secondary/promote`), which converts it and evicts
the old primary. Deliberate manual action; there is no automatic failover, and a
shared keepalived VIP remains the only route to one.

### Still to do

`.13` is not yet in DHCP, so **none of the above is reachable by clients** —
turning off the primary today still takes the LAN's DNS with it.

```
/ip/dhcp-server/network/set [find] dns-server=192.168.1.12,192.168.1.13
```

And: because clustering syncs Users/Groups, `dns-slave`'s admin password is now
`dns-master`'s. The per-host `technitium_admin_passwords` dict bootstrapped each
box before it joined; both entries must now hold the primary's value or the next
run's login falls through to the adopt path and fails.

### Bugs found on the way to a clean run

Three, all mine, all introduced while adding the adopt/cluster paths:

1. **`register:` on a skipped task clobbers the variable.** The adopt block's
   final re-login reused `register: technitium_login`, so on the normal path
   (first login fine → block skips) the skip result overwrote the real login,
   producing the contradictory "status ok, but no token".
2. **The logout was in the wrong role.** `technitium-config` runs third of five
   and ended by logging out, invalidating the session that `technitium-cluster`
   and `technitium-replication` both depend on. First cluster call returned
   HTTP 200 with `{"status":"invalid-token"}`. Moved to `playbook.yml`
   `post_tasks`, which runs after every role rather than after one.
3. **A cascading failure with a useless message.** When the primary's init
   failed, the secondary died on a raw Jinja error about `HostVarsVars` having
   no `technitium_cluster_primary_url` — saying nothing about the real cause
   being upstream. Now an explicit assert: "fix the PRIMARY first".

Each was invisible to `--syntax-check` and to YAML validation. The pattern
across all three: **role-to-role state coupling is where this breaks**, not
inside any single role.
