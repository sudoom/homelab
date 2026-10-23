# Homepage: a start page for the lab

About fifteen web UIs now hang off `*.apps.okd.sudops.pl` plus the LAN boxes (TrueNAS, MikroTik, Technitium), and
the only index of them was the browser's bookmarks. These notes cover choosing a start page and running it on OKD
behind the cluster's own login.

## 2026-10-24 — choosing

Candidates, checked on GitHub the same day:

| | What it is | Notes |
|---|---|---|
| Homepage (`gethomepage/homepage`, 33k★, v2.7.0) | YAML-configured dashboard with service widgets | widgets for nearly everything here: Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, Transmission, Immich, Homebox, Gatus, Argo CD, Grafana, TrueNAS, MikroTik, Technitium, healthchecks.io, plus a kubernetes info widget |
| Glance (`glanceapp/glance`, 38k★, v0.8.7) | single Go binary, feed-oriented | more a personal start page (RSS, weather) than a lab dashboard |
| Homer (`bastienwirtz/homer`, 12k★) | static page from YAML | the lightest; effectively "plain HTML", nicer |
| Homarr (`homarr-labs/homarr`, v2.8.2) | drag-and-drop UI, config in a database (SQLite/PostgreSQL/MySQL), built-in auth | config not in git; nginx + Node + Redis in one container; entrypoint `chown`s `/appdata` and `/etc/nginx` then `su-exec`s, which fights restricted-v2 |
| Plain HTML / OKD ConsoleLinks | | links only; ConsoleLinks only show inside the console |

Decision: Homepage — config in git like the rest of the lab, nothing to back up. Its Kubernetes service discovery
reads Ingress, Traefik IngressRoute and Gateway API HTTPRoute (`docs/configs/kubernetes.md`), never OpenShift Routes,
so services are listed by hand in YAML. Gatus was left off the page: it has no alerting configured and mostly
duplicates the alert stack.

## 2026-10-24 — the chart

`components/apps/homepage/`, root-app entry `homepage`, wave 7, host `home.apps.okd.sudops.pl`.

- **Image** `ghcr.io/gethomepage/homepage:v2.6.0` (v2.7.0 was a day old). The image ends `USER root` with an
  entrypoint whose `PUID` defaults to 0, which skips every `chown`, so under restricted-v2's injected UID it simply
  runs Node. Writable `/app/config` (it writes `logs/` and copies missing skeleton files) is an emptyDir with each
  ConfigMap file subPath-mounted on top; `/app/.next/cache` is a second emptyDir. A `checksum/config` annotation
  rolls the pod on config changes, since subPath mounts never update.
- **Only reachable through the cluster login.** Homepage has no auth and the kubernetes widget shows cluster usage,
  so it binds `HOSTNAME=127.0.0.1` (Kubernetes sets `HOSTNAME` to the pod name, so it has to be explicit) and an
  `oauth-proxy` sidecar is the only way in: `--provider=openshift`, `--openshift-service-account=homepage` (the SA
  carries the `oauth-redirectreference` annotation pointing at the Route),
  `--openshift-sar={"namespace":"homepage","resource":"services","verb":"get"}` (cluster admins), TLS from the service
  CA (`service.beta.openshift.io/serving-cert-secret-name: homepage-tls`) and a `reencrypt` Route. Image: the payload
  image behind the `openshift/oauth-proxy:v4.4` ImageStream, pinned by digest
  (`quay.io/okd/scos-content@sha256:bd59d8b8…`), to refresh after an OKD upgrade. Probes on the app are `exec` wget
  to `127.0.0.1:3000/api/healthcheck` (the kubelet probes the pod IP, where nothing listens);
  `HOMEPAGE_ALLOWED_HOSTS` is the Route host plus `127.0.0.1:3000`.
- **Content:** links grouped Media, Keepers, Photos & inventory, Platform, Network & NAS; widgets `kubernetes`
  (cluster + nodes, via a read-only ClusterRole on namespaces/pods/nodes and `metrics.k8s.io`) and `datetime`.
  `settings` is a literal YAML block because Homepage orders groups by its `layout` map and Helm's `toYaml` sorts keys.
- **Cookie secret** for oauth-proxy sealed on the operator's side (`openssl rand -base64 32`), never printed.

Validation:

```bash
C=components/apps/homepage
helm lint $C                                   # 1 chart(s) linted, 0 chart(s) failed
helm template homepage $C -n homepage -f $C/values.yaml | kubeconform -strict -ignore-missing-schemas -summary \
  -schema-location default \
  -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json'
# Summary: 8 resources found in 1 file - Valid: 7, Invalid: 0, Errors: 0, Skipped: 1   (the Route)
```

Per-app widgets need each app's API key as a SealedSecret and are left for later, one at a time.

## 2026-10-24 — live

Synced/Healthy at 23:26Z, both containers Ready with 0 restarts under restricted-v2. The only hiccup was the usual
first-start race: `MountVolume.SetUp failed for volume "proxy-tls" : secret "homepage-tls" not found` one second
before the service CA issued it; kubelet's retry mounted it. Logs:

```
homepage:    - Local: http://127.0.0.1:3000   ✓ Ready in 0ms
oauth-proxy: OAuthProxy configured for  Client ID: system:serviceaccount:homepage:homepage
oauth-proxy: Cookie settings: name:_oauth_proxy secure(https):true httponly:true expiry:168h0m0s
oauth-proxy: HTTPS: listening on [::]:8443
```

Not yet checked: the browser login round-trip through the OpenShift OAuth server and the kubernetes widget's numbers.
