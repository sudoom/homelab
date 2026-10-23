# technitium-exporter

Prometheus metrics for the Technitium DNS cluster (`dns-master` 192.168.1.12 primary,
`dns-slave` 192.168.1.13), from
[guycalledseven/technitium-dns-prometheus-exporter](https://github.com/guycalledseven/technitium-dns-prometheus-exporter)
v2.2.0 in cluster mode: one pod asks the primary for each node's stats and labels the
series `server=<node>`.

| File | What |
|---|---|
| `templates/namespace.yaml` | `technitium-exporter` ns, `openshift.io/cluster-monitoring: "false"` (user workload) |
| `templates/deployment.yaml` | ServiceAccount (no token mounted) + exporter Deployment, restricted-v2 |
| `templates/service.yaml` | headless Service `technitium-exporter`; its name is the scrape `job` |
| `templates/servicemonitor.yaml` | 60 s scrape, `instance` pinned, `pod`/`container` dropped |
| `templates/prometheusrule.yaml` | six rules adapted from the exporter's own; `TechnitiumResolutionFailing` is the DNS-down alert |
| `templates/sealed-technitium-exporter-token.yaml` | `TECHNITIUM_TOKEN`, sealed by the operator |

The dashboard is grafana.com 24555 revision 4 in `grafana-config` (bump it together with
the image tag).

**Token.** A read-only API token for the `metrics` user, created by the
`technitium-config` Ansible role and sealed by the operator: `ansible/technitium/README.md`,
"Day-2: metrics user and API token". A 401 in the pod log means the token was rotated
or revoked.
