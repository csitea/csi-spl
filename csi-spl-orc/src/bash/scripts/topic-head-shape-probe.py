#!/usr/bin/env python3
"""spec 099 T009 shape probe, READ-ONLY: drive the six topic-list shapes.

The topic-head shadow (hub view.go topicShape) counts its compares per list
shape. Organic traffic reaches only some of them, so this signs one member in
and issues PROBE_N list reads of each shape:

  all       GET /v1/view/topics
  all_flat  GET /v1/view/topics?roots=false
  channel   GET /v1/view/topics?channel=<c>
  dm        GET /v1/view/topics?dm=true
  agent     GET /v1/view/topics?agent=<id>
  children  GET /v1/view/topics/<task_id>/children

The channel, agent and parent default to ones seen in the member's own `all`
and `all_flat` pages (PROBE_CHANNEL, PROBE_AGENT, PROBE_PARENT override).
Nothing is written: GET only after the sign-in.

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE,
PROBE_N (reads per shape), PROBE_SHAPES (comma list, default all six),
PROBE_CHANNEL, PROBE_AGENT, PROBE_PARENT (optional).

Prints one row per shape (shape, requests, statuses, request) and one JSON
summary; exit 0 = every read answered 200, 1 = some did not or a shape had no
target, 2 = could not sign in. The password and cookie are never printed.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

SHAPES = ("all", "all_flat", "channel", "dm", "agent", "children")
UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
NOT_AGENT = re.compile(r"^(HUM|ALL)-")  # a person, or the broadcast id
OVERRIDE = {
    "channel": "PROBE_CHANNEL",
    "agent": "PROBE_AGENT",
    "children": "PROBE_PARENT",
}


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
        r = urllib.request.urlopen(req, timeout=30)
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


def session_cookie(hdrs):
    for v in (hdrs.get_all("Set-Cookie") if hdrs else None) or []:
        pair = v.split(";", 1)[0]
        if pair.startswith("spool_session") and "=" in pair and pair.split("=", 1)[1]:
            return pair
    return ""


def topics(body):
    return (body.get("topics") or []) if isinstance(body, dict) else []


def targets(api, cookie):
    """A channel, an agent and a parent task the member can read, from its
    own `all` and `all_flat` pages; each may be overridden by env."""
    rows = []
    for q in ("", "?roots=false"):
        st, _, body = http("GET", api + "/v1/view/topics" + q, cookie=cookie)
        if st == 200:
            rows += topics(body)
    ch = next((t["channel"] for t in rows if t.get("channel")), "")
    ids = (
        p.split("@", 1)[0] for t in rows for p in (t.get("participants") or [])
    )  # <id>@<box> -> <id>
    agent = next((i for i in ids if i and not NOT_AGENT.match(i)), "")
    parent = next((t["parent_task_id"] for t in rows if t.get("parent_task_id")), "")
    parent = parent or next((t["task_id"] for t in rows if t.get("task_id")), "")
    return (
        os.environ.get("PROBE_CHANNEL") or ch,
        os.environ.get("PROBE_AGENT") or agent,
        os.environ.get("PROBE_PARENT") or parent,
    )


def request_for(shape, ch, agent, parent):
    """The path the hub classifies as <shape>; "" = no target for it."""
    q = urllib.parse.quote
    if shape == "channel":
        return "/v1/view/topics?channel=" + q(ch) if ch else ""
    if shape == "agent":
        return "/v1/view/topics?agent=" + q(agent) if agent else ""
    if shape == "children":
        return (
            "/v1/view/topics/" + parent + "/children"
            if UUID.match(parent or "")
            else ""
        )
    return {
        "all": "/v1/view/topics",
        "all_flat": "/v1/view/topics?roots=false",
        "dm": "/v1/view/topics?dm=true",
    }[shape]


def main():
    api = os.environ.get("PROBE_API", "").rstrip("/")
    n = int(os.environ.get("PROBE_N", "10"))
    want = [
        s for s in (os.environ.get("PROBE_SHAPES") or ",".join(SHAPES)).split(",") if s
    ]
    bad = [s for s in want if s not in SHAPES]
    if bad:
        print(
            json.dumps({"step": "args", "error": "unknown shape(s): " + ",".join(bad)})
        )
        return 1
    with open(os.environ.get("PROBE_PW_FILE", "")) as f:
        pw = f.read().strip()
    st, hdrs, out = http(
        "POST",
        api + "/api/v1/auth/login",
        {
            "email": os.environ.get("PROBE_EMAIL", ""),
            "password": pw,
            "tenant": os.environ.get("PROBE_TENANT", ""),
        },
    )
    cookie = session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        print(
            json.dumps(
                {
                    "step": "login",
                    "status": st,
                    "error": out.get("error", "") if isinstance(out, dict) else "",
                }
            )
        )
        return 2
    ch, agent, parent = targets(api, cookie)
    ok, summary = True, {}
    print("%-9s %8s  %-20s %s" % ("shape", "requests", "statuses", "request"))
    for shape in want:
        path = request_for(shape, ch, agent, parent)
        codes = {}
        for _ in range(n if path else 0):
            st, _, _ = http("GET", api + path, cookie=cookie)
            codes[str(st)] = codes.get(str(st), 0) + 1
        good = bool(path) and codes == {"200": n}
        ok = ok and good
        summary[shape] = {
            "requests": sum(codes.values()),
            "statuses": codes,
            "ok": good,
        }
        stat = ",".join("%s=%d" % kv for kv in sorted(codes.items())) or "-"
        print(
            "%-9s %8d  %-20s %s"
            % (
                shape,
                sum(codes.values()),
                stat,
                path or "(no target: set %s)" % OVERRIDE.get(shape, "?"),
            )
        )
    print(json.dumps({"ok": ok, "n": n, "shapes": summary}, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
