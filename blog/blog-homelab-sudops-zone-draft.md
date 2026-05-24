# `homelab.sudops.pl` zone — design draft

Working notes for the new LAN-appliance DNS zone + automated wildcard cert
delivery. Pulled out of a 2026-05-15 thread about adding the Synology NAS
to a "real" hostname with a valid TLS cert.

## Goal

Make every non-OKD LAN appliance addressable as `<name>.homelab.sudops.pl`
with a valid public TLS cert, without leaking any LAN IPs to the public
internet. Today's targets: Synology NAS, `dns-master` (Technitium box).
Future: anything else worth a name on the LAN.

## DNS architecture (where each name resolves)

```
sudops.pl                                 ← Cloudflare (public registrar)
├── okd.sudops.pl                         ← cluster: split-horizon
│   ├── api.okd.sudops.pl                 (Technitium internal + Cloudflare DNS-01)
│   └── *.apps.okd.sudops.pl
└── homelab.sudops.pl                     ← NEW: LAN-only authoritative
    ├── nas.homelab.sudops.pl             → NAS LAN IP
    ├── dns.homelab.sudops.pl             → 192.168.1.12 (dns-master)
    └── … (future)
```

**Split-horizon**: Technitium serves `homelab.sudops.pl` authoritatively to
LAN clients with real LAN IPs. Cloudflare doesn't have any A records for
this subdomain — external queries return NXDOMAIN. No public LAN-IP leak.

**Cert delivery**: even though Cloudflare doesn't serve A records for
`homelab.sudops.pl`, the parent `sudops.pl` zone IS on Cloudflare, so the
DNS-01 challenge mechanism works — cert-manager creates a transient
`_acme-challenge.foo.homelab.sudops.pl` TXT in the `sudops.pl` zone via
the Cloudflare API, LE validates, cert issued. Same pattern as the
existing `*.apps.okd.sudops.pl` wildcard.

## Implementation plan

### 1. Technitium — add the zone (Ansible)

Touches `ansible/technitium/`. Add a new zone via Technitium's API:

```yaml
# tasks/main.yml addition
- name: Add homelab.sudops.pl as authoritative zone
  ansible.builtin.uri:
    url: "{{ technitium_api }}/api/zones/create"
    method: GET
    body_format: form-urlencoded
    body:
      token: "{{ technitium_api_token }}"
      zone: homelab.sudops.pl
      type: Primary

- name: Add A records under homelab.sudops.pl
  ansible.builtin.uri:
    url: "{{ technitium_api }}/api/zones/records/add"
    body:
      token: "{{ technitium_api_token }}"
      domain: "{{ item.name }}.homelab.sudops.pl"
      type: A
      ipAddress: "{{ item.ip }}"
      ttl: 3600
  loop:
    - { name: nas, ip: 192.168.1.<NAS_IP> }
    - { name: dns, ip: 192.168.1.12 }
```

`ansible.builtin.uri` (not `community.general.uri`) keeps with the
"all-builtin" invariant in CLAUDE.md.

### 2. cert-manager — wildcard Certificate

Touches `components/cluster-config/cert-manager-config/`. Add a sibling
to the existing `*.apps.okd.sudops.pl` Certificate:

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: homelab-wildcard
  namespace: cert-manager
spec:
  secretName: homelab-wildcard-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  commonName: "*.homelab.sudops.pl"
  dnsNames:
    - "*.homelab.sudops.pl"
    - "homelab.sudops.pl"
```

The Cloudflare API token already has permission on the parent `sudops.pl`
zone — no token re-seal needed.

### 3. Synology DSM cert auto-import (CronJob)

Touches `components/cluster-config/` (new chart, e.g. `synology-cert-sync/`).
Daily CronJob that:

1. Reads `homelab-wildcard-tls` Secret
2. Logs into DSM via the API (auth → SID cookie)
3. Computes a hash of the in-cluster cert + the current DSM cert
4. If different: uploads the new cert via DSM's certificate API
5. Else: no-op

DSM API endpoints (per Synology docs):
- `POST /webapi/auth.cgi?api=SYNO.API.Auth&method=login&...`
- `POST /webapi/entry.cgi?api=SYNO.Core.Certificate&method=import` (multipart upload)

Auth: a dedicated DSM user with **Certificate management** permission
only (not full admin). Creds land in a SealedSecret in the cluster.

Pseudocode:
```bash
#!/bin/bash
set -euo pipefail
DSM_HOST=nas.homelab.sudops.pl
SID=$(curl -sk "https://$DSM_HOST/webapi/auth.cgi?api=SYNO.API.Auth&version=3&method=login&account=$DSM_USER&passwd=$DSM_PASS&format=sid" | jq -r .data.sid)
# pull current cert serial from DSM and compare to /tls/tls.crt — short-circuit if equal
# else multipart-upload the new cert+key+chain
curl -sk -b "id=$SID" -F "file=@/tls/tls.crt" -F "key=@/tls/tls.key" \
  "https://$DSM_HOST/webapi/entry.cgi?api=SYNO.Core.Certificate&method=import&version=1"
curl -sk "https://$DSM_HOST/webapi/auth.cgi?api=SYNO.API.Auth&method=logout&version=2&_sid=$SID"
```

Mount the `homelab-wildcard-tls` Secret at `/tls`. Schedule: `0 3 * * *`
(once daily; LE renews 30d before expiry so daily-poll is fine).

### 4. Open questions before implementation

- **Hostname list** — `nas` + `dns` confirmed; anything else (mikrotik?
  printer? camera? other)? Want all of them in the initial zone or grow
  organically?
- **NAS LAN IP** — needs the actual IP for the A record
- **DSM cert-import user** — caller needs to create it on the NAS before
  the CronJob can land. Username + password get sealed.
- **DSM hostname** — once DNS + cert are in place, change DSM's
  "FQDN/Hostname" in Control Panel → Info Center to `nas.homelab.sudops.pl`
  so its self-issued links + email notifications use the new name.
- **Renaming `dns-master`** — the technitium ansible inventory currently
  uses `dns-master` (also the literal hostname of the RPi). Cosmetic
  question: bump to match `dns.homelab.sudops.pl`, or leave as-is. Lean
  toward leaving — the hostname is `dns-master`, the FQDN-with-zone is
  `dns.homelab.sudops.pl`. They don't have to match.

## Not in scope

- Public-facing services on `homelab.sudops.pl` (router exposure, port
  forwarding, etc.). The zone is LAN-only by design.
- Per-host certs (vs wildcard). One wildcard simplifies renewal + delivery.
- HA Technitium — separate ongoing TODO (RPi Zero 2W as `dns-secondary`).
  If `dns-master` goes down, `homelab.sudops.pl` resolution dies with it.
  Same exposure as today's `okd.sudops.pl`.

## Renovate / lifecycle

- LE renews 30d before expiry; cert-manager triggers automatically
- CronJob picks up new cert within 24h of renewal; no DSM touch
- Re-seal DSM creds only when password rotates
- No code changes between renewals

---

## 2026-05-24 — Rollout chronology (all three phases shipped)

### Phase 1: `*.homelab.sudops.pl` wildcard cert (a49a8d2)

Added a Certificate entry in `components/cluster-config/cert-manager-config/values.yaml`:

```yaml
- name: homelab-wildcard
  namespace: cert-manager
  secretName: homelab-wildcard-tls
  dnsNames:
    - "*.homelab.sudops.pl"
    - "homelab.sudops.pl"
```

DNS-01 challenge ran against the parent `sudops.pl` Cloudflare zone — even though Cloudflare carries no records under `homelab.sudops.pl`, the challenge only needs the parent zone, and the existing Cloudflare API token (from the okd wildcard) already has scope. Cert issued in ~2 min. Valid until 2026-08-22.

### Phase 2: Technitium zone (4e20c77)

Mirrored the okd zone pattern in `ansible/technitium/roles/technitium-config/tasks/main.yml`. Two new tasks: zone create + records add. Idempotent shape (status="error" + "already exists" tolerated) matches the okd zone.

Initial A records:
- `nas.homelab.sudops.pl → 192.168.1.2`
- `dns.homelab.sudops.pl → 192.168.1.12`

Ran via `ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass --tags zones`. Verified with `dig +short @192.168.1.12 nas.homelab.sudops.pl` returning `192.168.1.2`.

### Phase 3: Synology DSM cert-sync CronJob (47ecb54 + 4 fixes)

Three rounds of bugs before this was happy:

| Commit | Bug | Fix |
|---|---|---|
| `f53e39c` | `quay.io/curl/curl` had no `openssl` → fingerprint compare failed | Switched main container to `ose-cli` (already used by init container) |
| (manual) | DSM login returned `code:406` → 2-step verification required | Disabled 2FA on the dedicated DSM admin user; CronJobs can't do interactive 2FA |
| `3858f91` | DSM cert import returned `code:5512` | cert-manager bundles leaf+chain in `tls.crt`, DSM wants them SPLIT (leaf in `cert`, intermediates in `inter_cert`). Added an awk PEM-block splitter. |
| `6010411` | Each run created a new DSM cert entry — duplicates accumulated | Look up existing by `desc` via `SYNO.Core.Certificate.CRT/list`, pass `id=<existing>` to import → DSM replaces in place |

End-to-end now: cert-manager auto-renews 30d before expiry → next daily CronJob run fingerprint-detects the diff → replaces DSM cert by `id` (service bindings stick) → fingerprint check matches → no-op until next renewal. Zero-touch from here.

### Lessons learned

- **Wildcard DNS-01 works fine over a parent Cloudflare zone even when the subdomain has no Cloudflare records.** That's how LE validates the challenge — they don't care that the subdomain isn't otherwise public.
- **DSM 7.x has no per-section admin delegation for Certificate management.** Service accounts have to be in the `administrators` group + 2FA disabled. Acceptable trade-off when the API is LAN-only and the password is sealed.
- **cert-manager `tls.crt` is a bundle; DSM expects split.** The empty `inter_cert` form silently returns 5512 — diagnostic was clear once we knew to split.
- **`SYNO.Core.Certificate.CRT/list` is the right endpoint for cert enumeration in DSM 7.x** (despite the `.import` call being on the non-`.CRT` namespace). Useful to remember if/when we automate other DSM cert operations.
- **Wildcards cover ANY single-label subdomain** — `*.homelab.sudops.pl` is valid for `nas.homelab.sudops.pl`, `dns.homelab.sudops.pl`, and any future name. We don't need (or want) per-host certs in DSM. Confirmed visually: DSM cert list shows `*.homelab.sudops.pl` covering all services, no per-host cert needed.
