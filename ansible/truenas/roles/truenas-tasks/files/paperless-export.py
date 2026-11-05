#!/usr/bin/env python3
"""
Nightly paperless-ngx document export, plus the metrics that say it worked.

Runs `document_exporter` inside the paperless container, then counts the
`documents.document` records in the manifest it wrote and publishes two gauges
through node_exporter's textfile collector:

  truenas_paperless_export_last_success_timestamp_seconds
  truenas_paperless_export_documents

The export directory (tank/paperless/export) is what both Cloud Sync legs copy,
so a stale export is a stale backup; TrueNASPaperlessExportStale watches the
timestamp.

Silent on success (TrueNAS mails any cron job whose stdout is non-empty). On any
failure it prints one line to stderr, exits non-zero and leaves the previous
.prom file untouched, so the staleness alert keeps counting from the last good
run.

The .prom file is written through a temp file that does NOT end in `.prom` and
os.replace()d into place: a half-written file would make node_exporter discard
the whole textfile scrape (see node-exporter-textfile.py).

No `-u` on the exec: the container runs as 0:0 and the image's wrapper drops to
the paperless user (568), so exported files are 568-owned like the dataset.
"""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time

PROM_NAME = "paperless-export.prom"
EXPORT_TIMEOUT = 3 * 3600


def fail(msg):
    print("paperless-export: %s" % msg, file=sys.stderr)
    return 1


def find_container(docker, app):
    # Labels are the compose project and service of the TrueNAS catalog app;
    # fallback if they ever differ: --filter name=ix-<app>-paperless-1.
    p = subprocess.run(
        [docker, "ps", "-q",
         "--filter", "label=com.docker.compose.project=ix-%s" % app,
         "--filter", "label=com.docker.compose.service=paperless"],
        capture_output=True, text=True, timeout=60)
    if p.returncode != 0:
        raise RuntimeError("docker ps failed: %s" % p.stderr.strip())
    ids = p.stdout.split()
    if len(ids) != 1:
        raise RuntimeError("expected exactly one paperless container, found %d" % len(ids))
    return ids[0]


def count_documents(manifest):
    with open(manifest) as f:
        records = json.load(f)
    return sum(1 for r in records if isinstance(r, dict) and r.get("model") == "documents.document")


def write_prom(textfile_dir, documents, now):
    body = (
        "# HELP truenas_paperless_export_last_success_timestamp_seconds Unix time the last paperless export finished.\n"
        "# TYPE truenas_paperless_export_last_success_timestamp_seconds gauge\n"
        "truenas_paperless_export_last_success_timestamp_seconds %d\n"
        "# HELP truenas_paperless_export_documents Documents in the last paperless export manifest.\n"
        "# TYPE truenas_paperless_export_documents gauge\n"
        "truenas_paperless_export_documents %d\n" % (now, documents))
    fd, tmp = tempfile.mkstemp(prefix=".paperless-export.", suffix=".tmp", dir=textfile_dir)
    try:
        with os.fdopen(fd, "w") as f:
            f.write(body)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(textfile_dir, PROM_NAME))
    except BaseException:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[1])
    ap.add_argument("textfile_dir")
    ap.add_argument("--app-name", required=True)
    ap.add_argument("--export-host-path", required=True)
    ap.add_argument("--export-container-path", required=True)
    ap.add_argument("--docker", default="/usr/bin/docker")
    a = ap.parse_args(argv)
    try:
        cid = find_container(a.docker, a.app_name)
        p = subprocess.run(
            [a.docker, "exec", cid, "document_exporter", a.export_container_path,
             "-d", "--no-progress-bar"],
            capture_output=True, text=True, timeout=EXPORT_TIMEOUT)
        if p.returncode != 0:
            tail = (p.stderr or p.stdout).strip().splitlines()[-1:] or [""]
            return fail("document_exporter exited %d: %s" % (p.returncode, tail[0]))
        manifest = os.path.join(a.export_host_path, "manifest.json")
        if not os.path.isfile(manifest):
            return fail("no manifest at %s after the export" % manifest)
        documents = count_documents(manifest)
        write_prom(a.textfile_dir, documents, int(time.time()))
    except Exception as e:  # noqa: BLE001 - one line on stderr, non-zero exit
        return fail("%s: %s" % (type(e).__name__, e))
    return 0


if __name__ == "__main__":
    sys.exit(main())
