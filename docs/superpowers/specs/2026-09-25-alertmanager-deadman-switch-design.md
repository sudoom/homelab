# Alertmanager dead-man's switch — Watchdog heartbeat to healthchecks.io

Status: shipped 2026-09-25 — `1eaf6d2` (SealedSecret, flag off), `d43de9f` (route/receiver/mount,
flag on), `17952d0` + `e36ca6e` (docs). Verified live: pings arrive on schedule and a silence
produced a DOWN then UP email as designed. See `blog/blog-monitoring-foundation-draft.md`, the
"2026-09-25 — a dead-man's switch for the alert pipeline" section, for the rollout chronology and
the review-driven corrections made after this design was written.

## Why

Alert email works end to end since 2026-09-25 (a synthetic critical reached the inbox as FIRING and
RESOLVED). But Alertmanager runs in the cluster: when the cluster, Ceph or the node network under
it fails, nothing is sent, and `Watchdog` — the alert that fires continuously to prove the pipeline
is alive — is routed to a receiver with no integrations, so nobody notices the silence. Silent
gaps have run 21 h (2026-07-24) and 5 h (2026-07-30), each found by a routine status check.

Goal: an email from outside the cluster within about 20 minutes of the alert pipeline going quiet.
Constraints: cost-effective (free), and this is a homelab, not production — no code to maintain.

## Decisions (agreed 2026-09-25)

| Decision | Choice | Note |
|---|---|---|
| Approach | Hosted heartbeat, healthchecks.io free plan | Rejected: a self-hosted watcher in the house (misses whole-house outages, depends on Mailjet, needs a new privileged token — the readonly SA cannot read alerts, and a script to maintain) and folding into the planned Mac-mini analyst (not built; also in the house). The analyst stays a separate, proactive idea. |
| Plan | Hobbyist, $0 | 20 checks, 100 log entries per check; the $5 Supporter plan has the same limits. |
| Detection | Period 5 min, grace 15 min | About 20 min from the last ping to the DOWN email; rides out an Alertmanager restart or a node reboot. |
| Secret transport | New SealedSecret now | Same pattern as `alertmanager-mailjet`; moves to ESO in the same cutover step (ESO spec step 6). |

## Design

### healthchecks.io (user, in its UI)

One check, `okd-alertmanager-watchdog`: period 5 min, grace 15 min, notifications to the account's
email (the default integration; Telegram or others can be added in the UI later). It sends DOWN
when pings stop and UP when they resume.

### Alertmanager route and receiver

`components/cluster-config/monitoring-config/templates/alertmanager-config.yaml`, behind a new
`alertmanager.heartbeat.enabled` flag:

```yaml
        - receiver: "Watchdog"
          matchers: ["alertname = Watchdog"]
{{- if .Values.alertmanager.heartbeat.enabled }}
          group_interval: 1m
          repeat_interval: 5m
{{- end }}
        # (the Critical routes and the Default/Critical receivers are unchanged)
      - name: "Watchdog"
{{- if .Values.alertmanager.heartbeat.enabled }}
        webhook_configs:
          - url_file: "/etc/alertmanager/secrets/{{ .Values.alertmanager.heartbeat.credentialsSecret }}/url"
            send_resolved: false
            max_alerts: 1
{{- end }}
```

- Alertmanager is 0.29.0 (`alertmanager --version` in `alertmanager-main-0`); `url_file` and `url`
  are mutually exclusive webhook fields, so the URL is never in the rendered config.
- `repeat_interval` is checked after each `group_interval` and must be a multiple of it: 1m/5m gives
  one ping about every 5 minutes. Today the Watchdog route inherits 12 h and goes nowhere.
- The two replicas share their notification log, so normally one ping per interval; an occasional
  duplicate is harmless.
- The comment explaining why Watchdog is "deliberately sunk into a null receiver" is rewritten: it
  still never goes to email; it now feeds the heartbeat.
- The whole `alertmanager.yaml` template is already behind `alertmanager.email.enabled`; the
  heartbeat therefore also requires `email.enabled` (both are true).

What leaves the cluster: Alertmanager's webhook JSON for Watchdog — labels such as
`alertname=Watchdog`, `namespace=openshift-monitoring`, `severity=none`. No secrets. The only
sensitive value is the ping URL; anyone holding it could send false "alive" pings.

### Mount

`templates/cluster-monitoring-config.yaml` builds `alertmanagerMain.secrets` from both flags:

```yaml
{{- if or .Values.alertmanager.email.enabled .Values.alertmanager.heartbeat.enabled }}
      secrets:
{{- if .Values.alertmanager.email.enabled }}
        - {{ .Values.alertmanager.email.credentialsSecret }}
{{- end }}
{{- if .Values.alertmanager.heartbeat.enabled }}
        - {{ .Values.alertmanager.heartbeat.credentialsSecret }}
{{- end }}
{{- end }}
```

CMO mounts each listed Secret at `/etc/alertmanager/secrets/<name>/` **without `optional: true`**
(verified on the live StatefulSet: the `alertmanager-mailjet` volume has no `optional`). A listed
Secret that does not exist leaves both Alertmanager pods in `ContainerCreating` — all alerting
down. Hence the two-commit order below. Changing the list makes CMO roll both pods, one at a time.

### Secret

`openshift-monitoring/alertmanager-healthchecks`, key `url` = the full `https://hc-ping.com/<uuid>`.
Sealed by the user so the URL never appears in chat or git (`kubeseal` v0.40.0 is installed; the
committed sealing cert is valid to 2036):

```bash
read -rs HC_URL   # paste the ping URL; nothing is echoed
oc create secret generic alertmanager-healthchecks -n openshift-monitoring \
  --from-literal=url="$HC_URL" --dry-run=client -o yaml \
  | kubeseal --cert components/operators/sealed-secrets/sealed-secrets-pub.pem -o yaml \
  > components/cluster-config/monitoring-config/templates/sealed-alertmanager-healthchecks.yaml
unset HC_URL
```

`values.yaml` gains:

```yaml
  heartbeat:
    enabled: false
    credentialsSecret: alertmanager-healthchecks
```

## Rollout

1. **Commit 1 — the SealedSecret only**, flag still `false`. Verify the Secret exists with a `url`
   key (key names only, never the value).
2. **Commit 2 — `heartbeat.enabled: true`.** Before pushing: `helm lint`, `helm template`, `oc diff`,
   and a route test of the rendered `alertmanager.yaml`. `amtool` is not installed locally, so use
   the Alertmanager container's copy on stdin — read-only, it only resolves routes:

   ```bash
   helm template monitoring-config components/cluster-config/monitoring-config/ \
     | yq 'select(.kind=="Secret" and .metadata.name=="alertmanager-main").stringData."alertmanager.yaml"' > am.yaml
   oc -n openshift-monitoring exec -i alertmanager-main-0 -c alertmanager -- \
     amtool config routes test --config.file=/dev/stdin alertname=Watchdog severity=none < am.yaml
   ```

   Expected (baseline verified on today's render, 2026-09-25): `alertname=Watchdog` → `Watchdog`;
   `severity=critical` → `Critical`; `UserNamespaceJobFailed` and `CNPGWALArchiveFailingWarning`
   (warning) → `Critical`; `KubeCPUOvercommit` (warning) → `Default`. Pass labels as separate
   arguments — zsh does not word-split an unquoted variable, which silently turns
   `severity=critical namespace=x` into one label and every route test into `Default`.
   After pushing: both Alertmanager pods roll; pings start.

Rollback: `heartbeat.enabled: false` — the mount goes away and Watchdog returns to the empty
receiver. (a) Pause the check in the healthchecks.io UI first, or a DOWN email arrives about 20
minutes after the last ping — expected noise, but avoidable. (b) Deleting the SealedSecret is
optional; if done, do it in a later commit, after the mount is gone — same two-commit order as the
rollout, in reverse, so a delete never races an Alertmanager pod still expecting the mounted Secret.

## Verification

1. **Pings arrive.** The check goes from "new" to "up"; `alertmanager_notifications_total{integration="webhook"}`
   rises about every 5 minutes with `alertmanager_notifications_failed_total{integration="webhook"}`
   at 0; the email integration's counters are unchanged.
2. **The alarm fires** (the real test). The user adds a 25-minute silence on `alertname=Watchdog`
   (writing into the Alertmanager pod is user-run). Pings stop; a DOWN email from healthchecks.io
   must arrive within about 20 minutes; after the silence expires, an UP email. This also proves
   healthchecks' mail does not land in spam.

## Docs

- README TODO "Alert DELIVERY that survives an in-cluster storage brownout": rewrite as delivered,
  or remove if nothing is left.
- `monitoring-config/values.yaml` comments.
- `blog/blog-monitoring-foundation-draft.md`: a new dated section.
- ESO spec (`2026-09-24-external-secrets-bitwarden-design.md`): the 13th secret,
  `openshift-monitoring/alertmanager-healthchecks` key `url`, cut over with `alertmanager-mailjet`.
- `cluster-health` skill, alert notes: a healthchecks DOWN email means look at the cluster now;
  `Watchdog` feeds the heartbeat.

## Limits

- A DOWN email says the pipeline is silent, not why: Prometheus not evaluating, Alertmanager down,
  Alertmanager's node without internet egress (`br-ex.forwarding=0`), cluster down, house offline,
  or healthchecks.io itself failing. The last gives a false alarm; accepted for a homelab.
- It does not replace alert rules: when the cluster is up but something is wrong, the existing
  critical-alert email still carries that.

## Out of scope

- Telegram or other channels (can be added in the healthchecks UI without a repo change).
- The Mac-mini health analyst.
