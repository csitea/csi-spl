#!/usr/bin/env python3
"""Count what Mistral Vibe (m-) lanes pay for tool output and error loops.

    vibe-loop-cost.py [--since 2026-10-15T18] [--cap N] [--ratio 3.3] [SESSION_DIR...]

Reads vibe's unified session journals (default: every session under
~/.vibe/logs/session/unified started at or after --since). Per lane (the
session's working directory basename) it prints one markdown row:

- completions and their input / cached / output tokens, as vibe recorded them
- tool results, failed ones (a tool failure or a bash returncode != 0)
- error loops: the same failing tool with the same last error line 3+ times
- re-fed tokens: vibe resends the whole context on every completion, so a
  result of T tokens costs T again in each later completion until the input
  drops by half (a compaction). chars / --ratio estimates T (3.3 measured on
  these journals: input-token deltas against the result sizes, n=210).

--cap N replays the same journals as if every bash result had been capped at
N chars (the spool-output-cap hook, spool-install Y15) and prints the
re-fed tokens it removes. SPL-2217, csi-spl-doc/doc/md/vibe-output-cap.md.
"""

import argparse
import collections
import glob
import json
import os
import re
import sys

LOOP_MIN = 3
CAP_NOTE = 200  # the chars the hook's header line adds


def _norm(s):
    return re.sub(r"\s+", " ", s).strip()


def _last_line(text):
    try:
        j = json.loads(text)
    except ValueError:
        j = None
    out = (
        (j.get("stderr") or "") + "\n" + (j.get("stdout") or "")
        if isinstance(j, dict) and "returncode" in j
        else text
    )
    lines = [x for x in out.splitlines() if x.strip()]
    return re.sub(r"\d+", "N", lines[-1] if lines else "")[:120]


def _failed(m, text):
    if m.get("outcome") != "success":
        return True
    rc = (
        re.search(r'"returncode":\s*(-?\d+)', text) if m.get("name") == "bash" else None
    )
    return bool(rc and rc.group(1) != "0")


def read_session(d):
    """(lane, completion usages, tool results, segment end per completion)."""
    meta = json.load(open(os.path.join(d, "meta.json")))
    lane = os.path.basename(meta["environment"]["working_directory"])
    usage, results, pending = [], [], 0
    for f in sorted(glob.glob(os.path.join(d, "journal", "*.jsonl"))):
        for line in open(f):
            r = json.loads(line)
            p = r["payload"]
            if r["type"] == "action_intent" and p.get("kind") == "completion":
                ci = pending
                pending += 1
                for m in p["request"]["model_input"]["messages"]["messages"]:
                    if m["role"] != "tool":
                        continue
                    text = "".join(c.get("text", "") for c in m["content"])
                    results.append(
                        dict(
                            ci=ci,
                            name=m.get("name"),
                            chars=len(text),
                            fail=_failed(m, text),
                            sig=_last_line(text),
                        )
                    )
            elif r["type"] == "action_result":
                rr = p.get("result", {}).get("result", {})
                if isinstance(rr, dict) and "usage" in rr:
                    usage.append(rr["usage"])
    inp = [u.get("input_tokens", 0) for u in usage]
    seg, end = [0] * len(inp), len(inp)
    for i in range(len(inp) - 1, -1, -1):
        if i + 1 < len(inp) and inp[i + 1] < 0.5 * inp[i]:
            end = i + 1
        seg[i] = end
    return lane, usage, results, seg


def count(dirs, ratio, cap):
    rows = collections.OrderedDict()
    loops = []
    for d in dirs:
        try:
            lane, usage, results, seg = read_session(d)
        except (OSError, ValueError, KeyError) as e:
            print("skip %s: %s" % (d, e), file=sys.stderr)
            continue
        if not usage:
            continue
        R = rows.setdefault(lane, collections.Counter())
        R["sessions"] += 1
        R["completions"] += len(usage)
        R["input"] += sum(u.get("input_tokens", 0) for u in usage)
        R["cached"] += sum(u.get("cached_input_tokens", 0) for u in usage)
        R["output"] += sum(u.get("output_tokens", 0) for u in usage)
        R["results"] += len(results)
        groups = collections.defaultdict(list)
        for x in results:
            rides = max(seg[min(x["ci"], len(seg) - 1)] - x["ci"], 0)
            x["refeed"] = x["chars"] / ratio * rides
            R["refeed"] += x["refeed"]
            if x["name"] == "bash":
                R["refeed_bash"] += x["refeed"]
                if cap:
                    R["cap_saves"] += (
                        max(x["chars"] - (cap + CAP_NOTE), 0) / ratio * rides
                    )
            if x["fail"]:
                R["failed"] += 1
                R["refeed_fail"] += x["refeed"]
                groups[(x["name"], x["sig"])].append(x)
        for (name, sig), xs in groups.items():
            if len(xs) >= LOOP_MIN:
                R["loops"] += 1
                R["loop_calls"] += len(xs)
                R["loop_refeed"] += sum(x["refeed"] for x in xs)
                loops.append(
                    (lane, name, sig, len(xs), int(sum(x["refeed"] for x in xs)))
                )
    return rows, loops


def table(rows, cap):
    cols = [
        "sessions",
        "completions",
        "input",
        "cached",
        "output",
        "results",
        "failed",
        "loops",
        "loop_calls",
        "loop_refeed",
        "refeed_fail",
        "refeed_bash",
        "refeed",
    ]
    if cap:
        cols.append("cap_saves")
    out = ["| lane | " + " | ".join(cols) + " |", "|---" * (len(cols) + 1) + "|"]
    total = collections.Counter()
    for lane, R in list(rows.items()) + [("all", None)]:
        if R is None:
            R = total
        else:
            total.update(R)
        out.append(
            "| %s | %s |" % (lane, " | ".join("{:,}".format(int(R[c])) for c in cols))
        )
    return "\n".join(out), total


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("dirs", nargs="*")
    ap.add_argument("--since", default="")
    ap.add_argument("--cap", type=int, default=0)
    ap.add_argument("--ratio", type=float, default=3.3)
    ap.add_argument(
        "--root", default=os.path.expanduser("~/.vibe/logs/session/unified")
    )
    a = ap.parse_args(argv)
    dirs = a.dirs
    if not dirs:
        for m in sorted(glob.glob(os.path.join(a.root, "*", "meta.json"))):
            try:
                if json.load(open(m)).get("start_time", "") >= a.since:
                    dirs.append(os.path.dirname(m))
            except (OSError, ValueError):
                pass
    rows, loops = count(dirs, a.ratio, a.cap)
    text, total = table(rows, a.cap)
    print(text)
    if total["input"]:
        print(
            "\nre-fed tool results: %.1f%% of input; error loops: %.1f%%; bash results: %.1f%%"
            % (
                100 * total["refeed"] / total["input"],
                100 * total["loop_refeed"] / total["input"],
                100 * total["refeed_bash"] / total["input"],
            )
        )
        if a.cap:
            print(
                "a %d-char bash cap removes %.1f%% of input"
                % (a.cap, 100 * total["cap_saves"] / total["input"])
            )
    print("\nerror loops (lane, tool, last line, calls, re-fed tokens):")
    for x in sorted(loops, key=lambda t: -t[4])[:15]:
        print(
            "- %s | %s | %s | %d | %s" % (x[0], x[1], x[2], x[3], "{:,}".format(x[4]))
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
