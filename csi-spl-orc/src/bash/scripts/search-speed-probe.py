#!/usr/bin/env python3
"""SPL-1832 search speed probe, READ-ONLY: time GET /v1/view/search per term.

Signs one member in, then for each term issues PROBE_N searches exactly as the
WUI's first call does (GET /v1/view/search?q=<term>, grouped, no limit), and,
when that first page offers a message cursor, PROBE_N "Load more" calls of the
message section (?cursor=<next>). Each request is timed on the client (wall
clock, ms). Nothing is written: GET only after the sign-in.

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE,
PROBE_N (searches per term), PROBE_TERMS (comma list).

Prints one row per (term, call): n, statuses, p50 / max ms and the rows of the
message section, then one JSON summary; exit 0 = every search answered 200,
1 = some did not, 2 = could not sign in. The password and cookie are never
printed.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request


def http(method, url, body=None, cookie=""):
    h = {"Accept": "application/json"}
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        h["Content-Type"] = "application/json"
    if cookie:
        h["Cookie"] = cookie
    req = urllib.request.Request(url, data=data, headers=h, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=60)
        status, hdrs, raw = r.status, r.headers, r.read()
    except urllib.error.HTTPError as e:
        status, hdrs, raw = e.code, e.headers, e.read()
    except (urllib.error.URLError, OSError):
        return 0, None, None
    try:
        out = json.loads(raw.decode()) if raw else None
    except ValueError:
        out = None
    return status, hdrs, out


def session_cookie(hdrs):
    for v in (hdrs.get_all("Set-Cookie") if hdrs else None) or []:
        pair = v.split(";", 1)[0]
        if pair.startswith("spool_session") and "=" in pair and pair.split("=", 1)[1]:
            return pair
    return ""


def messages(body):
    g = (body.get("groups") or {}) if isinstance(body, dict) else {}
    return g.get("messages") or {}


def p50(xs):
    s = sorted(xs)
    return s[(len(s) - 1) // 2] if s else 0


def run(api, cookie, path, n):
    """n timed GETs of path -> (statuses, ms list, message rows, next cursor)."""
    codes, ms, rows, nxt = {}, [], 0, ""
    for _ in range(n):
        t0 = time.monotonic()
        st, _, body = http("GET", api + path, cookie=cookie)
        ms.append(round((time.monotonic() - t0) * 1000))
        codes[str(st)] = codes.get(str(st), 0) + 1
        if st == 200:
            sec = messages(body)
            rows, nxt = len(sec.get("results") or []), sec.get("next") or ""
    return codes, ms, rows, nxt


def main():
    api = os.environ.get("PROBE_API", "").rstrip("/")
    n = int(os.environ.get("PROBE_N", "5"))
    terms = [t for t in (os.environ.get("PROBE_TERMS") or "").split(",") if t]
    with open(os.environ.get("PROBE_PW_FILE", "")) as f:
        pw = f.read().strip()
    st, hdrs, out = http(
        "POST",
        api + "/api/v1/auth/login",
        {
            "email": os.environ.get("PROBE_EMAIL", ""),
            "password": pw,
            "tenant": os.environ.get("PROBE_TENANT", ""),
        },
    )
    cookie = session_cookie(hdrs) if st == 200 else ""
    if not cookie:
        err = out.get("error", "") if isinstance(out, dict) else ""
        print(json.dumps({"step": "login", "status": st, "error": err}))
        return 2
    ok, summary = True, []
    print(
        "%-16s %-6s %3s  %-14s %7s %7s %5s"
        % ("term", "call", "n", "statuses", "p50_ms", "max_ms", "rows")
    )
    for term in terms:
        q = "/v1/view/search?" + urllib.parse.urlencode({"q": term})
        calls = [("first", q)]
        codes, ms, rows, nxt = run(api, cookie, q, n)
        results = [(codes, ms, rows)]
        if nxt:
            calls.append(("more", q + "&" + urllib.parse.urlencode({"cursor": nxt})))
            codes, ms, rows, _ = run(api, cookie, calls[1][1], n)
            results.append((codes, ms, rows))
        for (call, _), (codes, ms, rows) in zip(calls, results):
            ok = ok and codes == {"200": n}
            stat = ",".join("%s=%d" % kv for kv in sorted(codes.items()))
            print(
                "%-16s %-6s %3d  %-14s %7d %7d %5d"
                % (term, call, n, stat, p50(ms), max(ms), rows)
            )
            summary.append(
                {
                    "term": term,
                    "call": call,
                    "n": n,
                    "statuses": codes,
                    "ms": ms,
                    "p50_ms": p50(ms),
                    "max_ms": max(ms),
                    "rows": rows,
                }
            )
    print(json.dumps({"ok": ok, "n": n, "results": summary}, sort_keys=True))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
