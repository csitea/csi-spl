#!/usr/bin/env python3
"""Rebuild the Cloud Monitoring alert incidents of a window from the metrics.

Cloud Monitoring has no public API that lists incidents (GET
v3/projects/<p>/incidents answers 404 "Method not found", measured
2026-10-22) and writes no log entry per incident. So do_gcp_list_alert_incidents
REPLAYS each alert policy: it reads the time series of every threshold
condition with the condition's own filter and aggregation, and this script
finds where the condition held for its duration. One run of violating points
is one incident: Cloud Monitoring opens one when a condition starts to hold
and closes it when it stops.

  plan <policies.json> <dir>
      writes <dir>/q<N>.curl (a curl -K config: the timeSeries query of one
      condition, without the interval) and prints one line per query: N
  report <policies.json> <dir> <since> <until>
      reads <dir>/q<N>.p<M>.json (the pages of query N) and prints the table
      (type, count, first, last, series read, resource), then one line per
      incident. SERIES 0 means the metric had no data in the window: that
      reads "nothing to replay", never "no incident proven".
"""

import datetime
import glob
import json
import os
import re
import sys

CMP = {
    "COMPARISON_GT": lambda v, t: v > t,
    "COMPARISON_GE": lambda v, t: v >= t,
    "COMPARISON_LT": lambda v, t: v < t,
    "COMPARISON_LE": lambda v, t: v <= t,
    "COMPARISON_EQ": lambda v, t: v == t,
    "COMPARISON_NE": lambda v, t: v != t,
}


def seconds(s, default=0):
    """'60s' or '60.5s' -> 60; '' -> default."""
    m = re.match(r"^([0-9.]+)s$", s or "")
    return int(float(m.group(1))) if m else default


def ts(s):
    s = re.sub(r"\.[0-9]+Z$", "Z", s)
    return datetime.datetime.strptime(s, "%Y-%m-%dT%H:%M:%SZ").replace(
        tzinfo=datetime.timezone.utc
    )


def hm(t):
    return t.strftime("%Y-%m-%dT%H:%MZ")


def conditions(policies):
    """[(N, policy name, conditionThreshold)] for each threshold condition of an
    enabled policy, and [(policy name, kind)] for each one this replay cannot read."""
    out, skipped = [], []
    for p in policies:
        if p.get("enabled") is False:
            continue
        for c in p.get("conditions", []):
            th = c.get("conditionThreshold")
            if th is None or "denominatorFilter" in th:
                kind = next((k for k in c if k.startswith("condition")), "?")
                skipped.append((p.get("displayName", "?"), kind))
                continue
            out.append((len(out), p.get("displayName", "?"), th))
    return out, skipped


def curl_quote(s):
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def plan(policies, d):
    conds, _ = conditions(policies)
    for n, _, th in conds:
        agg = (th.get("aggregations") or [{}])[0]
        args = [("filter", th.get("filter", ""))]
        for k in ("alignmentPeriod", "perSeriesAligner", "crossSeriesReducer"):
            if agg.get(k):
                args.append(("aggregation." + k, agg[k]))
        for g in agg.get("groupByFields", []):
            args.append(("aggregation.groupByFields", g))
        with open(os.path.join(d, "q%d.curl" % n), "w") as f:
            for k, v in args:
                f.write("data-urlencode = %s\n" % curl_quote("%s=%s" % (k, v)))
        print(n)


def point_value(p):
    v = p.get("value", {})
    for k in ("doubleValue", "int64Value"):
        if k in v:
            return float(v[k])
    if "boolValue" in v:
        return 1.0 if v["boolValue"] else 0.0
    return None


def resource_of(series, flt):
    """What fired: the labels left on the series (its group-by), else the
    resource labels the condition's filter pins."""
    labels = {}
    labels.update(series.get("resource", {}).get("labels", {}))
    labels.update(series.get("metric", {}).get("labels", {}))
    labels.pop("project_id", None)
    if labels:
        return ",".join("%s=%s" % kv for kv in sorted(labels.items()))
    pinned = re.findall(r'resource\.labels?\.([a-z_]+)\s*=\s*"([^"]*)"', flt)
    pinned += re.findall(r'metric\.labels?\.(check_id)\s*=\s*"([^"]*)"', flt)
    return ",".join("%s=%s" % kv for kv in pinned) or series.get("resource", {}).get(
        "type", "?"
    )


def runs(points, period, duration, holds, worse):
    """[(open, last, peak)]: each run of violating aligned points that held for
    at least <duration>; it opens <duration> after its first point. Points are
    (end time, value) in any order. A gap of more than one period ends a run:
    no data is not a violation."""
    out, cur = [], None
    for t, v in sorted(points):
        if v is not None and holds(v):
            if cur and (t - cur[1]).total_seconds() <= period:
                cur = [cur[0], t, worse(cur[2], v)]
                continue
            if cur:
                out.append(cur)
            cur = [t, t, v]
        elif cur:
            out.append(cur)
            cur = None
    if cur:
        out.append(cur)
    return [
        (s + datetime.timedelta(seconds=duration), e, pk)
        for s, e, pk in out
        if (e - s).total_seconds() >= duration
    ]


def read_pages(d, n):
    series, errors = [], []
    for f in sorted(glob.glob(os.path.join(d, "q%d.p*.json" % n))):
        try:
            with open(f) as fh:
                page = json.load(fh)
        except ValueError as e:
            errors.append("unreadable %s: %s" % (os.path.basename(f), e))
            continue
        if "error" in page:
            errors.append(page["error"].get("message", str(page["error"])))
        series.extend(page.get("timeSeries", []))
    return series, errors


def replay(n, name, th, d, rows, detail):
    agg = (th.get("aggregations") or [{}])[0]
    period = seconds(agg.get("alignmentPeriod"), 60)
    duration = seconds(th.get("duration"))
    thr = float(th.get("thresholdValue", 0))
    comparison = th.get("comparison", "COMPARISON_GT")
    holds = CMP.get(comparison, CMP["COMPARISON_GT"])
    worse = min if comparison in ("COMPARISON_LT", "COMPARISON_LE") else max
    series, errors = read_pages(d, n)
    row = rows.setdefault(
        name, {"count": 0, "first": None, "last": None, "res": set(), "series": 0}
    )
    row["series"] += len(series)
    for s in series:
        pts = [
            (ts(p["interval"]["endTime"]), point_value(p)) for p in s.get("points", [])
        ]
        res = resource_of(s, th.get("filter", ""))
        for start, end, peak in runs(
            pts, period, duration, lambda v: holds(v, thr), worse
        ):
            row["count"] += 1
            row["first"] = start if row["first"] is None else min(row["first"], start)
            row["last"] = end if row["last"] is None else max(row["last"], end)
            row["res"].add(res)
            detail.append((start, name, end, peak, res))
    return errors


def report(policies, d, since, until):
    conds, skipped = conditions(policies)
    rows, detail, rc = {}, [], 0
    for n, name, th in conds:
        for e in replay(n, name, th, d, rows, detail):
            print("ERROR %s: %s" % (name, e), file=sys.stderr)
            rc = 1
    print(
        "== alert incidents %s .. %s (rebuilt from each policy's own condition)"
        % (since, until)
    )
    fmt = "%-42s %5s %-17s %-17s %6s %s"
    print(fmt % ("TYPE", "COUNT", "FIRST", "LAST", "SERIES", "RESOURCE"))
    for name in sorted(rows, key=lambda k: (-rows[k]["count"], k)):
        r = rows[name]
        print(
            fmt
            % (
                name,
                r["count"],
                hm(r["first"]) if r["first"] else "-",
                hm(r["last"]) if r["last"] else "-",
                r["series"],
                " ".join(sorted(r["res"])) or "-",
            )
        )
    for name, kind in skipped:
        print(fmt % (name, "?", "-", "-", "-", "not replayed: %s" % kind))
    print("== incidents (open .. last violating point, peak value)")
    if not detail:
        print("none")
    for start, name, end, peak, res in sorted(detail):
        print("%s .. %s  %-42s peak=%g  %s" % (hm(start), hm(end), name, peak, res))
    return rc


def main(argv):
    if (
        len(argv) < 3
        or argv[0] not in ("plan", "report")
        or (argv[0] == "report" and len(argv) != 5)
    ):
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1]) as f:
        policies = json.load(f)
    if isinstance(policies, dict):
        policies = policies.get("alertPolicies", [])
    if argv[0] == "plan":
        plan(policies, argv[2])
        return 0
    return report(policies, argv[2], argv[3], argv[4])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
