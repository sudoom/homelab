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
