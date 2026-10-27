#!/usr/bin/env python3
"""One Cloud Monitoring alert incident: its policy, resource and timeline.

do_gcp_get_alert_incident (SPL-2887) names an incident by its policy display
name and the minute it opened, as do_gcp_list_alert_incidents prints it: an
incident has no id (no public incidents API). This script reuses that
action's replay (alert-incidents.py beside it, imported, never changed): the
same conditions, the same queries, the same runs, and the same combiner
(policy_runs, SPL-3773): an AND policy's incident is the overlap of its
conditions' runs, with one timeline per condition.

  select <policies.json> <policy display name>
      prints the one ENABLED policy of that name as a JSON list (exit 3: none)
  detail <policy.json> <dir> <opened> <since> <until>
      reads <dir>/q<N>.p<M>.json (the pages of the policy's query N) and
      prints the policy, each incident of it that opened at <opened>
      (YYYY-MM-DDTHH:MMZ) with its resource and peak, and its timeline: every
      aligned point of that series from one duration plus three periods
      before the open to three periods after the last violating point.
      Exit 4: no incident of that policy opened then (the ones that did open
      in the window are listed).
"""

import datetime
import importlib.util
import json
import os
import sys

_spec = importlib.util.spec_from_file_location(
    "alert_incidents", os.path.join(os.path.dirname(__file__), "alert-incidents.py")
)
ai = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ai)


def load(path):
    with open(path) as f:
        p = json.load(f)
    return p.get("alertPolicies", []) if isinstance(p, dict) else p


def select(policies, name):
    hit = [
        p
        for p in policies
        if p.get("displayName") == name and p.get("enabled") is not False
    ]
    if not hit:
        print("no enabled alert policy named %r" % name, file=sys.stderr)
        return 3
    print(json.dumps(hit[:1]))
    return 0


def fmt_v(v):
    return "-" if v is None else "%g" % v


def timelines(n, th, d, start, end, res):
    """The timeline of each series of condition N whose own run covers the
    incident <start> .. <end>: one for an OR incident, one per condition for
    an AND one (alert-incidents.py policy_runs decides which incidents exist)."""
    agg = (th.get("aggregations") or [{}])[0]
    period = ai.seconds(agg.get("alignmentPeriod"), 60)
    duration = ai.seconds(th.get("duration"))
    thr = float(th.get("thresholdValue", 0))
    holds = ai.CMP.get(th.get("comparison"), ai.CMP["COMPARISON_GT"])
    series, _ = ai.read_pages(d, n)
    for s in series:
        pts = [
            (ai.ts(p["interval"]["endTime"]), ai.point_value(p))
            for p in s.get("points", [])
        ]
        rs = ai.resource_of(s, th.get("filter", ""))
        covers = any(
            o <= start and last >= end
            for o, last, _ in ai.runs(
                pts, period, duration, lambda v: holds(v, thr), max
            )
        )
        if rs not in res or not covers:
            continue
        lo = start - datetime.timedelta(seconds=duration + 3 * period)
        hi = end + datetime.timedelta(seconds=3 * period)
        print("== timeline (%s, aligned point end, value, verdict)" % rs)
        for t, v in sorted(pts):
            if lo <= t <= hi:
                verdict = "-" if v is None else ("VIOLATES" if holds(v, thr) else "ok")
                print(
                    "%s  %s  %s" % (t.strftime("%Y-%m-%dT%H:%M:%SZ"), fmt_v(v), verdict)
                )


def detail(policies, d, opened, since, until):
    pol = policies[0]
    name = pol.get("displayName", "?")
    conds, skipped = ai.conditions(policies)
    print(
        "== incident %s opened %s (replayed over %s .. %s)"
        % (name, opened, since, until)
    )
    print(
        "policy: %s  enabled=%s  notification channels=%d"
        % (
            name,
            str(pol.get("enabled", True)).lower(),
            len(pol.get("notificationChannels") or []),
        )
    )
    for c in pol.get("conditions", []):
        th = c.get("conditionThreshold")
        if th is None or "denominatorFilter" in th:
            continue
        agg = (th.get("aggregations") or [{}])[0]
        print(
            "condition: %s: %s %s %g for %ss (align %ss %s%s)"
            % (
                c.get("displayName", "?"),
                th.get("filter", ""),
                th.get("comparison", "COMPARISON_GT"),
                float(th.get("thresholdValue", 0)),
                ai.seconds(th.get("duration")),
                ai.seconds(agg.get("alignmentPeriod"), 60),
                agg.get("perSeriesAligner", "-"),
                ", " + agg["crossSeriesReducer"]
                if agg.get("crossSeriesReducer")
                else "",
            )
        )
    for _, kind in skipped:
        print("condition: not replayed: %s" % kind)
    found, others, rc, cond_runs = 0, [], 0, []
    for n, _, th in conds:
        got, _, errors = ai.condition_runs(n, th, d)
        for e in errors:
            print("ERROR %s: %s" % (name, e), file=sys.stderr)
            rc = 1
        cond_runs.append(got)
    for start, end, peak, res in ai.policy_runs(
        name, ai.combiner(policies, name), cond_runs
    ):
        r = " ".join(sorted(res))
        if ai.hm(start) != opened:
            others.append("%s .. %s  peak=%g  %s" % (ai.hm(start), ai.hm(end), peak, r))
            continue
        found += 1
        print(
            "incident: %s .. %s  peak=%g  resource=%s"
            % (ai.hm(start), ai.hm(end), peak, r)
        )
        for n, _, th in conds:
            timelines(n, th, d, start, end, res)
    if not found:
        print("no incident of %s opened at %s in this window" % (name, opened))
        print(
            "== incidents of this policy in the window (open .. last, peak, resource)"
        )
        print("\n".join(sorted(others)) or "none")
        return rc or 4
    return rc


def main(argv):
    if len(argv) == 3 and argv[0] == "select":
        return select(load(argv[1]), argv[2])
    if len(argv) == 6 and argv[0] == "detail":
        return detail(load(argv[1]), argv[2], argv[3], argv[4], argv[5])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
