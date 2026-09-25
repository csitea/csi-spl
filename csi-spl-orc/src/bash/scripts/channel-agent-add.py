#!/usr/bin/env python3
"""Seat agents in a channel on the DEPLOYED hub, as a signed-in member.

The same two calls the web UI makes (specs/038 live proof, and any time a
channel needs its agents without a browser): optionally POST /v1/channels
(create; the creator becomes its owner), then POST /v1/channels/{ch}/agents
{id, box} once per agent. An agent already seated answers 201 again (the row
is idempotent), so a re-run is harmless.

Env: SEAT_API (https://<api host>), SEAT_TENANT, SEAT_EMAIL, SEAT_PW_FILE,
SEAT_CHANNEL, SEAT_AGENTS (space-separated ids), SEAT_BOX, SEAT_CREATE (1 =
create the channel first; 409 channel_exists is fine).

Prints one JSON verdict; exit 0 = every agent seated, 1 = one was refused,
2 = could not sign in. The password and cookie are never printed.
"""
import json
import os
import sys
import urllib.error
import urllib.request

API = os.environ.get("SEAT_API", "").rstrip("/")


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
    try:
        out = json.loads(raw.decode()) if raw else None
    except ValueError:
        out = None
    return status, hdrs, out


def session_cookie(hdrs):
    for v in hdrs.get_all("Set-Cookie") or []:
        pair = v.split(";", 1)[0]
        if pair.startswith("spool_session") and "=" in pair and pair.split("=", 1)[1]:
            return pair
    return ""


def err(out):
    return out.get("error", "") if isinstance(out, dict) else ""


def main():
    tenant, ch, box = os.environ["SEAT_TENANT"], os.environ["SEAT_CHANNEL"], os.environ["SEAT_BOX"]
    agents = os.environ.get("SEAT_AGENTS", "").split()
    with open(os.environ["SEAT_PW_FILE"]) as f:
        pw = f.read().strip()
    st, hdrs, out = http("POST", API + "/api/v1/auth/login",
                         {"email": os.environ["SEAT_EMAIL"], "password": pw, "tenant": tenant})
    cookie = session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        print(json.dumps({"step": "login", "status": st, "error": err(out)}))
        return 2
    v = {"tenant": tenant, "channel": ch, "box": box, "agents": {}, "ok": True}
    if os.environ.get("SEAT_CREATE") == "1":
        st, _, out = http("POST", API + "/v1/channels", {"channel": ch}, cookie=cookie)
        v["create"] = {"status": st, "error": err(out)}
        if st not in (201, 409):
            v["ok"] = False
            print(json.dumps(v, sort_keys=True))
            return 1
    for a in agents:
        st, _, out = http("POST", f"{API}/v1/channels/{ch}/agents", {"id": a, "box": box}, cookie=cookie)
        v["agents"][a] = {"status": st, "error": err(out)}
        v["ok"] = v["ok"] and st == 201
    print(json.dumps(v, sort_keys=True))
    return 0 if v["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
