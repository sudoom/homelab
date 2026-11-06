# paperless-ngx on TrueNAS — design record and build notes

Working notes for putting the freelance paperwork (taxes, expenses, invoices, electricity and water bills) into one
filed, full-text-searchable, sortable archive, with "where does the money go" answerable per month and per category,
and plain-language questions (RAG) answered by a model that runs in the house. paperless-ngx runs as a TrueNAS SCALE
25.10 catalog app, declared in `ansible/truenas`; the cluster is not involved apart from one alert rule later.
Chronological, appended as the work happens. Everything below the design record is dated.

## Design record (approved 2026-11-05)

### What the operator decided (2026-11-05)

- Tool: paperless-ngx. Documents arrive "99% pdf via mail or downloadable via portal". Mail is Tuta, which has no
  IMAP and no automatic forwarding, so documents are dropped in by hand; no mailbox is connected.
- No drop folder: upload through the web UI from the Mac and the Mac mini. One user, from home.
- Database: not SQLite (the operator has seen it corrupt often).
- AI: Ollama on the Mac mini (M4 Pro, 64 GB) at `192.168.1.3`; RAG wanted. Polish documents, PLN.
- Models after a side-by-side test (one Polish invoice prompt, `--think=false`): generation `gemma4:26b` (44.8 tok/s,
  clean Polish; `gemma4:26b-mlx` 40.2 tok/s; `qwen3.6:35b-mlx` 72.6 tok/s but it called a VAT invoice "paragonowa" and
  gave a hedged date), embeddings `bge-m3`. Speed paperless can spare, wrong Polish it cannot.
- Cost figures are an overview, not tax filing: one amount per expense in the currency paid, no net/VAT split;
  categories as tags (children of a parent tag `Category`), sender = correspondent, type = bill, invoice, receipt or
  tax document; totals per month × category from a small script; amounts typed by hand first.
- Offsite copy unencrypted, like the photos; Synology folder `photo/backups/paperless`; existing pile about 300
  documents, no Office files.
- Hosting (my recommendation, not contradicted): a TrueNAS catalog app, not the OKD cluster, so the archive does not
  depend on the cluster being up.

### Anti-goals

- A document leaves the house for a hosted model. No hosted LLM backend is ever configured.
- SQLite anywhere.
- A backup that stops without anyone noticing (the exporter stops while the Cloud Sync tasks keep reporting success
  against a frozen export, the failure the old C2 photo task had).
- TrueNAS settings changed in the web UI. Everything the role can declare is declared. Paperless's own content (tags,
  types, correspondents, custom fields, saved views) is application data, created in the paperless UI and covered by
  the exporter.

### Verified facts

- Catalog app `paperless-ngx` in `truenas/apps` `ix-dev/community`, app version `1.6.78`, paperless-ngx `3.4.2`. It
  always uses Postgres (selector 17, deprecated, or 18), Valkey 9.1.3, optional Tika + Gotenberg.
- Values: `TZ`; `paperless.{postgres_image_selector, db_password, redis_password, secret_key, admin_user, admin_mail,
  admin_password, enable_trash, enable_tika_gotenberg, additional_envs[{name, value, container}]}`; `run_as`;
  `network.web_port`; `storage.{data, media, consume, trash, postgres_data}` plus `additional_storage[]`;
  `resources.limits`. `admin_user`, `admin_mail`, `admin_password` are `immutable: true` and used only at the first
  install. Only `postgres_data` has `auto_permissions`. The compose template keeps only `additional_envs` entries whose
  `container` is `paperless`.
- Paperless 3.x: OCR mode `auto`; the image ships no Polish pack, `PAPERLESS_OCR_LANGUAGES=pol` installs it at every
  start; duplicates are imported by default since 3.0, `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` refuses them (the
  docs describe it for the consume directory only); nested tags since v2.19. AI is off by default; a value in the
  admin UI's Application Configuration overrides the environment.
- `app.ip_choices` on this box offers only `0.0.0.0`, `::` and `192.168.10.10`, so the UI also answers on the backnet,
  the same accepted exposure as garage and Syncthing.

### Design in one screen

- App `paperless`, community train, version pinned in `truenas_paperless`, Postgres 18, Tika/Gotenberg off, in-app
  trash off (snapshots cover deletions), `run_as` 568:568, port 30070, plain HTTP, `PAPERLESS_URL` on the NAS address.
- Datasets `paperless` (parent) with `data`, `media`, `consume`, `postgres`, `export`, all `host_path` so snapshot and
  Cloud Sync tasks can name them. `consume` exists only because the app requires the path.
- Secrets: `db_password`, `redis_password`, `secret_key` generated at create time (garage pattern); admin password in
  the vault, first install only.
- Backups: a recursive snapshot task every 6 h kept 90 d; a nightly `document_exporter` into `paperless/export`; two
  Cloud Sync legs from it (Synology `COPY`, Hetzner Storage Box `SYNC`); a restore test into a throwaway second app
  before the pile is imported; a `TrueNASPaperlessExportStale` alert (36 h / 72 h) in the existing PrometheusRule.
- AI last: Ollama endpoint, `gemma4:26b`, `bge-m3` embeddings, Polish output, all in the environment.
- Order: datasets, the app, snapshots/exporter/Cloud Sync/alert, restore test, Ollama hookup, document model and totals
  script, the existing pile.

## 2026-11-05 — Task 1: datasets and the app in code

Declared, not yet deployed (the vault is interactive, so the operator runs `playbook.yml`).

**Datasets** (`ansible/truenas/group_vars/all.yml`, after the `s3/*` tree): `paperless` 128K parent first, then `data`,
`media`, `consume`, `export` at 128K and `postgres` at 16K (Postgres pages are 8K). No `owner_uid`: the role chowns, as
for Syncthing.

**`truenas_paperless` block** (next to `truenas_syncthing`): app `paperless`, catalog app `paperless-ngx`, train
`community`, version `"1.6.78"`, 568:568, port 30070, bind `0.0.0.0` (the box offers no frontnet-only address, so the
app gets `host_ips: []`), 2 CPUs and 4096 MB, admin user `admin`, admin mail `paperless@homelab.sudops.pl` (required by
the schema, no mail is sent). `envs`: `PAPERLESS_URL=http://192.168.1.25:30070`, OCR `pol` / `pol+eng`, date parser
`pl+en`, `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true`, and `PAPERLESS_FILENAME_FORMAT`. `PAPERLESS_SEARCH_LANGUAGE` is
left unset. `ai_envs` holds the eight AI settings, composed in by one variable:

```yaml
truenas_paperless_ai_enabled: false
truenas_paperless_additional_envs: "{{ truenas_paperless.envs + (truenas_paperless.ai_envs if truenas_paperless_ai_enabled | bool else []) }}"
```

Every entry carries `container: paperless`: the schema requires the key and the compose template keeps only those.

**The filename format.** Ansible would render `{{ created_year }}` to an empty string and every file would land under
`//-`, so the value is tagged `!unsafe`. Placeholders `created_year`, `correspondent` and `created` are in the usage
docs' placeholder list, and `{{ title }}` is a documented filename placeholder too (paperless-ngx v3.4.2
`docs/advanced_usage.md:401-407`), so the template `{{ created_year }}/{{ correspondent }}/{{ created }} {{ title }}`
is confirmed.

**AI output language.** `PAPERLESS_AI_LLM_OUTPUT_LANGUAGE` goes through `get_language_name`
(`src/paperless_ai/ai_classifier.py:85-90`), which returns a non-code string unchanged, so `Polish` reaches the prompt
as is.

**Role section** (`roles/truenas-apps/tasks/main.yml`, after Syncthing): stat and chown the four non-Postgres paths to
568; generate the three secrets (`openssl rand -hex 32`, `no_log`) only when the app is absent and the vault password
exists; build `_pl_values` once; create with `app.create --job` (`no_log`, `failed_when: false`, job-record read and
real-reason fail); reconcile on a signature over run_as, port + host_ips, every storage path, the env names=values, the
trash/Tika booleans and the Postgres selector. The update sends `TZ`, `run_as`, `network`, `storage`, `resources` and
`paperless` = the live `paperless` dict combined with the declared one minus `db_password`, `redis_password`,
`secret_key`, `admin_user`, `admin_mail`, `admin_password`. The live dict carries the generated secrets through, since
`app.update` merges top-level keys (the garage reconcile shows it). The whole live `app.config` is never echoed. A
failed update is surfaced through `core.get_jobs` filtered on `app.update`. If the vault lacks
`truenas_paperless_admin_password` and the app is absent, the create is skipped with a loud message.

**Checks** (nothing ran against the box):

```
ansible-playbook -i localhost, -c local ansible/truenas/tests/paperless-render.yml                                 # red before the vars existed ('truenas_paperless_additional_envs' is undefined), green after
ansible-playbook -i localhost, -c local ansible/truenas/tests/paperless-render.yml -e truenas_paperless_ai_enabled=true   # green, eight PAPERLESS_AI_* names present
cd ansible/truenas && ansible-playbook -i inventory.yml playbook.yml --syntax-check                                # rc 0
```

The role section was also exercised with a stub `midclt` on `PATH` that logged its arguments: no create without the
vault password; a create payload with the three generated secrets and literal `{{ created_year }}` braces; no
`app.update` when the live config matches; and on drift an update payload with only the six top-level keys, the live
secrets carried through, and the admin fields taken from the live dict, not the declared one.

## 2026-11-05 — Task 2: nightly export, snapshots, offsite copies, alert rule

The paperless data is backed up as a `document_exporter` run, not by copying the live dataset: the export is a
self-consistent set (originals, archive PDFs, a manifest that carries the database), and it is what the two Cloud Sync
legs copy. Per the docs (administration, "Document exporter"), `-d` deletes files of removed documents from the
target, and `--no-progress-bar` keeps it quiet for cron.

**Script.** `ansible/truenas/roles/truenas-tasks/files/paperless-export.py <textfile-dir> --app-name paperless
--export-host-path /mnt/tank/paperless/export --export-container-path /paperless/export [--docker /usr/bin/docker]`.
Container lookup is `docker ps -q --filter label=com.docker.compose.project=ix-paperless --filter
label=com.docker.compose.service=paperless` and must return exactly one id. The labels are unverified until the app
exists (Task 3 Step 4); the fallback is `--filter name=ix-paperless-paperless-1`. The exec has no `-u`: the container
runs as 0:0 and the image wrapper drops to the paperless user (568), so the files come out 568-owned. After a zero
exit it counts `documents.document` records in `manifest.json` and writes the `.prom` file atomically (temp file
without the `.prom` suffix, `os.replace`), as the textfile collector does. Silent on success; one stderr line and a
non-zero exit on every failure, with the old `.prom` untouched (so the staleness alert keeps counting from the last
good run). `--docker` exists so the tests can pass a fake binary's absolute path.

**Tests (RED then GREEN).**

```
python3 -m unittest ansible/truenas/tests/test_paperless_export.py -v    # RED: FileNotFoundError, the script did not exist (5 errors)
python3 -m unittest ansible/truenas/tests/test_paperless_export.py -v    # GREEN: 5 tests OK
```

They cover success (both metrics, documents = 3 out of a manifest that also holds tag and user records, timestamp
about now, `os.replace` called with no `.prom` present and a temp name not ending in `.prom`, the right exec argv) and
four failures (no container, two containers, exporter exit 1, manifest missing), each with a non-zero code, a stderr
line and a pre-existing `.prom` left byte-identical.

**Ansible.** `truenas_paperless_export` in group_vars (cron `15 4 * * *`, description `paperless export (managed by
ansible/truenas)`, stdout hidden, stderr kept so a failure is mailed). The cron command passes every argument
explicitly. A recursive snapshot task on `paperless` (every 6 h, 90 days). Two Cloud Sync tasks on
`paperless/export`: Synology `COPY` at 04:45 into `photo/backups/paperless`, Hetzner `SYNC` at 07:30 into `/paperless`
with `transfers: 2`, both from a snapshot, no excludes. 07:30 is after the Immich offsite leg (06:00) because the box
allows 10 connections per account and each task can open 2 transfers plus 8 checkers; the pre-check is the Immich
task's finish time over the past week (PromQL in the task report), and the paperless leg moves later if that leg ever
runs close to 07:30. Both reuse the Immich legs' credentials (`synology-sftp`, `hetzner-storagebox`), so no new vault entries.

**Alert group `truenas-paperless`** (`TrueNASPaperlessExportStale`: warning at 36 h, critical at 72 h, both `for: 15m`
with `keep_firing_for: 2h`, and a critical `absent_over_time(...[36h])` rule with a `window` label, for the same reason
the Cloud Sync rules carry one). It is validated here but committed in Task 3, after the first export has produced the
series: the absent rule would otherwise fire from the commit until the app exists and dirty the health sweeps the Rook
stages gate on.

Checks: `ansible-playbook -i inventory.yml playbook.yml --syntax-check` rc 0; `helm lint` clean; `helm template |
kubeconform -strict -ignore-missing-schemas` 5 valid, 0 invalid. Nothing ran against the box or the cluster.

## 2026-11-06 — Task 3, first playbook run: vault quoting, then a catalog version that no longer exists

The first run stopped in the `pre_tasks` vault load: `include_vars` failed, and `no_log: true` hid why. To get the
reason without showing a value, the decrypted vault went through a checker that prints only the YAML error and its
position, redacting the fragments PyYAML quotes in its messages:

```
ansible-vault view vars/vault.yml | /opt/homebrew/Cellar/ansible/14.5.0_3/libexec/bin/python -I vaultcheck.py
YAML ERROR: while scanning for the next token | found character '<redacted>' that cannot start any token | line 69, column 39
```

The new `truenas_paperless_admin_password` value was in double quotes and contained characters that ended the
scalar early. Single quotes fixed it (inside them only `'` needs escaping, as `''`). The role passes the password
through `to_json` inside an argv list, with no shell, so any character is safe once the YAML parses.

The second run created the datasets (`tank/paperless/{data,media,consume,postgres,export}`), the export cron job
(id 5, 04:15 daily), both Cloud Sync tasks (ids 3 and 4, not run yet) and the 6-hourly snapshot task on
`tank/paperless` (90 days), but no app. The middleware job log had the reason:

```
midclt call core.get_jobs '[["method","^","app."]]' '{"order_by": ["-id"], "limit": 5}'
app.create FAILED: [ENOENT] Version 1.6.78 not found in paperless-ngx app
```

`catalog.get_app_details paperless-ngx` offers one version only: `1.6.79` (app version 3.4.2), published
2026-11-05 17:13Z by truenas/apps `fe7f2337fd`, about two hours after Task 1 pinned 1.6.78. That commit changes the
chart version and one image tag (`8.39.0` → `8.40.0`), nothing in the schema. The catalog keeps only the newest
version of each app, so a pinned version breaks the next fresh create whenever the catalog moves. The pin is now
`1.6.79`. The same holds for Task 3 Step 5: the throwaway restore app must be created with whatever version the
catalog offers on that day.

## 2026-11-06 — first start hangs in `usermod`; paperless now runs as uid 1000

With 1.6.79 the create job succeeded (job 71672), but the app stayed `DEPLOYING` and the `paperless` container
`starting`, with an empty `data` dataset, for over 30 minutes. My first guess, that the Polish OCR install needs root
and the container is non-root, was wrong. `truenas_admin` cannot reach the Docker socket, but the middleware log
stream works when `midclt subscribe` gets an event count and a timeout:

```
midclt subscribe -n 60 -t 20 'app.container_log_follow:{"app_name": "paperless", "container_id": "<id>", "tail_lines": 60}'
11:20:37 [init-start] paperless-ngx docker container starting init as root
11:20:37 [init-user] Mapping UID for paperless to 568
11:20:52 [init-tesseract-langs] Installed tesseract-ocr-pol
```

Nothing after 11:20:52. In the image's s6 graph, `init-migrations` waits for `init-folders` and
`init-compile-bytecode`, both of which print a first line at once, and neither had. Both wait for
`init-modify-user`, which printed "Mapping UID" but never "Mapping GID"/"No GID changes". On the host:

```
ps -eo pid,stat,etime,time,args | grep usermod
2275672  D  26:22  00:00:04  usermod --non-unique --uid 568 paperless
grep ctxt /proc/2275672/status   # 7823, then 7873 ten seconds later
```

`usermod` had been in uninterruptible I/O wait for 26 minutes with 4 s of CPU, advancing at about 5 blocking
waits a second. The catalog passes `run_as` (568, the apps account) as `USERMAP_UID`, and the image's `paperless`
user is uid 1000 with home `/usr/src/paperless`. `usermod --uid` re-owns everything in that home, which in a container
means copying each image file into the writable layer, and Docker's storage here is `tank/ix-apps` on the RAIDZ2 HDDs.
The pool itself was not the bottleneck: `zpool iostat -l` showed sync-write waits of 1-2 ms, and the busy datasets were
garage's `tank/s3/meta` (writes) and `tank/media` (reads), with `tank/ix-apps/docker` nearly idle. Which kernel path
makes each step that slow was not established. What matters operationally is that every container recreate (any
`app.update`, catalog upgrades) starts from a fresh writable layer and repeats it.

Fix: `run_as` 1000:1000 (the catalog's minimum is 568, no maximum; uid and gid 1000 are unused on the box). The role
already chowns `data`, `media`, `consume` and `export` to `run_as` and reconciles `run_as` through `app.update`, so the
change is the two values in `group_vars` plus comments. With `USERMAP_UID` equal to the image's uid, `init-modify-user`
prints "No UID changes" and `usermod` never runs. Checks: `--syntax-check` rc 0, `tests/paperless-render.yml` 8 ok,
`test_paperless_export` 5 tests OK.

Result (playbook run 4, `changed=3 failed=0`: the chown of the four paths, the `app.update` with `run_as` 1000,
and one other): the recreated container logged `[init-user] No UID changes for paperless` at 12:11:48Z, compiled
bytecode in 7 s, applied migrations, and served (`Paperless-ngx version: v3.4.2`) at 12:12:28Z, 40 s after start.
`init-superuser` reported "a user admin already exists": the uid-568 container must have finished its `usermod` and
run migrations and the superuser step before `app.update` replaced it, with the same vault password. `data`, `media`,
`consume` and `export` read 1000:1000; app state RUNNING.

## 2026-11-06 — Task 3 Steps 2-4: login, reconcile check, first documents

Login with the vault password works. The second playbook run reported `changed=0` and the converge assert passed. The
reconcile check (Step 3) set `PAPERLESS_DATE_PARSER_LANGUAGES` to `en+pl` in git (875ad6a), and the next run made one
change: `app.config` read `en+pl` and the container was recreated (`No UID changes`, RUNNING about 40 s later). The
revert (851d6f0) went the same way back to `pl+en`. Declared values reach the live app in both directions through
`app.update`.

Step 4: five real PDFs uploaded through the UI, all five consumed (`consumption finished` ×5, no other ERROR lines).
Each was then uploaded a second time, and all five were refused:

```
[WARNING] [paperless.consumer] Consuming duplicate <file>.pdf: 1 existing document(s) share the same content.
[ERROR] [paperless.consumer] Not consuming <file>.pdf: It is a duplicate of <title> (#2)
[INFO] [paperless.tasks] ConsumerPreflightPlugin rejected duplicate: ...
... succeeded in 0.17s: {'duplicate_of': 2, 'duplicate_in_trash': False}
```

So `PAPERLESS_CONSUMER_DELETE_DUPLICATES=true` also applies to uploads through the UI, which the docs describe only for
the consume directory. The log stream is read with `midclt subscribe -n <count> -t <s>
'app.container_log_follow:{...}'`; file names are not reproduced here.

Step 4 continued: `midclt call --job cronjob.run 5` (rc 0) wrote `paperless-export.prom` with documents = 5 and left 12
files (511K, 1000:1000) in `tank/paperless/export`. Both Cloud Sync tasks then ran once: SUCCESS, 12/12 files, 550 KiB;
`cloudsync.list_directory` on each destination lists 12 files, 563,595 bytes, `manifest.json` included. In the
cluster, the user-workload Prometheus returns `truenas_paperless_export_documents` = 5. The alert rule went in as
ba39e3f after `promtool check rules` (SUCCESS, 20 rules) and an `oc diff` that added only the `truenas-paperless`
group; ArgoCD synced at 13:00:12Z and Thanos Ruler reports all three rules `health=ok state=inactive`.

One thing for the review pass: an exported file name starts with `2026-01-11` (the created date, from
`PAPERLESS_FILENAME_FORMAT`) while the original's own name carries `20261101`, which looks like day and month swapped
by the date parser. To check on the document itself before drawing a conclusion.

## 2026-11-06 — Task 3 Step 5: the restore test passes

Procedure and scripts: `tests/paperless-restore/` (5999fd3, fix 1d20d39). Fresh export first (13:14:35Z, documents =
5), then `create-app.sh` built `paperless-restore` on port 30071: catalog version read at run time (1.6.79),
ix_volume storage, run_as 1000:1000, bootstrap account `restore-admin`, and the live export mounted read-only at
`/restore`. The script reads the bootstrap password with a hidden prompt, so it needs a real terminal: run through
Claude Code's `!`, `read` gets end-of-input and `set -e` stops the script before anything is created (it happened
twice; nothing was created).

The importer, from the TrueNAS UI shell of the throwaway's `paperless` container:

```
# document_importer /restore
Found existing user(s), this might indicate a non-empty installation
Checking the manifest
Copy files into paperless...
  Copying files... 5/?
Updating search index...
  Indexing documents... 5/5
```

The bootstrap account only produced that warning; nothing had to be worked around. The import carries the live
`admin` account with its password hash: logging in to :30071 as `admin` with the live password worked, and the
dashboard showed 5 documents, 9,434 characters.

`compare.sh` logs in to both APIs and compares the document count and the set of `original_checksum` values from
`/api/documents/<id>/metadata/`. Its first run got a 401 on the live side, before touching the restore: my bug. The
script hands the password to curl as `user = "<user>:<password>"` on a config read from stdin (to keep it out of
`ps`), and inside a double-quoted curl config value `\` and `"` are escapes, so a password containing either reaches
the server altered. Escaping both (tested under macOS `/bin/bash` 3.2) fixed it:

```
documents: live=5 restore=5
checksums read: live=5 restore=5
checksums only on live: 0, only on restore: 0
PASS: same count, identical original_checksum sets
```

Cleanup 17:42Z: `midclt call --job app.delete paperless-restore '{"remove_ix_volumes": true}'`; the app and its five
`tank/ix-apps/app_mounts/paperless-restore/*` datasets are gone, the live app RUNNING. So the nightly export restores
into a working paperless with the same originals, and since both Cloud Sync legs copy that same folder (12 files,
563,595 bytes on each), the offsite copies are restorable the same way.
