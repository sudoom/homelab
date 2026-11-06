# TrueNAS apps by name over HTTPS — working notes

The apps on the TrueNAS box (paperless, syncthing, garage and the TrueNAS UI itself) are reached today by IP and port, over plain HTTP, and garage's S3 endpoint is the same. The goal is a name and a valid Let's Encrypt certificate for each: a Traefik reverse proxy on the box terminates TLS with a DNS-01 wildcard, and the home DNS (Technitium, Ansible-managed, outside the cluster) points the names at it. These notes follow the work in order, starting with the DNS names.

## 2026-11-06 — names for the TrueNAS apps in Technitium

**What changed.** Seven records were added to `homelab_records` in `ansible/technitium/group_vars/all.yml`, all in the `homelab.sudops.pl` zone and all `192.168.1.25` (the TrueNAS box): `paperless`, `syncthing`, `garage`, `s3`, `*.s3`, `truenas`, `traefik`. `nas` (Synology, `.2`) and `dns` are unchanged. The wildcard `*.s3` is for S3 virtual-host style bucket names (`loki.s3`, `velero.s3`). It is quoted in YAML because a bare `*` is an alias indicator and would not parse.

**Why the task changed too.** The "Add/update homelab.sudops.pl A records" task only checked HTTP 200. Technitium answers HTTP 200 with `"status": "error"` in the JSON body when it rejects a record, so a bad record would have been reported as converged. The task now has `return_content: true`, a `register`, and `failed_when: _homelab_record_r.status != 200 or (_homelab_record_r.json.status | default('')) != "ok"`, the same shape as the zone-create task (which was fixed for the same reason earlier). `overwrite: "true"` and TTL 3600 are kept, so re-runs stay idempotent.

**Verification (workstation, no vault, nothing run against the DNS hosts).** The playbook itself needs the vault, so the vars were parsed with Ansible and the tasks file syntax-checked through a throwaway play outside the repo (`base-only.yml` runs only the `base` role):

```
ansible -i localhost, -c local localhost -m ansible.builtin.debug -a 'var=homelab_records' -e @ansible/technitium/group_vars/all.yml
  -> nine entries: nas, dns, paperless, syncthing, garage, s3, *.s3, truenas, traefik; "*.s3" is a string
ansible-playbook -i localhost, -c local <scratch>/t1.yml --syntax-check     # import_tasks of the role's tasks/main.yml
  -> playbook: <scratch>/t1.yml   (no errors)
```

Both ansible runs needed `ANSIBLE_LOCAL_TEMP`/`ANSIBLE_HOME` pointed at a writable directory, and the ad-hoc `debug` run needs a local RPC socket, which the Bash sandbox refuses.

**Next.** The operator runs `ansible-playbook -i inventory.yml playbook.yml --ask-vault-pass --limit dns-master`; the slave gets the records by zone transfer. Then `dig +short @192.168.1.12 truenas.homelab.sudops.pl` and the same on `.13` for each name, plus `nas.homelab.sudops.pl` still `192.168.1.2`.

## 2026-11-06 — the TrueNAS UI moves to 8080/8443

**What and why.** Traefik will own 80/443 on the TrueNAS box, so the web UI has to leave them. `ansible/truenas/group_vars/all.yml` gets `truenas_ui_ports: {http: 8080, https: 8443}`; the `truenas-system` role reads `system.general.config` (now `no_log: true`, the object can carry the UI certificate's key), derives a fact with only `ui_port`, `ui_httpsport`, `ui_httpsredirect`, and when the live ports differ from the target it calls `system.general.update` with just the two port fields, then `system.general.ui_restart`, then `wait_for` 8443 started and 443 stopped (60 s each; the restart is asynchronous, and Traefik binds 443 later in the same run). The playbook connects over SSH, so restarting the UI does not cut its own connection. The Homepage links change in the same step, because `https://192.168.1.25` stops being the UI at run #1.

**Method facts** (`midclt call core.get_methods`, TrueNAS 25.10.7, read by the controller the same day):

```
system.general.update      job=False   -> plain midclt call (trap 1 checked, no --job)
system.general.ui_restart  job=False, optional `delay` argument
port.in_use                not present on this release
app.used_ports             job=False
```

Without `port.in_use`, the pre-check asserts that 8080 and 8443 are in neither the `app.used_ports` result nor the live UI ports (the UI's own current ports are excluded when they already equal the targets), and fails with the sorted list.

**Verification (workstation, nothing run against the box).**

```
cd ansible/truenas && ansible-playbook -i inventory.yml playbook.yml --syntax-check
  -> playbook: playbook.yml
```

The new Jinja was run in a throwaway local play with a fake config (`ui_port 80`, `ui_httpsport 443`, an extra certificate field): the derived fact held exactly `ui_httpsport 443, ui_httpsredirect false, ui_port 80`, and `_taken` came out as the app ports plus 80 and 443. Homepage chart: `helm lint` clean, `helm template` renders the four links below in the `homepage` ConfigMap, kubeconform `-strict` with the datree CRD catalog: 9 resources, 8 valid, 1 skipped (the SealedSecret has no schema), 0 invalid.

```
TrueNAS:   https://192.168.1.25            -> https://truenas.homelab.sudops.pl
Syncthing: http://192.168.1.25:8384        -> https://syncthing.homelab.sudops.pl
new:       Paperless https://paperless.homelab.sudops.pl, Garage https://garage.homelab.sudops.pl
```

**Next.** Playbook run #1 (after Task 4): `https://192.168.1.25:8443` (self-signed warning) and `http://192.168.1.25:8080` open; `midclt call system.general.config | jq '{ui_port, ui_httpsport}'` reads 8080 and 8443. The Homepage links are pushed right after, with the staging-certificate warning accepted until the production cert lands.

Applied the same evening (operator run of `ansible/technitium/playbook.yml`: `dns-master ok=49 changed=2`,
`dns-slave ok=37 changed=1`, `failed=0`). Both servers answer for every name, the slave by zone transfer:

```
$ for s in 192.168.1.12 192.168.1.13; do for n in truenas paperless syncthing garage s3 traefik loki.s3 velero.s3 nas; do dig +short @$s $n.homelab.sudops.pl A; done; done
192.168.1.25   (× 8 names, both servers; loki.s3 and velero.s3 through the *.s3 wildcard)
192.168.1.2    (nas, unchanged)
```

## 2026-11-06 — the Traefik app (staging certificate)

**What changed.** `ansible/truenas` now declares the community-train catalog app `traefik` (catalog 1.0.38, Traefik v3.7.17) and the file it routes from. Three datasets in `truenas_datasets`: `apps/traefik`, `apps/traefik/config` (owner 950, `truenas_admin`, so Ansible writes the routing file without `become`, the `monitoring/bin` precedent) and `apps/traefik/acme` (owner 568, the uid Traefik runs as). In `group_vars/all.yml`: `truenas_traefik` (the inputs), top-level `truenas_traefik_acme_resolver: lestaging`, and three computed variables the role sends as they are: `truenas_traefik_additional_args`, `truenas_traefik_app_values` (everything except the token) and `truenas_traefik_dashboard_enabled` (a boolean from the vault line). The role section in `truenas-apps` comes after paperless: assert the resolver is `lestaging` or `le`, write `/mnt/tank/apps/traefik/config/homelab.yml` from `templates/traefik-homelab.yml.j2` (0644, `no_log`), create the app only when the vault holds the Cloudflare token, otherwise warn on every run; on an existing app, compare a signature against `app.config` and send `app.update` with the whole declared values on drift. Two new vault variables in `vars/vault.yml.example`: `truenas_traefik_cf_dns_api_token` (a new Cloudflare token, Zone:Read + DNS:Edit on `sudops.pl`) and `truenas_traefik_dashboard_users` (one `htpasswd -nbB admin '<password>'` line).

**The args Traefik gets** (flag without `--`, all lowercase), as the render test prints them for the staging resolver:

```
log.level=INFO
providers.docker.exposedbydefault=false
entrypoints.web.http.redirections.entrypoint.to=websecure
entrypoints.web.http.redirections.entrypoint.scheme=https
entrypoints.websecure.http.tls=true
entrypoints.websecure.http.tls.certresolver=lestaging
entrypoints.websecure.http.tls.domains[0].main=*.homelab.sudops.pl
entrypoints.websecure.http.tls.domains[0].sans=*.s3.homelab.sudops.pl
entrypoints.websecure.transport.respondingtimeouts.readtimeout=300s
certificatesresolvers.lestaging.acme.email=<the ClusterIssuer's address>
certificatesresolvers.lestaging.acme.dnschallenge.provider=cloudflare
certificatesresolvers.lestaging.acme.dnschallenge.resolvers=1.1.1.1:53,8.8.8.8:53
certificatesresolvers.lestaging.acme.caserver=https://acme-staging-v02.api.letsencrypt.org/directory
```

Only the active resolver is declared. With `le` the last line goes and the other three name `le`. A resolver left defined but unused would keep renewing its stored certificate.

**The routing file** has one router and one service per name on `websecure`, no `tls` key on any router (the entry point's `http.tls` gives each one the wildcard by SNI), `passHostHeader` at its default, and one serversTransport, `truenas-selfsigned` with `insecureSkipVerify: true`, used only by the `truenas` service (`https://192.168.1.25:8443`). The `s3` rule is `Host(`s3.homelab.sudops.pl`) || HostRegexp(`^[a-z0-9-]+\.s3\.homelab\.sudops\.pl$`)`, a single-quoted YAML scalar so the backslashes stay literal. The `dashboard` router (`api@internal`, middleware `dashboard-auth` with the vault's htpasswd line) is rendered only when that vault variable is set and is not `CHANGEME`.

**What I checked against the catalog sources** (local copies of `traefik` 1.0.38 and ix library 2.3.18, fetched the same day):

- `templates/docker-compose.yaml` line 9, `c1.add_docker_socket()`, and library `container.py` lines 295-297 (it adds group 999 and mounts `/var/run/docker.sock`); `app.yaml` lines 9-11 list the socket under `host_mounts`. Line 19 hard-codes `--providers.docker=true`. Neither can be switched off through values, so the socket is an accepted cost and `providers.docker.exposedbydefault=false` keeps container labels from creating routes.
- Line 56: each flag is `lstrip("-")|lower`, so flags go in lowercase, otherwise `app.config` would keep a spelling the signature never matches. Line 58: `=` in a flag fails the render. Line 59: the flag must not be in `consts.reserved_flags` (`ix_values.yaml` lines 17-27: `ping`, `ping.entrypoint`, `entrypoints.ping.address`, `providers.docker`, `providers.file.watch`, `providers.file.directory`, `api.basepath`, `api.insecure`, `api.dashboard`, `entrypoints.traefik.address`).
- Lines 62-73 and 100-102: any `certificatesresolvers.<r>.*` flag registers `<r>`, `.acme.storage` fails, and the template appends `--certificatesresolvers.<r>.acme.storage=/acme/<r>-acme.json` (`consts.acme_base_path: /acme`, `acme_file_suffix: acme.json`, `ix_values.yaml` lines 13-14).
- Lines 76-94: an `entrypoints.<name>.*` flag must name an entry point from the network section (or `ping`/`traefik`), `.address` fails, and http3 flags need the entry point's http3 option. Line 43 sets `--entrypoints.<name>.address=:<port>/<protocol>`, line 45 publishes the port.
- Line 96: `--flag=value`, or `--flag` alone when the value is empty, so `entrypoints.websecure.http.tls` carries the value `true`.
- Line 106 `c1.add_port(values.network.api_port)` and line 124 `tpl.portals.add(...)`: `container.py` lines 258-261 return without a port when `bind_mode` is `""`, and `portals.py` lines 20-22 skip anything not `published`. The API entry point still listens inside the container on 30384 (line 28), unreachable from outside.
- Lines 109-112: `config` at `/file-configs` (`consts.config_dir_path`) and `acme` at `/acme`, each passed to the permissions container; `deps_perms.py` lines 55-61 return `None` for a `host_path` without `auto_permissions`, so the dataset owners above are what the container sees.
- `container.py` line 268: an empty `host_ips` becomes `["0.0.0.0", "::"]`, both families on 80 and 443.
- `questions.yaml`: `api_insecure` defaults to true (lines 31-39) and is sent as false; `additional_args` items are `flag`/`value` strings (46-68), `additional_envs` `name`/`value` (69-88); `run_as` minimum 568 (95-110); `api_port.bind_mode` enum includes `""` (123-141), `port_number` default 30384 (142-149); entry point fields `entrypoint_name`, `bind_mode`, `port_number`, `protocol`, `http3`, `host_ips` (165-245); `storage.config` and `storage.acme` are `host_path` or `ix_volume` (348-503); `resources.limits.cpus`/`memory` (696-720).

Traefik's v3.7 option reference (doc.traefik.io, configuration options) lists every flag above; `entrypoints.<name>.transport.respondingtimeouts.readtimeout` defaults to 60 there, which is why it is set to 300s, and `providers.docker.exposedbydefault` defaults to true.

**Test first.** `ansible/truenas/tests/traefik-render.yml` loads `group_vars/all.yml`, renders the role's template with `lookup('ansible.builtin.template')`, parses the role's task list with `from_yaml`, and asserts the flags against the reserved list, the resolver switch, the ports, the routers and backends, and `no_log` on every task that references the token, the htpasswd variable, the routing template, the values fact, the traefik `app.config` read or the job records (their arguments carry the payload). Before any implementation:

```
$ ansible-playbook -i localhost, -c local tests/traefik-render.yml -e truenas_traefik_cf_dns_api_token=dummy -e "truenas_traefik_dashboard_users='admin:\$2y\$05\$dummy'"
fatal: [localhost]: FAILED! => {"changed": false, "msg": "Task failed: Finalization of task args for 'ansible.builtin.set_fact' failed: Error while resolving value for '_args': 'truenas_traefik_additional_args' is undefined"}
localhost : ok=0 changed=0 unreachable=0 failed=1
```

After:

```
default (lestaging, dashboard users)   ok=21 changed=0 failed=0
-e truenas_traefik_acme_resolver=le    ok=21 changed=0 failed=0   (certresolver=le, three certificatesresolvers.le.* flags, no caserver)
without the dashboard users            ok=21 changed=0 failed=0   (routers: paperless, syncthing, garage, s3, truenas)
dashboard users = CHANGEME             ok=21 changed=0 failed=0   (dashboard false)
tests/paperless-render.yml             ok=8  changed=0 failed=0   (also with -e truenas_paperless_ai_enabled=true)
ansible-playbook -i inventory.yml playbook.yml --syntax-check   -> playbook: playbook.yml
```

To see that the assertions can fail, I ran the test against twelve broken copies of the files in a scratch directory. Each one failed, at the assertion meant for it: `no_log` dropped from the `app.config` read or from a job-record read, read timeout 60s, the s3 router without `HostRegexp`, a router with `tls: {}`, the reserved flag `api.insecure`, `exposedbydefault` dropped, the API port published, the token inside the group_vars values, the syncthing route on the sync port, the `truenas` backend without its transport, and the staging CA kept with `le`.

**The role logic, against a fake `midclt`.** I extracted the Traefik section into a scratch play with a shell `midclt` that logs its arguments and answers `app.config` from a file. With `-v` the token and htpasswd strings (marker values) appeared 0 times in any output, and 0 times with `-vvv --diff` on a changed routing file.

```
absent, token + users          -> app.create sent; payload: envs [CF_DNS_API_TOKEN], api_port {bind_mode: '', port_number: 30384, host_ips: []},
                                  entry points web 80 / websecure 443 published tcp, run_as 568:568, limits 1 CPU / 512 MB, 13 args
present, live == declared      -> app.config read, no update, changed=0   (live had extra schema keys and no api_port.host_ips)
present, live args reordered   -> no update
present, live readtimeout 60s  -> app.update with TZ, network, resources, run_as, storage, traefik
present, live has another token, or live cpus 2 -> app.update
present, declared le           -> app.update
present, no token              -> "traefik NOT UPDATED: the Cloudflare DNS token is missing ...", no midclt call
absent, token CHANGEME         -> "traefik NOT CREATED: ...", routing file still written, no dashboard router
create fails / update fails    -> "traefik app.create failed: [EINVAL] boom" / "traefik app.update failed: [EINVAL] boom" (from core.get_jobs)
resolver typo (lestagin)       -> assert fails before anything else runs
```

**Not done here.** I did not run `check.yml` or `playbook.yml`: both connect to the box, and the playbook needs the operator's vault. The catalog version is the `app.yaml` of the local copy (1.0.38), not a fresh `catalog.get_app_details` read, so it has to be checked again just before run #1.

**Next.** Task 4 (garage `root_domain` for virtual-host buckets), then playbook run #1: the UI ports, the three datasets, the routing file, the traefik create with the staging resolver, and the garage update in one run.

## 2026-11-06 — garage answers virtual-host S3 requests

Loki talks to garage in virtual-host style (`<bucket>.s3.homelab.sudops.pl`), Velero in path style. garage serves virtual-host style only when `s3_api.root_domain` is set, and then serves both. The catalog garage app takes arbitrary garage.toml keys through `additional_options` (`{type, path, value}`, path matching `^\..+$`), which its config container writes into garage.toml on every start. The create task sent none, so the live config carries the catalog default `{string, .s3_web.root_domain, ""}`.

Declared (`truenas_garage.additional_options` in `group_vars/all.yml`): that default plus `{string, .s3_api.root_domain, ".s3.homelab.sudops.pl"}` (leading dot, as garage's reference manual shows). `s3.homelab.sudops.pl` itself does not end in `.s3.homelab.sudops.pl`, so it stays path style, as does `192.168.1.25:30188` (Host does not match).

Role: new task "Reconcile the garage s3 root domain" after the port-binding reconcile. It compares the live `garage.additional_options` and the declared list as sorted `path=value` pairs and, on drift, calls `app.update` with the whole live `garage` dict combined with the declared list: `app.update` replaces a sent top-level key whole, and the live dict carries `admin_token`, `rpc_secret` and `web_ui_password`, which must survive. All tasks that read or send the config are `no_log`; a failure reason comes from `core.get_jobs`. The update restarts garage, so Velero and Loki see seconds of S3 errors and retry.

Test first, `tests/garage-render.yml` (declared list, `no_log` on every garage config task, the reconcile exists):

```
ansible-playbook -i localhost, -c local tests/garage-render.yml
  -> fatal: object of type 'dict' has no attribute 'additional_options'      (before)
  -> All assertions passed, ok=5 failed=0                                    (after)
ansible-playbook -i inventory.yml playbook.yml --syntax-check   -> playbook: playbook.yml
```

The drift expression, run against a fake live dict holding only the default: have `[.s3_web.root_domain=]`, want `[.s3_api.root_domain=.s3.homelab.sudops.pl, .s3_web.root_domain=]`, differs. Not run against the box; that is playbook run #1.

## 2026-11-06 — production certificate and paperless on its name

Run #1 proved the staging order, so the committed resolver moves to `le` (`truenas_traefik_acme_resolver` in `group_vars/all.yml`). The staging account and `lestaging-acme.json` stay on disk, unused.

Observed after run #1: logging in to paperless through `https://paperless.homelab.sudops.pl` failed with `403 CSRF verification failed`. `PAPERLESS_URL` was still `http://192.168.1.25:30070`, and Django sees plain HTTP from Traefik, so the Origin (`https://…`) never matched. Fix: `PAPERLESS_URL=https://paperless.homelab.sudops.pl` plus the new env `PAPERLESS_PROXY_SSL_HEADER='["HTTP_X_FORWARDED_PROTO", "https"]'` (a YAML string, single-quoted). The plain `http://192.168.1.25:30070` keeps working: Django's same-origin check passes when the Origin matches the request host. `bin/paperless-costs` `DEFAULT_URL` now points at the name (`bin/test_paperless_costs.py` does not assert the URL).

`tests/traefik-render.yml` now asserts the committed default (read from the group_vars file, so a `-e` override cannot mask it) is `le`; the staging run still checks the `caserver` flag.

```
ansible-playbook -i localhost, -c local tests/traefik-render.yml -e …dummy…                                  -> ok=21 failed=0
ansible-playbook -i localhost, -c local tests/traefik-render.yml -e …dummy… -e truenas_traefik_acme_resolver=lestaging -> ok=21 failed=0
ansible-playbook -i localhost, -c local tests/paperless-render.yml                                           -> ok=8 failed=0
ansible-playbook -i inventory.yml playbook.yml --syntax-check                                                -> playbook: playbook.yml
python3 -m unittest bin/test_paperless_costs.py                                                              -> Ran 19 tests, OK
```

Not run against the box; that is playbook run #2 (traefik args, paperless envs).

### Run #2 applied and verified (2026-11-06 23:15Z)

Operator run: `ok=89 changed=2 failed=0` (traefik app update to resolver `le`, paperless envs). Traefik's log:

```
23:15:11 INF Testing certificate renew... acmeCA=https://acme-v02.api.letsencrypt.org/directory providerName=le.acme
23:15:13 INF Register... providerName=le.acme
23:15:13 INF Obtaining bundled SAN certificate.
23:15:32 INF Validations succeeded; requesting certificates.
23:15:35 INF Server responded with a certificate.
```

The store is saved: `le-acme.json` 16,084 bytes, uid 568, mode `0600`, written 23:15:35.13 (a listing taken a few
seconds earlier caught the 3,431-byte account-only file between registration and issuance). Every name verifies
against the system trust store, no `-k`:

```
$ for n in paperless syncthing garage truenas s3 loki.s3 traefik; do printf '%-10s ' $n; curl -s -o /dev/null -w '%{http_code} %{ssl_verify_result}\n' https://$n.homelab.sudops.pl/; done
paperless  302 0
syncthing  200 0
garage     200 0
truenas    302 0
s3         403 0
loki.s3    403 0
traefik    401 0
```

`loki.s3` verifying proves the `*.s3.homelab.sudops.pl` SAN; 403 on both S3 names is garage refusing an anonymous
request, by path and by bucket host.

## 2026-11-06 — the in-cluster probe

Names that verify from the workstation say nothing about what a pod sees, and a Let's Encrypt wildcard that
silently fails to renew repeats the Synology's 2026-08-26 expiry. So a prometheus blackbox_exporter
(`components/cluster-config/homelab-tls-probe/`, image `quay.io/prometheus/blackbox-exporter:v0.29.1`) probes
all eight names from inside the cluster: seven Traefik names (`loki.s3` stands for the `*.s3` SAN) and the
Synology at `nas.homelab.sudops.pl:5001`. One module, `https_answers`: HTTP prober, 20 s, IPv4, `fail_if_not_ssl`,
200/401/403 count as answering (garage and Traefik refuse anonymous requests), redirects followed, TLS
verification on, never `insecure_skip_verify`, so a Traefik default certificate fails the probe.

The ServiceMonitor has one endpoint per target (`/probe`, `module` and `target` params, `__param_target` →
`instance`, every 2 m, 30 s timeout), generated from `values.yaml`. Three `warning` rules:
`HomelabTLSCertExpiringSoon` (`probe_ssl_earliest_cert_expiry - time() < 14 * 86400`, 1 h),
`HomelabTLSEndpointDown` (`probe_success == 0`, 15 m), `HomelabTLSProbeAbsent`
(`absent(probe_success{namespace="homelab-tls-probe"})`, 30 m). Warnings are not mailed, so
`monitoring-config` gets a route `alertname =~ HomelabTLS.*` → `Critical`.

Validation (no cluster commands):

```
$ helm lint components/cluster-config/homelab-tls-probe
1 chart(s) linted, 0 chart(s) failed
$ helm lint components/cluster-config/monitoring-config
1 chart(s) linted, 0 chart(s) failed
$ kubeconform -strict -ignore-missing-schemas -schema-location default -schema-location '<datreeio CRDs-catalog>' -summary
probe chart:       7 resources found - Valid: 7, Invalid: 0, Errors: 0, Skipped: 0
monitoring-config: 6 resources found - Valid: 5, Invalid: 0, Errors: 0, Skipped: 1
$ helm template root-app bootstrap/root-app/ -f bootstrap/root-app/values.yaml   # new Application homelab-tls-probe, wave 5
```

kubeconform needed the sandbox off (TLS to raw.githubusercontent.com failed under it). The live checks (DNS from
pods, eight probes, negative controls) follow after the push.
