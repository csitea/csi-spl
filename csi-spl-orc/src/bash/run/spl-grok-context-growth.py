#!/usr/bin/env python3
"""Context size per model call, grok lanes vs claude lanes (SPL-2215).

  scan   SINCE_EPOCH HOME...  -> one JSON line per lane session touched since
                                 SINCE_EPOCH: {"v": vendor, "lane": id,
                                 "comp": compactions, "seq": [ctx per call]}
  report CAPS                 -> reads scan lines on stdin, prints markdown:
                                 call number -> median context, per vendor;
                                 then, for grok, the input tokens a cap at each
                                 of CAPS (comma list of tokens) would have cost

The context of a call is the tokens the model read for it:
  grok    updates.jsonl, the first `_meta.totalTokens` of each streamStartMs
          (one stream per model call: their count equals usage.json modelCalls)
  claude  a transcript's assistant rows, input + cache read + cache creation,
          once per message.id; subagent (sidechain) rows left out
Only numbers and lane ids leave `scan`: no prompt, no output, no path.

The cap model (report): a session's per-call growth is replayed; when the
context passes the cap the compaction call reads it once and the context drops
to P, the median post-compaction size grok itself produced in the same data.
At grok's own threshold (80% of 256000) it must reproduce the measured total
within a few %: that row is the model's control.
"""

import glob
import json
import os
import re
import statistics
import sys

DROP = 50000  # a fall this large between two calls is a compaction


def grok_sessions(home, since):
    for d in glob.glob(os.path.join(home, ".grok/sessions/*csi-spl-wt%2Fg-*/*/")):
        up = os.path.join(d, "updates.jsonl")
        try:
            if os.path.getmtime(up) < since:
                continue
            streams = {}
            with open(up, errors="replace") as f:
                for line in f:
                    try:
                        meta = json.loads(line).get("params", {}).get("_meta", {})
                    except ValueError:
                        continue
                    t, s = meta.get("totalTokens"), meta.get("streamStartMs")
                    if isinstance(t, int) and s is not None and s not in streams:
                        streams[s] = t
        except OSError:
            continue
        try:
            with open(os.path.join(d, "signals.json")) as f:
                comp = json.load(f).get("compactionCount", 0)
        except (OSError, ValueError):
            comp = 0
        m = re.search(r"wt%2F(g-[0-9]+)", d)
        seq = [streams[k] for k in sorted(streams)]
        if seq and m:
            yield {"v": "grok", "lane": m.group(1), "comp": comp, "seq": seq}


def claude_sessions(home, since):
    for p in glob.glob(os.path.join(home, ".claude/projects/*-wt-c-*/*.jsonl")):
        try:
            if os.path.getmtime(p) < since:
                continue
            seen, comp = {}, 0
            with open(p, errors="replace") as f:
                for line in f:
                    try:
                        o = json.loads(line)
                    except ValueError:
                        continue
                    if (
                        o.get("type") == "system"
                        and o.get("subtype") == "compact_boundary"
                    ):
                        comp += 1
                    m = o.get("message")
                    if (
                        o.get("type") != "assistant"
                        or o.get("isSidechain")
                        or not isinstance(m, dict)
                    ):
                        continue
                    u = m.get("usage")
                    if isinstance(u, dict) and m.get("id") not in seen:
                        seen[m.get("id")] = (
                            u.get("input_tokens", 0)
                            + u.get("cache_read_input_tokens", 0)
                            + u.get("cache_creation_input_tokens", 0)
                        )
        except OSError:
            continue
        m = re.search(r"-wt-(c-[0-9]+)", p)
        if seen and m:
            yield {
                "v": "claude",
                "lane": m.group(1),
                "comp": comp,
                "seq": list(seen.values()),
            }


def scan(since, homes):
    for h in homes:
        for s in list(grok_sessions(h, since)) + list(claude_sessions(h, since)):
            print(json.dumps(s))


def simulate(rows, cap, post):
    total = comps = 0
    for r in rows:
        s = r["seq"][1:]  # call 1 of a grok session is a small side call
        if not s:
            continue
        ctx = s[0]
        total += ctx
        for i in range(1, len(s)):
            d = s[i] - s[i - 1]
            ctx += 0 if d < -DROP else d
            if ctx > cap:
                total += ctx
                comps += 1
                ctx = post
            total += ctx
    return total, comps


def report(caps):
    rows = {"grok": [], "claude": []}
    for line in sys.stdin:
        try:
            r = json.loads(line)
        except ValueError:
            continue
        if r.get("v") in rows and len(r.get("seq", [])) >= 10:
            rows[r["v"]].append(r)
    med = lambda v: int(statistics.median(v)) if v else 0
    print("| call | grok n | grok median ctx | claude n | claude median ctx |")
    print("|---:|---:|---:|---:|---:|")
    for c in (1, 2, 10, 25, 50, 100, 150, 200, 300):
        g = [r["seq"][c - 1] for r in rows["grok"] if len(r["seq"]) >= c]
        k = [r["seq"][c - 1] for r in rows["claude"] if len(r["seq"]) >= c]
        print("| %d | %d | %d | %d | %d |" % (c, len(g), med(g), len(k), med(k)))
    print()
    print(
        "| vendor | sessions | calls/session median | input/session median | max ctx median | growth/call c10..c40 | sessions compacted |"
    )
    print("|---|---:|---:|---:|---:|---:|---:|")
    for v, rs in rows.items():
        sl = [(r["seq"][39] - r["seq"][9]) / 30 for r in rs if len(r["seq"]) >= 40]
        print(
            "| %s | %d | %d | %d | %d | %d (n=%d) | %d |"
            % (
                v,
                len(rs),
                med([len(r["seq"]) for r in rs]),
                med([sum(r["seq"]) for r in rs]),
                med([max(r["seq"]) for r in rs]),
                med(sl),
                len(sl),
                sum(1 for r in rs if r["comp"]),
            )
        )
    g = rows["grok"]
    drops = [b for r in g for a, b in zip(r["seq"][1:], r["seq"][2:]) if b < a - DROP]
    if not g:
        return
    post = med(drops) or 35000
    base = sum(sum(r["seq"][1:]) for r in g)
    print()
    print(
        "grok cap model: %d compactions seen, median context after one P=%d; measured input %d"
        % (len(drops), post, base)
    )
    print()
    print(
        "| cap (tokens) | % of 256000 | simulated grok input | vs measured | compactions |"
    )
    print("|---:|---:|---:|---:|---:|")
    for cap in caps:
        t, n = simulate(g, cap, post)
        print(
            "| %d | %d | %d | %+.1f%% | %d |"
            % (
                cap,
                round(100 * cap / 256000),
                t,
                100.0 * (t - base) / base if base else 0,
                n,
            )
        )


if __name__ == "__main__":
    if len(sys.argv) >= 3 and sys.argv[1] == "scan":
        scan(float(sys.argv[2]), sys.argv[3:])
    elif len(sys.argv) == 3 and sys.argv[1] == "report":
        report([int(x) for x in sys.argv[2].split(",") if x.strip()])
    else:
        sys.exit(
            "usage: spl-grok-context-growth.py scan SINCE_EPOCH HOME... | report CAPS"
        )
