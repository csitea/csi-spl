#!/usr/bin/env python3
"""Print the LIVE `GET /v1/view/roster` JSON of a cloud tenant (view-v1 4.1),
read through a real member session - the same door and the same bytes the
owner sees in the WUI.

READ-ONLY: view-v1 0 says a viewer read never delivers, drains, claims or
touches roster / boxes.last_hello_at / pins, so this cannot change what it
reports.

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE.
PROBE_COOKIE_FILE (optional): keep the session there (0600) and reuse it, so
a caller that reads the roster again and again signs in once; a refused
session (401/403) signs in again (SPL-5233: the hub allows 10 member logins
per address per 15 min).
Prints the roster JSON (2-space indent, sorted keys) on stdout; a one-line
{"step": ...} verdict instead when it could not be read; a login 429 carries
the hub's Retry-After as "retry_after" (seconds). Exit 0 = printed,
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
COOKIE_FILE = os.environ.get("PROBE_COOKIE_FILE", "")


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


def saved_cookie():
    if not COOKIE_FILE:
        return ""
    try:
        with open(COOKIE_FILE) as f:
            return f.read().strip()
    except OSError:
        return ""


def save_cookie(cookie):
    if not COOKIE_FILE:
        return
    fd = os.open(COOKIE_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(cookie)


def login():
    """The session cookie, or "" after printing the login verdict."""
    with open(PW_FILE) as f:
        pw = f.read().strip()
    st, hdrs, out = http(
        "POST",
        API + "/api/v1/auth/login",
        {"email": EMAIL, "password": pw, "tenant": TENANT},
    )
    cookie = session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        v = {"step": "login", "status": st, "error": err(out)}
        ra = (hdrs.get("Retry-After") or "").strip() if hdrs else ""
        if st == 429 and ra.isdigit():
            v["retry_after"] = int(ra)
        print(json.dumps(v))
        return ""
    save_cookie(cookie)
    return cookie


def main():
    cookie = saved_cookie()
    if cookie:
        st, _, roster = http("GET", API + "/v1/view/roster", cookie=cookie)
        if st == 200 and isinstance(roster, dict):
            print(json.dumps(roster, indent=2, sort_keys=True))
            return 0
        if st not in (401, 403):
            print(json.dumps({"step": "roster", "status": st, "error": err(roster)}))
            return 1
    cookie = login()
    if not cookie:
        return 2
    st, _, roster = http("GET", API + "/v1/view/roster", cookie=cookie)
    if st != 200 or not isinstance(roster, dict):
        print(json.dumps({"step": "roster", "status": st, "error": err(roster)}))
        return 1
    print(json.dumps(roster, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    sys.exit(main())
