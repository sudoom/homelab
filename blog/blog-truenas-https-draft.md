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
