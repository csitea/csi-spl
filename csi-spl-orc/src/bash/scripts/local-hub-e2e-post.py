#!/usr/bin/env python3
"""do_spl_local_hub_e2e, the post step: sign in natively to the local hub as
the throwaway owner, send ONE message to #general over the browser socket
(/v1/wui/ws) the way the web UI does, then read its topic back.

Env: LHE2E_API (http://127.0.0.1:<hub port>), LHE2E_TENANT, LHE2E_EMAIL,
LHE2E_PW_FILE, LHE2E_BODY. Prints one JSON line; exit 0 = the body read back,
1 = refused or not read back, 2 = could not sign in. The password and the
cookie are never printed.
"""

import importlib.util
import json
import os
import sys
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
API = os.environ.get("LHE2E_API", "").rstrip("/")
os.environ["M3_HUB_URL"] = API
os.environ["M3_AUTH_URL"] = API
os.environ["M3_TENANT"] = os.environ.get("LHE2E_TENANT", "")
_spec = importlib.util.spec_from_file_location(
    "m3_e2e", os.path.join(HERE, "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)


def login():
    with open(os.environ["LHE2E_PW_FILE"]) as fh:
        pw = fh.read().strip()
    st, hdrs, _ = m3.http(
        "POST",
        API + "/api/v1/auth/login",
        {
            "email": os.environ["LHE2E_EMAIL"],
            "password": pw,
            "tenant": os.environ["LHE2E_TENANT"],
        },
    )
    return st, (m3.session_cookie(hdrs) if st == 200 else "")


def send(cookie, body):
    f = {
        "type": "send",
        "task_id": str(uuid.uuid4()),
        "kind": "note",
        "body": body,
        "msg_id": str(uuid.uuid4()),
        "channel": "general",
        "is_parent": 1,
    }
    ws = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    try:
        ws.send({"type": "hello", "as": "local-hub-e2e"})
        wel = ws.wait(lambda x: x.get("type") in ("welcome", "error"))
        if not wel or wel.get("type") != "welcome":
            return f, {"step": "welcome", "frame": wel}
        ws.send(f)
        ack = ws.wait(
            lambda x: (
                x.get("msg_id") == f["msg_id"] and x.get("type") in ("ack", "error")
            ),
            25,
        )
        if not ack or ack.get("type") != "ack":
            return f, {"step": "send", "frame": ack}
        return f, None
    finally:
        ws.close()


def body_of(m):
    """A topic view row's body: the hub nests it in the envelope
    (messages[].env.msg.body); a flat "body" is read too."""
    return m.get("body") or ((m.get("env") or {}).get("msg") or {}).get("body")


def main():
    st, cookie = login()
    if not cookie:
        print(json.dumps({"step": "login", "status": st}))
        return 2
    body = os.environ["LHE2E_BODY"]
    f, err = send(cookie, body)
    if err:
        print(json.dumps(err))
        return 1
    st, _, out = m3.http(
        "GET", API + "/v1/view/topics/" + f["task_id"], headers={"Cookie": cookie}
    )
    msgs = out.get("messages", []) if st == 200 and isinstance(out, dict) else []
    back = any(body_of(m) == body for m in msgs)
    print(
        json.dumps(
            {"step": "read-back", "status": st, "task_id": f["task_id"], "ok": back}
        )
    )
    return 0 if back else 1


if __name__ == "__main__":
    sys.exit(main())
