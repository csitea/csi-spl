#!/usr/bin/env python3
"""specs/025 live probe: sign one member in, read its role and permissions
(GET /v1/view/me) and check two gates WITHOUT writing anything:

- POST /v1/channels {"channel": "BAD!"}: with channels.manage the hub answers
  400 bad_channel (the body is refused after the gate), without it 403
  forbidden - no channel is ever created.
- PUT /v1/members/HUM-0/role: with members.roles 404 not_found (no HUM-0),
  without it 403 forbidden - no role is ever changed.

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE,
PROBE_EXPECT_ROLE (optional). Prints one JSON verdict; exit 0 = consistent,
1 = a gate contradicts /v1/view/me or the role is not the expected one,
2 = could not sign in. The password and the cookie are never printed.
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
EXPECT = os.environ.get("PROBE_EXPECT_ROLE", "")


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
    st, hdrs, out = http(
        "POST",
        API + "/api/v1/auth/login",
        {"email": EMAIL, "password": pw, "tenant": TENANT},
    )
    cookie = session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        print(json.dumps({"step": "login", "status": st, "error": err(out)}))
        return 2
    st, _, me = http("GET", API + "/v1/view/me", cookie=cookie)
    if st != 200 or not isinstance(me, dict):
        print(json.dumps({"step": "me", "status": st, "error": err(me)}))
        return 1
    perms = set(me.get("permissions") or [])
    v = {
        "tenant_id": me.get("tenant_id"),
        "human_id": me.get("human_id"),
        "role": me.get("role"),
        "tenant_owner": me.get("tenant_owner"),
        "permissions": sorted(perms),
        "gates": {},
        "ok": True,
    }
    for name, method, path, body, allowed_status, perm in (
        (
            "channels.manage",
            "POST",
            "/v1/channels",
            {"channel": "BAD!"},
            400,
            "channels.manage",
        ),
        (
            "members.roles",
            "PUT",
            "/v1/members/HUM-0/role",
            {"role": "tester"},
            404,
            "members.roles",
        ),
    ):
        st, _, out = http(method, API + path, body, cookie=cookie)
        granted = perm in perms
        want = allowed_status if granted else 403
        agrees = st == want and (
            granted or (err(out) == "forbidden" and out.get("permission") == perm)
        )
        v["gates"][name] = {
            "granted": granted,
            "status": st,
            "error": err(out),
            "agrees": agrees,
        }
        v["ok"] = v["ok"] and agrees
    if EXPECT and v["role"] != EXPECT:
        v["ok"] = False
        v["expected_role"] = EXPECT
    print(json.dumps(v, sort_keys=True))
    return 0 if v["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
