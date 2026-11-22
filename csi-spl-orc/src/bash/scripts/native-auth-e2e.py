#!/usr/bin/env python3
"""do_spl_native_auth_e2e, the flow half (SPL-6182): the whole native
(email + password) account flow against a cloud hub, with no human step. The
account is a NEW plus-address of the relay mailbox; both mails are read from
that mailbox over IMAP with m3-e2e.py's reader.

Steps, each one PASS/FAIL line with evidence (http codes, mail Message-ID,
served /version), never a token, password, cookie or the address:
  0 version   GET /version: the served build
  1 sign-up   POST register -> 202 verification_required
  2 mail      the verify mail reaches the mailbox (/verify-email link)
  3 verify    POST email/verify (token + password) -> 200 + session cookie
  4 sign-in   POST login with the password -> 200 + session cookie
  5 wrong     CONTROL: POST login with a wrong password -> 401
  6 forgot    POST password/forgot -> 204 (after the account mail floor)
  7 mail      the reset mail reaches the mailbox (/reset-password link)
  8 reset     POST password/reset (token + new password) -> 200 + session
  9 old       CONTROL: the old password -> 401
 10 new       POST login with the new password -> 200 + session cookie

Env: NAE_AUTH_URL (https://<api host>), NAE_EMAIL (the fresh plus-address),
NAE_STATE (0700 dir: results.json), NAE_FLOOR_S (seconds between the two
mails, default 65: the hub's account mail floor is 60 s), M3_IMAP_*.
Exit 0 = every step PASS.
"""

import importlib.util
import json
import os
import secrets
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "m3_e2e", os.path.join(HERE, "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)

AUTH = os.environ.get("NAE_AUTH_URL", "").rstrip("/")
API = AUTH + "/api/v1/auth/"
FLOOR_S = int(os.environ.get("NAE_FLOOR_S", "65"))
RESULTS = []


def record(step, ok, ev):
    RESULTS.append({"step": step, "result": "PASS" if ok else "FAIL", "evidence": ev})
    print(
        "%s %s %s" % ("PASS" if ok else "FAIL", step, json.dumps(ev, sort_keys=True)),
        flush=True,
    )
    return ok


def post(path, body):
    st, hdrs, out = m3.http("POST", API + path, body)
    ev = {"http": st}
    if isinstance(out, dict):
        for k in ("status", "error", "code"):
            if k in out and isinstance(out[k], (str, int)):
                ev["body_" + k] = out[k]
    ev["session_cookie"] = bool(m3.session_cookie(hdrs))
    return st, ev


def mail_step(step, email, link):
    token, ev = m3.imap_verify_token(email, set(), link)
    ev = {k: v for k, v in ev.items() if k != "link_page"}
    record(step, bool(token), ev)
    return token


def flow(email):
    st, _, out = m3.http("GET", AUTH + "/version")
    record("0 version", st == 200, {"http": st, "version": out if st == 200 else None})
    pw, pw2 = secrets.token_urlsafe(18), secrets.token_urlsafe(18)
    st, ev = post("register", {"email": email, "password": pw, "name": "Native E2E"})
    t_mail = time.time()
    if not record(
        "1 sign-up", st == 202 and ev.get("body_status") == "verification_required", ev
    ):
        return
    tok = mail_step("2 verify mail", email, m3.VERIFY_LINK)
    if not tok:
        return
    st, ev = post("email/verify", {"token": tok, "password": pw})
    record("3 verify", st == 200 and ev["session_cookie"], ev)
    st, ev = post("login", {"email": email, "password": pw})
    record("4 sign-in", st == 200 and ev["session_cookie"], ev)
    st, ev = post("login", {"email": email, "password": pw + "x"})
    record("5 wrong password (CONTROL)", st == 401 and not ev["session_cookie"], ev)
    time.sleep(max(0, t_mail + FLOOR_S - time.time()))
    st, ev = post("password/forgot", {"email": email})
    if not record("6 forgot", st == 204, ev):
        return
    tok = mail_step("7 reset mail", email, m3.RESET_LINK)
    if not tok:
        return
    st, ev = post("password/reset", {"token": tok, "password": pw2})
    record("8 reset", st == 200 and ev["session_cookie"], ev)
    st, ev = post("login", {"email": email, "password": pw})
    record("9 old password (CONTROL)", st == 401 and not ev["session_cookie"], ev)
    st, ev = post("login", {"email": email, "password": pw2})
    record("10 sign-in new password", st == 200 and ev["session_cookie"], ev)


def main():
    email, state = os.environ["NAE_EMAIL"], os.environ["NAE_STATE"]
    if not (AUTH and m3.IMAP_USER):
        print(json.dumps({"ok": False, "error": "need NAE_AUTH_URL and M3_IMAP_USER"}))
        return 1
    flow(email)
    p = os.path.join(state, "results.json")
    with open(p, "w") as f:
        json.dump({"auth": AUTH, "results": RESULTS}, f, indent=1, sort_keys=True)
    ok = (
        bool(RESULTS)
        and len(RESULTS) == 11
        and all(r["result"] == "PASS" for r in RESULTS)
    )
    print(
        "%s native auth e2e: %d/11 steps PASS, results %s"
        % ("PASS" if ok else "FAIL", sum(r["result"] == "PASS" for r in RESULTS), p),
        flush=True,
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
