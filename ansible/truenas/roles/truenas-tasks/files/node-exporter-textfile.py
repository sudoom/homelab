#!/usr/bin/env python3
"""
Textfile-collector feed for the node_exporter running on this box.

WHY THIS EXISTS: node_exporter's zfs collector reads /proc/spl/kstat/zfs, which
gives ARC, ZIL and per-dataset IO counters -- and nothing else. Verified against
the live scrape on 2026-09-08: there is NO pool health, NO capacity, NO
fragmentation, NO scrub state and NO SMART data in its output at all. Those are
exactly the things an operator looks at when a NAS is unwell, and every one of
them needs a shell rather than a kernel interface. Hence this.

WHY NOT THE NATIVE GRAPHITE EXPORTER (`reporting.exporters`, the only type
TrueNAS offers -- there is no InfluxDB one): it is fed by netdata, and netdata's
shape is unusable for these six metrics.
  * pool usage exists but BOTH pools carry identical labels
    (chart="truenas_pool.usage" for boot-pool AND tank) -- they are
    indistinguishable except by magnitude.
  * disk temps exist as ONE METRIC NAME PER DISK, with serial and lunid baked
    into the name, so `avg by (disk)` and a single alert rule are both
    impossible.
  * scrub, fragmentation and snapshot age: zero series, none at all.
  * values are pre-averaged (`_average` suffix), so rate() is meaningless.
It would also need a graphite_exporter deployment plus a mapping config in the
cluster -- more moving parts, to deliver two of six metrics badly.

ATOMICITY IS LOAD-BEARING. node_exporter reads whatever is in the directory at
scrape time; a half-written file is a parse error that sets
`node_textfile_scrape_error 1` and discards the WHOLE scrape's textfile metrics.
So this writes to a temp file that does NOT end in `.prom` (the collector only
reads `*.prom`) and then os.replace()s it, which is atomic within a filesystem.
Never write to the .prom path directly.

Run as root -- smartctl needs it. Reads use `-n standby` so a sleeping disk is
never spun up just to be measured.
"""

import json
import os
import subprocess
import sys
import tempfile
import time

NS = "truenas"
errors = 0


def run(argv, timeout=60):
    """Run a command, return stdout ('' on any failure). Never raises."""
    global errors
    try:
        p = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
        if p.returncode != 0 and not p.stdout:
            errors += 1
            return ""
        return p.stdout
    except Exception:
        errors += 1
        return ""


def esc(v):
    """Escape a Prometheus label value."""
    return str(v).replace("\\", "\\\\").replace('"', '\\"').replace("\n", " ")


def labels(**kw):
    inner = ",".join('%s="%s"' % (k, esc(v)) for k, v in sorted(kw.items()) if v not in (None, ""))
    return "{%s}" % inner if inner else ""


class Out:
    def __init__(self):
        self.lines = []
        self._declared = set()

    def metric(self, name, value, help_text=None, mtype="gauge", **lbl):
        full = "%s_%s" % (NS, name)
        if full not in self._declared:
            if help_text:
                self.lines.append("# HELP %s %s" % (full, help_text))
            self.lines.append("# TYPE %s %s" % (full, mtype))
            self._declared.add(full)
        self.lines.append("%s%s %s" % (full, labels(**lbl), value))


def skip_dataset(name):
    """
    Datasets that are noise rather than signal.

    `boot-pool` is excluded WHOLESALE: its children are the OS image tree
    (boot-pool/ROOT/<version>/{audit,conf,etc,...}), which nobody acts on, and
    its snapshots are TrueNAS upgrade snapshots. Those snapshots are legitimately
    weeks old, so leaving them in would make any "newest snapshot is stale" alert
    fire permanently on datasets that are supposed to look like that. Boot-disk
    capacity still reaches Prometheus via truenas_zpool_*{pool="boot-pool"},
    which is the only boot-pool fact worth acting on.

    `.system` is the middleware's internal tree and `ix-apps` is Docker's.
    """
    return (name == "boot-pool" or name.startswith("boot-pool/")
            or "/.system" in name or "/ix-apps" in name)


def collect_pools(out):
    # `-p` gives exact machine-readable values: bytes for size/alloc/free and
    # plain integers for frag/cap (which are percentages).
    raw = run(["zpool", "list", "-Hp", "-o", "name,size,alloc,free,frag,cap,health"])
    for line in raw.strip().splitlines():
        f = line.split("\t")
        if len(f) != 7:
            continue
        name, size, alloc, free, frag, cap, health = f
        out.metric("zpool_size_bytes", size, "Total pool size in bytes.", pool=name)
        out.metric("zpool_allocated_bytes", alloc, "Allocated bytes in the pool.", pool=name)
        out.metric("zpool_free_bytes", free, "Free bytes in the pool.", pool=name)
        # Ratios rather than percents: 0-1 is the Prometheus convention and
        # keeps threshold expressions readable (> 0.8, not > 80).
        out.metric("zpool_fragmentation_ratio", int(frag) / 100.0,
                   "Pool fragmentation, 0-1.", pool=name)
        out.metric("zpool_capacity_ratio", int(cap) / 100.0,
                   "Pool capacity used, 0-1.", pool=name)
        out.metric("zpool_healthy", 1 if health == "ONLINE" else 0,
                   "1 if the pool state is ONLINE, 0 otherwise.", pool=name)
        # Info-style series so the actual state string is queryable/alertable
        # without encoding a lookup table in PromQL.
        out.metric("zpool_state_info", 1, "Pool state as a label; value is always 1.",
                   pool=name, state=health)


def collect_scrub(out):
    """
    Scrub state comes from `pool.query`, NOT from parsing `zpool status` text.
    The middleware returns a structured `scan` dict; the text output's "scan:"
    line has at least three different shapes (finished / in progress / none
    requested) and embeds a locale-formatted date.

    A pool that has NEVER been scrubbed returns every scan field as null. That
    is a real state worth exporting rather than skipping -- on 2026-09-08 `tank`
    was in exactly that state, 11 days after creation, because the scrub task's
    35-day threshold had skipped the 09-01 run.
    """
    raw = run(["midclt", "call", "pool.query"])
    if not raw:
        return
    try:
        pools = json.loads(raw)
    except ValueError:
        global errors
        errors += 1
        return
    now = time.time()
    for p in pools:
        name = p.get("name")
        scan = p.get("scan") or {}
        end = scan.get("end_time")
        # midclt renders timestamps as {"$date": <epoch_ms>}.
        if isinstance(end, dict):
            end = end.get("$date")
        ever = 1 if end else 0
        out.metric("zpool_scrub_ever", ever,
                   "1 if this pool has ever completed a scrub, 0 if never.", pool=name)
        if end:
            out.metric("zpool_scrub_end_timestamp_seconds", float(end) / 1000.0,
                       "Unix time the last scrub finished.", pool=name)
            out.metric("zpool_scrub_age_seconds", now - (float(end) / 1000.0),
                       "Seconds since the last scrub finished.", pool=name)
        if scan.get("errors") is not None:
            out.metric("zpool_scrub_errors", scan["errors"],
                       "Errors reported by the last scrub.", pool=name)
        # Verified against a live scrub 2026-09-08: the middleware reports
        # state "SCANNING" with a `percentage` float while one is running.
        out.metric("zpool_scrub_in_progress",
                   1 if scan.get("state") == "SCANNING" else 0,
                   "1 while a scrub is running.", pool=name)
        if scan.get("percentage") is not None:
            out.metric("zpool_scrub_percent_complete", round(float(scan["percentage"]), 2),
                       "Progress of the running scrub, 0-100.", pool=name)

        # autotrim, exported so a setting made outside Ansible is VISIBLE rather
        # than merely present. Note that on `tank` this is a no-op: every vdev
        # reports "(trim unsupported)" because all six are HUS726040ALA610
        # spinning disks. It would only do something on `boot-pool` (the Intel
        # SSD), where it is currently off.
        at = p.get("autotrim") or {}
        atv = at.get("parsed") if isinstance(at, dict) else at
        if atv is not None:
            out.metric("zpool_autotrim", 1 if str(atv).lower() in ("on", "true") else 0,
                       "1 if pool autotrim is enabled.", pool=name)


def collect_datasets(out):
    raw = run(["zfs", "list", "-Hp", "-o", "name,used,available,referenced", "-t", "filesystem"])
    for line in raw.strip().splitlines():
        f = line.split("\t")
        if len(f) != 4:
            continue
        name, used, avail, refer = f
        if skip_dataset(name):
            continue
        out.metric("dataset_used_bytes", used, "Bytes used by the dataset.", dataset=name)
        out.metric("dataset_available_bytes", avail, "Bytes available to the dataset.", dataset=name)
        out.metric("dataset_referenced_bytes", refer, "Bytes referenced by the dataset.", dataset=name)


def collect_snapshots(out):
    """
    Newest snapshot age per dataset. This is the metric that catches a snapshot
    task that silently stopped -- the snapshots that exist still look fine, so
    nothing else in the stack notices.
    """
    raw = run(["zfs", "list", "-Hp", "-t", "snapshot", "-o", "name,creation", "-s", "creation"])
    newest = {}
    for line in raw.strip().splitlines():
        f = line.split("\t")
        if len(f) != 2 or "@" not in f[0]:
            continue
        ds = f[0].split("@", 1)[0]
        if skip_dataset(ds):
            continue
        try:
            newest[ds] = max(newest.get(ds, 0), int(f[1]))
        except ValueError:
            continue
    now = time.time()
    for ds, ts in sorted(newest.items()):
        out.metric("snapshot_newest_timestamp_seconds", ts,
                   "Unix time of the newest snapshot for this dataset.", dataset=ds)
        out.metric("snapshot_age_seconds", now - ts,
                   "Seconds since the newest snapshot for this dataset.", dataset=ds)


def collect_smart(out):
    """
    Per-disk SMART, keyed by SERIAL rather than /dev/sdX.

    Device names re-enumerate on any disk add/remove/reseat -- the same hazard
    that produced a false CephNodeDiskspaceWarning on the OKD nodes on
    2026-09-08 when a pulled drive moved every node's boot disk from sdb to sda.
    A serial-keyed series survives that; a /dev/sdX-keyed one silently becomes a
    different disk.

    node_exporter DOES already expose drive temperatures via hwmon (the
    `drivetemp` module is loaded, 7 devices) -- but labelled by SCSI target
    (`target3:0:0_3:0:0:0`), which cannot be mapped to a physical disk. So the
    temperature here is not duplication; it is the same reading with a usable
    identity.
    """
    scan = run(["smartctl", "--scan"])
    scanned = 0
    read_ok = 0
    for line in scan.strip().splitlines():
        dev = line.split()[0] if line.split() else None
        if not dev:
            continue
        scanned += 1
        # -n standby: report without spinning up a sleeping disk.
        raw = run(["smartctl", "-j", "-n", "standby", "-A", "-i", "-H", dev], timeout=30)
        if not raw:
            continue
        try:
            d = json.loads(raw)
        except ValueError:
            continue
        serial = d.get("serial_number") or ""
        model = d.get("model_name") or ""
        if not serial:
            continue
        read_ok += 1
        lbl = dict(device=os.path.basename(dev), serial=serial, model=model)

        passed = d.get("smart_status", {}).get("passed")
        if passed is not None:
            out.metric("disk_smart_healthy", 1 if passed else 0,
                       "1 if SMART overall-health self-assessment passed.", **lbl)

        temp = (d.get("temperature") or {}).get("current")
        if temp is not None:
            out.metric("disk_temperature_celsius", temp,
                       "Drive temperature in celsius, keyed by serial.", **lbl)

        poh = (d.get("power_on_time") or {}).get("hours")
        if poh is not None:
            out.metric("disk_power_on_hours", poh, "Drive power-on hours.", **lbl)

        # The three attributes that actually predict a failing spinning disk.
        wanted = {5: "reallocated_sectors", 197: "pending_sectors", 198: "uncorrectable_sectors"}
        table = (d.get("ata_smart_attributes") or {}).get("table") or []
        for attr in table:
            key = wanted.get(attr.get("id"))
            if key:
                out.metric("disk_%s" % key, (attr.get("raw") or {}).get("value", 0),
                           "SMART attribute %d raw value." % attr["id"], **lbl)

    # THE CHECK THAT CAUGHT A REAL BUG. Run as a non-root user, smartctl prints
    # "Permission denied" on STDOUT and exits non-zero -- so run() saw output and
    # counted no error, json.loads() failed, and the loop `continue`d over every
    # disk. Result: zero SMART series and `truenas_textfile_collector_errors 0`,
    # i.e. a totally broken collector reporting itself perfectly healthy. That is
    # the same "converges clean, nothing works" shape as a garage bucket with no
    # key permission. Exporting scanned-vs-read makes the failure assertable:
    #   truenas_disk_smart_read_ok < truenas_disk_smart_scanned  ->  alert.
    out.metric("disk_smart_scanned", scanned,
               "Disks returned by `smartctl --scan`.")
    out.metric("disk_smart_read_ok", read_ok,
               "Disks whose SMART data was parsed successfully. Below _scanned means SMART is broken.")


def main():
    if len(sys.argv) != 2:
        sys.stderr.write("usage: %s <textfile-directory>\n" % sys.argv[0])
        return 2
    directory = sys.argv[1]
    started = time.time()

    out = Out()
    for fn in (collect_pools, collect_scrub, collect_datasets, collect_snapshots, collect_smart):
        try:
            fn(out)
        except Exception as exc:            # one broken collector must not lose the rest
            global errors
            errors += 1
            sys.stderr.write("collector %s failed: %s\n" % (fn.__name__, exc))

    # Staleness + failure guards. Without these a cron job that stops running
    # leaves the LAST GOOD FILE in place forever and every dashboard keeps
    # showing healthy, frozen values -- the worst possible failure shape.
    out.metric("textfile_collector_last_run_timestamp_seconds", int(started),
               "Unix time this collector last completed a run.")
    out.metric("textfile_collector_duration_seconds", round(time.time() - started, 3),
               "Seconds the last collector run took.")
    out.metric("textfile_collector_errors", errors,
               "Number of sub-commands that failed during the last run.")

    body = "\n".join(out.lines) + "\n"

    # Temp file in the SAME directory (os.replace is only atomic within a
    # filesystem) and WITHOUT a .prom suffix (node_exporter reads *.prom, so a
    # half-written file must not match that glob).
    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".truenas-", suffix=".tmp")
    try:
        with os.fdopen(fd, "w") as fh:
            fh.write(body)
        os.chmod(tmp, 0o644)
        os.replace(tmp, os.path.join(directory, "truenas.prom"))
    except Exception:
        if os.path.exists(tmp):
            os.unlink(tmp)
        raise
    return 0


if __name__ == "__main__":
    sys.exit(main())
