#!/usr/bin/env python3
"""SPL-3337 search doc probe: does GET /v1/view/search find a Qto document?

Signs one member in, makes one throwaway Qto document whose words are fresh
random words (in no message, no other doc), then searches as the WUI does:

  1. q=<word A>              the plain search (no type:)
  2. q=type:doc <word A>     the doc section asked for by name
  3. edits the section body to <word C>; q=<word C> must find it and
     q=<word B> (its old body word) must not
  4. deletes the document (always, also after a failure)

Env: PROBE_API (https://<api host>), PROBE_TENANT, PROBE_EMAIL, PROBE_PW_FILE,
PROBE_NONCE (optional, the random words' seed; default a random one).

Prints one line per step and one JSON summary. Exit 0 = every step found what
it should (green), 1 = some search missed the doc or found a stale word (red:
the summary names it, with each search's status and hit counts), 2 = could not
sign in or set the document up. The password and cookie are never printed.
"""

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


def words(nonce):
    """Three fresh lower-case words of letters only, so every tokenizer keeps
    each one whole; the same nonce gives the same words."""
    al = "abcdefghijklmnopqrstuvwxyz"
    seed = int.from_bytes(nonce.encode(), "big")
    out = []
    for tag in "abc":
        n, w = seed * 31 + ord(tag), "zq" + tag
        for _ in range(12):
            n, r = divmod(n * 7 + 13, 26)
            w += al[r]
        out.append(w)
    return out


def err_of(st, out):
    return out.get("error", "") if isinstance(out, dict) and st != 200 else ""


class Probe:
    def __init__(self, api, cookie):
        self.api, self.cookie = api, cookie

    def call(self, method, path, body=None):
        return http(method, self.api + path, body, self.cookie)

    def search(self, q):
        """q -> {status, total, docs, doc_ids}: the hits of every group, and
        the doc group's own."""
        st, _, body = self.call(
            "GET", "/v1/view/search?" + urllib.parse.urlencode({"q": q})
        )
        groups = body.get("groups") or {} if isinstance(body, dict) else {}
        total, docs = 0, []
        for name, g in groups.items():
            rows = (g or {}).get("results") or []
            total += len(rows)
            if name == "docs":
                docs = rows
        return {
            "q": q,
            "status": st,
            "error": err_of(st, body),
            "total": total,
            "docs": len(docs),
            "doc_ids": sorted({str(r.get("doc_id", "")) for r in docs}),
        }


def setup(p, a, b):
    """The throwaway document, one section holding a and b -> (doc, item) or
    None."""
    st, _, out = p.call(
        "POST", "/v1/workspace/doctree", {"title": "search doc probe " + a}
    )
    if st != 200 or not isinstance(out, dict):
        print(json.dumps({"step": "create", "status": st, "error": err_of(st, out)}))
        return None
    doc = out.get("id", "")
    st, _, out = p.call(
        "POST",
        "/v1/workspace/doctree/%s/items" % doc,
        {
            "rev": out.get("rev", 1),
            "where": "child",
            "title": "probe section " + a,
            "body": "%s %s" % (a, b),
        },
    )
    if st != 200 or not isinstance(out, dict):
        print(json.dumps({"step": "add", "status": st, "error": err_of(st, out)}))
        p.call("DELETE", "/v1/workspace/doctree/%s" % doc)
        return None
    return doc, out.get("item", "")


def checks(p, doc, item, a, b, c):
    """The four searches and the edit, each with what it must show -> (ok,
    rows)."""
    rows = []

    def want(q, found):
        r = p.search(q)
        r["want"] = "found" if found else "absent"
        r["ok"] = r["status"] == 200 and ((doc in r["doc_ids"]) == found)
        rows.append(r)
        print(
            "%-6s %-36s status=%s total=%d docs=%d want=%s"
            % (
                "OK" if r["ok"] else "MISS",
                q,
                r["status"],
                r["total"],
                r["docs"],
                r["want"],
            )
        )

    want(a, True)
    want("type:doc " + a, True)
    st, _, out = p.call(
        "PATCH",
        "/v1/workspace/doctree/%s/items/%s" % (doc, item),
        {"field": "body", "value": c, "rev": 1},
    )
    print(
        "%-6s %-36s status=%s"
        % ("OK" if st == 200 else "MISS", "edit body -> " + c, st)
    )
    rows.append(
        {"step": "edit", "status": st, "ok": st == 200, "error": err_of(st, out)}
    )
    want(c, True)
    want(b, False)
    return all(r["ok"] for r in rows), rows


def main():
    api = os.environ.get("PROBE_API", "").rstrip("/")
    nonce = os.environ.get("PROBE_NONCE") or secrets.token_hex(8)
    a, b, c = words(nonce)
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
    made = setup(p, a, b)
    if not made:
        return 2
    doc, item = made
    try:
        ok, rows = checks(p, doc, item, a, b, c)
    finally:
        dst, _, _ = p.call("DELETE", "/v1/workspace/doctree/%s" % doc)
    print(
        json.dumps(
            {
                "ok": ok,
                "nonce": nonce,
                "doc": doc,
                "deleted": dst == 200,
                "searches": rows,
            },
            sort_keys=True,
        )
    )
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
