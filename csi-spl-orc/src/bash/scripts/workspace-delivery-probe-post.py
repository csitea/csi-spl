#!/usr/bin/env python3
"""do_spl_workspace_delivery_probe, the HUMAN half: sign in as the workspace's
probe member and send ONE message over the browser socket (/v1/wui/ws), the
way the web UI does.

  PROBE_TO set      a DM to that agent (no channel): the hidden probe topic,
                    seen by the probe member and the agent only
  PROBE_CHANNEL set a new topic in that channel (the t1 #alerts blocker post)

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE,
PROBE_BODY, PROBE_TASK (the topic; default a new uuid), PROBE_TO or
PROBE_CHANNEL. Prints one JSON line {"msg_id", "task_id"}; exit 0 = acked,
1 = refused, 2 = could not sign in. The password and the cookie are never
printed.
"""

import importlib.util
import json
import os
import sys
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


def frame():
    f = {
        "type": "send",
        "task_id": os.environ.get("PROBE_TASK") or str(uuid.uuid4()),
        "kind": "note",
        "body": os.environ["PROBE_BODY"],
        "msg_id": str(uuid.uuid4()),
    }
    if os.environ.get("PROBE_TO"):
        f["to"] = os.environ["PROBE_TO"]
    else:
        f["channel"] = os.environ["PROBE_CHANNEL"]
        f["is_parent"] = 1
    return f


def main():
    with open(os.environ["PROBE_PW_FILE"]) as fh:
        pw = fh.read().strip()
    st, hdrs, _ = m3.http(
        "POST",
        API + "/api/v1/auth/login",
        {
            "email": os.environ["PROBE_EMAIL"],
            "password": pw,
            "tenant": os.environ["PROBE_TENANT"],
        },
    )
    cookie = m3.session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        print(json.dumps({"step": "login", "status": st}))
        return 2
    ws = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    try:
        ws.send({"type": "hello", "as": "workspace-delivery-probe"})
        wel = ws.wait(lambda f: f.get("type") in ("welcome", "error"))
        if not wel or wel.get("type") != "welcome":
            print(json.dumps({"step": "welcome", "frame": wel}))
            return 1
        f = frame()
        ws.send(f)
        ack = ws.wait(
            lambda x: (
                x.get("msg_id") == f["msg_id"] and x.get("type") in ("ack", "error")
            ),
            25,
        )
        if not ack or ack.get("type") != "ack":
            print(json.dumps({"step": "send", "frame": ack}))
            return 1
        print(
            json.dumps(
                {"msg_id": ack.get("msg_id") or f["msg_id"], "task_id": f["task_id"]}
            )
        )
        return 0
    finally:
        ws.close()


if __name__ == "__main__":
    sys.exit(main())
