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

- **TODO** — pull the actual list URLs from the live pi-hole UI before cutover. Technitium imports the same Steven Black / OISD / etc. lists natively.

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

## Open items / TODOs

Closed during 2026-05-12 design session:

- ✅ OS confirmed — RPi OS Lite aarch64 (kernel 6.12.75, Bookworm-based, build 2026-03-11). Same image for primary + future secondary.
- ✅ Install method decided — native via Technitium's installer script. Not Docker.
- ✅ Config management approach — Ansible playbook under `ansible/technitium/`, applied manually from a workstation. Not under ArgoCD (DNS shouldn't depend on the cluster being up).
- ✅ Hostname / inventory key — `dns-master` (matches the existing `pi-hole-master` convention). Future secondary: `dns-secondary`.
- ✅ SSH access shape — `ssh admin@192.168.1.12 -i ~/.ssh/vadz_key`, passwordless sudo confirmed.
- ✅ Ansible scaffold built — `playbook.yml` (full configure), `base-only.yml` (no-vault validation), `upgrade.yml` (OS + Technitium periodic upgrade). All `ansible.builtin.*` modules only.
- ✅ Base role validated end-to-end against the live box (ok=6, changed=2 — installed missing packages + dropped 20auto-upgrades config).
- ✅ Block list URLs decided — StevenBlack/hosts only (validated 2026-05-12, ~82.6k blocked domains, hosts-file format, recent upstream commit). Single source of truth; add more later if a specific gap shows up.
- ✅ Technitium HTTP API param names pinned (see section above).

Still open:

- [ ] **End-to-end run of `playbook.yml`** against the live Technitium API with the vault password. Will surface any param-name drift between APIDOCS.md and the actual installed version.
- [ ] **Confirm `gw.home.lab` (MikroTik) conditional-forwarder for `okd.sudops.pl`** — point or remove. After technitium becomes authoritative on the LAN view, the gateway's forwarder rule should either be removed (if nothing else needs it) or repointed at `192.168.1.12`. Verify before cutover.
- [ ] **Cutover swap**: stop pi-hole, restart `dns.service`, verify Technitium grabs `:53`. ~1 min LAN DNS downtime; pick a quiet window.
- [ ] **24h soak after cutover** then `apt remove --purge pihole pihole-FTL` to clean up.
- [ ] **Monitoring**: Technitium has a Prometheus exporter (community); scrape from the cluster's existing stack into a dashboard. Low priority — defer until cutover is done.
- [ ] **Procurement**: RPi Zero 2W for the secondary. Not blocking; primary works standalone.
