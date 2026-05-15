# Sonarr v4.0.17 leaks the Postgres password in cleartext in the migration log

**Upstream:** https://github.com/Sonarr/Sonarr
**Component:** Migration / log redaction (`MigrationController` / NLog target)
**Affected version:** Sonarr v4.0.17.2952 (lscr.io/linuxserver/sonarr:4.0.17). Confirmed against `develop`/`main` of upstream Sonarr on 2026-05-15.
**Severity:** Information disclosure — the Postgres user's password is written to stdout/stderr (and from there to whatever log sink the container is attached to: kubectl logs, Loki, journald, etc.). Anyone with read access to the application logs can extract DB credentials.

## Summary

On startup, Sonarr's `MigrationController` logs the connection string it's about to migrate against — **including the password in cleartext**:

```
[Info] MigrationController: *** Migrating Database=sonarr-main;Host=media-postgres-rw;Username=media;Password=kSJdyptLUFqP
```

Radarr v5+ (same servarr codebase lineage) **does** redact the password in the equivalent log line:

```
[Info] MigrationController: *** Migrating Database=radarr-main;Host=media-postgres-rw;Username=(removed);Password=(removed);Port=5432;Enlist=False ***
```

So Radarr's log redactor (or its `MigrationController.Migrate` log call) sanitizes the connection string; Sonarr's does not. This is a Sonarr-specific bug — both apps share the FluentMigrator + Npgsql plumbing but the wrapping log line in `MigrationController` differs.

## Steps to reproduce

1. Run Sonarr v4.0.17 (or any current 4.x version) configured with Postgres via env vars:
   ```yaml
   - name: Sonarr__Postgres__Host
     value: somewhere
   - name: Sonarr__Postgres__User
     value: sonarr
   - name: Sonarr__Postgres__Password
     value: secret123
   - name: Sonarr__Postgres__MainDb
     value: sonarr-main
   ```
2. Start Sonarr fresh (so it runs the initial migration).
3. `kubectl logs deploy/sonarr | grep MigrationController`
4. Observe the password appears in cleartext in the `*** Migrating Database=...;Password=secret123 ***` line.

## Expected behavior

Match Radarr's behavior — pre-sanitize the connection string before passing it to the log call, replacing `User=` and `Password=` values with a redaction placeholder like `(removed)` or `***`.

## Actual behavior

Plaintext password in the application log.

## Workaround

None at the application level — the line is unconditional on every Sonarr boot. The credential is also visible in any log aggregator (Loki, journald, cluster logging) that ingests Sonarr's stdout. Operational mitigations:

- Restrict `kubectl logs` / log-sink access to trusted operators
- Rotate the Postgres password after every Sonarr upgrade or scale-up event (since the password is re-logged on each fresh boot)
- Use a transient password for the CNPG-generated `<cluster>-app` Secret and consume the value via `valueFrom.secretKeyRef` (already in place here) — limits exposure to log readers, but doesn't eliminate it

## Notes

- The corresponding `MigrationController` log line for `sonarr-log` database does the same thing (separate log entry but same shape, same leak).
- Radarr's redaction may stem from a different invocation of the connection-string serializer (Npgsql exposes both `ConnectionString` and a sanitized form). Worth checking the diff between Radarr's `MigrationController` and Sonarr's.
- Prowlarr (v2.x) was not checked for this specific log line — should be verified before assuming all servarrs do/don't have it.

## Local context where this was observed

- 3-node OKD 4.20 bare-metal cluster
- Sonarr deployed via the linuxserver/sonarr:4.0.17 image
- Postgres backend = CloudNativePG-managed cluster (PG 18), single shared user across the servarr stack
- Discovered while comparing Sonarr's vs Radarr's startup logs for the same migration step on 2026-05-15
