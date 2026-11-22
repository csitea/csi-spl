#!/usr/bin/env python3
"""SPL-6251 search calendar probe: does the search box find a calendar entry?

Signs one member in, makes one throwaway calendar entry (audience workspace,
tomorrow) whose title holds a fresh random word, then searches as the WUI
does (spec 100 section 16, calendar entries):

  1. q=type:calendar <word>   the entry is in the calendars group
  2. q=type:cal <word>        the alias finds it too
  3. q=type:event <word>      the event log only: no calendar section
  4. deletes the entry (always, also after a failure)

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE,
PROBE_NONCE (optional, the random word's seed; default a random one).

Prints one line per search and one JSON summary. Exit 0 = every search showed
what it should (green), 1 = a search missed the entry or answered a calendar
section to type:event (red: each search's status and hit counts are named),
2 = could not sign in or make the entry. The password and cookie are never
printed.
"""

import datetime
import json
import os
import secrets
import sys
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


def word(nonce):
    """One fresh lower-case word of letters only, so every tokenizer keeps it
    whole; the same nonce gives the same word."""
    al = "abcdefghijklmnopqrstuvwxyz"
    n, w = int.from_bytes(nonce.encode(), "big") * 31, "zqcal"
    for _ in range(12):
        n, r = divmod(n * 7 + 13, 26)
        w += al[r]
    return w


def err_of(st, out):
    return out.get("error", "") if isinstance(out, dict) and st != 200 else ""


class Probe:
    def __init__(self, api, cookie):
        self.api, self.cookie = api, cookie

    def call(self, method, path, body=None):
        return http(method, self.api + path, body, self.cookie)

    def search(self, q):
        """q -> {status, types, total, calendars, ids}: the answer's types,
        the hits of every group, and the calendars group's own."""
        st, _, body = self.call(
            "GET", "/v1/view/search?" + urllib.parse.urlencode({"q": q})
        )
        body = body if isinstance(body, dict) else {}
        groups = body.get("groups") or {}
        total, cal = 0, []
        for name, g in groups.items():
            rows = (g or {}).get("results") or []
            total += len(rows)
            if name == "calendars":
                cal = rows
        return {
            "q": q,
            "status": st,
            "error": err_of(st, body),
            "types": body.get("types") or [],
            "total": total,
            "calendars": len(cal),
            "ids": sorted({str(r.get("id", "")) for r in cal}),
        }


def setup(p, w):
    """The throwaway entry, tomorrow 10:00-11:00 UTC -> its id, or None."""
    day = datetime.datetime.now(datetime.timezone.utc).date() + datetime.timedelta(
        days=1
    )
    st, _, out = p.call(
        "POST",
        "/v1/calendar/events",
        {
            "title": "search calendar probe " + w,
            "audience": "workspace",
            "starts_at": "%sT10:00:00Z" % day.isoformat(),
            "ends_at": "%sT11:00:00Z" % day.isoformat(),
        },
    )
    ev = out.get("event") if isinstance(out, dict) else None
    if st != 201 or not isinstance(ev, dict) or not ev.get("id"):
        print(json.dumps({"step": "create", "status": st, "error": err_of(st, out)}))
        return None
    return str(ev["id"])


def checks(p, ev, w):
    """The three searches, each with what it must show -> (ok, rows)."""
    rows = []

    def want(q, found):
        r = p.search(q)
        r["want"] = "found" if found else "absent"
        r["ok"] = r["status"] == 200 and ((ev in r["ids"]) == found)
        if not found:
            r["ok"] = r["ok"] and "calendar" not in r["types"]
        rows.append(r)
        print(
            "%-6s %-42s status=%s total=%d calendars=%d want=%s"
            % (
                "OK" if r["ok"] else "MISS",
                q,
                r["status"],
                r["total"],
                r["calendars"],
                r["want"],
            )
        )

    want("type:calendar " + w, True)
    want("type:cal " + w, True)
    want("type:event " + w, False)
    return all(r["ok"] for r in rows), rows


def main():
    api = os.environ.get("PROBE_API", "").rstrip("/")
    nonce = os.environ.get("PROBE_NONCE") or secrets.token_hex(8)
    w = word(nonce)
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
        print(json.dumps({"step": "login", "status": st, "error": err_of(st, out)}))
        return 2
    p = Probe(api, cookie)
    ev = setup(p, w)
    if not ev:
        return 2
    try:
        ok, rows = checks(p, ev, w)
    finally:
        dst, _, _ = p.call("DELETE", "/v1/calendar/events/%s" % ev)
    print(
        json.dumps(
            {
                "ok": ok,
                "nonce": nonce,
                "word": w,
                "event": ev,
                "deleted": dst in (200, 204),
                "searches": rows,
            },
            sort_keys=True,
        )
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
