#!/usr/bin/env python3
"""SPL-1008 live seed, the HUMAN half: sign in ONCE as the test member and
send a plan of posts over one browser socket (/v1/wui/ws), exactly as the web
UI does. One sign-in per batch: native login is rate limited per email.

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL,
PROBE_PW_FILE, PROBE_CHANNEL, PROBE_PLAN - a JSON list of
{"task": "new" | "<uuid>" | "$<n>", "body": "<text>"}: "new" opens a topic
in the channel (is_parent 1, channel tagged); a uuid, or "$<n>" (the task of
the n-th post of this plan), is a reply in it (is_parent 0, no channel tag,
as the reply pane sends it). Prints one JSON list
[{"msg_id", "task_id"}]; exit 0 = every post acked, 1 = one refused, 2 = could
not sign in. The password and the cookie are never printed.
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


def frames(plan, channel, done):
    """The send frame for each plan step; `done` holds the tasks sent so far."""
    for step in plan:
        task = str(step.get("task", "new"))
        if task.startswith("$"):
            task = done[int(task[1:])]["task_id"]
        f = {
            "type": "send",
            "msg_id": str(uuid.uuid4()),
            "kind": "note",
            "body": str(step["body"]),
        }
        if task == "new":
            f.update(task_id=str(uuid.uuid4()), is_parent=1, channel=channel)
        else:
            f.update(task_id=task, is_parent=0)
        yield f


def main():
    tenant, ch = os.environ["PROBE_TENANT"], os.environ["PROBE_CHANNEL"]
    plan = json.loads(os.environ["PROBE_PLAN"])
    with open(os.environ["PROBE_PW_FILE"]) as f:
        pw = f.read().strip()
    st, hdrs, _ = m3.http(
        "POST",
        API + "/api/v1/auth/login",
        {"email": os.environ["PROBE_EMAIL"], "password": pw, "tenant": tenant},
    )
    cookie = m3.session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        print(json.dumps({"step": "login", "status": st}))
        return 2
    ws = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    done = []
    try:
        ws.send({"type": "hello", "as": "reply-count-probe"})
        wel = ws.wait(lambda f: f.get("type") in ("welcome", "error"))
        if not wel or wel.get("type") != "welcome":
            print(json.dumps({"step": "welcome", "frame": wel}))
            return 1
        for frame in frames(plan, ch, done):
            ws.send(frame)
            mid = frame["msg_id"]
            ack = ws.wait(
                lambda f: (
                    f.get("type") in ("ack", "error")
                    and f.get("msg_id") in (mid, None, "")
                )
            )
            if not ack or ack.get("type") != "ack":
                print(json.dumps({"step": "send", "n": len(done), "frame": ack}))
                return 1
            done.append({"msg_id": ack.get("msg_id", mid), "task_id": frame["task_id"]})
        print(json.dumps(done))
        return 0
    finally:
        ws.close()


if __name__ == "__main__":
    sys.exit(main())
