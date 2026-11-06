#!/usr/bin/env bash
# Create the throwaway paperless app for the restore test (tests/paperless-restore/README.md).
#
# Builds the app.create payload on the Mac and pipes it over ssh on stdin, so no secret lands in a
# file, a log or this terminal. The database, Redis and Django secrets come from `openssl rand`.
# The bootstrap admin is `restore-admin` with the password you type (the live admin password is the
# sensible choice: after the import the live `admin` account exists here too, with its own hash).
#
# Storage is ix_volume (deleted with the app), the live export is mounted read-only at /restore,
# run_as is 1000:1000 like the live app (any other uid makes the image's init usermod the whole
# home on first start, over 30 minutes on this box). The catalog keeps only its newest version, so
# the version is read from the catalog at run time instead of pinned.
set -euo pipefail

HOST="${PAPERLESS_RESTORE_HOST:-truenas_admin@192.168.1.25}"
APP="paperless-restore"
PORT=30071
EXPORT_PATH="/mnt/tank/paperless/export"

if ssh -o BatchMode=yes "$HOST" "midclt call app.query '[[\"name\",\"=\",\"$APP\"]]' '{\"select\": [\"name\"]}'" | grep -q "$APP"; then
  echo "$APP already exists; delete it first (README step 6)" >&2
  exit 1
fi

VERSION=$(ssh -o BatchMode=yes "$HOST" "midclt call catalog.get_app_details paperless-ngx '{\"train\": \"community\"}'" \
  | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["latest_version"])')
echo "catalog version: $VERSION"

read -rsp "bootstrap password for restore-admin (input hidden): " ADMIN_PW
echo
[ -n "$ADMIN_PW" ] || { echo "empty password" >&2; exit 1; }

DB_PW=$(openssl rand -hex 32) REDIS_PW=$(openssl rand -hex 32) SECRET_KEY=$(openssl rand -hex 32) \
ADMIN_PW="$ADMIN_PW" VERSION="$VERSION" APP="$APP" PORT="$PORT" EXPORT_PATH="$EXPORT_PATH" \
python3 -I -c '
import json, os
e = os.environ
vol = lambda name: {"type": "ix_volume", "ix_volume_config": {"dataset_name": name}}
payload = {
    "app_name": e["APP"],
    "catalog_app": "paperless-ngx",
    "train": "community",
    "version": e["VERSION"],
    "values": {
        "TZ": "Europe/Warsaw",
        "paperless": {
            "postgres_image_selector": "postgres_18_image",
            "admin_user": "restore-admin",
            "admin_mail": "paperless@homelab.sudops.pl",
            "admin_password": e["ADMIN_PW"],
            "db_password": e["DB_PW"],
            "redis_password": e["REDIS_PW"],
            "secret_key": e["SECRET_KEY"],
            "enable_trash": False,
            "enable_tika_gotenberg": False,
            "additional_envs": [],
        },
        "run_as": {"user": 1000, "group": 1000},
        "network": {"web_port": {"bind_mode": "published", "port_number": int(e["PORT"]), "host_ips": []}},
        "storage": {
            "data": vol("data"),
            "media": vol("media"),
            "consume": vol("consume"),
            "trash": vol("trash"),
            "postgres_data": vol("postgres_data"),
            "additional_storage": [{
                "type": "host_path",
                "read_only": True,
                "mount_path": "/restore",
                "host_path_config": {"path": e["EXPORT_PATH"]},
            }],
        },
        "resources": {"limits": {"cpus": 2, "memory": 4096}},
    },
}
print(json.dumps(payload))
' | ssh -o BatchMode=yes "$HOST" 'midclt call --job app.create "$(cat)" > /dev/null && echo "app.create: done"'

ssh -o BatchMode=yes "$HOST" "midclt call app.query '[[\"name\",\"=\",\"$APP\"]]' '{\"select\": [\"name\", \"state\", \"version\"]}'"
echo "UI (once RUNNING): http://192.168.1.25:$PORT"
