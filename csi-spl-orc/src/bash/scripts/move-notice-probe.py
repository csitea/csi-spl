#!/usr/bin/env python3
"""Live proof, first half: a message made a topic of its own on a DEPLOYED hub
(bug topic 226a8209, prd t1 645f9e3e).

Signs one member in, posts a topic card c0 and a reply m1 into channel
PROBE_CHANNEL over the browser socket (topic A), then promotes m1 to a topic
of its own (N) with POST /v1/messages/<m1>/promote-topic. The second half -
hub-tail on N and on A as a desk box that holds both - is the action's
(do_spl_move_notice_probe): only a box reads hub-tail.

Env: PROBE_API (https://<api host>), PROBE_AUTH (https://<auth fqdn>),
PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE, PROBE_CHANNEL. Prints one PASS/FAIL
line per step, then one JSON line {c0, m1, task_a, task_n, human, rc}; exit 0
= every step PASS. The password and the cookie are never printed.
"""
import importlib.util
import json
import os
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))

API = os.environ.get("PROBE_API", "").rstrip("/")
AUTH = os.environ.get("PROBE_AUTH", "").rstrip("/") or API
TENANT = os.environ.get("PROBE_TENANT", "")
EMAIL = os.environ.get("PROBE_EMAIL", "")
PW_FILE = os.environ.get("PROBE_PW_FILE", "")
CHANNEL = os.environ.get("PROBE_CHANNEL", "")

# m3-e2e.py reads its globals at import time, so its env is set first.
os.environ.setdefault("M3_HUB_URL", API)
os.environ.setdefault("M3_AUTH_URL", AUTH)
os.environ.setdefault("M3_TENANT", TENANT)
_spec = importlib.util.spec_from_file_location("m3_e2e", os.path.join(HERE, "m3-e2e.py"))
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)

OUT = {}
OK = True


def record(step, ok, evidence):
    global OK
    OK = OK and ok
    print("%-4s %s %s" % ("PASS" if ok else "FAIL", step, json.dumps(evidence, sort_keys=True)[:500]), flush=True)
    return ok


def finish(rc):
    print(json.dumps(dict(OUT, rc=rc, tenant=TENANT, channel=CHANNEL), sort_keys=True))
    return rc


def post(ws, task, is_parent, body):
    mid = str(uuid.uuid4())
    ws.send({"type": "send", "msg_id": mid, "task_id": task, "channel": CHANNEL, "kind": "note",
             "is_parent": is_parent, "body": body})
    ack = ws.wait(lambda f: f.get("type") in ("ack", "error"))
    return mid, ack or {}


def main():
    for k, v in (("PROBE_API", API), ("PROBE_TENANT", TENANT), ("PROBE_EMAIL", EMAIL),
                 ("PROBE_PW_FILE", PW_FILE), ("PROBE_CHANNEL", CHANNEL)):
        if not v:
            print("FATAL %s must be set" % k, file=sys.stderr)
            return 2
    with open(PW_FILE) as f:
        pw = f.read().strip()
    st, hdrs, out = m3.http("POST", AUTH + "/api/v1/auth/login", {"email": EMAIL, "password": pw, "tenant": TENANT})
    cookie = m3.session_cookie(hdrs) if st == 200 else ""
    if not record("m-login", bool(cookie), {"status": st, "error": (out or {}).get("error") if isinstance(out, dict) else None}):
        return finish(2)

    ws = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    try:
        ws.send({"type": "hello", "as": "move-notice-probe"})
        wel = ws.wait(lambda f: f.get("type") in ("welcome", "error")) or {}
        OUT["human"] = wel.get("as", "")
        if not record("m-welcome", OUT["human"].startswith("HUM-"), {"as": OUT["human"]}):
            return finish(1)
        nonce = uuid.uuid4().hex[:8]
        task_a = str(uuid.uuid4())
        c0, ack = post(ws, task_a, 1, "move-notice-probe %s: topic A (stays here)" % nonce)
        if not record("m-card", ack.get("type") == "ack", {"msg_id": c0, "task_id": task_a, "error": ack.get("error")}):
            return finish(1)
        m1, ack = post(ws, task_a, 0, "move-notice-probe %s: this reply becomes its own topic" % nonce)
        if not record("m-reply", ack.get("type") == "ack", {"msg_id": m1, "error": ack.get("error")}):
            return finish(1)
        OUT.update(c0=c0, m1=m1, task_a=task_a)
    finally:
        ws.close()

    st, _, pr = m3.http("POST", API + "/v1/messages/" + m1 + "/promote-topic", {}, {"Cookie": cookie})
    pr = pr if isinstance(pr, dict) else {}
    OUT["task_n"] = pr.get("task_id", "")
    record("m-promote", st == 200 and pr.get("from_task") == task_a and OUT["task_n"] not in ("", task_a),
           {"status": st, "task_id": OUT["task_n"], "from_task": pr.get("from_task"), "error": pr.get("error")})
    return finish(0 if OK else 1)


if __name__ == "__main__":
    sys.exit(main())
