#!/usr/bin/env python3
"""do_spl_dev_password_reset, the hub half: give a dev native (015) account a
NEW password, then one sign-in to the tenant with it through the hub.

Two ways to set it, the first that applies:
- operator route (dev since SPL-2157, the hub answers no debug token there):
  `spool hub-reset-password --tenant --email --password-stdin` against the hub
  DB (RESET_SPOOL, SPL_PROXY_DSN from the action's Cloud SQL proxy, as the
  env's project SA). The password goes on STDIN only.
- the hub's own reset flow, lde only: POST password/forgot -> debug_token ->
  POST password/reset. A hub that answers no debug token and no operator
  route set fails here, naming why.

Env: RESET_API (https://<api host>), RESET_EMAIL, RESET_TENANT, RESET_PW_FILE
(written 0600 only after the reset AND the sign-in worked); RESET_SPOOL +
SPL_PROXY_DSN for the operator route. Prints one JSON line
{"step", "status", "via"}; exit 0 = reset and signed in. The token, the DSN
and the password are never printed.
"""

import importlib.util
import json
import os
import secrets
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "m3_e2e", os.path.join(HERE, "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)
API = os.environ.get("RESET_API", "").rstrip("/") + "/api/v1/auth/"
NO_DEBUG = (
    "the hub answered no debug_token (lde only since SPL-2157): run "
    "do_spl_dev_password_reset, which sets the operator route"
)


def say(step, status, via, ok=False, **ev):
    print(json.dumps(dict({"step": step, "status": status, "via": via}, **ev)))
    return 0 if ok else 1


def operator_reset(email, tenant, pw):
    """spool hub-reset-password; (rc, error line without the DSN)."""
    env = dict(os.environ, SPOOL_HUB_DB_DSN=os.environ["SPL_PROXY_DSN"])
    env.pop("SPL_PROXY_DSN")
    r = subprocess.run(
        [
            os.environ["RESET_SPOOL"],
            "hub-reset-password",
            "--tenant",
            tenant,
            "--email",
            email,
            "--password-stdin",
        ],
        input=pw + "\n",
        capture_output=True,
        text=True,
        env=env,
        timeout=120,
    )
    return r.returncode, (r.stderr or r.stdout).strip().splitlines()[-1:] or [""]


def set_password(email, tenant, pw):
    """(ok, via, step, status, evidence)."""
    if os.environ.get("RESET_SPOOL") and os.environ.get("SPL_PROXY_DSN"):
        rc, err = operator_reset(email, tenant, pw)
        return (
            rc == 0,
            "operator",
            "hub-reset-password",
            rc,
            {} if rc == 0 else {"error": err[0]},
        )
    st, _, out = m3.http("POST", API + "password/forgot", {"email": email})
    token = out.get("debug_token", "") if isinstance(out, dict) else ""
    if not token:
        return False, "debug_token", "forgot", st, {"error": NO_DEBUG}
    st, _, _ = m3.http("POST", API + "password/reset", {"token": token, "password": pw})
    return st in (200, 204), "debug_token", "reset", st, {}


def main():
    email, tenant = os.environ["RESET_EMAIL"], os.environ["RESET_TENANT"]
    pw = secrets.token_urlsafe(18)
    ok, via, step, st, ev = set_password(email, tenant, pw)
    if not ok:
        return say(step, st, via, **ev)
    st, hdrs, _ = m3.http(
        "POST", API + "login", {"email": email, "password": pw, "tenant": tenant}
    )
    if st != 200 or not m3.session_cookie(hdrs):
        return say("login", st, via)
    path = os.environ["RESET_PW_FILE"]
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    os.fchmod(fd, 0o600)  # an existing file keeps its mode through O_CREAT
    with os.fdopen(fd, "w") as f:
        f.write(pw + "\n")
    return say("login", st, via, True)


if __name__ == "__main__":
    sys.exit(main())
