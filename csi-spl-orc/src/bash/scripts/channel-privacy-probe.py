#!/usr/bin/env python3
"""rdb 0028 live probe, READ-ONLY: prove the read door on the DEPLOYED hub.

Signs one member in and asserts, against a topic the caller names:

  * the messages it may read come back (the CONTROL - a door that returns
    nothing passes every "must not be readable" assertion vacuously, so the
    positive half is not optional), and
  * the messages it may NOT read do not. A topic that mixes a DM with a
    channel-tagged reply is the interesting case, and is the shape the defect
    was reported from: PROBE_DENY_FROM names the id whose UNTAGGED messages
    this member is not an end of, and none of them may appear.

Nothing is written: only GET /v1/view/topics/{task_id} is called after the
sign-in.

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE,
PROBE_TASK (the task_id to read), PROBE_ALLOW_MIN (int, default 1: at least
this many messages must come back), PROBE_DENY_FROM (optional: a from id whose
messages must NOT appear).

PROBE_FILE + PROBE_FILE_WANT check the ATTACHMENT door (rdb 0030) instead:
GET /v1/files/{id} must answer PROBE_FILE_WANT (200 for a file this member may
read, 404 for one it may not). Named separately from the message checks
because a file and the message carrying it are two doors, and a green on one
says nothing about the other.

Prints one JSON verdict; exit 0 = the door holds, 1 = it does not, 2 = could
not sign in. The password and cookie are never printed.
"""
import json
import os
import sys
import urllib.error
import urllib.request

API = os.environ.get("PROBE_API", "").rstrip("/")
TENANT = os.environ.get("PROBE_TENANT", "")
EMAIL = os.environ.get("PROBE_EMAIL", "")
PW_FILE = os.environ.get("PROBE_PW_FILE", "")
TASK = os.environ.get("PROBE_TASK", "")
ALLOW_MIN = int(os.environ.get("PROBE_ALLOW_MIN", "1"))
DENY_FROM = os.environ.get("PROBE_DENY_FROM", "")
FILE_ID = os.environ.get("PROBE_FILE", "")
FILE_WANT = int(os.environ.get("PROBE_FILE_WANT", "0") or 0)


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


def senders(messages):
    """(from_id, channel) of every message the hub returned."""
    out = []
    for m in messages:
        env = m.get("env") or {}
        inner = env.get("msg") or {}
        out.append((inner.get("from", ""), env.get("channel", "") or ""))
    return out


def main():
    with open(PW_FILE) as f:
        pw = f.read().strip()
    st, hdrs, out = http("POST", API + "/api/v1/auth/login", {"email": EMAIL, "password": pw, "tenant": TENANT})
    cookie = session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        print(json.dumps({"step": "login", "status": st, "error": err(out)}))
        return 2
    st, _, me = http("GET", API + "/v1/view/me", cookie=cookie)
    who = me.get("human_id") if isinstance(me, dict) else ""
    if FILE_ID:
        # The attachment door (rdb 0030). A raw status is the whole verdict:
        # the body is the file's bytes, which this probe never prints.
        st, _, _ = http("GET", f"{API}/v1/files/{FILE_ID}", cookie=cookie)
        v = {"human_id": who, "file_id": FILE_ID, "status": st, "want": FILE_WANT,
             "ok": st == FILE_WANT}
        print(json.dumps(v, sort_keys=True))
        return 0 if v["ok"] else 1
    st, _, body = http("GET", f"{API}/v1/view/topics/{TASK}", cookie=cookie)
    v = {"human_id": who, "task_id": TASK, "status": st, "ok": True, "checks": {}}
    if st == 404:
        # The whole topic is closed to this member. Legitimate, but it is not
        # a proof of anything unless nothing was expected back.
        v["checks"]["topic"] = {"readable": 0, "want_min": ALLOW_MIN}
        v["ok"] = ALLOW_MIN == 0
        print(json.dumps(v, sort_keys=True))
        return 0 if v["ok"] else 1
    if st != 200 or not isinstance(body, dict):
        v["ok"] = False
        v["error"] = err(body)
        print(json.dumps(v, sort_keys=True))
        return 1
    rows = senders(body.get("messages") or [])
    v["checks"]["readable"] = {"got": len(rows), "want_min": ALLOW_MIN,
                               "ok": len(rows) >= ALLOW_MIN}
    v["ok"] = v["ok"] and v["checks"]["readable"]["ok"]
    if DENY_FROM:
        leaked = [f"{f}/{c or 'DM'}" for f, c in rows if f == DENY_FROM and not c]
        v["checks"]["denied"] = {"from": DENY_FROM, "leaked": leaked, "ok": not leaked}
        v["ok"] = v["ok"] and v["checks"]["denied"]["ok"]
    v["from_ids"] = sorted({f for f, _ in rows})
    print(json.dumps(v, sort_keys=True))
    return 0 if v["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
