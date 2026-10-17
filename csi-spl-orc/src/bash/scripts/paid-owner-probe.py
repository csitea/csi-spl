#!/usr/bin/env python3
"""047 W1 live probe (SPL-1161): after a paid test checkout, the buyer signs in
with the checkout email and lands as biz_owner, with no operator invite; any
other verified address is refused.

For each of the two addresses: POST /api/v1/auth/register (a fresh random
password, never printed or stored), POST /api/v1/auth/email/verify with the
token, then POST /api/v1/auth/login naming the tenant. The buyer's session
reads GET /v1/view/me. The token is the hub's debug_token when it answers one
(lde only since SPL-2157), else the link in the verify mail, read over IMAP
from the relay mailbox (m3-e2e.py's imap_verify_token): both addresses must
then be plus-addresses of that mailbox.

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_BUYER_EMAIL,
PROBE_OTHER_EMAIL; M3_IMAP_USER / M3_IMAP_PASS_FILE / M3_IMAP_HOST for the
mail path. Prints one JSON verdict (no address, password, token or cookie);
exit 0 = buyer is biz_owner and the other is refused, 1 = not so, 2 = an
account could not be made (register / verify refused, no token).
"""

import importlib.util
import json
import os
import secrets
import sys
import urllib.error
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "m3_e2e", os.path.join(HERE, "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)
NO_TOKEN = (
    "the hub answered no debug_token (lde only since SPL-2157) and no "
    "M3_IMAP_USER mailbox is set to read the verify mail: run "
    "do_spl_paid_owner_probe, which sets it"
)

API = os.environ.get("PROBE_API", "").rstrip("/")
TENANT = os.environ.get("PROBE_TENANT", "")
BUYER = os.environ.get("PROBE_BUYER_EMAIL", "")
OTHER = os.environ.get("PROBE_OTHER_EMAIL", "")


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


def account(email):
    """Register + verify a fresh native account; its password, or a failure dict."""
    pw = secrets.token_urlsafe(18)
    seen = m3.imap_uids(email) if m3.IMAP_USER else set()
    st, _, out = http(
        "POST",
        API + "/api/v1/auth/register",
        {"email": email, "password": pw, "name": "W1 probe"},
    )
    tok = out.get("debug_token", "") if isinstance(out, dict) else ""
    if st // 100 != 2:
        return None, {"step": "register", "status": st, "error": err(out)}
    via, why = "debug_token", ""
    if not tok and m3.IMAP_USER:
        tok, _ = m3.imap_verify_token(email, seen)  # its evidence names the address
        via, why = "imap", "no verify mail within %ds" % m3.IMAP_TIMEOUT
    elif not tok:
        why = NO_TOKEN
    if not tok:
        return None, {"step": "register", "status": st, "via": via, "error": why}
    st, _, out = http(
        "POST", API + "/api/v1/auth/email/verify", {"token": tok, "password": pw}
    )
    if st // 100 != 2:
        return None, {"step": "verify", "status": st, "error": err(out)}
    return pw, None


def login(email, pw):
    st, hdrs, out = http(
        "POST",
        API + "/api/v1/auth/login",
        {"email": email, "password": pw, "tenant": TENANT},
    )
    return st, session_cookie(hdrs), err(out)


def main():
    if not (API and TENANT and BUYER and OTHER) or BUYER.lower() == OTHER.lower():
        print(
            json.dumps(
                {
                    "ok": False,
                    "error": "PROBE_API, PROBE_TENANT and two different emails are required",
                }
            )
        )
        return 2
    verdict = {"tenant": TENANT, "operator_actions": 0}
    pw, bad = account(BUYER)
    if bad:
        verdict.update(ok=False, buyer=bad)
        print(json.dumps(verdict))
        return 2
    st, cookie, e = login(BUYER, pw)
    buyer = {"login": st, "error": e}
    if st == 200 and cookie:
        mst, _, me = http("GET", API + "/v1/view/me", cookie=cookie)
        me = me if isinstance(me, dict) else {}
        buyer.update(me=mst, role=me.get("role", ""), tenant_id=me.get("tenant_id", ""))
    verdict["buyer"] = buyer
    pw2, bad = account(OTHER)
    if bad:
        verdict.update(ok=False, other=bad)
        print(json.dumps(verdict))
        return 2
    st, cookie, e = login(OTHER, pw2)
    verdict["other"] = {"login": st, "error": e, "session": bool(cookie)}
    ok = (
        buyer.get("role") == "biz_owner"
        and buyer.get("tenant_id") == TENANT
        and st != 200
        and not cookie
    )
    verdict["ok"] = ok
    print(json.dumps(verdict, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
