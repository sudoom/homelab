#!/usr/bin/env python3
"""
Turn fio JSON into one result row, with its conditions attached.

WHY THIS EXISTS RATHER THAN READING fio's HUMAN TABLE: every wrong number in
this repo's history was a transcription or a relabelling, not a bad measurement
(see data/storage-throughput.md, "Corrections log"). A number that is parsed
from JSON by the same run that produced it cannot be transcribed wrong, and a
row that carries backend/workload/clients/nodes/date cannot be quoted later
without them.

Reads the concatenated logs of all client pods on stdin, extracts each
### FIO_JSON_BEGIN ... ### FIO_JSON_END block, and AGGREGATES:
  * bandwidth and IOPS are SUMMED across clients -- N clients doing 100 MB/s
    each is 300 MB/s of storage throughput, which is the thing being measured.
  * latency is taken as the WORST p99 across clients, not the mean. A mean p99
    hides the client that was starved, and on a shared backend that client is
    usually the interesting one.
"""
import argparse, json, os, re, sys
from datetime import date

AP = argparse.ArgumentParser()
for a in ("run-id", "backend", "storage-class", "layout", "workload",
          "clients", "nodes", "filesize", "runtime", "ioengine", "results"):
    AP.add_argument("--" + a, required=True)
# Switch-side cross-check. Optional and defaulted: a missing cross-check must
# never lose an otherwise-good result, and cephfs-hdd has no single port to
# watch (its traffic is node-to-node and would be double-counted).
for a in ("switch-if", "switch-rx-mbps", "switch-tx-mbps"):
    AP.add_argument("--" + a, default="")
args = AP.parse_args()

raw = sys.stdin.read()
blocks = re.findall(r"### FIO_JSON_BEGIN\s*(.*?)\s*### FIO_JSON_END", raw, re.S)
if not blocks:
    print("  no fio JSON found in pod logs -- nothing recorded", file=sys.stderr)
    sys.exit(0)

read_bw = write_bw = 0.0      # KiB/s, summed across clients
read_iops = write_iops = 0.0
lat_p99_ms = 0.0              # worst across clients
n_parsed = 0

for b in blocks:
    try:
        doc = json.loads(b)
    except json.JSONDecodeError as e:
        print("  skipping unparseable fio block: %s" % e, file=sys.stderr)
        continue
    n_parsed += 1
    for job in doc.get("jobs", []):
        for direction in ("read", "write"):
            d = job.get(direction, {})
            # bw_bytes, NOT bw: fio's `bw` is KiB/s by convention but that is a
            # convention, and a unit ambiguity in a throughput harness is
            # unacceptable. bw_bytes is bytes/s and cannot be misread.
            bw = float(d.get("bw_bytes", 0) or 0) / 1024.0   # bytes/s -> KiB/s
            iops = float(d.get("iops", 0) or 0)
            if direction == "read":
                read_bw += bw; read_iops += iops
            else:
                write_bw += bw; write_iops += iops
            # fio nests percentiles under clat_ns; keys are strings like "99.000000"
            pct = (d.get("clat_ns", {}) or {}).get("percentile", {}) or {}
            for k, v in pct.items():
                if k.startswith("99.0"):
                    lat_p99_ms = max(lat_p99_ms, float(v) / 1e6)

if n_parsed == 0:
    print("  no parseable fio JSON -- nothing recorded", file=sys.stderr)
    sys.exit(0)

if n_parsed != int(args.clients):
    # Do NOT silently record a 3-client row built from 2 clients' data -- that
    # is exactly the "real number, invented conditions" failure this whole
    # harness exists to prevent.
    print("  WARNING: expected %s client result blocks, parsed %d. Recording "
          "with clients=%d to keep the row honest."
          % (args.clients, n_parsed, n_parsed), file=sys.stderr)

to_mbps = lambda kib: round(kib / 1024.0, 1)   # KiB/s -> MiB/s

# Auto-annotate the failure modes we already know how to detect.
note = "ok"
if n_parsed != int(args.clients):
    note = "PARTIAL: %d of %s clients reported" % (n_parsed, args.clients)
if args.switch_rx_mbps or args.switch_tx_mbps:
    _wire = max([float(x) for x in (args.switch_rx_mbps, args.switch_tx_mbps) if x] or [0])
    _fio = (read_bw + write_bw) * 8 / 1000.0
    if _wire and _fio and _fio / _wire > 1.05:
        note = ("SUSPECT: fio ~%.0f Mb/s exceeds wire %.0f Mb/s by %.0f%%"
                % (_fio, _wire, (_fio/_wire - 1) * 100))

row = [
    args.run_id, date.today().isoformat(), args.backend, args.storage_class,
    args.layout, args.workload, str(n_parsed), args.nodes or "-",
    args.filesize, args.runtime, args.ioengine,
    f"{to_mbps(read_bw)}", f"{to_mbps(write_bw)}",
    f"{round(read_iops)}", f"{round(write_iops)}",
    f"{round(lat_p99_ms, 2)}",
    args.switch_if or "-", args.switch_rx_mbps or "-", args.switch_tx_mbps or "-",
    # NOTHING IS EVER DELETED FROM THIS FILE. A run that turns out not to be
    # quotable gets its reason written here instead -- deleting it destroys the
    # evidence of WHY, which is the only thing that stops the same mistake
    # being made again. Three rows were purged on 2026-09-05 and had to be
    # recovered from git; that is the practice this column replaces.
    note,
]

with open(args.results, "a") as fh:
    fh.write("\t".join(row) + "\n")

print("  %-16s read %8s MiB/s  write %8s MiB/s  riops %7s  wiops %7s  p99 %6s ms  (%d client%s on %s)"
      % (args.workload, row[11], row[12], row[13], row[14], row[15],
         n_parsed, "" if n_parsed == 1 else "s", args.nodes or "?"))

# Sanity-check fio against the wire. fio reports what the client believes it
# got; the switch reports what actually crossed. When they disagree materially
# the client is usually the one that is wrong -- a cache-served read looks fast
# to fio while the port shows nearly nothing.
if args.switch_rx_mbps or args.switch_tx_mbps:
    fio_mbps = (read_bw + write_bw) * 8 / 1000.0          # KiB/s -> ~Mb/s
    wire = max([float(x) for x in (args.switch_rx_mbps, args.switch_tx_mbps) if x] or [0])
    verdict = ""
    if wire and fio_mbps:
        ratio = fio_mbps / wire
        if ratio > 1.05:
            verdict = "  <-- fio CLAIMS MORE THAN CROSSED THE WIRE (cache?)"
        elif ratio < 0.5:
            verdict = "  (wire carried much more -- layout/other traffic in window)"
    print("                   wire %s peak rx %s / tx %s Mb/s vs fio ~%.0f Mb/s%s"
          % (args.switch_if, args.switch_rx_mbps or "-", args.switch_tx_mbps or "-",
             fio_mbps, verdict))
