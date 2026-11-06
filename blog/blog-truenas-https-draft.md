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
