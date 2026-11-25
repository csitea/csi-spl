#!/usr/bin/env python3
"""busy-wait-replay.py <spool root> [--time] -- READ-ONLY (SPL-6515, latency action 5).

How long a message waits for a BUSY claude agent's hook to show it, before
(PostToolUse only; else the next prompt, the poke queued behind the turn) and
after SPL-6515 (the first PreToolUse, PostToolUse or Stop after it), replayed
over every claude seat's real <id>/heartbeat.log (its last 200 hook events).

Default: message-weighted, the real arrivals (the UTC stamp that starts each
inbox/ and archive/ file name) that fell inside a turn (a UserPromptSubmit
followed by a Stop). --time: an arrival every second of every turn instead
(time-weighted: long tool runs dominate). Prints p50 / p90 / max and n.
It writes nothing; the timeline has 1 s resolution, so each arrival sits at
.5 s and a wait is +-0.5 s.
"""

import datetime, glob, json, os, re, sys

RX = re.compile(r"^(\d{8}T\d{6}Z)--")
HOOKS_AFTER = ("PreToolUse", "PostToolUse", "Stop")


def ep(s, f="%Y-%m-%dT%H:%M:%SZ"):
    return (
        datetime.datetime.strptime(s, f)
        .replace(tzinfo=datetime.timezone.utc)
        .timestamp()
    )


def timeline(d):
    ev = []
    for line in open(os.path.join(d, "heartbeat.log")):
        p = line.split()
        if len(p) >= 2:
            try:
                ev.append((ep(p[0]), p[1]))
            except ValueError:
                pass
    return ev


def arrivals(d):
    out = []
    for sub in ("inbox", "archive"):
        p = os.path.join(d, sub)
        for n in os.listdir(p) if os.path.isdir(p) else []:
            m = RX.match(n)
            if m:
                out.append(ep(m.group(1), "%Y%m%dT%H%M%SZ") + 0.5)
    return out


def turns(ev):
    """(i, j, k): UserPromptSubmit at i, its Stop at j, the next prompt at k or None."""
    i = 0
    while i < len(ev):
        if ev[i][1] != "UserPromptSubmit":
            i += 1
            continue
        j = next(
            (
                x
                for x in range(i + 1, len(ev))
                if ev[x][1]
                in ("Stop", "StopFailure", "UserPromptSubmit", "SessionStart")
            ),
            None,
        )
        if j is None:
            return
        if ev[j][1] == "Stop":
            yield (
                i,
                j,
                next(
                    (
                        x
                        for x in range(j + 1, len(ev))
                        if ev[x][1] == "UserPromptSubmit"
                    ),
                    None,
                ),
            )
        i = j


def waits(ev, i, j, k, t):
    post = [e[0] for e in ev[i + 1 : j + 1] if e[1] == "PostToolUse" and e[0] > t]
    before = post[0] if post else (ev[k][0] if k is not None else None)
    after = next(e[0] for e in ev[i + 1 : j + 1] if e[1] in HOOKS_AFTER and e[0] > t)
    return None if before is None else (before - t, after - t)


def main():
    root, by_time = sys.argv[1], "--time" in sys.argv[2:]
    B, A, seats = [], [], 0
    for lp in sorted(glob.glob(os.path.join(root, "*", "heartbeat.log"))):
        d = os.path.dirname(lp)
        try:
            if (
                json.load(open(os.path.join(d, "heartbeat.json"))).get("harness")
                != "claude"
            ):
                continue
        except (OSError, ValueError):
            continue
        ev = timeline(d)
        if not ev:
            continue
        seats += 1
        arr = None if by_time else arrivals(d)
        for i, j, k in turns(ev):
            ts = (
                [x for x in arr if ev[i][0] < x < ev[j][0]]
                if arr is not None
                else [ev[i][0] + 0.5 + n for n in range(int(ev[j][0] - ev[i][0]))]
            )
            for t in ts:
                w = waits(ev, i, j, k, t)
                if w:
                    B.append(w[0])
                    A.append(w[1])
    if not B:
        print("no busy arrivals in %s (%d claude seats)" % (root, seats))
        return

    def q(v, p):
        v = sorted(v)
        return v[min(len(v) - 1, int(p * len(v)))]

    print(
        "mode=%s claude_seats=%d"
        % ("time-weighted" if by_time else "message-weighted", seats)
    )
    for name, v in (
        ("before: PostToolUse, else the next prompt", B),
        ("after: PreToolUse | PostToolUse | Stop", A),
    ):
        print(
            "%s\tn=%d\tp50=%.1fs\tp90=%.1fs\tmax=%.1fs"
            % (name, len(v), q(v, 0.5), q(v, 0.9), max(v))
        )


main()
