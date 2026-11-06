# Paperless restore test

Proves the nightly export (`tank/paperless/export`, copied to the Synology and the Storage Box) restores into a
working paperless. Run it once before the real pile goes in (plan Task 3 Step 5), and again after any change to the
export job. Everything runs from the Mac; the throwaway app lives on TrueNAS next to the live one and is deleted at
the end with its volumes.

| | |
|---|---|
| Throwaway app | `paperless-restore`, port 30071, ix_volume storage, run_as 1000:1000, catalog version read at run time |
| Source | the live export, mounted read-only at `/restore` |
| Pass | same document count on both APIs, identical sets of `original_checksum` |

## Steps

1. **Fresh export first** so the throwaway restores what the live app holds now:

   ```bash
   ssh truenas_admin@192.168.1.25 "midclt call --job cronjob.run 5"   # cron job "paperless export (managed by ansible/truenas)"
   ssh truenas_admin@192.168.1.25 "cat /mnt/tank/monitoring/textfile/paperless-export.prom" | grep documents
   ```

2. **Create the throwaway** (asks for a bootstrap password for `restore-admin`; prints no secret):

   ```bash
   bash tests/paperless-restore/create-app.sh
   ```

   Wait until `midclt call app.query '[["name","=","paperless-restore"]]'` reads `RUNNING` (about a minute; the
   Polish OCR pack is not installed here, nothing in the import needs it).

3. **Import** inside the throwaway's `paperless` container. The image's `document_importer` wrapper drops to the
   paperless user itself. Either the TrueNAS UI (Apps → paperless-restore → Workloads → paperless → Shell) or:

   ```bash
   ssh -t truenas_admin@192.168.1.25 'sudo docker exec -it $(sudo docker ps -q -f label=com.docker.compose.project=ix-paperless-restore -f label=com.docker.compose.service=paperless) document_importer /restore'
   ```

   If the importer refuses because of the bootstrap `restore-admin` account, record the message and the fix used.

4. **Log in** at `http://192.168.1.25:30071` as the live `admin` with the live password: the import carries the live
   account and its password hash. Record it if that fails.

5. **Compare** (asks for the account and password; prints counts and the verdict only):

   ```bash
   bash tests/paperless-restore/compare.sh
   ```

6. **Delete the throwaway and its volumes:**

   ```bash
   ssh truenas_admin@192.168.1.25 "midclt call --job app.delete paperless-restore '{\"remove_ix_volumes\": true}'"
   ```

## Notes

- The throwaway binds all interfaces, like the live app. It holds a copy of the paperwork until step 6, so do not
  leave it running.
- `document_importer` reads the manifest and copies the originals and archive files into the throwaway's `media`
  volume; the read-only mount is enough.
- Results and anything that deviated go into `blog/blog-paperless-draft.md`.
