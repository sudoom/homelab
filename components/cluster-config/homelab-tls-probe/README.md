# homelab-tls-probe

A prometheus [blackbox_exporter](https://github.com/prometheus/blackbox_exporter) (v0.29.1) that opens
an HTTPS connection to every TrueNAS app name and to the Synology, from inside the cluster, and checks
that the name resolves, the certificate verifies against the system trust store, and the app answers.

Targets (`values.yaml`, `targets`): `paperless`, `syncthing`, `garage`, `s3`, `loki.s3` (covers the
`*.s3` SAN), `truenas` and `traefik` under `homelab.sudops.pl` (Traefik on the TrueNAS box, Let's
Encrypt wildcard), plus `https://nas.homelab.sudops.pl:5001/` (the Synology, own certificate).

**Why from inside the cluster.** The consumers of these names are pods (Loki writes to
`loki.s3.homelab.sudops.pl`), so the probe sees what they see: pod DNS through CoreDNS and the node
resolvers, the real trust store, no `-k`. A check from the workstation would pass while a pod fails.

| File | What |
|---|---|
| `templates/namespace.yaml` | `homelab-tls-probe` ns, `openshift.io/cluster-monitoring: "false"` (user workload) |
| `templates/configmap.yaml` | `blackbox.yml`: one module `https_answers` (TLS verification on, 200/401/403 count as answering, redirects followed, IPv4, 20 s) |
| `templates/deployment.yaml` | ServiceAccount (no token) + 1 replica, restricted-v2, read-only root fs, 10m/32Mi, limit 64Mi |
| `templates/service.yaml` | ClusterIP Service `homelab-tls-probe`, port `http` 9115; its name is the scrape `job` |
| `templates/servicemonitor.yaml` | one endpoint per target, `/probe`, every 2 m, `instance` = the URL |
| `templates/prometheusrule.yaml` | the three alerts below |

## Read one probe by hand

```bash
KUBECONFIG=~/.kube/config-readonly oc get --raw \
  '/api/v1/namespaces/homelab-tls-probe/services/http:homelab-tls-probe:9115/proxy/probe?module=https_answers&target=https://paperless.homelab.sudops.pl/'
```

Add `&debug=true` for the resolver, connection and certificate log. `probe_success 1` and
`probe_ssl_earliest_cert_expiry` (epoch seconds) are the two series that matter.

## Alerts

All `warning`, all mailed: `monitoring-config` has a route `alertname =~ HomelabTLS.*` to the `Critical`
receiver (warnings are not mailed otherwise).

| Alert | Fires when | First check |
|---|---|---|
| `HomelabTLSCertExpiringSoon` | earliest certificate expiry under 14 days, 1 h | Traefik log on the TrueNAS box (ACME); for the Synology, `synology-cert-sync` |
| `HomelabTLSEndpointDown` | `probe_success == 0` for 15 m | the probe with `debug=true`, then the Technitium answer, Traefik log, the backend's plain port on 192.168.1.25 |
| `HomelabTLSProbeAbsent` | no `probe_success` series for 30 m | `oc -n homelab-tls-probe get pods`, the ServiceMonitor |

A new target is one line in `values.yaml`.
