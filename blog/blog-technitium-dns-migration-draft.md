# technitium: DNS migration from pi-hole — planning notes

Working notes for replacing the home pi-hole (RPi 3B+ at `192.168.1.12`) with **Technitium DNS Server** on the same physical RPi 3B+, host name `dns-master` (matches the existing `pi-hole-master` convention). Later: add a secondary on an RPi Zero 2W for HA — `dns-secondary`, primary/secondary pair clustered via Technitium's built-in replication. Web UI reachable at `http://dns-master:5380` once the LAN resolves the new hostname. **Plan, not implementation.**

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
| Secondary IP | TBD (likely `192.168.1.13`) | Decide when the Zero 2W lands; needs DHCP reservation. |
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
    └── (future) replication to secondary on 192.168.1.13 (RPi Zero 2W)

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
- **Secondary** (`192.168.1.13`, RPi Zero 2W): read-only replica, polls primary for zone transfers (NOTIFY+IXFR), serves the same answers.
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
├── inventory.yml          # dns-master (RPi 3B+), dns-secondary (RPi Zero 2W, future)
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

The playbook is **idempotent and pull-based** — running it against either node converges that node to the desired state. Primary and secondary differ only in role-level params (replication mode, peer address). The user runs `ansible-playbook -i inventory.yml playbook.yml --limit dns-master` (or `--limit dns-secondary`) from a workstation.

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
- ✅ Hostname / inventory key — `dns-master`; future secondary `dns-secondary`.
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

Still open (queued for tomorrow / future):

- [ ] **24h soak then pi-hole purge** — verify Technitium remains stable through Mon/IoT/laptop traffic patterns overnight, then on `dns-master`: `sudo apt remove --purge pihole pihole-FTL && sudo rm -rf /etc/pihole /var/log/pihole*`. Reclaims disk and removes the now-dead pi-hole binary.
- [ ] **Audit MikroTik's static DNS table for other LAN-local zones** that might need Forwarder zones in Technitium too. Today's `kube-cp.homelab.net` surprise proved the design needs zone-by-zone validation, not just `okd.sudops.pl`. Check every active entry in `/ip dns static print` — if it's a zone Technitium doesn't have either authoritatively or via Forwarder, add it to `technitium_forwarder_zones` in `group_vars/all.yml`.
- [ ] **Apply `failed_when status != "ok"` to the other zone-create tasks** (okd.sudops.pl + blocked zones). They're working empirically today but currently subject to the same silent-failure pattern — would silently no-op on a future Technitium API change. Cheap belt-and-braces.
- [ ] **Cosmetic: SOA primary NS shows `pi-hole-master.`** for all three Technitium-served zones (`okd.sudops.pl`, `cluster.local`, `svc.cluster.local.okd.sudops.pl`). Holdover from the box's old hostname before today's rename. Fix via the web UI's zone editor (`Zones → <zone> → SOA → Primary Name Server` → `dns-master.`) or by deleting + recreating the zones via the Ansible role. Purely cosmetic.
- [ ] **Cosmetic: MikroTik DHCP lease record + DNS static entries.** The lease still labels `192.168.1.12` as `pi-hole-master` — change the lease's "Host Name" field to `dns-master`. Also after the 24h soak, remove the now-dead static DNS entries for `api.okd.sudops.pl`, `api-int.okd.sudops.pl`, and the `*.apps.okd.sudops.pl` regex on the router (technitium answers these authoritatively now).
- [ ] **Monitoring**: Technitium has a Prometheus exporter (community — pick one); scrape from the cluster's stack into a dashboard. Lower priority; defer.
- [ ] **Procurement**: RPi Zero 2W for the `dns-secondary` secondary. Not blocking; primary works standalone.
