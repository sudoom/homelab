#!/usr/bin/env python3
"""Verify one backend's completed 6x3 grid before trusting it or moving on.

WHY THIS EXISTS AS A SEPARATE STEP. run.sh already annotates each row as it is
produced, but it can only see ONE row at a time. Every defect that cost this
harness real time was only visible ACROSS rows:

  * the clients=2 run that read a partial file left by a killed clients=3 run
    looked fine on its own (127.1 MiB/s); it was impossible only next to the
    wire counter and the link rate.
  * the wire cross-check itself was the broken instrument for an entire
    session. A single row cannot tell "fio is lying" from "the checker is
    biased" -- but 18 rows can, because instrument bias is SYSTEMATIC and
    caching is not.

So this reads the whole grid and asks questions a single row cannot answer.
It prints findings; it never edits or deletes rows (history is preserved --
annotate, never drop).

Usage:  ./verify-backend.py nfs-csi [--tsv path] [--since YYYY-MM-DD]
Exit 0 = grid is trustworthy, 1 = something needs a human before proceeding.
"""
import argparse, collections, csv, sys

WORKLOADS = ["seq-read-1m", "seq-write-1m", "rand-read-4k", "rand-write-4k",
             "smallfile-write", "smallfile-read"]
CLIENTS = ["3", "2", "1"]

# Practical payload ceiling per link, in Mb/s of NFS payload -- DERIVED, not
# assumed, because assuming it is what made the harness's own SUSPECT
# annotations meaningless in both directions on 2026-09-05.
#
# Per frame: wire bytes = MTU + 14 (eth hdr) + 4 (FCS) + 8 (preamble) + 12 (IFG)
#            payload    = MTU - 20 (IPv4) - 32 (TCP + timestamps)
#
#   1 GbE, MTU 1500 (measured: `ip link show br-ex` on node4 = 1500):
#       1448 / 1538 * 1000 Mb/s = 941 Mb/s = 112.2 MiB/s
#   10 GbE, MTU 9000 (measured: enp1s0f0np0 = 9000, the storage backnet):
#       8948 / 9038 * 10000 Mb/s = 9900 Mb/s
#
# A row above this did not cross the wire, whatever fio believes. Note the
# Synology sits on the FRONTNET at MTU 1500 -- it does not get the backnet's
# jumbo frames, which is why the two ceilings are not simply 10x apart.
LINK_PAYLOAD_CEILING = {"home-router/nas": 941.0, "home-switch/TrueNAS": 9900.0}

def mbps(mib_s):
    """TSV 'MBps' columns actually hold MiB/s (parse-results.py: bytes/s -> KiB/s
    -> MiB/s), so the header is mislabelled. Convert honestly here rather than
    inherit the ambiguity -- run.sh's own annotation converts with 8 * 1.024 and
    lands ~2.4% LOW, which is most of why its verdicts cannot be trusted."""
    return float(mib_s) * 1024 * 1024 * 8 / 1e6

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("backend")
    ap.add_argument("--tsv", default="../../data/storage-benchmark-results.tsv")
    # Scoping by DATE is not enough: a whole 18-cell grid runs inside one day,
    # alongside every earlier attempt from the same day. run_id is
    # bench-YYYYmmdd-HHMMSS, so it sorts lexically and is the only cut that
    # separates "this grid" from "everything I tried before lunch".
    ap.add_argument("--since-run", default=None,
                    help="only consider rows with run_id >= this (e.g. bench-20260905-193943)")
    # A grid deliberately restricted to some workloads is not an incomplete grid.
    # Without this the TrueNAS bulk run -- which excludes smallfile on purpose,
    # because that design is still being proven on the Synology -- would report
    # six missing cells and a FAIL verdict every time, training the reader to
    # ignore the verdict. A gate nobody believes is worse than no gate.
    ap.add_argument("--workloads", default="all", choices=["all", "bulk", "smallfile"],
                    help="which workload set this grid was meant to cover (default all 6)")
    a = ap.parse_args()

    with open(a.tsv) as fh:
        rows = [r for r in csv.DictReader(fh, delimiter="\t") if r["backend"] == a.backend]
    if not rows:
        print(f"FAIL: no rows at all for backend {a.backend}")
        return 1

    since = a.since_run or "bench-00000000-000000"
    grid = [r for r in rows if r["run_id"] >= since]
    print(f"=== verifying {a.backend}: {len(grid)} rows with run_id >= {since} "
          f"({len(rows)-len(grid)} older rows ignored, NOT deleted) ===\n")

    problems, warnings = [], []

    # 1. COVERAGE. The point of a 6x3 grid is that every cell exists; a missing
    #    cell is indistinguishable from a cell that was never run.
    have = collections.defaultdict(list)
    for r in grid:
        have[(r["workload"], r["clients"])].append(r)
    want = {"all": WORKLOADS,
            "bulk": [w for w in WORKLOADS if not w.startswith("smallfile")],
            "smallfile": [w for w in WORKLOADS if w.startswith("smallfile")]}[a.workloads]
    missing = [f"{w}/c{c}" for w in want for c in CLIENTS if (w, c) not in have]
    dupes = [f"{k[0]}/c{k[1]}x{len(v)}" for k, v in have.items() if len(v) > 1]
    print(f"[coverage] {len(have)}/{len(want)*len(CLIENTS)} cells present "
          f"({a.workloads} workload set)")
    if missing:
        problems.append(f"missing cells: {', '.join(missing)}")
    if dupes:
        warnings.append(f"duplicate cells (newest wins downstream): {', '.join(dupes)}")

    # 2. THE MIKROTIK CROSS-CHECK -- the whole reason a switch column exists.
    #    Two distinct questions, and conflating them is what wasted a session:
    #      (a) is any row ABOVE the link's physical ceiling?  -> fio is wrong
    #      (b) is the fio/wire ratio biased the SAME WAY everywhere? -> the
    #          CHECKER is wrong, and no individual row is evidence of caching.
    print("\n[wire cross-check vs MikroTik counters]")
    ratios = []
    for r in grid:
        sw = r["switch_if"]
        if sw in ("-", ""):
            continue
        rd, wr = float(r["read_MBps"]), float(r["write_MBps"])
        payload = mbps(rd + wr)
        # reads pull FROM the device (router rx on that port), writes push TO it
        wire = float(r["sw_peak_rx_Mbps"] or 0) if rd >= wr else float(r["sw_peak_tx_Mbps"] or 0)
        # 2% tolerance, and it is not a fudge to make a row pass. This is a
        # GROSS-VIOLATION SCREEN -- it exists to catch the 1793 Mb/s class of
        # nonsense -- while both sides of the comparison carry ~1% uncertainty:
        # fio reports bandwidth to 0.1 MiB/s over a 60 s window, and the ceiling
        # assumes every frame is full-MTU. A hard inequality against a model
        # that imprecise turns a 0.4% overshoot into a failure. The AUTHORITATIVE
        # check is recheck-wire.py's byte-for-byte comparison against the switch
        # counter; this one is the coarse screen in front of it.
        ceiling = LINK_PAYLOAD_CEILING.get(sw)
        if ceiling and payload > ceiling * 1.02:
            problems.append(f"{r['workload']}/c{r['clients']}: fio payload {payload:.0f} Mb/s "
                            f"EXCEEDS the {sw} link ceiling {ceiling:.0f} Mb/s -- cannot have "
                            f"crossed the wire")
        if wire > 0:
            ratios.append((payload / wire, r))
    if ratios:
        vals = sorted(x[0] for x in ratios)
        med = vals[len(vals) // 2]
        print(f"  fio payload / wire ratio over {len(vals)} rows: "
              f"min {vals[0]:.2f}  median {med:.2f}  max {vals[-1]:.2f}")
        # A payload/wire ratio > 1 is impossible for a single row. If EVERY row
        # sits above 1, the counter window is reading low and the annotations
        # that blamed caching are wrong.
        above = [v for v in vals if v > 1.0]
        if len(above) == len(vals) and len(vals) >= 6:
            problems.append(f"ALL {len(vals)} rows report more payload than crossed the wire "
                            f"(median {med:.2f}x). That is systematic -- suspect the counter "
                            f"window (mktxp scrapes every 30s), not the storage.")
        elif above:
            warnings.append(f"{len(above)}/{len(vals)} rows exceed their wire figure "
                            f"(max {vals[-1]:.2f}x) -- check those individually")
    else:
        warnings.append("no usable wire figures -- the MikroTik cross-check did not run")

    # 3. SCALING. On shared storage, aggregate throughput must not FALL as
    #    clients are added; if it does, either the backend is thrashing or the
    #    higher-client run measured something else (a short file, a cache).
    print("\n[scaling with client count]")
    for w in WORKLOADS:
        pts = []
        for c in ("1", "2", "3"):
            for r in have.get((w, c), []):
                pts.append((c, float(r["read_MBps"]) + float(r["write_MBps"])))
        if len(pts) < 2:
            continue
        print("  %-16s %s" % (w, "  ".join(f"c{c}={v:.1f}" for c, v in pts)))
        vals = [v for _, v in pts]
        if vals[-1] < vals[0] * 0.9:
            warnings.append(f"{w}: aggregate FALLS from c1 to c3 "
                            f"({vals[0]:.1f} -> {vals[-1]:.1f} MB/s)")

    # 4. NODE SPREAD. A 3-client number means something different if the three
    #    clients shared a node: one NFS mount is one TCP flow, so same-node
    #    clients cannot show what LACP would.
    print("\n[node spread]")
    for r in grid:
        n = len(set(r["nodes"].split(",")))
        if int(r["clients"]) > 1 and n < int(r["clients"]):
            warnings.append(f"{r['workload']}/c{r['clients']}: only {n} distinct nodes -- "
                            f"clients shared a mount, so this is not a multi-flow measurement")
    print(f"  checked {len(grid)} rows")

    # 5. ANNOTATIONS. run.sh's own per-row verdicts.
    print("\n[per-row notes]")
    notes = collections.Counter(r["note"].split(":")[0] for r in grid)
    for k, v in notes.most_common():
        print(f"  {v:2d}  {k}")

    print("\n=== verdict ===")
    for w in warnings:
        print(f"  WARN  {w}")
    for p in problems:
        print(f"  FAIL  {p}")
    if problems:
        print(f"\nNOT CLEAR TO PROCEED: {len(problems)} blocking finding(s).")
        return 1
    print("\nCLEAR TO PROCEED" + (f" ({len(warnings)} warning(s) to read)" if warnings else ""))
    return 0

if __name__ == "__main__":
    sys.exit(main())
