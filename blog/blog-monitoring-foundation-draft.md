# Monitoring foundation — platform Prometheus + user-workload monitoring

Working notes on `components/cluster-config/monitoring-config/`, the chart that owns the
OpenShift monitoring stack's configuration surface: platform Prometheus retention and
storage, Alertmanager storage, and the user-workload-monitoring (UWM) enablement +
retention. It is a *configuration* chart — it does not install anything. The
cluster-monitoring-operator (CMO) reads two ConfigMaps and renders the actual
`Prometheus`/`Alertmanager` CRs from them.

This is deliberately small and deliberately load-bearing: the UWM half of it is what makes
`CNPGWALArchiveFailing` (offsite-backup detection) evaluable at all, and the platform half
is what keeps 15 days of cluster history on Ceph RBD.

---

## 2026-08-06 — `retentionSize`: bounding the TSDB by disk, not just by age

### How it surfaced

Routine session-start alert triage. 15 alerts firing, zero critical — but one was not on
the known-benign list:

```
KubePersistentVolumeFillingUp   ns=openshift-monitoring   since 2026-08-06T02:40:53Z
  Based on recent sampling, the PersistentVolume claimed by
  prometheus-k8s-db-prometheus-k8s-1 in Namespace openshift-monitoring is expected to
  fill up within four days. Currently 10.66% is available.
```

First read of the filesystem, via the prometheus container:

```
$ oc -n openshift-monitoring exec prometheus-k8s-1 -c prometheus -- df -h /prometheus
Filesystem      Size  Used Avail Use% Mounted on
/dev/rbd0        49G   44G  5.3G  90% /prometheus

$ oc -n openshift-monitoring exec prometheus-k8s-0 -c prometheus -- df -h /prometheus
/dev/rbd10       49G   40G  9.7G  81% /prometheus
```

The obvious question was whether this was still ramping toward steady state or already at
it. Oldest block settles that:

```
$ oc -n openshift-monitoring exec prometheus-k8s-1 -c prometheus -- \
    sh -c 'ls -1dt /prometheus/01* | tail -1 | xargs stat -c "%y %n"'
2026-07-22 17:05:03.126747479 +0000 /prometheus/01KY5CG5QBTNK8QP7GFWY2DXDK
```

2026-07-22 → 2026-08-06 is exactly 15 days. Time retention is already pruning. So this is
**not** a fill trajectory — 15 days of current ingest simply *is* ~41 GiB on a 49 GiB
volume, and the only thing that moves it is series growth.

### The measurement that changed the framing

A second read ~30 minutes later disagreed with the first, which was the interesting part:

```
$ oc -n openshift-monitoring exec prometheus-k8s-1 -c prometheus -- \
    sh -c 'df -B1 /prometheus | tail -1; stat -f -c "blocks=%b free=%f avail=%a bsize=%S" /prometheus'
/dev/rbd0      52521566208  44298727424  8206061568  85% /prometheus
blocks=12822648 free=2007529 avail=2003433 bsize=4096
```

- capacity 52,521,566,208 B = **48.91 GiB**
- used 44,298,727,424 B = **41.26 GiB**
- available 8,206,061,568 B = **7.64 GiB**
- `free` (7.66 GiB) ≈ `avail` (7.64 GiB) → **no meaningful ext4 root reserve** to subtract

So 90% at 13:00 and 85% at 13:30 were *both* real: the filesystem swings roughly 3 GiB
across a compaction cycle. Prometheus writes the compacted block *before* dropping its
sources, so peak usage transiently exceeds steady-state by about the size of the largest
block being written.

Prometheus's own accounting, which is what `retention.size` actually measures:

```
$ ... query 'prometheus_tsdb_storage_blocks_bytes{job="prometheus-k8s"}'
prometheus-k8s-1  blocks = 40.28 GiB
prometheus-k8s-0  blocks = 38.37 GiB
$ ... du -sh /prometheus/wal /prometheus/chunks_head
1.5G  /prometheus/wal
344M  /prometheus/chunks_head
```

The real risk was never "it fills in four days". It is that a **7.6 GiB headroom absorbing
a ~3–4 GiB periodic swing** has no floor under it as series count grows. ENOSPC on a
Prometheus TSDB stops ingestion and can corrupt the WAL.

### Why not just grow the PVC

That was the previous reflex — `1d9bd22` bumped these from 30Gi to 50Gi on 2026-05-13.
It is the wrong lever now:

```
$ ceph df
--- POOLS ---
POOL              ID  PGS   STORED  OBJECTS     USED  %USED  MAX AVAIL
nvme-replicated    1  128  282 GiB   91.33k  819 GiB  60.49    178 GiB
```

`nvme-replicated` is at 60% with 178 GiB MAX AVAIL, and at `size=3` every +1 GiB of PVC
costs 3 GiB raw. Taking both replicas 50 → 75 Gi is +50 GiB stored = **+150 GiB raw**,
i.e. most of the remaining headroom on the tier that also backs every RBD workload on the
cluster. Growing the volume converts a bounded monitoring problem into an unbounded
storage-tier problem.

### The fix

`retention` bounds the TSDB by **age**; it says nothing about bytes. Prometheus also
supports a size bound, and prunes on whichever limit trips first. CMO exposes it:

```yaml
# components/cluster-config/monitoring-config/values.yaml
prometheus:
  retention: 15d
  retentionSize: 38GiB
  volumeSize: 50Gi

userWorkload:
  retention: 15d
  retentionSize: 7GiB
  volumeSize: 10Gi
```

Note the parent-key asymmetry in the rendered ConfigMaps — same field name, different
parent: platform is `prometheusK8s.retentionSize`, UWM is `prometheus.retentionSize`.

### Verification before shipping — what the review caught

This went through an adversarial review pass before commit, and three of the original
premises did not survive:

1. **"90% full and filling"** — wrong, or rather half-right. 84–85% at rest, 90% at a
   compaction peak. The change is a guardrail against series growth, not an emergency.
   Shipping it under an urgency framing would have been a lie in the commit message.
2. **"rolling restart of the 2 prometheus-k8s pods"** — understated by 2×. Capping UWM as
   well means `prometheus-user-workload` also re-renders its args, so the real blast radius
   is **4 pods across 2 StatefulSets**. UWM is where `CNPGWALArchiveFailing` evaluates —
   the sole offsite-backup guard — so that is worth knowing before syncing, even though a
   StatefulSet RollingUpdate takes them one at a time and one replica always keeps
   evaluating.
3. **Sizing derived from the inflated number.** Against the real 41.26 GiB, a 38GiB cap
   drops roughly 3 GiB of oldest blocks on the first reload — about 1.1 days of history —
   not the ~6 GiB implied by the bad premise.

Two footguns worth recording:

- **`38Gi` fails; it must be `38GiB`.** The Prometheus CRD validates this as a ByteSize:
  ```
  $ oc get crd prometheuses.monitoring.coreos.com -o jsonpath='...retentionSize}'
  {"pattern":"(^0|([0-9]*[.])?[0-9]+((K|M|G|T|E|P)i?)?B)$", ...}
  ```
  A trailing `B` is mandatory. This is nastier than a key typo because `volumeSize: 50Gi`
  sits two lines away in the same file and *is* a plain Kubernetes quantity — the natural
  mistake is to match it. A bad **key** fails loudly (CMO parses with `UnmarshalStrict`,
  so an unknown key rejects the entire config and degrades the `monitoring`
  ClusterOperator). A bad **unit** sails through the ConfigMap and only dies later at
  Prometheus-CR admission inside CMO's reconcile loop — a much muddier signal.
- **The `volumeClaimTemplate` is the thing not to disturb.** CMO delete/recreates the
  StatefulSet only on a 422 `Invalid` (an immutable field, i.e. a VCT change); an
  args-only change is a legal update → plain RollingUpdate. And per
  `blog/blog-multus-ceph-migration-draft.md`, when this ConfigMap *vanished* entirely, CMO
  re-rendered the StatefulSets without a VCT at all and auto-deleted the PVCs. The `oc
  diff` below exists specifically to prove the VCT is untouched.

### Sizing rationale

- Volume 48.91 GiB usable, no root reserve.
- Upstream guidance: set retention size to at most 80–85% of allocated disk.
- `38GiB` = **77.7%** — deliberately just under the band, because the compaction transient
  is *not* counted against the cap. Worst-case compacted block spans ~10% of the retention
  window (~36 h ≈ 4.1 GiB at the observed 2.75 GiB/day density), so peak on-disk lands near
  42 GiB = 86% of the volume, leaving ~6.8 GiB.
- Effective retention becomes ~13 d instead of 15 d.
- UWM: `7GiB` of a 9.75 GiB volume = 71.8%, deliberately looser in ratio than the platform
  cap because 1 GiB of *absolute* headroom on a small volume is worth more than a
  percentage point of retention. UWM is at 0.18 GiB today, so this never binds at current
  volume — it is insurance against per-namespace exporter growth.

Residual, recorded honestly: at a compaction peak this leaves ~13.9% available, and
`KubePersistentVolumeFillingUp` warns below 15%. The rule also requires a negative
`predict_linear` trend, which a bounded steady state should not produce — but if it does
keep tripping at peaks, the answer is `36GiB` (~12.4 d), **not** a bigger PVC.

### Validation

```bash
helm lint components/cluster-config/monitoring-config/
helm template monitoring-config components/cluster-config/monitoring-config/ \
  -f components/cluster-config/monitoring-config/values.yaml
helm template monitoring-config components/cluster-config/monitoring-config/ | \
  kubeconform -strict -ignore-missing-schemas -schema-location default \
    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
helm template monitoring-config components/cluster-config/monitoring-config/ | oc diff -f -
```

`oc diff` is a server-side dry-run apply, so it needs patch/update — the readonly SA
(`claude-reader`) returns `no` for `oc auth can-i patch configmap -n openshift-monitoring`
and the diff fails. Run it with the operator kubeconfig. Do not `|| true` it: that step is
the only guard on the volumeClaimTemplate footgun above.

The diff was exactly the two keys and nothing else:

```
     prometheusK8s:
       retention: 15d
+      retentionSize: 38GiB
       volumeClaimTemplate:
...
     prometheus:
       retention: 15d
+      retentionSize: 7GiB
       volumeClaimTemplate:
```

### Post-sync checks

- `oc -n openshift-monitoring get prometheus k8s -o jsonpath='{.spec.retentionSize}'` → `38GiB`
- STS args gain `--storage.tsdb.retention.size=38GiB` alongside the existing
  `--storage.tsdb.retention.time=15d` (the prometheus-operator emits both when both are set)
- `oc get co monitoring` stays `Available=True Degraded=False` (a bad key would degrade it)
- 4 VolumeAttachments, not just the 2 platform ones — the RWO RBD PVs re-attach if a pod
  lands on a different node, which on this cluster is the documented stuck-VA path
- **Freed blocks do not return to the Ceph pool.** `ceph-nvme-block` has no `discard`
  mountOption, so the ~3 GiB pruned frees filesystem space but leaves the RBD allocation
  until the weekly `node-fstrim` DaemonSet pass. Expect no `ceph df` movement; do not chase it.

Not a degraded-window event — 4 pods replaying WAL off RBD. Safe any time, just not
concurrent with OSD-impacting work on the no-drain topology.

### Open

- Nothing reports that the retention *window* has silently shrunk below 15 d once the size
  cap starts binding. `prometheus_tsdb_lowest_timestamp` is the metric; no rule watches it.
- The UWM volume will start receiving nmstate metrics once the RoleBinding fix in
  `components/operators/nmstate/` lands (see `blog/blog-multus-ceph-migration-draft.md`),
  which is the first real growth this TSDB has seen in a while.

## 2026-09-16/17 — both platform Prometheus replicas panicked within a minute: client-cert rotation

Found on the 09-17 session-start sweep. Everything else was clean; the restart-recency check
returned exactly two containers:

```
openshift-monitoring/prometheus-k8s-0 prometheus exit=2 at=2026-09-16T15:12:33Z n=1
openshift-monitoring/prometheus-k8s-1 prometheus exit=2 at=2026-09-16T15:11:40Z n=1
```

Exit 2 is a Go panic, not an OOM (137). Two replicas on two nodes dying 53 s apart is a shared
input, not a node problem. `oc -n openshift-monitoring logs prometheus-k8s-0 -c prometheus --previous`:

```
panic: runtime error: invalid memory address or nil pointer dereference
[signal SIGSEGV: segmentation violation code=0x1 addr=0x18 pc=0x98ed5f]
github.com/prometheus/common/config.(*tlsRoundTripper).RoundTrip(...)
	vendor/github.com/prometheus/common/config/http_config.go:1386 +0x4ff
...
github.com/prometheus/prometheus/scrape.(*targetScraper).scrape(...)
```

`tlsRoundTripper` is the transport that re-reads CA/cert/key files and rebuilds itself when their
hash changes, so the question is which mounted file changed just before 15:11. `oc get -o json`
strips `managedFields` unless asked, which made my first two searches return nothing:

```bash
for k in secret cm; do oc get $k -A --show-managed-fields -o json | jq -r --arg k $k \
  '.items[] | . as $s | ([.metadata.managedFields[]?.time] | max) as $t
   | select($t >= "2026-09-16T14:30:00Z" and $t <= "2026-09-16T15:13:00Z")
   | "\($t) \($k) \($s.metadata.namespace)/\($s.metadata.name)"'; done
...
2026-09-16T15:11:13Z secret openshift-monitoring/metrics-client-certs
```

and the certificate inside it (public half only) was issued that minute:

```
subject=CN=system:serviceaccount:openshift-monitoring:prometheus-k8s
notBefore=Sep 16 15:06:13 2026 GMT      # 5-minute backdate => issued 15:11:13
notAfter=Oct  6 13:32:15 2026 GMT
```

So: CMO rotated the mTLS client certificate Prometheus scrapes with, the kubelet synced the new
files into each pod within its own resync period (hence 27 s and 80 s after the write, not
simultaneous), and the first scrape to notice the new hash hit a nil pointer in the reload path
of Prometheus 3.7.3's vendored `prometheus/common`. Each replica restarted once, replayed its WAL
and has been up since. Nothing in the repo touches any of this; it is payload behaviour.

What it cost: both replicas were down together for part of a minute, so there is a short gap in
platform metrics around 15:12Z on 09-16 and any alert `for:` timer was reset. No data loss beyond
that, no PVC or attachment trouble on restart.

What to expect: the new certificate runs to 2026-10-06, so the next rotation is due before then
and may do the same thing. One restart per replica at a rotation is the known shape; more than
one, or a restart with no matching `metrics-client-certs` write, is something else. Not raised
upstream yet — it needs checking against the `prometheus/common` tracker first, since a reload
race in that function may already be fixed in a newer vendored version than 4.21 ships.

## 2026-09-25 — a dead-man's switch for the alert pipeline

Alert email has worked end to end since 2026-09-25 (Mailjet, `severity=critical` +
`UserNamespace*` + `CNPGWALArchiveFailing*`). That closed the two concrete silent gaps from this
year that were delivery-path failures, not the pipeline being down: 21 h on 2026-07-24 and 5 h on
2026-07-30, both cases where the `CNPGWALArchiveFailing*` rule fired the whole time and Alertmanager
itself was working — there was just no external route yet, so only a human noticing something else
was wrong caught either one (`blog/blog-cnpg-draft.md`, `blog/blog-ntp-dns-cluster-outage-draft.md`).
But Alertmanager runs *in* the cluster, and a brownout that takes the whole pipeline down — Mailjet
route included — is a different failure: the two cluster-wide `br-ex.forwarding=0` pod-egress breaks
this year, 2026-08-07 (~5 h, after the 10G switch firmware upgrade) and 2026-09-08 (~3.5 h) — during
both, Alertmanager had no outbound path to Mailjet's smarthost either, so each would have produced a
healthchecks.io DOWN email about 20 minutes in. `Watchdog`, the alert Prometheus fires continuously
to prove the pipeline is alive, was routed to a receiver with no integrations ("deliberately sunk
into a null receiver," per the old comment) — so there was no mechanism to notice the pipeline had
gone quiet, only ever a human noticing something else was wrong.

Three options considered for closing that gap, all in the spec
(`docs/superpowers/specs/2026-09-25-alertmanager-deadman-switch-design.md`):

1. A self-hosted watcher script in the house — rejected: misses whole-house outages, depends on
   the same Mailjet path being healthy, needs a new privileged token (the readonly SA can't read
   alerts), and is a script to maintain.
2. Fold it into the planned Mac-mini cluster-health analyst (README TODO, not built) — rejected
   for now: also physically in the house, so a whole-house outage takes it down too; it stays a
   separate, proactive idea rather than the dead-man's switch itself.
3. A hosted heartbeat, healthchecks.io free ("Hobbyist") plan — chosen. $0, 20 checks / 100 log
   entries (enough for one check), genuinely off-site, and the built-in period/grace model is
   exactly a dead-man's switch: ping every 5 minutes, DOWN email if no ping lands within a 15-minute
   grace window (~20 minutes from the last real ping to the email), UP email when pings resume.

### Mechanism

`components/cluster-config/monitoring-config/templates/alertmanager-config.yaml`, behind a new
`alertmanager.heartbeat.enabled` flag: the `Watchdog` route gains `group_interval: 1m` /
`repeat_interval: 5m` (today it inherits the default 12 h and goes nowhere), and the `Watchdog`
receiver gains a `webhook_configs` entry pointing `url_file` at the mounted secret. Alertmanager is
0.29.0, where `url_file` and `url` are mutually exclusive webhook fields — so the ping URL is never
in the rendered config, only a path to it. The cadence — about one POST every 5 minutes — comes
from the route's `group_interval`/`repeat_interval` and the two replicas' shared notification log;
`send_resolved: false` and `max_alerts: 1` instead guard against a resolved POST (which would
register as a false "alive" ping the moment Prometheus stops evaluating) or a burst of grouped
alerts turning into more than one. What actually leaves the cluster is Alertmanager's
webhook JSON for `Watchdog` — labels like `alertname=Watchdog`, `namespace=openshift-monitoring`,
`severity=none` — no secrets in the body; the only sensitive value is the ping URL itself, since
anyone holding it could send false "alive" pings.

The secret is `openshift-monitoring/alertmanager-healthchecks`, key `url`, same SealedSecret
pattern as `alertmanager-mailjet`, sealed by hand so the URL never touches chat or git:

```bash
read -rs HC_URL   # paste the ping URL; nothing is echoed
oc create secret generic alertmanager-healthchecks -n openshift-monitoring \
  --from-literal=url="$HC_URL" --dry-run=client -o yaml \
  | kubeseal --cert components/operators/sealed-secrets/sealed-secrets-pub.pem -o yaml \
  > components/cluster-config/monitoring-config/templates/sealed-alertmanager-healthchecks.yaml
unset HC_URL
```

**Two-commit order, and why it isn't `optional: true`.** CMO builds `alertmanagerMain.secrets` from
both the email and heartbeat flags, and mounts every listed Secret at
`/etc/alertmanager/secrets/<name>/` **without `optional: true`** — confirmed on the live
StatefulSet, the existing `alertmanager-mailjet` volume has no `optional` field either. A listed
Secret that doesn't exist yet leaves both Alertmanager pods stuck `ContainerCreating` — all
alerting down, not just the heartbeat. So commit 1 (`1eaf6d2`) shipped only the SealedSecret with
the flag still `false`, confirmed the Secret existed by key name (`url`, never the value), and only
then did commit 2 (`d43de9f`) flip `heartbeat.enabled: true` and add the mount/route/receiver
wiring. Pre-push checks on commit 2: render assertions RED (feature absent) then GREEN
(`url_file` populated, `send/max` = `false 1`, intervals `1m 5m`, both secrets listed), a
flag-off render byte-identical to the pre-change render (`git stash`-based diff), and an
`amtool config routes test` run against the rendered `alertmanager.yaml` from the Alertmanager
container's own binary (stdin, read-only):

```bash
oc -n openshift-monitoring exec -i alertmanager-main-0 -c alertmanager -- \
  amtool config routes test --config.file=/dev/stdin alertname=Watchdog severity=none < am.yaml
```

Results: `Watchdog` → `Watchdog`; `severity=critical` → `Critical`; `UserNamespaceJobFailed` and
`CNPGWALArchiveFailingWarning` (both warning-severity) → `Critical`; `KubeCPUOvercommit` (warning)
→ `Default` — routing of everything else unchanged. Commit 2 was pushed 17:53:31 UTC only after a
task review approved it.

One minor caught in review, left as-is: with `heartbeat.enabled=true` and `email.enabled=false`,
the chart lists the heartbeat secret in the mount but the `alertmanager.yaml` Secret itself is
gated on `email.enabled` and doesn't render — a harmless orphan mount for a combination this repo
doesn't actually run (both flags are true), and the values comment already states the dependency.

### Rollout and the pings

ArgoCD synced `d43de9f` by 17:57:49 UTC; `alertmanager-main-1` restarted 17:57:49, `-main-0` at
17:58:03, both back to 6/6 Ready by 17:58:20 — no `ContainerCreating`, so the `optional: true`
concern above never actually bit (the Secret was already there from commit 1). First ping seen on
the Alertmanager notification counter (30 s polling) at 17:58:21 UTC from `main-1` — healthchecks.io
flipped the check from "new" to "up", an HTTPS POST with a 1916-byte body and user agent
`Alertmanager/0.29.0`. Second ping seen on the counter at 18:03:30 UTC from `main-0`, about 5
minutes after the first — consistent with the 5-minute `repeat_interval` given jitter across two
replicas sharing a notification log and the 30 s poll granularity.
`alertmanager_notifications_failed_total{integration="webhook"}` stayed at 0 throughout, and the
Mailjet email counters were untouched by the restart.

### Proving the alarm

The real test isn't that pings arrive, it's that stopping them does something. At 18:03:54 UTC I
had a 25-minute silence added on `alertname=Watchdog` — via the break-glass kubeconfig, at my
explicit instruction even though the operator login was valid at the time (visible on both
Alertmanager replicas; `amtool silence add alertname=Watchdog --duration=25m`). Break-glass writes
land in the audit log under the break-glass service account rather than the operator's identity —
CLAUDE.md reserves break-glass for OAuth outages, so this was a deliberate one-off for the test, not
the normal path. The last ping seen on the counter was 18:03:30 UTC; healthchecks.io flipped to
DOWN at 18:23:25 UTC — inbox, not spam, "success signal did not arrive on time, grace time passed" —
which, at period(5m)+grace(15m), implies the last ping healthchecks.io actually received landed at
or just before 18:03:25 UTC. The silence expired 18:28:54; the resumed ping was seen on the counter
between 18:29:19 and 18:29:24 UTC (two 30-second-poll readings from `main-0`, taken minutes apart),
while healthchecks.io's own UP email landed 18:29:10 UTC: "downtime lasted 5 minutes, 44 seconds,"
3 pings in total (about five were suppressed by the silence).

One coincidence worth recording: an unrelated MCO rollout (node DHCP, `96d20ad`) drained and
rebooted all three nodes 18:05–18:24 during the silence window, restarting both Alertmanager pods
mid-test. The silence survived the restart — Alertmanager persists silences on its own volume and
gossips them between replicas — and the DOWN/UP timing tracked the silence window, not the reboot.
Coincidental timing, not a dependency; worth noting because it's exactly the kind of "was the
result actually caused by what I think" question this repo tries to answer with evidence rather
than a plausible-looking signal.

### What this does and doesn't cover

A DOWN email says the pipeline is silent, not why — Prometheus not evaluating, Alertmanager down,
Alertmanager's node without internet egress (`br-ex.forwarding=0`), the cluster down, the house
offline, or healthchecks.io itself. The last of those is a false alarm, accepted for a homelab.
It's not a substitute for alert rules either: when the cluster is up but something inside it is
wrong, the existing critical-alert Mailjet email still carries that — except that a green
healthchecks check only proves Watchdog reaches the webhook, not that Mailjet is actually
delivering: Mailjet has already suspended sending once this cycle (re-enabled 2026-09-21, capped at
20 emails/hour), and `AlertmanagerFailedToSendAlerts` is warning severity, so it is not itself
emailed. What the switch closes is specifically the brownout case — the cluster-wide
`br-ex.forwarding=0` pod-egress breaks (2026-08-07, 2026-09-08) during which Alertmanager has no
outbound path at all, critical or heartbeat. The 2026-07-24 and 2026-07-30 gaps were a different
failure — Alertmanager was healthy and the rule fired, there was just no external route yet — and
that gap was closed separately by the Mailjet critical-alert route shipped 2026-09-07.
