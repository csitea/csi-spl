#!/usr/bin/env python3
"""latency-hops.py - the box-side hops of every poke, from the poke ledger.

spec 053 section 8 (SPL-6511). Reads <root>/*/lifetime/poke-ledger.tsv (and
its one rotated .1), never a message body, and prints one row per hop:
hop, n, p50, p90, max, in milliseconds.

Ledger row (tab-separated): event ts_ms to msg_id written_ms start_ms rc via
send_ms. `poke` rows are written by spool_notify_poke, `surfaced` and
`prompt` rows by spool-agent-hook.sh.

Usage: latency-hops.py <spool root> <hours> [<now epoch s>]
Exit 0 with a table (n may be 0), 2 on a usage error.
"""

import glob
import os
import sys

HOPS = (
    ("send script (start -> inbox file)", "send"),
    ("inbox file -> poke start (send)", "wait_send"),
    ("inbox file -> poke start (sidecar)", "wait_sidecar"),
    ("poke (start -> Enter)", "poke"),
    ("poke -> next prompt", "prompt"),
    ("inbox file -> seen, idle (UserPromptSubmit)", "seen_idle"),
    ("inbox file -> seen, busy (PostToolUse)", "seen_busy"),
)


def num(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return None


def rows(root, since_ms):
    out = []
    for p in sorted(glob.glob(os.path.join(root, "*", "lifetime", "poke-ledger.tsv*"))):
        if not (p.endswith(".tsv") or p.endswith(".tsv.1")):
            continue
        try:
            fh = open(p, encoding="utf-8", errors="replace")
        except OSError:
            continue
        with fh:
            for line in fh:
                f = line.rstrip("\n").split("\t")
                if len(f) < 8:
                    continue
                f += ["-"] * (9 - len(f))
                ts = num(f[1])
                if ts is None or ts < since_ms:
                    continue
                out.append(
                    {
                        "ev": f[0],
                        "ts": ts,
                        "to": f[2],
                        "id": f[3],
                        "written": num(f[4]),
                        "start": num(f[5]),
                        "rc": f[6],
                        "via": f[7],
                        "sent0": num(f[8]),
                    }
                )
    out.sort(key=lambda r: r["ts"])
    return out


def add(acc, key, a, b):
    if a is not None and b is not None and b >= a:
        acc[key].append(b - a)


def hops(rs):
    acc = {k: [] for _, k in HOPS}
    rcs = {}
    prompts = {}
    for r in rs:
        if r["ev"] == "prompt":
            prompts.setdefault(r["to"], []).append(r["ts"])
    seen = set()
    for r in rs:
        if r["ev"] == "poke":
            rcs[r["rc"]] = rcs.get(r["rc"], 0) + 1
            if r["via"] == "send":
                add(acc, "send", r["sent0"], r["written"])
            if r["via"] in ("send", "sidecar"):
                add(acc, "wait_" + r["via"], r["written"], r["start"])
            if r["rc"] != "0":
                continue
            add(acc, "poke", r["start"], r["ts"])
            nxt = [t for t in prompts.get(r["to"], ()) if t >= r["ts"]]
            if nxt:
                add(acc, "prompt", r["ts"], nxt[0])
        elif r["ev"] == "surfaced" and (r["to"], r["id"]) not in seen:
            seen.add((r["to"], r["id"]))
            key = {"UserPromptSubmit": "seen_idle", "PostToolUse": "seen_busy"}.get(
                r["via"]
            )
            if key:
                add(acc, key, r["written"], r["ts"])
    return acc, rcs


def pct(xs, p):
    # nearest rank: a p90 of a short sample is a sample, never interpolated
    s = sorted(xs)
    return s[max(0, -(-len(s) * p // 100) - 1)]


def table(acc, rcs, hours):
    print("hop\tn\tp50_ms\tp90_ms\tmax_ms")
    for label, key in HOPS:
        xs = acc[key]
        if xs:
            print(
                "%s\t%d\t%d\t%d\t%d"
                % (label, len(xs), pct(xs, 50), pct(xs, 90), max(xs))
            )
        else:
            print("%s\t0\t-\t-\t-" % label)
    order = sorted(rcs, key=lambda k: (num(k) is None, num(k) or 0, k))
    print(
        "poke rc (last %sh): %s"
        % (hours, ", ".join("rc %s n=%d" % (k, rcs[k]) for k in order) or "none")
    )


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    try:
        hours = float(argv[2])
        now = float(argv[3]) if len(argv) > 3 else None
    except ValueError:
        sys.stderr.write("latency-hops: <hours> and <now> are numbers\n")
        return 2
    if now is None:
        import time

        now = time.time()
    acc, rcs = hops(rows(argv[1], int((now - hours * 3600) * 1000)))
    table(acc, rcs, argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
