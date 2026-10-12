#!/usr/bin/env python3
"""Spec 133's eight CI axes (X1..X8) from the runs and the cached jobs and
annotations that do_report_ci_axes fetched (report-ci-axes.func.sh says what
each axis measures). Usage: ci-axes.py <tmp> <cache> <since> <until>.
"""

import json, os, sys
from datetime import datetime

tmp, cache, since, until = sys.argv[1:5]
ts = lambda s: (
    datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() if s else None
)
mins = lambda a, b: (b - a) / 60.0


def pct(a, p):
    a = sorted(a)
    if not a:
        return float("nan")
    k = (len(a) - 1) * p
    f = int(k)
    c = min(f + 1, len(a) - 1)
    return a[f] + (a[c] - a[f]) * (k - f)


runs = [json.loads(l) for l in open(os.path.join(tmp, "runs.jsonl")) if l.strip()]
t0, t1 = ts(since), ts(until)
inwin = [r for r in runs if t0 <= ts(r["created_at"]) <= t1]
verdict = lambda r: (
    r.get("status") == "completed" and r.get("conclusion") in ("success", "failure")
)


def jobs(rid):
    p = os.path.join(cache, "jobs-%s.json" % rid)
    if not os.path.isfile(p):
        return None
    return [json.loads(l) for l in open(p) if l.strip()]


def ann(jid):
    p = os.path.join(cache, "ann-%s.json" % jid)
    try:
        return json.load(open(p))
    except Exception:
        return []


conc = {}
for r in inwin:
    k = r.get("conclusion") or "running"
    conc[k] = conc.get(k, 0) + 1
newest = max(inwin, key=lambda r: r["created_at"])
print(
    "   runs %d: %s; newest head %s"
    % (
        len(inwin),
        ", ".join("%s %d" % kv for kv in sorted(conc.items())),
        newest["head_sha"][:9],
    )
)

# X1 push to verdict: a verdict created after UNTIL still answers a push inside
allv = sorted((ts(r["created_at"]), ts(r["updated_at"])) for r in runs if verdict(r))
ptv, nov = [], 0
for r in inwin:
    if r.get("event") != "push":
        continue
    c = ts(r["created_at"])
    ends = [u for (cc, u) in allv if cc >= c]
    if ends:
        ptv.append(mins(c, min(ends)))
    else:
        nov += 1
print(
    "X1 push to verdict      p50 %.1f / p90 %.1f min (n=%d pushes, %d with no verdict yet)   target p50 <= 30, p90 <= 60"
    % (pct(ptv, 0.5), pct(ptv, 0.9), len(ptv), nov)
)

# X2 red minutes per day, X3 verdicts green
vw = sorted((ts(r["updated_at"]), r["conclusion"]) for r in inwin if verdict(r))
red = 0.0
for i, (u, c) in enumerate(vw):
    end = vw[i + 1][0] if i + 1 < len(vw) else t1
    if c == "failure":
        red += mins(u, max(u, min(end, t1)))
span = mins(vw[0][0], t1) if vw else 0
if span > 0:
    print(
        "X2 red minutes per day  %.0f min/day = %.0f%% of %.1f h (n=%d verdicts)   target <= 120"
        % (red / span * 1440, 100 * red / span, span / 60, len(vw))
    )
else:
    print("X2 red minutes per day  n/a (no verdict in the window)")
ng = sum(1 for _, c in vw if c == "success")
print(
    "X3 verdicts green       %s (%d of %d)   target >= 80%%"
    % ("%.0f%%" % (100.0 * ng / len(vw)) if vw else "n/a", ng, len(vw))
)

# X4, X6 critical path (seat A); X5 job-minutes per completed run
onp, qp, jm = [], [], []
for r in inwin:
    if not verdict(r):
        continue
    js = jobs(r["id"])
    if not js:
        continue
    js = [
        j
        for j in js
        if j.get("started_at")
        and j.get("completed_at")
        and j.get("conclusion") != "skipped"
    ]
    if not js:
        continue
    jm.append(sum(mins(ts(j["started_at"]), ts(j["completed_at"])) for j in js))
    by = lambda s: [j for j in js if s in j["name"]]
    body = [j for j in js if "gate health" not in j["name"]]
    if not body:
        continue
    cj = max(body, key=lambda j: ts(j["completed_at"]))
    chain = by("classify")[:1]
    if "e2e" in cj["name"]:
        chain += by("nuxt generate")
    if cj not in chain:
        chain.append(cj)
    chain += by("gate health")[:1]
    qp.append(sum(mins(ts(j["created_at"]), ts(j["started_at"])) for j in chain))
    onp.append(sum(mins(ts(j["started_at"]), ts(j["completed_at"])) for j in chain))
print(
    "X4 critical-path run    p50 %.1f min (n=%d completed runs with jobs)   target <= 20"
    % (pct(onp, 0.5), len(onp))
)
print(
    "X5 job-minutes per run  median %.1f (n=%d)   target <= 60"
    % (pct(jm, 0.5), len(jm))
)
print(
    "X6 queue on the path    p90 %.1f min (n=%d)   target <= 3"
    % (pct(qp, 0.9), len(qp))
)

# X7 timeout headroom: nearest-rank p90, as do_report_ci_gate's headroom block
tos = []
for l in open(os.path.join(tmp, "timeouts.tsv")):
    p = l.rstrip("\n").split("\t")
    if len(p) == 2:
        tos.append((p[0], int(p[1])))


def tmo(name):
    for pat, t in tos:
        i = pat.find("${{")
        if i < 0:
            if name == pat:
                return t
            continue
        pre, rest = pat[:i], pat[pat.find("}}") + 2 :]
        if (
            name.startswith(pre)
            and name.endswith(rest)
            and len(name) >= len(pre) + len(rest)
        ):
            return t
    return 0


walls = {}
for r in inwin:
    if not verdict(r):
        continue
    for j in jobs(r["id"]) or []:
        if (
            j.get("started_at")
            and j.get("completed_at")
            and j.get("conclusion") in ("success", "failure")
        ):
            walls.setdefault(j["name"], []).append(
                ts(j["completed_at"]) - ts(j["started_at"])
            )
risk, known = [], 0
for name, w in sorted(walls.items()):
    t = tmo(name)
    if not t:
        continue
    known += 1
    w = sorted(w)
    p90 = w[int((len(w) * 9 + 9) / 10) - 1]
    if p90 * 100 > t * 75:
        risk.append("%s %d%%" % (name, p90 * 100 / t))
print(
    "X7 jobs at timeout risk %d of %d%s   target 0"
    % (len(risk), known, (" (" + "; ".join(risk) + ")") if risk else "")
)

# X8 first reds on a suite pre-push cannot run (seat B's rule); guard: non-code reds
NOLOCAL = ("browser e2e", "nuxt generate", "feature tests")
rows = nol = 0
nfail = covered = noncode = 0
for r in inwin:
    if not (verdict(r) and r["conclusion"] == "failure"):
        continue
    nfail += 1
    js = jobs(r["id"])
    if js is None:
        continue
    covered += 1
    kinds = []
    for j in js:
        if j.get("conclusion") not in ("failure", "cancelled"):
            continue
        msgs = ann(j["id"])
        if any("gate fail-fast: stopped" in m for m in msgs):
            continue
        if any("exceeded the maximum execution time" in m for m in msgs):
            kind = "timeout"
        elif any("lost communication with the server" in m for m in msgs):
            kind = "runner-lost"
        elif j["conclusion"] == "failure":
            kind = "failure"
        else:
            continue
        kinds.append(kind)
        rows += 1
        if any(s in j["name"] for s in NOLOCAL):
            nol += 1
    if kinds and all(k != "failure" for k in kinds):
        noncode += 1
print(
    "X8 reds with no local gate %s (%d of %d first-red rows, %d of %d failure runs read)   target <= 10%%"
    % ("%.0f%%" % (100.0 * nol / rows) if rows else "n/a", nol, rows, covered, nfail)
)
print(
    "   guard: red verdicts whose first reds are all timeout / runner-lost: %d of %d   target < 2%%"
    % (noncode, covered)
)
