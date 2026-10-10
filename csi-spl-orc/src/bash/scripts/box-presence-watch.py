#!/usr/bin/env python3
"""Measure how long each machine reads OFFLINE across hub rolls (t1 b3bf3d13):
poll the LIVE `GET /v1/view/roster` (the WUI's door, one member session) and
`GET /v1/wui/revision` (the revision serving NEW requests) every WATCH_EVERY
seconds for WATCH_SECS, one JSON line per read, then summarise.

READ-ONLY (view-v1 0): a viewer read touches nothing.

Env (watch): PROBE_API, PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE,
WATCH_SECS (default 5400), WATCH_EVERY (default 5), WATCH_OUT (the JSONL).
Env (summary only): WATCH_SUMMARY=<JSONL> reads a recorded file, no network.

A ROLL is a change of the serving revision between two reads. An offline RUN
is a box's consecutive offline reads between two online reads (a box never
seen online is not a live machine and is skipped). A run that starts within
ROLL_SLACK (120 s) of a roll is that roll's; any other run is reported as
"no roll" (a request served by an instance without the socket, or a real
disconnect). Exit 0 = summarised, 1 = a read failed, 2 = could not sign in.
The password and the session cookie are never printed.
"""

import json
import os
import statistics
import sys
import time
import urllib.error
import urllib.request

API = os.environ.get("PROBE_API", "").rstrip("/")
ROLL_SLACK = 120.0


def http(method, url, body=None, cookie=""):
    h = {"Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    if cookie:
        h["Cookie"] = cookie
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=20)
        status, hdrs, raw = r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        status, hdrs, raw = e.code, e.headers, e.read()
    except (urllib.error.URLError, OSError):
        return 0, None, None
    try:
        out = json.loads(raw.decode()) if raw else None
    except ValueError:
        out = None
    return status, hdrs, out


def login():
    with open(os.environ["PROBE_PW_FILE"]) as f:
        pw = f.read().strip()
    st, hdrs, _ = http(
        "POST",
        API + "/api/v1/auth/login",
        {
            "email": os.environ["PROBE_EMAIL"],
            "password": pw,
            "tenant": os.environ["PROBE_TENANT"],
        },
    )
    for v in (hdrs.get_all("Set-Cookie") or []) if (st == 200 and hdrs) else []:
        pair = v.split(";", 1)[0]
        if pair.startswith("spool_session") and "=" in pair and pair.split("=", 1)[1]:
            return pair
    return ""


def watch(out_path, secs, every):
    cookie = login()
    if not cookie:
        print(json.dumps({"step": "login"}))
        return 2
    end = time.time() + secs
    with open(out_path, "a") as out:
        while time.time() < end:
            t0 = time.time()
            _, _, rv = http("GET", API + "/v1/wui/revision")
            t1 = time.time()
            st, _, roster = http("GET", API + "/v1/view/roster", cookie=cookie)
            ms = round((time.time() - t1) * 1000, 1)
            if st == 401:
                cookie = login()
            line = {
                "ts": round(t0, 3),
                "rev": (rv or {}).get("revision", "") if isinstance(rv, dict) else "",
                "status": st,
                "ms": ms,
            }
            if st == 200 and isinstance(roster, dict):
                line["boxes"] = {
                    b["box_id"]: bool(b.get("online"))
                    for b in roster.get("boxes", [])
                    if not b.get("revoked")
                }
            out.write(json.dumps(line, sort_keys=True) + "\n")
            out.flush()
            time.sleep(max(0.0, every - (time.time() - t0)))
    return 0


def summarise(path):
    reads = []
    with open(path) as f:
        for raw in f:
            raw = raw.strip()
            if raw:
                reads.append(json.loads(raw))
    reads = [r for r in reads if "boxes" in r]
    rolls, prev = [], None
    for r in reads:
        if r.get("rev") and prev and r["rev"] != prev:
            rolls.append({"ts": r["ts"], "from": prev, "to": r["rev"], "runs": []})
        prev = r.get("rev") or prev
    live = sorted({b for r in reads for b, on in r["boxes"].items() if on})
    stray = []
    for box in live:
        start, seen_on = None, False
        for r in reads:
            on = r["boxes"].get(box)
            if on is None:
                continue
            if on:
                if start is not None and seen_on:
                    run = {
                        "box": box,
                        "start": start,
                        "secs": round(float(r["ts"] - start), 1),
                    }
                    near = sorted(
                        (abs(k["ts"] - start), i)
                        for i, k in enumerate(rolls)
                        if abs(k["ts"] - start) <= ROLL_SLACK
                    )
                    (rolls[near[0][1]]["runs"] if near else stray).append(run)
                start, seen_on = None, True
            elif start is None:
                start = r["ts"]
    ms = sorted(r["ms"] for r in reads)
    out = {
        "reads": len(reads),
        "live_boxes": live,
        "span_secs": round(reads[-1]["ts"] - reads[0]["ts"], 1) if reads else 0,
        "roster_ms_median": statistics.median(ms) if ms else None,
        "rolls": [],
        "no_roll_runs": stray,
    }
    for k in rolls:
        secs = [x["secs"] for x in k["runs"]]
        out["rolls"].append(
            {
                "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(k["ts"])),
                "from": k["from"],
                "to": k["to"],
                "n": len(secs),
                "boxes_offline": sorted(x["box"] for x in k["runs"]),
                "min": min(secs) if secs else 0,
                "median": statistics.median(secs) if secs else 0,
                "max": max(secs) if secs else 0,
            }
        )
    print(json.dumps(out, indent=2, sort_keys=True))
    return 0


def main():
    if os.environ.get("WATCH_SUMMARY"):
        return summarise(os.environ["WATCH_SUMMARY"])
    out_path = os.environ["WATCH_OUT"]
    rc = watch(
        out_path,
        float(os.environ.get("WATCH_SECS", "5400")),
        float(os.environ.get("WATCH_EVERY", "5")),
    )
    return rc if rc else summarise(out_path)


if __name__ == "__main__":
    sys.exit(main())
