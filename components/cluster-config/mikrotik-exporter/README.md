# mikrotik-exporter

Scrape RouterOS metrics into Prometheus via [`akpw/mktxp`](https://github.com/akpw/mktxp). The exporter talks to the RouterOS API on each configured router, polls the requested resource trees on a fixed interval, and serves Prometheus metrics on `:49090/metrics`.

## What this chart deploys

- `Namespace` `mikrotik-exporter` (opted out of platform monitoring; UWM scrapes it)
- `ConfigMap` `mikrotik-exporter-system` — `_mktxp.conf` system settings (timeouts, worker count, parallel mode)
- `Deployment` `mikrotik-exporter` — single replica, mounts the system ConfigMap and a `mktxp-config` Secret containing the per-router credentials
- `Service` + `ServiceMonitor` for Prometheus scraping (UWM picks it up automatically because the namespace label is `openshift.io/cluster-monitoring=false`)

The per-router credentials are **not** in this chart — they live in a `SealedSecret` you create out-of-band (see Prereqs below). Without that secret the Deployment will Pending on volume mount.

## Prereqs

### 1. RouterOS-side: enable the API and create a read-only user

The exporter needs the RouterOS API enabled and a dedicated read-only user. SSH into RouterOS (or use Winbox) and run:

```routeros
# Enable the API service on the management VLAN only (adjust address subnet to taste)
/ip service set api address=192.168.1.0/24 disabled=no port=8728

# Create a group with the minimum policy mktxp needs (read + api + login)
/user group add name=prometheus policy=read,api,test,winbox

# Create the user. Use a long random password — you'll seal it in step 2.
/user add name=mktxp group=prometheus password="<LONG_RANDOM_PASSWORD>" comment="prometheus / mktxp"
```

Verify with `/user print` and `/ip service print`. If the router has a firewall rule on the management interface, allow `tcp/8728` from the cluster nodes (`192.168.1.7-9`).

> mktxp also supports `api-ssl` on `tcp/8729` if you've imported a cert. The chart's example config defaults to plain `api`/`8728` to keep first-time setup simple — flip `use_ssl = True` and adjust the port once you've validated end-to-end.

### 2. Seal the per-router credentials into a `SealedSecret`

Copy the example, fill in the real password, then seal it:

```bash
# from the chart directory
cp examples/mktxp.conf.example /tmp/mktxp.conf
$EDITOR /tmp/mktxp.conf       # paste the real password into [home-router].password

# Build a regular Secret manifest (note: --from-file= keys it as 'mktxp.conf')
kubectl create secret generic mktxp-config \
  -n mikrotik-exporter \
  --from-file=mktxp.conf=/tmp/mktxp.conf \
  --dry-run=client -o yaml \
  > /tmp/mktxp-config.secret.yaml

# Seal it against the cluster's sealed-secrets controller
kubeseal --format=yaml \
  --controller-namespace=sealed-secrets \
  --controller-name=sealed-secrets \
  < /tmp/mktxp-config.secret.yaml \
  > components/cluster-config/mikrotik-exporter/templates/sealed-mktxp-config.yaml

# Wipe the plaintext copies before they end up in shell history / a backup
shred -u /tmp/mktxp.conf /tmp/mktxp-config.secret.yaml
```

Commit `templates/sealed-mktxp-config.yaml`. ArgoCD reconciles, the sealed-secrets controller decrypts it into the live `mktxp-config` Secret, and the Deployment volume mount succeeds.

### 3. Confirm the scrape

Once Argo has synced the chart:

```bash
oc -n mikrotik-exporter get pods                       # mikrotik-exporter-... 1/1 Running
oc -n mikrotik-exporter logs deploy/mikrotik-exporter  # should show 'home-router scraping...' lines

# From inside the cluster — UWM Prometheus picks it up via ServiceMonitor
# (no manual config needed because the ns has openshift.io/cluster-monitoring=false)
oc -n openshift-user-workload-monitoring exec prometheus-user-workload-0 -c prometheus -- \
  wget -qO- localhost:9090/api/v1/targets | python3 -c \
  "import json,sys; print([t['labels']['job'] for t in json.load(sys.stdin)['data']['activeTargets'] if 'mikrotik' in t['labels'].get('job','')])"
```

The Grafana dashboard (id `13679`) is provisioned by `grafana-config` and bound to the `Prometheus` datasource via the chart-level helper.

## Updating the credentials later

`kubeseal` is pinned to the cluster's controller key, so re-running steps 2 above with a new password produces a new sealed blob. Replace the file in-tree, commit, push — ArgoCD picks it up and the controller updates the live Secret. The mktxp pod re-reads its config on restart, so trigger a roll:

```bash
oc -n mikrotik-exporter rollout restart deploy/mikrotik-exporter
```
