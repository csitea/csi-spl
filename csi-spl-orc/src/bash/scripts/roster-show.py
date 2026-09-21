#!/usr/bin/env python3
"""Print the LIVE `GET /v1/view/roster` JSON of a cloud tenant (view-v1 4.1),
read through a real member session - the same door and the same bytes the
owner sees in the WUI.

READ-ONLY: view-v1 0 says a viewer read never delivers, drains, claims or
touches roster / boxes.last_hello_at / pins, so this cannot change what it
reports.

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE.
Prints the roster JSON (2-space indent, sorted keys) on stdout; a one-line
{"step": ...} verdict instead when it could not be read. Exit 0 = printed,
1 = the roster read failed, 2 = could not sign in. The password and the
session cookie are never printed.
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
    with open(PW_FILE) as f:
        pw = f.read().strip()
    st, hdrs, out = http("POST", API + "/api/v1/auth/login", {"email": EMAIL, "password": pw, "tenant": TENANT})
    cookie = session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        print(json.dumps({"step": "login", "status": st, "error": err(out)}))
        return 2
    st, _, roster = http("GET", API + "/v1/view/roster", cookie=cookie)
    if st != 200 or not isinstance(roster, dict):
        print(json.dumps({"step": "roster", "status": st, "error": err(roster)}))
        return 1
    print(json.dumps(roster, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
