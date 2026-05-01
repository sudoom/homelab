# Pi-hole rebinding protection silently broke ArgoCD UI on the cluster

A short session that started as "the GitOps UI is loading slowly" and turned out to be a cluster-wide DNS regression that had probably been latent for weeks. Worth writing up because the failure mode is confusing — the upstream resolver was *partially* responsive, and the symptom only surfaced after a pod roll cleared a warm cache.

## Symptom

User reported the ArgoCD UI behaving strangely. The login flow completed (OAuth callback succeeded against Dex), but the app list never rendered. `argocd-server` logs were full of:

```
warning  Reconnect to redis because error: "dial tcp: lookup openshift-gitops-redis.openshift-gitops.svc.cluster.local: i/o timeout"
warning  Failed to resync revoked tokens. retrying again in 1 minute: dial tcp: lookup openshift-gitops-redis...: i/o timeout
```

Looped roughly once a minute. Redis pod itself was 1/1 Running, age 6h57m; `oc get endpoints openshift-gitops-redis` resolved fine.

## First false lead

Initial assumption: Redis pod was the problem. It wasn't. `Service`, `Endpoints`, and the pod itself were healthy. `oc -n openshift-gitops get pods` showed the **`argocd-server` pod was 3m37s old** while the rest of the GitOps stack was 6h57m. So the server had just been rolled — the question became, "why is *this* pod failing DNS when the others aren't?"

Answer (I figured out later): the others had warm Redis connections that bypassed DNS. Newly-started pods have to resolve from cold and that's where the failure lived.

## Following the DNS chain

Confirming the problem was actually DNS rather than networking:

```bash
$ oc -n openshift-gitops exec deploy/openshift-gitops-server -- timeout 3 getent hosts openshift-gitops-redis.openshift-gitops.svc.cluster.local
exit 124  # timeout
$ oc -n openshift-gitops exec deploy/openshift-gitops-server -- cat /etc/resolv.conf
search openshift-gitops.svc.cluster.local svc.cluster.local cluster.local okd.sudops.pl
nameserver 172.30.0.10
options ndots:5
```

Standard OKD pod DNS — the `okd.sudops.pl` suffix in the search list is the foot-gun.

Cluster CoreDNS (in `openshift-dns`, on each node) showed the actual upstream errors:

```
[ERROR] plugin/errors: 2 openshift-gitops-redis.openshift-gitops.svc.cluster.local.okd.sudops.pl. A:
        read udp 10.130.0.17:46037->192.168.1.7:53: i/o timeout
```

CoreDNS-on-pod was forwarding the okd.sudops.pl-suffixed form to the host CoreDNS at `192.168.1.7:53`. Then on the host:

```
$ oc debug node/node4.okd.sudops.pl --quiet -- chroot /host crictl logs --tail 5 <coredns-id>
[ERROR] plugin/errors: 2 ...okd.sudops.pl. AAAA: read udp 192.168.1.7:34211->192.168.1.12:53: i/o timeout
```

So host CoreDNS was forwarding upstream to **192.168.1.12** (the home pi-hole) and *that* was the timeout point. Confirmed by reading the host Corefile:

```
forward . 192.168.1.12 {
    policy sequential
}
```

## The "partial responsiveness" trap

The first surprise: pi-hole was clearly *up* — the LAN was working, name resolution for normal external names was fine. So upstream DNS being "broken" wasn't quite the right framing. Demonstrated:

```bash
$ dig @192.168.1.12 grafana.com +short
34.120.177.193                                # ← works, ~5ms

$ dig @192.168.1.12 anything.cluster.local.okd.sudops.pl +short
;; communications error to 192.168.1.12#53: timed out
;; communications error to 192.168.1.12#53: timed out
;; communications error to 192.168.1.12#53: timed out
```

Pi-hole was happily resolving public names, but **silently dropping queries that contained `cluster.local`** anywhere in the qname. No REFUSED, no NXDOMAIN — just no response.

That's classic dnsmasq DNS rebinding protection (`stop-dns-rebind`) hitting the `cluster.local` namespace because, from pi-hole's perspective, it looks like a query for an internal/locally-assigned domain. Pi-hole's role as a recursive resolver doesn't know what `cluster.local` is *for*; the heuristic just says "I shouldn't forward this upstream and I don't have an authoritative answer, so… nothing."

## Why the search-list mattered

The argocd-server resolver was looking up `openshift-gitops-redis.openshift-gitops.svc.cluster.local` — 4 dots. With `ndots:5`, glibc/Go's resolver tries the search list expansions *first*, in order:

1. `openshift-gitops-redis.openshift-gitops.svc.cluster.local.openshift-gitops.svc.cluster.local` → CoreDNS NXDOMAIN, fast
2. `…cluster.local.svc.cluster.local` → NXDOMAIN, fast
3. `…cluster.local.cluster.local` → NXDOMAIN, fast
4. `…cluster.local.okd.sudops.pl` → CoreDNS forwards to host CoreDNS → forwards to pi-hole → **timeout, 6 s**
5. (would have tried absolute `…cluster.local.` next, which would have succeeded)

Go's net resolver gave up at step 4 with the timeout error rather than continuing to step 5. So the ServiceIP that *would* have resolved correctly was never queried.

This was happening on every fresh DNS lookup in every pod that didn't already have a warm cache. Long-lived workloads (rook-ceph, cephfs CSI, the older argocd-controller, dex, repo-server) had cached Redis/Service IPs from earlier and didn't notice. argocd-server, freshly rolled minutes earlier, did.

## The fix

Two-line dnsmasq config on the pi-hole host:

```
# /etc/pihole/dnsmasq.d/02-okd-cluster-local.conf  (pi-hole v6 path)
local=/cluster.local/
local=/svc.cluster.local/
```

`local=/<domain>/` registers the zone as locally-handled — dnsmasq answers itself (NXDOMAIN if it has no record, REFUSED if rebinding-protected) instead of forwarding upstream and waiting on a response that never comes.

After `systemctl restart pihole-FTL` (note: pi-hole v6 dropped `pihole restartdns`):

```bash
$ dig @192.168.1.12 anything.cluster.local.okd.sudops.pl
;; ->>HEADER<<- opcode: QUERY, status: REFUSED, id: 39266
;; Query time: 5 msec
```

REFUSED in 5 ms instead of a 6 s timeout. Glibc/Go's resolver immediately moves on to step 5 (absolute query) and gets the in-cluster ServiceIP. argocd-server's Redis errors stopped within seconds, no pod restart needed.

## Lessons / things to bake in

- **Pi-hole v6 paths are different from v5.** `/etc/dnsmasq.d/` is ignored; configs live in `/etc/pihole/dnsmasq.d/`. `pihole restartdns` is gone — `systemctl restart pihole-FTL` is the equivalent. Both bit me.
- **Search-list pollution is a real production problem** when an OKD cluster runs on a domain that the LAN's recursive resolver also "knows about". `okd.sudops.pl` ends up in the pod search list because the host's resolv.conf has it; that means *every* internal lookup gets variants forwarded outside the cluster. The `local=/cluster.local/` rule is a one-time hardening that any home/lab cluster on a public-ish base domain should have on the LAN's primary resolver.
- **Diagnose by following the actual chain.** It's tempting to assume "DNS works for everyone else, so it's not DNS." The fact that `dig grafana.com` works at the upstream doesn't tell you that *every* query works there. The give-away here was the heterogeneous failure: `dig grafana.com` succeeds, `dig anything.cluster.local.okd.sudops.pl` times out — same upstream, same path, only the qname differs.
- **A pod's `NAME-AGE` mismatched against the rest of its stack is a strong signal.** If one pod is freshly rolled and the rest are 7 hours old, the freshly-rolled one has had to do everything from cold (DNS, TLS, secrets) — that's where DNS regressions reveal themselves first.

## Aftershock — node6 REFUSED by pi-hole

A few hours after the rebinding-protection fix landed, ArgoCD started failing differently:

```
Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = failed to list refs:
dial tcp: lookup github.com on 172.30.0.10:53: server misbehaving
```

`server misbehaving` is what Go's resolver reports for SERVFAIL/REFUSED. Cluster CoreDNS logs showed `i/o timeout` forwarding to `192.168.1.9` (node6's host CoreDNS) for `github.com.okd.sudops.pl` (search-list expansion).

The diagnostic that cracked it was running the same `dig @192.168.1.12 github.com` from each node:

| client                | result          | time |
|-----------------------|-----------------|------|
| laptop (192.168.1.x) | NOERROR, A      | 6 ms |
| node4 (192.168.1.7)  | NOERROR, A      | 3 ms |
| node5 (192.168.1.8)  | NOERROR, A      | 17 ms|
| node6 (192.168.1.9)  | **REFUSED**     | 2 ms |

Per-client REFUSED in 2 ms is the pi-hole v6 rate-limit signature. Default is 1000 queries/min per client; pi-hole v6 returns REFUSED (rather than the v5 silent-drop) once a client exceeds it within the rolling 60-second window.

Why only node6: smartctl-exporter, rook-ceph-mon, and at least one busy CoreDNS-on-pod replica all happened to land there, and those pods do enough cold lookups (with 4-attempt search-list expansion under `ndots:5`) to drive a single node well past 1000 q/min. The other two nodes stayed under.

Two follow-ups to bake in:
1. **Raise pi-hole's `RATE_LIMIT`** for cluster-node clients (or set it to `0/0` to disable). The cluster's lookup volume is legitimate, not an attack surface — rate-limiting it just creates the kind of opaque, intermittent failure we just hit. Best done via pi-hole web UI → Settings → All settings → DNS → Rate limit, or in `/etc/pihole/pihole.toml`.
2. **Cluster CoreDNS's i/o-timeout error is misleading here.** When pi-hole rate-limits, host CoreDNS sees no UDP response, eventually marks pi-hole unhealthy, then returns REFUSED (which Go reports as "server misbehaving"). The chain `pod → cluster CoreDNS → host CoreDNS → pi-hole` has three places that can each turn a rate-limit into a different-looking error.

## Open follow-ups

- ~~Consider switching the pi-hole Conditional Forwarding target for `okd.sudops.pl` from the home router (`192.168.1.1`) to the OKD API VIP (`192.168.1.240`).~~ **Tried this. Caused a forwarding loop and an 80 qps DNS firehose. Reverted to `192.168.1.1`. See "Aftershock — pi-hole ↔ node6 forwarding loop" below.**
- Document a "lab DNS prerequisites" section in the bootstrap docs once we have a few of these workarounds: rebinding-protection exemption for `cluster.local` plus a raised rate-limit for cluster-node clients are both invisible-until-it-bites items.

## Aftershock — pi-hole ↔ node6 forwarding loop (2026-05-01)

After the pi-hole rate-limit was lifted (so the box would stop returning REFUSED to nodes), the dashboard finally showed real query volume — and it was wild. ~80 sustained QPS at the upstream, and the "Top Permitted Domains" view was full of search-suffix-leaked names like:

```
openshift-gitops-repo-server.openshift-gitops.svc.cluster.local.okd.sudops.pl   465876
github.com.okd.sudops.pl                                                        141147
grafana.com.okd.sudops.pl                                                       116437
monitoring-plugin.openshift-monitoring.svc.cluster.local.okd.sudops.pl           23170
```

…and "Top Clients" showed **node6 at 1,121,164 queries** while node4/node5 were each at ~25,000. A 40-50× ratio between near-identical hosts is never legitimate workload imbalance.

### Root cause: pi-hole forwarding to node6's host CoreDNS, which forwards back to pi-hole

A few sessions earlier I had recommended switching pi-hole's Conditional Forwarding for `okd.sudops.pl` from the home router (`192.168.1.1`) to the OKD API VIP (`192.168.1.240`), on the theory that host CoreDNS authoritatively serves `api.okd.sudops.pl` / `*.apps.okd.sudops.pl` and would be a more useful answer source for LAN clients.

That recommendation was wrong, in a way that's worth dissecting because the failure mode isn't obvious from either side in isolation:

1. `192.168.1.240` is the keepalived-managed OKD API VIP. It's pinned to whichever control-plane node is currently the leader — node6, in this cluster.
2. The thing listening on `1.240:53` is node6's host CoreDNS static pod. It is authoritative for **only** the OKD-installer-managed names (`api.okd.sudops.pl`, `api-int.okd.sudops.pl`, `*.apps.okd.sudops.pl` via wildcard).
3. For anything else — including search-list-expanded names like `github.com.okd.sudops.pl` — host CoreDNS falls through to its `forward . <upstream>` block.
4. That upstream is configured as `forward . 192.168.1.12 …` (pi-hole), per the host Corefile already documented above.

So every `*.okd.sudops.pl` query that wasn't a real cluster name became:

```
client → pi-hole → 1.240 (= node6) → pi-hole → 1.240 → pi-hole → ...
```

A two-hop A→B→A loop. Pi-hole's per-query timeout/retry behavior amplified each external lookup by 10-100× before something gave up. Pi-hole counted node6 as the source for the back-half of every loop iteration, which is why "Top Clients" showed node6 doing 40× more queries than node5 — node6 wasn't *issuing* extra queries, it was *relaying pi-hole's own queries back at pi-hole*.

This also explains why the symptom was concentrated specifically on whichever node held the API VIP. If keepalived had failed over to node4 or node5 mid-session, the "1.12M-queries client" would have shifted with it.

### Fix and confirmation

User flipped pi-hole Conditional Forwarding back to `192.168.1.1` (the home router), which simply returns NXDOMAIN for `okd.sudops.pl` queries it doesn't know about. Result: **upstream QPS dropped from 80 to 6.**

Post-revert "Top Clients" looks healthy:

```
gw.home.lab.okd.sudops.pl     609 (32.3%)
node6                         608 (32.3%)
192.168.1.61                  333 (17.7%)
node5.okd.sudops.pl           168  (8.5%)
node4.okd.sudops.pl            30  (1.6%)
node6.okd.sudops.pl            27  (1.4%)
```

node5 ≈ node6 to within a small constant. That's what nodes-doing-similar-work actually looks like.

### Lesson

**Never point a recursive resolver's conditional forwarder at a Kubernetes node that uses that same recursive resolver as upstream.** It's a textbook A→B→A loop and it's invisible until traffic volume gives it away. The "host CoreDNS will give better answers for `*.apps.okd.sudops.pl`" intuition isn't wrong on its own — but the loop risk dominates. If we ever want LAN clients to resolve cluster ingress names without `/etc/hosts`, the right answer is to add the records to whatever LAN-side resolver pi-hole *can* point at without looping (the router, or the planned technetium box), not to forward into the cluster.

## Aftershock — Argo repo-server can't fetch from GitHub (2026-04-30 ~20:45 CEST)

While shipping the Mikrotik exporter chart, ArgoCD got stuck on commit `fe5c239` and refused to pick up the next commit `6ad53ec`. The Application status condition was:

```
Failed to load target state: failed to generate manifest for source 1 of 1:
rpc error: code = Unknown desc = failed to list refs:
dial tcp: lookup github.com on 172.30.0.10:53: server misbehaving
```

Same fingerprint as before — `server misbehaving` is Go's translation of REFUSED. The rate-limit window keeps tripping because repo-server retries `git ls-remote` ~once per second, which is precisely the kind of self-feeding load that pi-hole's per-client rate-limit was designed to clamp.

`openshift-gitops-repo-server` was scheduled on **node6**, which is the same client pi-hole was REFUSING in the prior session. CoreDNS-on-node6 → pi-hole → REFUSED → repo-server's `net.LookupHost("github.com")` returns "server misbehaving" → Argo can't render manifests for any Helm-source app, not just Mikrotik.

Not fixed in-session per the planned pi-hole → technetium migration (don't pile workarounds onto the box that's going away). The acute symptom self-clears when the rate-limit window resets *and* the retry pressure drops — but with repo-server retrying every second on a permanent error, that doesn't happen until something breaks the loop (operator pod move, repo-server restart, pi-hole restart, or the migration). Recording it here so the same wake-up call doesn't have to happen a third time.
