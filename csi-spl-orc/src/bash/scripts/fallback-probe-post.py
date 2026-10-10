#!/usr/bin/env python3
"""SPL-997 live proof, the HUMAN half: sign in as the test member and post one
new topic into a channel over the browser socket (/v1/wui/ws), exactly as
the web UI does, so the hub signs it with box-wui and runs its fallback rule.

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL,
PROBE_PW_FILE, PROBE_CHANNEL, PROBE_BODY. Optional (SPL-1004 reply probe):
PROBE_TO (msg.to, e.g. a person), PROBE_TASK (post into this topic),
PROBE_PARENT=0 (a reply: is_parent 0 and NO channel tag, as the reply pane
sends it). Prints one JSON line
{"msg_id", "task_id", "sent_at"}; exit 0 = acked, 1 = refused, 2 = could not
sign in. The password and the cookie are never printed.
"""

import importlib.util
import json
import os
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
API = os.environ.get("PROBE_API", "").rstrip("/")
os.environ.setdefault("M3_HUB_URL", API)
os.environ.setdefault("M3_AUTH_URL", API)
os.environ.setdefault("M3_TENANT", os.environ.get("PROBE_TENANT", ""))
_spec = importlib.util.spec_from_file_location(
    "m3_e2e", os.path.join(HERE, "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)


def main():
    tenant, ch, body = (
        os.environ["PROBE_TENANT"],
        os.environ["PROBE_CHANNEL"],
        os.environ["PROBE_BODY"],
    )
    with open(os.environ["PROBE_PW_FILE"]) as f:
        pw = f.read().strip()
    st, hdrs, out = m3.http(
        "POST",
        API + "/api/v1/auth/login",
        {"email": os.environ["PROBE_EMAIL"], "password": pw, "tenant": tenant},
    )
    cookie = m3.session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        print(json.dumps({"step": "login", "status": st}))
        return 2
    ws = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    try:
        ws.send({"type": "hello", "as": "fallback-probe"})
        wel = ws.wait(lambda f: f.get("type") in ("welcome", "error"))
        if not wel or wel.get("type") != "welcome":
            print(json.dumps({"step": "welcome", "frame": wel}))
            return 1
        task = os.environ.get("PROBE_TASK") or str(uuid.uuid4())
        parent = 0 if os.environ.get("PROBE_PARENT") == "0" else 1
        frame = {
            "type": "send",
            "task_id": task,
            "kind": "note",
            "body": body,
            "is_parent": parent,
        }
        if parent:
            frame["channel"] = ch
        if os.environ.get("PROBE_TO"):
            frame["to"] = os.environ["PROBE_TO"]
        sent_at = time.time()
        ws.send(frame)
        ack = ws.wait(lambda f: f.get("type") in ("ack", "error"))
        if not ack or ack.get("type") != "ack":
            print(json.dumps({"step": "send", "frame": ack}))
            return 1
        print(
            json.dumps(
                {"msg_id": ack.get("msg_id", ""), "task_id": task, "sent_at": sent_at}
            )
        )
        return 0
    finally:
        ws.close()


if __name__ == "__main__":
    sys.exit(main())
