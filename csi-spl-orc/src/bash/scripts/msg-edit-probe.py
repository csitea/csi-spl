#!/usr/bin/env python3
"""specs/032 live proof: edit a sent message on a DEPLOYED hub, end to end.

Everything the deploy probes prove stops at rule 1 - an unauthenticated PATCH
is refused before the handler ever reaches the database, so a 401 reads the
same whether the DDL applied or not. This drives the whole chain instead:
sign in, post a message over the browser socket, PATCH it, and check that the
edit came back, reached a live socket, survived a re-read, and that the hub
still refuses an empty body.

It does NOT read the database; the register is checked separately with
do_spl_db_query against the msg_id this prints. That keeps the probe free of
any database credential.

Env: PROBE_API (https://<api host>), PROBE_AUTH (https://<auth fqdn>),
PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE. Prints one JSON verdict; exit 0 =
every step PASS. The password and the cookie are never printed.
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

# m3-e2e.py reads its globals at import time, so its env is set first.
os.environ.setdefault("M3_HUB_URL", API)
os.environ.setdefault("M3_AUTH_URL", AUTH)
os.environ.setdefault("M3_TENANT", TENANT)
_spec = importlib.util.spec_from_file_location(
    "m3_e2e", os.path.join(HERE, "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)

RESULTS = []


def record(step, ok, evidence):
    RESULTS.append(
        {"step": step, "result": "PASS" if ok else "FAIL", "evidence": evidence}
    )
    print(
        "%-4s %s %s"
        % ("PASS" if ok else "FAIL", step, json.dumps(evidence, sort_keys=True)[:500]),
        flush=True,
    )
    return ok


def finish(rc, extra=None):
    print(
        json.dumps(
            {"api": API, "tenant": TENANT, "rc": rc, "steps": RESULTS, **(extra or {})},
            sort_keys=True,
        )
    )
    return rc


def main():
    for k, v in (
        ("PROBE_API", API),
        ("PROBE_TENANT", TENANT),
        ("PROBE_EMAIL", EMAIL),
        ("PROBE_PW_FILE", PW_FILE),
    ):
        if not v:
            print("FATAL %s must be set" % k, file=sys.stderr)
            return 2
    with open(PW_FILE) as f:
        pw = f.read().strip()

    st, hdrs, out = m3.http(
        "POST",
        AUTH + "/api/v1/auth/login",
        {"email": EMAIL, "password": pw, "tenant": TENANT},
    )
    cookie = m3.session_cookie(hdrs) if st == 200 else ""
    if not record(
        "e-login",
        bool(cookie),
        {
            "status": st,
            "error": (out or {}).get("error") if isinstance(out, dict) else None,
        },
    ):
        return finish(2)

    ws = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    try:
        ws.send({"type": "hello", "as": "msg-edit-probe"})
        wel = ws.wait(lambda f: f.get("type") in ("welcome", "error"))
        hum = (wel or {}).get("as", "")
        task = (wel or {}).get("lobby_task_id", "")
        if not record(
            "e-welcome",
            bool(task) and hum.startswith("HUM-"),
            {"as": hum, "lobby_task_id": task},
        ):
            return finish(1)
        ws.send({"type": "subscribe", "task_id": task})
        ws.wait(lambda f: f.get("type") == "subscribed")

        nonce = uuid.uuid4().hex[:8]
        first = "msg-edit-probe %s ORIGINAL" % nonce
        second = "msg-edit-probe %s EDITED" % nonce
        ws.send({"type": "send", "task_id": task, "body": first})
        ack = ws.wait(lambda f: f.get("type") in ("ack", "error"))
        msg_id = (ack or {}).get("msg_id", "")
        if not record(
            "e-send",
            bool(msg_id) and (ack or {}).get("type") == "ack",
            {"msg_id": msg_id, "cursor": (ack or {}).get("cursor")},
        ):
            return finish(1)

        st, _, body = m3.http(
            "PATCH",
            API + "/v1/messages/" + msg_id,
            {"body": second},
            {"Cookie": cookie},
        )
        inner = (
            ((body or {}).get("env") or {}).get("msg") or {}
            if isinstance(body, dict)
            else {}
        )
        ok = (
            st == 200
            and inner.get("body") == second
            and bool((body or {}).get("edited_at"))
            and (body or {}).get("edited_by") == hum
            and (body or {}).get("revision") == 2
        )
        if not record(
            "e-patch",
            ok,
            {
                "status": st,
                "body": inner.get("body"),
                "edited_at": (body or {}).get("edited_at"),
                "edited_by": (body or {}).get("edited_by"),
                "revision": (body or {}).get("revision"),
                "error": (body or {}).get("error") if isinstance(body, dict) else None,
            },
        ):
            return finish(1, {"msg_id": msg_id})

        # FR-ED-009: the edit must NOT move the message in the topic.
        record(
            "e-not-moved",
            body.get("cursor") == ack.get("cursor")
            and body.get("received_at") == ack.get("received_at"),
            {
                "cursor_same": body.get("cursor") == ack.get("cursor"),
                "received_at_same": body.get("received_at") == ack.get("received_at"),
            },
        )

        # FR-ED-008: the same socket is in the fan-out audience.
        fr = ws.wait(
            lambda f: f.get("type") == "message_edited" and f.get("msg_id") == msg_id,
            timeout=10,
        )
        record(
            "e-frame",
            bool(fr)
            and (fr.get("envelope") or {}).get("body") == second
            and fr.get("revision") == 2,
            {
                "frame": {
                    k: fr.get(k) for k in ("type", "msg_id", "edited_by", "revision")
                }
                if fr
                else None,
                "frame_body": (fr.get("envelope") or {}).get("body") if fr else None,
            },
        )

        # FR-ED-007: a re-read agrees with the live frame.
        st, _, th = m3.http(
            "GET",
            API + "/v1/view/topics/" + task + "?order=desc&limit=20",
            None,
            {"Cookie": cookie},
        )
        row = (
            next(
                (
                    r
                    for r in (th or {}).get("messages", [])
                    if ((r.get("env") or {}).get("msg") or {}).get("msg_id") == msg_id
                ),
                None,
            )
            if st == 200
            else None
        )
        record(
            "e-reread",
            bool(row)
            and ((row.get("env") or {}).get("msg") or {}).get("body") == second
            and bool(row.get("edited_at"))
            and row.get("revision") == 2,
            {
                "status": st,
                "body": ((row.get("env") or {}).get("msg") or {}).get("body")
                if row
                else None,
                "edited_at": row.get("edited_at") if row else None,
                "revision": row.get("revision") if row else None,
            },
        )

        # CONTROL: the empty-body guard refuses, live, and changes nothing.
        st, _, refused = m3.http(
            "PATCH", API + "/v1/messages/" + msg_id, {"body": "   "}, {"Cookie": cookie}
        )
        record(
            "e-empty-refused",
            st == 400 and (refused or {}).get("error") == "empty_body",
            {"status": st, "error": (refused or {}).get("error")},
        )
        st, _, after = m3.http(
            "GET",
            API + "/v1/view/topics/" + task + "?order=desc&limit=20",
            None,
            {"Cookie": cookie},
        )
        row2 = (
            next(
                (
                    r
                    for r in (after or {}).get("messages", [])
                    if ((r.get("env") or {}).get("msg") or {}).get("msg_id") == msg_id
                ),
                None,
            )
            if st == 200
            else None
        )
        record(
            "e-refusal-changed-nothing",
            bool(row2)
            and ((row2.get("env") or {}).get("msg") or {}).get("body") == second
            and row2.get("revision") == 2,
            {
                "body": ((row2.get("env") or {}).get("msg") or {}).get("body")
                if row2
                else None,
                "revision": row2.get("revision") if row2 else None,
            },
        )

        rc = 0 if all(r["result"] == "PASS" for r in RESULTS) else 1
        return finish(
            rc,
            {
                "msg_id": msg_id,
                "task_id": task,
                "human": hum,
                "original_body": first,
                "edited_body": second,
            },
        )
    finally:
        ws.close()


if __name__ == "__main__":
    sys.exit(main())
