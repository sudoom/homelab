#!/usr/bin/env python3
"""Recompute the switch cross-check from raw counters, and re-annotate the rows.

WHY THIS IS A SEPARATE PASS AND NOT A FIX TO run.sh.
run.sh's live cross-check is wrong in a way that cannot be repaired in place
after the fact -- but it does not have to be, because everything needed to redo
it properly is already recorded. Keeping the recompute separate means the grid
runs under ONE consistent (if flawed) annotation, and the correction is applied
to all rows at once, by code that can be read and re-run.

WHAT WAS WRONG WITH THE LIVE CHECK (2026-09-05):
  1. `increase(counter[span+30s]) * 8 / span` -- a range one size, a divisor
     another. mktxp only refreshes the counter every 30 s, so a 66 s fio window
     contains 2-3 real samples and Prometheus extrapolates across them. Measured
     error ran from 24% low to 14% HIGH: two rows recorded wire figures ABOVE
     1 GbE line rate (1139.2 and 1003.3 Mb/s), which is not a fast disk, it is
     an instrument reporting the impossible.
  2. fio's payload was compared against the switch's L2 bytes with no framing
     factor, and with a stray 1.024 in the unit conversion. Roughly 8% of error
     against a 5% SUSPECT threshold -- the check could not resolve the thing it
     was testing.

WHAT THIS DOES INSTEAD: compares TOTAL BYTES, not rates. Rates need a divisor
and the divisor was the bug. A counter delta between the sample before the fio
window and the sample after it is alignment-free; idle traffic on these ports
is ~0.1 Mb/s, so the 30 s of slack on each side contributes nothing.

  expected L2 bytes = fio payload bytes / FRAMING_EFFICIENCY
  ratio             = measured / expected

  ratio ~1.0   fio and the wire agree
  ratio <0.85  fio claims more than crossed the wire -- cached, or an aggregate
               summed across clients that did not run concurrently
  ratio >1.3   more crossed the wire than fio asked for -- other traffic on the
               port, or the window is wrong

It also re-derives client synchronisation from the harvested pod logs, because
an aggregate is only meaningful if the clients overlapped.

Usage:  ./recheck-wire.py --since-run bench-20260905-204... [--apply]
Without --apply it prints what it would write and changes nothing.
"""
import argparse, csv, glob, json, os, re, subprocess, sys
from pathlib import Path

# The default TSV path is resolved from THIS FILE, not the working directory.
# It was "../../data/..." until 2026-09-06, which silently required the caller to
# be standing in tests/storage-benchmark/. The unattended orchestrator was not,
# so both tools died on FileNotFoundError the instant a grid finished -- and
# because a verify failure is deliberately non-fatal in that chain, the run
# recorded "VERIFY FAIL" and moved on as though the gate had been applied and
# had an opinion. A gate that cannot find its input must not look like a gate
# that ran.
_DEFAULT_TSV = str(Path(__file__).resolve().parents[2] / "data" / "storage-benchmark-results.tsv")


# Defaults to a well-known in-repo directory (gitignored) rather than "" so
# that a caller who did not think about the environment still finds harvested
# logs. It was "" until 2026-09-06, which made the unattended chain's rechecks
# silently unable to find any epochs at all.
PODLOGS = os.environ.get(
    "BENCH_PODLOGS",
    str(Path(__file__).resolve().parents[2] / ".bench-podlogs"))
# MTU 1500 path (Synology, frontnet): payload 1448 B per 1538 B on the wire.
# MTU 9000 path (TrueNAS, storage backnet): 8948 B per 9038 B.
#
# This is DELIBERATELY pure Ethernet + IPv4 + TCP framing and nothing else. It
# is a first-principles constant, derived from a measured MTU, so it can be
# checked by hand. It does NOT model NFS RPC headers, the ACK stream sharing
# the direction, or retransmits -- which is why healthy rows land near 1.07x
# rather than 1.00x, consistently, across every workload measured on 2026-09-05.
# That offset is real protocol overhead sitting above the model, not drift.
# DO NOT tune these constants to make the ratio come out at 1.00: that is
# fitting the instrument to the data, and the whole reason this file exists is
# that the previous check had no independently-derived reference at all. The
# 0.85-1.30 band absorbs it; a row outside that band is saying something.
FRAMING = {"home-router/nas": 1448 / 1538, "home-switch/TrueNAS": 8948 / 9038,
           # A Ceph pool counter measures the storage layer directly, so there
           # is no Ethernet/IP/TCP framing between the payload and the counter:
           # expected == payload exactly, ratio 1.0 is the ideal.
           "cephpool/cephfs-bulk-hdd": 1.0}

# PORTS THAT CARRY TRAFFIC OTHER THAN THE BENCHMARK.
# The Synology's port was clean all evening -- zero PVCs remain on nfs-csi, so
# every byte on it was ours and the ratio landed at a tight 1.07-1.08x. The
# TrueNAS 10G port is NOT clean: it also serves the live media, immich and
# keepers NFS mounts, so an elevated ratio there can be someone watching
# something, not a measurement fault. Ratios on this port are reported with that
# caveat rather than scored, because the counter cannot tell our bytes from
# theirs and pretending otherwise would be exactly the false precision this file
# was written to remove.
SHARED_PORT = {"home-switch/TrueNAS"}

def promq(query, platform=False):
    """Query Prometheus. THE TWO INSTANCES HOLD DIFFERENT METRICS:
    mktxp_* (the MikroTik switch counters) is scraped by USER-WORKLOAD
    monitoring, ceph_pool_* (the mgr metrics) by the PLATFORM one. Querying the
    wrong one returns an empty result rather than an error, which reads exactly
    like "no traffic" -- so the cephpool cross-check silently did nothing when it
    first shipped."""
    ns, pod = ("openshift-user-workload-monitoring", "prometheus-user-workload-0")
    if platform:
        ns, pod = ("openshift-monitoring", "prometheus-k8s-0")
    cmd = ["oc", "-n", ns, "exec",
           pod, "-c", "prometheus", "--",
           "wget", "-qO-", "--post-data=query=" + query,
           "http://localhost:9090/api/v1/query"]
    try:
        out = subprocess.run(cmd, capture_output=True, timeout=60).stdout
        return json.loads(out)["data"]["result"]
    except Exception:
        return []

def counter_delta(rb, ifn, direction, a, b):
    """Exact counter delta over [a-45, b+45]. No rate(), no extrapolation."""
    if rb == "cephpool":
        # Ceph's own per-pool byte counters, for a backend no switch port can
        # isolate. rd == read out of the pool, wr == written into it.
        #
        # NOTE the @ modifier binds to a SELECTOR, never to a parenthesised
        # binary expression -- "(expr) @ t" returns an empty vector with no
        # error, so a join written that way silently yields no cross-check at
        # all rather than failing loudly.
        metric = "ceph_pool_rd_bytes" if direction == "rx" else "ceph_pool_wr_bytes"
        j = f'on(pool_id) group_left ceph_pool_metadata{{name="{ifn}"}}'
        # Padded like the mktxp path: the counter is scraped every 15s and the
        # mgr's pool stats lag the client ack, so an exact window truncates real
        # bytes. Verified not to launder a bad row -- a cache-served read
        # plateaus at 0.176 however wide the window gets.
        lo = promq(f"{metric} @ {a-45} * {j} @ {a-45}", platform=True)
        hi = promq(f"{metric} @ {b+45} * {j} @ {b+45}", platform=True)
        if not lo or not hi:
            return None
        return float(hi[0]["value"][1]) - float(lo[0]["value"][1])
    m = f'mktxp_interface_{direction}_byte_total{{routerboard_name="{rb}",name="{ifn}"}}'
    lo = promq(f"{m} @ {a-45}")
    hi = promq(f"{m} @ {b+45}")
    if not lo or not hi:
        return None
    return float(hi[0]["value"][1]) - float(lo[0]["value"][1])

def client_sync(run_id, workload):
    """(spread_s, overlap_frac, n) from harvested pod logs, or None."""
    wins = []
    for f in glob.glob(os.path.join(PODLOGS, f"{run_id}-{workload}-*.log")):
        txt = open(f, errors="ignore").read()
        s = re.search(r"FIO_START_EPOCH (\d+)", txt)
        e = re.search(r"FIO_END_EPOCH (\d+)", txt)
        if s and e:
            wins.append((int(s.group(1)), int(e.group(1))))
    if not wins:
        return None
    starts = [w[0] for w in wins]
    ends = [w[1] for w in wins]
    # overlap of ALL windows / mean window length
    inter = max(0, min(ends) - max(starts))
    mean_len = sum(e - s for s, e in wins) / len(wins)
    return (max(starts) - min(starts), inter / mean_len if mean_len else 0, len(wins))

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tsv", default=_DEFAULT_TSV)
    ap.add_argument("--since-run", required=True)
    ap.add_argument("--apply", action="store_true")
    a = ap.parse_args()

    with open(a.tsv) as fh:
        head = fh.readline().rstrip("\n").split("\t")
        rows = [dict(zip(head, l.rstrip("\n").split("\t"))) for l in fh if l.strip()]

    changed = 0
    skipped_no_epochs = 0
    skipped_no_counter = 0
    for r in rows:
        if r["run_id"] < a.since_run or r["switch_if"] in ("-", ""):
            continue
        rb, ifn = r["switch_if"].split("/", 1)
        sync = client_sync(r["run_id"], r["workload"])
        rd, wr = float(r["read_MBps"]), float(r["write_MBps"])
        direction = "rx" if rd >= wr else "tx"
        payload_bytes = (rd + wr) * 1024 * 1024 * float(r["runtime_s"])
        eff = FRAMING.get(r["switch_if"], 0.94)
        expected = payload_bytes / eff

        note, verdict = r["note"], "?"
        if sync is None:
            # LEAVE THE ROW ALONE. Not being able to re-check is a fact about
            # this tool's inputs, not about the measurement, and it must never
            # replace a verdict that run.sh produced live from epochs it
            # actually had.
            #
            # This branch used to write "NO EPOCHS: ... wire recheck impossible"
            # into the note column. On 2026-09-06 it overwrote 13 good verdicts
            # -- twelve `ok`/`SUSPECT` results from the idle-window re-take plus
            # one from the bench16 A/B -- with that string, destroying the
            # annotations of a grid that had just cost an operator three
            # services being offline. The wire columns survived and the notes
            # were restored from the driver log, but only because the driver
            # happened to log them.
            #
            # Same species as the cwd-relative --tsv default fixed the same day:
            # a check reporting on data it never read. Skipping is the only
            # correct behaviour; a tool with no input has no opinion.
            skipped_no_epochs += 1
            continue
        else:
            spread, overlap, n = sync
            if n < int(r["clients"]):
                verdict = f"PARTIAL EPOCHS: {n}/{r['clients']} client logs"
            elif overlap < 0.8:
                verdict = (f"INVALID AGGREGATE: clients overlapped only "
                           f"{overlap*100:.0f}% (start spread {spread}s); summed "
                           f"bandwidth across non-concurrent runs")
            else:
                # windows are aligned, so the union is the measurement window
                lo = min(int(re.search(r"FIO_START_EPOCH (\d+)", open(f, errors='ignore').read()).group(1))
                         for f in glob.glob(os.path.join(PODLOGS, f"{r['run_id']}-{r['workload']}-*.log")))
                hi = max(int(re.search(r"FIO_END_EPOCH (\d+)", open(f, errors='ignore').read()).group(1))
                         for f in glob.glob(os.path.join(PODLOGS, f"{r['run_id']}-{r['workload']}-*.log")))
                meas = counter_delta(rb, ifn, direction, lo, hi)
                if meas is None:
                    # Same rule as the NO EPOCHS branch above: a tool that could
                    # not read the counter has no opinion about the measurement,
                    # and must not overwrite the verdict that did.
                    skipped_no_counter += 1
                    continue
                else:
                    ratio = meas / expected if expected else 0
                    # THE UPPER BOUND ONLY MEANS SOMETHING FOR LARGE-BLOCK IO.
                    # FRAMING models Ethernet/IP/TCP per MTU-sized frame, which is
                    # a good approximation at bs=1M (few headers per byte) and a
                    # bad one at bs=4k, where every operation is a small request
                    # packet plus an NFS/RPC-wrapped reply and the per-op overhead
                    # is a large fraction of the payload. Measured 2026-09-05: 1M
                    # workloads land at 1.07-1.08x, 4k workloads at 1.1-2.0x. That
                    # spread is protocol cost, not a measurement fault, and
                    # flagging it as NOISY (as the first version did) mislabels
                    # good rows.
                    #
                    # The direction that is ALWAYS diagnostic is the low one:
                    # fewer bytes crossing the wire than fio claims to have moved
                    # is physically impossible and means the number came from a
                    # cache or from summing clients that never ran together.
                    big_block = "-1m" in r["workload"]
                    if ratio < 0.85:
                        verdict = (f"SUSPECT: only {ratio:.2f}x of the expected bytes crossed "
                                   f"{r['switch_if']} ({meas/1e9:.2f} GB vs {expected/1e9:.2f} GB)")
                    elif big_block and ratio > 1.3:
                        verdict = (f"NOISY: {ratio:.2f}x expected bytes on {r['switch_if']} at bs=1M -- "
                                   f"unrelated traffic or a bad window")
                    elif r["switch_if"] in SHARED_PORT and ratio > 1.5:
                        # NOT "ok". The first version of this branch appended a
                        # caveat to an `ok` verdict, which meant a row whose port
                        # carried 259.95x the expected bytes was recorded as
                        # PASSING. That is the "gate nobody believes" failure,
                        # self-inflicted one commit after warning about it.
                        #
                        # A shared port cannot isolate this run's bytes from the
                        # media/immich/keepers NFS traffic beside them. When the
                        # excess is small the cross-check still bounds things
                        # usefully; when it is 3x or 260x it bounds nothing, and
                        # the honest verdict is that the fio figure stands
                        # UNCORROBORATED -- not that it was checked and passed.
                        # This bites hardest on rand-*, where the payload is
                        # ~1 MB/s and any background traffic dwarfs it.
                        verdict = (f"UNCORROBORATED: {ratio:.2f}x expected bytes on shared port "
                                   f"{r['switch_if']}; fio figure stands but the wire cannot "
                                   f"confirm it (sync {overlap*100:.0f}%)")
                    elif ratio > 3.0:
                        # THE GENERAL UPPER BOUND, and its absence is why this
                        # ladder wrote "ok (wire 99.42x expected)" on a cephfs
                        # rand-write row -- a passing verdict on a counter
                        # showing ninety-nine times the workload's bytes. The
                        # three branches above cover: too FEW bytes (any
                        # workload), too many at bs=1M, and too many on a port
                        # known to be shared. A small-block workload on a
                        # dedicated instrument fell through every one of them.
                        #
                        # The same hole was fixed in parse-results.py earlier the
                        # same day and NOT looked for here -- an instance
                        # patched instead of a class. That is the actual lesson.
                        #
                        # 3x, not 1.3x: small-block workloads legitimately run
                        # 1.1-2.0x over payload because per-operation protocol
                        # overhead is a large fraction of a 4k request. Above 3x
                        # the window is measuring another workload -- usually
                        # this cell's own corpus layout, which is a write and so
                        # lands on the counter a write workload reads.
                        verdict = (f"UNCORROBORATED: {ratio:.2f}x expected bytes on "
                                   f"{r['switch_if']} ({meas/1e9:.2f} GB vs {expected/1e9:.2f} GB "
                                   f"expected) -- the window is measuring more than this run, "
                                   f"most likely its own corpus layout. fio figure stands; the "
                                   f"cross-check does not confirm it (sync {overlap*100:.0f}%)")
                    else:
                        verdict = f"ok (wire {ratio:.2f}x expected, sync {overlap*100:.0f}%)"
                    # REWRITE THE WIRE COLUMNS TOO, not just the note. They were
                    # written by the live check, which this file exists because it
                    # is wrong -- leaving them in place means every later reader
                    # (verify-backend.py included) scores against numbers already
                    # known to be bad, two of which exceeded 1 GbE line rate. The
                    # superseded figure is carried into the note so the correction
                    # is auditable rather than silent.
                    win = hi - lo
                    corrected = meas * 8 / win / 1e6 if win > 0 else 0
                    col = "sw_peak_rx_Mbps" if direction == "rx" else "sw_peak_tx_Mbps"
                    old_wire = r[col]
                    r[col] = f"{corrected:.1f}"
                    verdict += f"; wire recomputed {old_wire}->{corrected:.1f} Mb/s"
        if verdict != note:
            print(f"{r['run_id']} {r['workload']:<16} c{r['clients']}")
            print(f"    was: {note}")
            print(f"    now: {verdict}")
            r["note"] = verdict
            changed += 1

    if skipped_no_counter:
        print(f"\nNOTE: {skipped_no_counter} row(s) LEFT UNCHANGED -- counter series unavailable")
        print(f"      for their window. Their existing verdicts stand.")
    if skipped_no_epochs:
        print(f"\nNOTE: {skipped_no_epochs} row(s) LEFT UNCHANGED -- no harvested pod logs found in")
        print(f"      {PODLOGS}")
        print(f"      Their wire figures stay as run.sh's live in-run estimate, which quantises")
        print(f"      badly on low-rate cells. Start the harvester BEFORE a grid to get a real")
        print(f"      counter-delta recheck; there is no way to recover the epochs afterwards.")
    print(f"\n{changed} row(s) re-annotated" + ("" if a.apply else " (dry run; pass --apply to write)"))
    if a.apply and changed:
        with open(a.tsv, "w") as fh:
            w = csv.DictWriter(fh, fieldnames=head, delimiter="\t", lineterminator="\n")
            w.writeheader()
            w.writerows(rows)
        print(f"wrote {a.tsv}")
    return 0

if __name__ == "__main__":
    sys.exit(main())
