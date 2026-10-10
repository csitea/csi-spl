#!/usr/bin/env python3
"""db-maint.py - the arithmetic of csi-spl-orc do_spl_db_maint (spl-db-maint.func.sh).

estimate <raw>          raw facts.sql rows -> T|schema|table|live|dead|mod|heap_bytes|
                        total_bytes|bloat_pct|last_vacuum|last_autovacuum|last_analyze|
                        last_autoanalyze and I|schema|index|table|bytes|bloat_pct|valid|am|scans.
                        Bloat is an ESTIMATE: ideal pages from the sampled average width
                        against the pages the relation holds; empty when it cannot be
                        estimated (under 8 pages, nothing sampled, an expression or
                        non-btree index).
plan <facts>            KIND|schema|name|reason lines, thresholds from the MAINT_* env.
render <facts>          the report's snapshot tables (n and units in every header).
delta <before> <after>  the report's before -> after tables.
"""

import math, os, sys


def rows(path):
    with open(path) as f:
        return [l.rstrip("\n").split("|") for l in f if "|" in l]


def a8(n):
    return int(math.ceil(n / 8.0) * 8)


def pct(ideal, pages):
    return "%.1f" % max(0.0, 100.0 * (1 - float(ideal) / pages))


def estimate(path):
    raw = rows(path)
    tw = {
        (r[1], r[2]): (int(r[3]), float(r[4]))
        for r in raw
        if r[0] == "TW" and len(r) >= 5
    }
    iw = {
        (r[1], r[2]): (int(r[3]), float(r[4]))
        for r in raw
        if r[0] == "IW" and len(r) >= 5
    }
    for r in raw:
        if r[0] == "T" and len(r) >= 15:
            s, t, live, dead, mod, pages, _, heap, total, ff = r[1:11]
            b = ""
            n, w = tw.get((s, t), (0, 0))
            if int(pages) >= 8 and n > 0 and w > 0:
                per = max(1, int((8192 - 24) * int(ff) / 100 // (a8(w) + 4)))
                b = pct(max(1, math.ceil(int(live) / float(per))), int(pages))
            print("|".join(["T", s, t, live, dead, mod, heap, total, b] + r[11:15]))
        elif r[0] == "I" and len(r) >= 12:
            s, i, t, pages, tuples, size, valid, am, ff, expr, scans = r[1:12]
            b = ""
            n, w = iw.get((s, i), (0, 0))
            if (
                am == "btree"
                and valid == "t"
                and expr == "f"
                and int(pages) >= 8
                and int(tuples) > 0
                and n > 0
            ):
                per = max(1, int((8192 - 24 - 16) * int(ff) / 100 // (a8(8 + w) + 4)))
                b = pct(math.ceil(int(tuples) / float(per)) + 1, int(pages))
            print("|".join(["I", s, i, t, size, b, valid, am, scans]))


def env(name, default):
    return int(os.environ.get(name) or default)


def plan(path):
    dmin, dpct = env("MAINT_DEAD_MIN", 1000), env("MAINT_DEAD_PCT", 5)
    rpct, rmin = env("MAINT_REINDEX_PCT", 30), env("MAINT_REINDEX_MIN_MB", 1) << 20
    fpct, fmin = env("MAINT_FULL_PCT", 40), env("MAINT_FULL_MIN_MB", 8) << 20
    heavy = os.environ.get("MAINT_HEAVY", "0") == "1"
    fr = rows(path)
    full, out = set(), []
    for r in fr:
        if r[0] == "T" and r[8] and float(r[8]) >= fpct and int(r[6]) >= fmin:
            why = (
                "est. heap bloat %s%% of %.1f MB (>= %d%%, >= %d MB); ACCESS EXCLUSIVE lock"
                % (r[8], int(r[6]) / 1048576.0, fpct, fmin >> 20)
            )
            out.append(("FULL" if heavy else "HELD", r[1], r[2], why))
            if heavy:
                full.add((r[1], r[2]))
    vac = []
    for r in fr:
        if r[0] != "T" or (r[1], r[2]) in full:
            continue
        live, dead, mod = int(r[3]), int(r[4]), int(r[5])
        dp = 100.0 * dead / (live + dead) if live + dead else 0.0
        why = []
        if dead >= dmin and dp >= dpct:
            why.append(
                "dead %d rows = %.1f%% (>= %d, >= %d%%)" % (dead, dp, dmin, dpct)
            )
        if mod >= dmin and mod * 10 >= live:
            why.append("%d rows changed since the last analyze" % mod)
        if live >= dmin and not r[11] and not r[12]:
            why.append("%d rows never analyzed" % live)
        if why:
            vac.append(("VACUUM", r[1], r[2], "; ".join(why)))
    idx = []
    for r in fr:
        if r[0] != "I":
            continue
        if r[6] != "t":
            idx.append(
                (
                    "NOTE",
                    r[1],
                    r[2],
                    "INVALID index on %s (a failed CONCURRENTLY build?): not rebuilt here"
                    % r[3],
                )
            )
        elif (
            r[5]
            and float(r[5]) >= rpct
            and int(r[4]) >= rmin
            and (r[1], r[3]) not in full
        ):
            idx.append(
                (
                    "REINDEX",
                    r[1],
                    r[2],
                    "est. bloat %s%% of %.1f MB on %s (>= %d%%, >= %d MB)"
                    % (r[5], int(r[4]) / 1048576.0, r[3], rpct, rmin >> 20),
                )
            )
    for k in vac + idx + out:
        print("|".join(k))


def mb(b):
    return "%.2f" % (int(b) / 1048576.0)


def render(path):
    fr = rows(path)
    ts = [r for r in fr if r[0] == "T"]
    print(
        "tables n=%d (rows; MB; est. heap bloat %%, empty = not estimable; last times UTC)"
        % len(ts)
    )
    print(
        "%-28s %10s %9s %8s %9s %9s %7s  %-20s %-20s %-20s %-20s"
        % (
            "table",
            "live",
            "dead",
            "changed",
            "heap_MB",
            "total_MB",
            "bloat%",
            "last_vacuum",
            "last_autovacuum",
            "last_analyze",
            "last_autoanalyze",
        )
    )
    for r in ts:
        print(
            "%-28s %10s %9s %8s %9s %9s %7s  %-20s %-20s %-20s %-20s"
            % (
                r[2][:28],
                r[3],
                r[4],
                r[5],
                mb(r[6]),
                mb(r[7]),
                r[8] or "-",
                r[9] or "-",
                r[10] or "-",
                r[11] or "-",
                r[12] or "-",
            )
        )
    ix = [r for r in fr if r[0] == "I"]
    print()
    print("indexes n=%d (MB; est. btree bloat %%; scans since stats reset)" % len(ix))
    print(
        "%-40s %-24s %9s %7s %6s %12s"
        % ("index", "table", "MB", "bloat%", "valid", "scans")
    )
    for r in ix:
        print(
            "%-40s %-24s %9s %7s %6s %12s"
            % (r[2][:40], r[3][:24], mb(r[4]), r[5] or "-", r[6], r[8])
        )


def delta(bp, ap):
    b = {(r[0], r[1], r[2]): r for r in rows(bp)}
    a = {(r[0], r[1], r[2]): r for r in rows(ap)}
    keys = [k for k in b if k in a and k[0] == "T"]
    print(
        "tables n=%d (dead rows; MB total incl. indexes and toast; est. heap bloat %%)"
        % len(keys)
    )
    print(
        "%-28s %19s %21s %15s"
        % ("table", "dead before->after", "total MB before->after", "bloat% b->a")
    )
    sb = sa = db = da = 0
    for k in keys:
        x, y = b[k], a[k]
        sb += int(x[7])
        sa += int(y[7])
        db += int(x[4])
        da += int(y[4])
        print(
            "%-28s %9s->%-9s %10s->%-10s %7s->%-7s"
            % (k[2][:28], x[4], y[4], mb(x[7]), mb(y[7]), x[8] or "-", y[8] or "-")
        )
    print(
        "SUM n=%d tables: dead rows %d -> %d; total %s MB -> %s MB"
        % (len(keys), db, da, mb(sb), mb(sa))
    )
    ik = [k for k in b if k in a and k[0] == "I" and b[k][4] != a[k][4]]
    print()
    print("indexes whose size changed n=%d (MB; est. bloat %%)" % len(ik))
    for k in ik:
        print(
            "%-40s %9s->%-9s %7s->%-7s"
            % (k[2][:40], mb(b[k][4]), mb(a[k][4]), b[k][5] or "-", a[k][5] or "-")
        )


cmd = sys.argv[1]
if cmd == "estimate":
    estimate(sys.argv[2])
elif cmd == "plan":
    plan(sys.argv[2])
elif cmd == "render":
    render(sys.argv[2])
elif cmd == "delta":
    delta(sys.argv[2], sys.argv[3])
else:
    sys.exit("usage: estimate|plan|render|delta")
