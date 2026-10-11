#!/usr/bin/env python3
"""do_spl_dev_password_reset, the hub half: give a dev native (015) account a
NEW password through the hub's own reset flow, the way a member would:
POST password/forgot -> the dev hub's debug_token -> POST password/reset,
then one sign-in to the tenant with it. Only the dev hub answers with a
debug token; prd mails the link and this stops at "no debug token".

Env: RESET_API (https://<api host>), RESET_EMAIL, RESET_TENANT, RESET_PW_FILE
(written 0600 only after the reset AND the sign-in worked). Prints one JSON
line {"step", "status"}; exit 0 = reset and signed in. The token and the
password are never printed.
"""

import importlib.util
import json
import os
import secrets
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "m3_e2e", os.path.join(HERE, "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)
API = os.environ.get("RESET_API", "").rstrip("/") + "/api/v1/auth/"


def say(step, status, ok=False):
    print(json.dumps({"step": step, "status": status}))
    return 0 if ok else 1


def main():
    email, tenant = os.environ["RESET_EMAIL"], os.environ["RESET_TENANT"]
    st, _, out = m3.http("POST", API + "password/forgot", {"email": email})
    token = out.get("debug_token", "") if isinstance(out, dict) else ""
    if st != 200 or not token:
        return say("forgot (no debug token: not a dev hub, or no such account)", st)
    pw = secrets.token_urlsafe(18)
    st, _, _ = m3.http("POST", API + "password/reset", {"token": token, "password": pw})
    if st not in (200, 204):
        return say("reset", st)
    st, hdrs, _ = m3.http(
        "POST", API + "login", {"email": email, "password": pw, "tenant": tenant}
    )
    if st != 200 or not m3.session_cookie(hdrs):
        return say("login", st)
    path = os.environ["RESET_PW_FILE"]
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(pw + "\n")
    return say("login", st, True)


if __name__ == "__main__":
    sys.exit(main())
