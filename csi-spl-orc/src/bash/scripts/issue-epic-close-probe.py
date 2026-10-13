#!/usr/bin/env python3
"""SPL-1643 live proof: closing an epic closes and archives its issues.

Drives a DEPLOYED hub as one signed-in member (issues-v1 section 9): file a
test epic with 2 open issues, check the unconfirmed close is refused with
409 epic_close_confirm naming 2, close with cascade, check the epic and both
issues are archived (an archived issue reads 404), unarchive the epic and
check all 3 come back with status done, then archive the tree again.

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

RESULTS = []


def load_m3():
    # m3-e2e.py reads its globals at import time, so its env is set first.
    os.environ.setdefault("M3_HUB_URL", API)
    os.environ.setdefault("M3_AUTH_URL", AUTH)
    os.environ.setdefault("M3_TENANT", TENANT)
    spec = importlib.util.spec_from_file_location(
        "m3_e2e", os.path.join(HERE, "m3-e2e.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def record(step, ok, evidence):
    RESULTS.append(
        {"step": step, "result": "PASS" if ok else "FAIL", "evidence": evidence}
    )
    print(
        f"{'PASS' if ok else 'FAIL':<4} {step} {json.dumps(evidence, sort_keys=True)[:500]}",
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
            print(f"FATAL {k} must be set", file=sys.stderr)
            return 2
    m3 = load_m3()
    with open(PW_FILE) as f:
        pw = f.read().strip()
    st, hdrs, _ = m3.http(
        "POST",
        AUTH + "/api/v1/auth/login",
        {"email": EMAIL, "password": pw, "tenant": TENANT},
    )
    cookie = m3.session_cookie(hdrs) if st == 200 else ""
    if not record("a-login", bool(cookie), {"status": st}):
        return finish(1)
    h = {"Cookie": cookie}

    def call(method, path, body=None):
        return m3.http(method, API + path, body, h)[0::2]

    tag = uuid.uuid4().hex[:8]
    st, out = call(
        "POST",
        "/v1/issues",
        {"title": "SPL-1643 probe epic " + tag, "kind": "epic", "status": "todo"},
    )
    epic = (out or {}).get("issue", {}).get("key", "") if isinstance(out, dict) else ""
    if not record(
        "b-create-epic", st == 201 and bool(epic), {"status": st, "key": epic}
    ):
        return finish(1)
    kids = []
    for i in (1, 2):
        st, out = call(
            "POST",
            "/v1/issues",
            {
                "title": f"SPL-1643 probe issue {i} {tag}",
                "epic": epic,
                "status": "todo",
            },
        )
        k = (out or {}).get("issue", {}).get("key", "") if isinstance(out, dict) else ""
        kids.append(k)
        if not record(
            f"c-create-issue-{i}", st == 201 and bool(k), {"status": st, "key": k}
        ):
            return finish(1, {"epic": epic})
    tree = [epic] + kids
    extra = {"epic": epic, "issues": kids}
    try:
        st, out = call("PATCH", "/v1/issues/" + epic, {"status": "done"})
        err = out if isinstance(out, dict) else {}
        ok = (
            st == 409
            and err.get("error") == "epic_close_confirm"
            and " 2 open" in err.get("detail", "")
        )
        record(
            "d-close-unconfirmed-refused",
            ok,
            {"status": st, "error": err.get("error"), "detail": err.get("detail")},
        )
        st, out = call(
            "PATCH", "/v1/issues/" + epic, {"status": "done", "cascade": True}
        )
        ans = out if isinstance(out, dict) else {}
        ok = (
            st == 200
            and ans.get("archived") is True
            and sorted(ans.get("closed") or []) == sorted(kids)
            and sorted(ans.get("descendants") or []) == sorted(kids)
        )
        record(
            "e-close-cascade",
            ok,
            {
                "status": st,
                "archived": ans.get("archived"),
                "closed": ans.get("closed"),
                "descendants": ans.get("descendants"),
                "cascade_error": ans.get("cascade_error"),
            },
        )
        reads = {k: call("GET", "/v1/view/issues/" + k)[0] for k in tree}
        record(
            "f-all-3-archived", all(v == 404 for v in reads.values()), {"reads": reads}
        )
        st, out = call("POST", f"/v1/issues/{epic}/unarchive")
        ans = out if isinstance(out, dict) else {}
        record(
            "g-unarchive-epic",
            st == 200 and sorted(ans.get("descendants") or []) == sorted(kids),
            {"status": st, "descendants": ans.get("descendants")},
        )
        back = {}
        for k in tree:
            st, out = call("GET", "/v1/view/issues/" + k)
            back[k] = [
                st,
                ((out or {}).get("issue") or {}).get("status")
                if isinstance(out, dict)
                else None,
            ]
        record(
            "h-all-3-restored-done",
            all(v == [200, "done"] for v in back.values()),
            {"reads": back},
        )
    finally:
        st, _ = call("POST", f"/v1/issues/{epic}/archive?cascade=1")
        record("z-cleanup-archive", st in (200, 404), {"status": st})
    rc = 0 if all(r["result"] == "PASS" for r in RESULTS) else 1
    return finish(rc, extra)


if __name__ == "__main__":
    sys.exit(main())
