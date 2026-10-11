#!/usr/bin/env python3
"""do_spl_probe_member_seat, the sign-in half: sign the (already invited) probe
member in with the native provider (015), registering it and verifying it with
the dev hub's debug token when no stored password works yet. m3-e2e.py's
native_login does the work, so its password lands in <M3_STATE>/pw-human
(0600), the file do_spl_workspace_delivery_probe reads.

Env: M3_AUTH_URL / M3_HUB_URL (https://<api host>), M3_TENANT, M3_STATE,
M3_HUMAN_EMAIL. Prints one JSON line {"status", "human_id"}; exit 0 = signed
in to the tenant, 1 = not. The password and the cookie are never printed.
"""

import importlib.util
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location(
    "m3_e2e", os.path.join(HERE, "m3-e2e.py")
)
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)


def human_id(body):
    if not isinstance(body, dict):
        return ""
    for k in ("human_id", "id"):
        if isinstance(body.get(k), str) and body[k].startswith("HUM-"):
            return body[k]
    for v in body.values():
        if isinstance(v, dict):
            h = human_id(v)
            if h:
                return h
    return ""


def main():
    st, body, cookie = m3.native_login(
        os.environ["M3_HUMAN_EMAIL"], os.environ["M3_TENANT"], "human"
    )
    out = {"status": st, "human_id": human_id(body)}
    if st != 200 or not cookie:
        out["error"] = body.get("error") if isinstance(body, dict) else ""
        out["step"] = body.get("step") if isinstance(body, dict) else ""
    print(json.dumps(out))
    return 0 if st == 200 and cookie else 1


if __name__ == "__main__":
    sys.exit(main())
