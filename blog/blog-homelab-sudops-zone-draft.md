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
- HA Technitium — separate ongoing TODO (RPi Zero 2W as `dns-slave`).
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

## 2026-08-26 — the wildcard expired on the Synology while cert-manager was green

Spotted from a browser cert dialog: `*.homelab.sudops.pl` **expired Saturday 22
August 2026 at 14:20:32 CEST**. Meanwhile, in-cluster:

```
$ oc -n cert-manager get secret homelab-wildcard-tls -o jsonpath='{.data.tls\.crt}' \
    | base64 -d | openssl x509 -noout -subject -enddate
subject=CN=*.homelab.sudops.pl
notAfter=Oct 21 11:24:57 2026 GMT
```

cert-manager had renewed correctly. **Delivery** was what broke.

```
$ oc -n synology-cert-sync get cronjob,job
cronjob.batch/synology-cert-sync   14 3 * * *   False   0   18h   93d
job.batch/synology-cert-sync-29746274   Complete   33d
job.batch/synology-cert-sync-29790914   Failed     2d18h
job.batch/synology-cert-sync-29792354   Failed     42h
job.batch/synology-cert-sync-29793794   Failed     18h
```

### The timeline is the whole diagnosis

Last `Complete` run ≈ **33 days ago**. Let's Encrypt renews ~30 days before
expiry, and the cert expired 22 Aug — so renewal was ~23 Jul, which is exactly
when the successes stop.

That means: for every run up to the renewal, the job was a **no-op** — the
script compares the cluster cert's SHA-256 fingerprint against what DSM is
serving and exits 0 when they match. It reported green for months **while doing
nothing**. The first time it had actual work to do, it failed — and has failed
every night since, unnoticed, until the old cert ran out and a browser complained.

**The no-op path worked; the replacement path was broken.** And the replacement
path only executes once every ~60–90 days, so it is the one path that is never
exercised until the moment it matters. Any `*-cert-sync` job has this shape by
construction.

### Ruled out

An appealing theory — DSM's cert expired, so the sync could no longer connect
over HTTPS to fix it, a self-inflicted deadlock — is **wrong**. The script uses
`curl -sk` throughout; `-k` skips validation, so an expired DSM cert cannot
block the connection. Worth writing down because it is exactly the kind of
tidy-sounding explanation that gets adopted without checking.

Remaining candidates, all on the DSM side of the replacement path: login
rejected (2FA enforcement on the admin account, changed password, or DSM's
auto-block after repeated attempts), or `SYNO.Core.Certificate` import failing.
The failed pods were garbage-collected, so a manual run is needed to capture the
response — the script echoes it.

### Two monitoring gaps, both worse than the cert

1. **Nothing alerts on a recurring CronJob failing.** `KubeJobFailed` is on this
   repo's known-benign list, but that entry is scoped to *completed one-shot
   bootstrap Jobs*. A CronJob failing nightly for a month is a different animal
   and must not be pattern-matched into the same bucket. This is precisely the
   trap CLAUDE.md already warns about with `PrometheusKubernetesListWatchFailures`
   — an unfamiliar alert absorbed into the benign list — and it happened again.
2. **Nothing alerts on certificate expiry at the consumer.** Only cert-manager's
   own view is monitored, and it was green the entire time. The measurement has
   to be taken where a *client* stands, not where the issuer does — a blackbox
   TLS probe against `nas.homelab.sudops.pl:5001` would have fired 30 days out.

Honest note on process: the session-start sweep earlier the same day reported
"12 alerts firing / 0 critical" without enumerating them. If a `KubeJobFailed`
for this was in that list, it was dismissed by counting rather than reading.
Counting alerts is not triaging them.

### Bearing on the Technitium cluster cert question

Asked in the same session whether Technitium's cluster TLS could use the
cert-manager wildcard instead of the self-signed cert init generates. The
argument against leaned on renewal being the risky part rather than first
install. This is that argument, live, on the very same wildcard — and it
strengthens the recommendation to leave Technitium's cluster on its self-signed
cert, where DANE-EE pins the certificate and there is no renewal path to break.

### Root cause: a SyntaxError that only ran once a quarter

A manual run gave the answer immediately:

```
cluster cert fp: DA:CE:84:F3:9D:05:...
dsm     cert fp: AF:6F:D6:9E:BF:D9:...
Fingerprints differ; uploading.
DSM login OK.
  File "<string>", line 14
SyntaxError: f-string expression part cannot include a backslash
```

DSM login was fine. The failure was in the embedded Python that resolves which
DSM certificate to replace:

```python
f"replacing id={chosen.get(\"id\")}, leaving {len(matches)-1} duplicate(s) alone.\n"
```

An **escaped double quote inside an f-string expression** — a SyntaxError on
Python < 3.12 (PEP 701 relaxed this in 3.12; the container image is older). And
the escape was not carelessness: the whole block is passed to `python3 -c '...'`
inside a **single-quoted shell string**, so a plain single quote would have
terminated that string early. Cornered by three levels of quoting, the author
picked the option that happened to be invalid Python.

**That code had never worked.** When the fingerprints match, the script exits 0
*before* reaching it — so the only runs that even compile it are the ~quarterly
ones with a certificate to replace. A daily job, green for months, whose single
purpose had never once been exercised.

Fix: bind the value to a name first, so the f-string needs no backslash.

```python
chosen_id = chosen.get("id", "")
print(chosen_id)
...
f"replacing id={chosen_id}, leaving {len(matches)-1} duplicate(s) alone.\n"
```

### Nearly repeating the mistake while fixing it

The first patch added an explanatory comment containing the literal text
`python3 -c '...'` — single quotes, inside the single-quoted block. That would
have ended the shell string early and broken the script in a *new* way. It
surfaced only because an extraction regex choked on it.

So two assertions now run against the rendered chart, both of which would have
caught the original bug at commit time rather than at renewal time:

```
$ helm template … > rendered.yaml
$ python3 checkpy.py rendered.yaml
single quotes inside python -c block: NONE (good)
embedded python COMPILES ok
$ sh -n sync.sh && echo "shell syntax: OK"
shell syntax: OK
```

Generalisable: **an embedded interpreter, inside a quoted shell string, inside
YAML, has three levels of quoting and zero syntax checking.** Nothing in
`helm lint`, `kubeconform` or ArgoCD looks inside that string. Any future
`*-cert-sync` has the identical shape.

### Verified end to end

```
$ oc -n synology-cert-sync logs job/cert-sync-fix-… --all-containers
Fingerprints differ; uploading.
DSM login OK.
Replacing existing DSM cert id=KB7FpK.      <-- the path that had never run
DSM cert import OK.

$ echo | openssl s_client -connect 192.168.1.2:5001 -servername nas.homelab.sudops.pl \
    | openssl x509 -noout -subject -issuer -enddate -fingerprint -sha256
subject=CN=*.homelab.sudops.pl
issuer=C=US, O=Let's Encrypt, CN=YR2
notAfter=Oct 21 11:24:57 2026 GMT
sha256 Fingerprint=DA:CE:84:F3:9D:05:...:66:95:00
```

`notAfter` moved from the expired 22 Aug to 21 Oct, and the served fingerprint
now matches the cluster secret exactly. Closed.

### What actually failed here

Three independent things, each individually reasonable:

1. A **quoting trap** produced code that could not run.
2. The broken path was **only reachable once a quarter**, so months of green
   runs proved nothing about it.
3. **Nothing alerted**, because OpenShift's `KubeJobFailed` is scoped to
   platform namespaces and this namespace was never in scope.

Any one of the three alone would have been caught. The lesson worth keeping is
(2): *a scheduled job whose common path is a no-op is not tested by running it.*
The only meaningful test is forcing the rare path — which for a cert-sync means
deliberately pushing a cert that differs, not waiting for a renewal to do it.
