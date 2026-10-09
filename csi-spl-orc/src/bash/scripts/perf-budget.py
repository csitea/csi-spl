#!/usr/bin/env python3
"""Repeatable performance numbers, and the ceiling check that fails when one is over.

Three measurements, nothing else:

  ci / dev initial JS gzip   the chunks the document names with src= or
                             modulepreload href=, gzipped at level 6 and
                             summed. The same set as
                             csi-spl-wui/src/node/test/bundle-size.mjs. A JS
                             file that is only a dynamic import is not in it.
                             `bundle` applies it to every prerendered
                             document: 200.html (ci_initial_gzip_kb, the SPA
                             fallback every deep link gets) and index.html
                             (ci_home_gzip_kb, the prerendered `/`, spec 109
                             D3). Any other *.html is reported, not gated.
  first-load transfer        wall time to GET the WUI document and then those
                             chunks in parallel, each on a new connection,
                             Accept-Encoding identity. Not a browser paint.
  three view reads           GET /v1/view/me, /v1/view/channels and
                             /v1/view/roster on ONE reused HTTP/1.1
                             connection. p50/p95 are time_starttransfer
                             (TTFB) after PERF_WARMUP, not a fresh handshake.
                             Each sample also records time_namelookup and
                             time_connect so a DNS stall is visible.

  route chunks               the lazy chunks of one route (spec 112 9: the
                             roadmap, ci_roadmap_route_gzip_kb), found by the
                             data-test values its compiled templates carry,
                             gzipped the same way and summed.

`bundle` reads a nuxt generate directory and checks ci_initial_gzip_kb and
ci_home_gzip_kb, and each route chunk budget the budgets file carries.
`live` talks to the hosts it is given. `check` compares an already written
report. A value greater than its ceiling, or a required value that was not
measured, exits 1. The password, the session cookie and every response body
stay out of the report and off stdout.

Env for `live` (the action sets these): PERF_WUI_URL, PERF_API_URL,
PERF_EMAIL, PERF_PW_FILE, PERF_TENANT, PERF_N (8..40, default 12),
PERF_WARMUP (0..5, default 1), PERF_TREE, PERF_ENV.
"""
import argparse
import gzip
import io
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

# The initial set is what the doc above says and nothing more: <script src=>
# and <link rel="modulepreload" href=>. A <link rel="prefetch"> is a lazy
# chunk fetched at idle, not first paint; counting it (the old (?:src|href)
# regex, 24 prefetch links on 200.html) made the "initial" gzip 214.1 KB for
# a real 149.7 KB, and made moving code to a lazy chunk read as worse.
SCRIPT_SRC_RE = re.compile(r'<script\b[^>]*\bsrc="/_nuxt/([A-Za-z0-9._-]+\.js)"')
LINK_RE = re.compile(r'<link\b[^>]*>')
LINK_HREF_RE = re.compile(r'\bhref="/_nuxt/([A-Za-z0-9._-]+\.js)"')
LINK_MODULEPRELOAD_RE = re.compile(r'\brel="modulepreload"')
# access.ts load() -> /v1/view/me; shell-bootstrap.mjs start() -> channels, roster.
ENDPOINTS = (
    ("view_me", "/v1/view/me"),
    ("view_channels", "/v1/view/channels"),
    ("view_roster", "/v1/view/roster"),
)
# Each gated prerendered document and its ceiling. Until spec 109 T002 only
# 200.html was read, so the prerendered `/` (85 chunks, 349.8 KB on prd) was
# never gated.
CI_DOCS = (
    ("ci_initial_gzip_kb", "200.html"),
    ("ci_home_gzip_kb", "index.html"),
)
CI_KEYS = tuple(key for key, _doc in CI_DOCS)
# Each route chunk budget and the markers of its chunks: a chunk whose text
# holds one of them is that route's (a quoted data-test value, as the
# compiled template writes it). Gated when the budgets file has the key, so a
# route whose markers match no chunk fails as not measured, never passes.
ROUTE_CHUNKS = (
    ("ci_roadmap_route_gzip_kb", ('"roadmap-page"', '"roadmap-spec-table"')),
)
# first_load_p95_ms is recorded and not gated: it is a new connection per
# chunk on this box, and that tail is the resolver (T124), not the bundle.
LIVE_KEYS = (
    "dev_initial_gzip_kb",
    "view_me_p95_ms",
    "view_channels_p95_ms",
    "view_roster_p95_ms",
)
UA = "spool-perf-budget"


def pct(xs, p):
    """Linear interpolation. A short sample must not report its maximum as p95."""
    if not xs:
        return None
    xs = sorted(float(x) for x in xs)
    if len(xs) == 1:
        return xs[0]
    k = (len(xs) - 1) * p / 100.0
    lo = int(k)
    hi = min(lo + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def r1(x):
    return float(f"{float(x):.1f}")


# Node's own zlib.gzipSync, the bytes the e2e (calendar.test.mjs AC-02) and
# bundle-size.mjs count. Two zlib builds do not emit identical bytes: on one
# bundle Python read 154.7 KB where node read 155.1 (c-568, 2026-10-08), so the
# budget step passed while the e2e failed. Python's zlib only without node.
NODE_GZIP_JS = (
    "const c=[];process.stdin.on('data',(d)=>c.push(d)).on('end',()=>"
    "process.stdout.write(String(require('zlib').gzipSync(Buffer.concat(c)).length)))"
)


def gzip_len(data):
    if isinstance(data, str):
        data = data.encode()
    node = shutil.which("node")
    if node:
        try:
            out = subprocess.run([node, "-e", NODE_GZIP_JS], input=data, capture_output=True, timeout=60, check=True)
            return int(out.stdout)
        except (OSError, ValueError, subprocess.SubprocessError):
            pass
    buf = io.BytesIO()
    # Level 6 is node zlib.gzipSync's setting. The ceiling applies to this
    # sum. The chunk set is the one bundle-size.mjs selects.
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=6, mtime=0) as z:
        z.write(data)
    return buf.tell()


def kb_of(n):
    return r1(n / 1024.0)


def initial_names(html):
    found = SCRIPT_SRC_RE.findall(html)
    for tag in LINK_RE.findall(html):
        href = LINK_HREF_RE.search(tag)
        if href and LINK_MODULEPRELOAD_RE.search(tag):
            found.append(href.group(1))
    seen = []
    for name in found:
        if name not in seen:
            seen.append(name)
    return seen


def bundle_dir(pub, doc="200.html"):
    """Return (gzip_kb, chunk_count) for one document. ValueError names what is missing."""
    nuxt = os.path.join(pub, "_nuxt")
    html_path = os.path.join(pub, doc)
    if not os.path.isfile(html_path):
        raise ValueError(f"no {doc} in {pub}")
    if not os.path.isdir(nuxt):
        raise ValueError(f"no _nuxt directory in {pub}")
    on_disk = {name for name in os.listdir(nuxt) if name.endswith(".js")}
    with open(html_path, encoding="utf-8", errors="replace") as f:
        html = f.read()
    names = [name for name in initial_names(html) if name in on_disk]
    if not names:
        raise ValueError(f"initial JS set is empty ({doc})")
    total = 0
    for name in names:
        with open(os.path.join(nuxt, name), "rb") as f:
            total += gzip_len(f.read())
    return kb_of(total), len(names)


def load_ceilings(path):
    with open(path, encoding="utf-8") as f:
        doc = json.load(f)
    ceilings = doc.get("ceilings") if isinstance(doc, dict) else None
    if not isinstance(ceilings, dict) or not ceilings:
        raise ValueError(f"{path} has no ceilings object")
    return ceilings


def check(metrics, ceilings, required):
    lines = []
    ok = True
    for key in required:
        if key not in ceilings:
            lines.append(f"FAIL {key} has no ceiling")
            ok = False
            continue
        if not isinstance(metrics, dict) or key not in metrics:
            lines.append(f"FAIL {key} was not measured")
            ok = False
            continue
        try:
            got = float(metrics[key])
            cap = float(ceilings[key])
        except (TypeError, ValueError):
            lines.append(f"FAIL {key} is not a number")
            ok = False
            continue
        if got > cap:
            lines.append(f"FAIL {key} {got:g} > {cap:g}")
            ok = False
        else:
            lines.append(f"PASS {key} {got:g} <= {cap:g}")
    return ok, lines


def required_for(name):
    if name == "ci":
        return CI_KEYS
    if name == "live":
        return LIVE_KEYS
    if name == "none":
        return ()
    raise ValueError(f"unknown require {name}")


def fetch(url, method="GET", body=None, cookie="", accept="*/*", timeout=20):
    headers = {
        "Accept": accept,
        "Accept-Encoding": "identity",
        "Cache-Control": "no-cache",
        "User-Agent": UA,
    }
    data = None
    if body is not None:
        data = json.dumps(body).encode()
        headers["Content-Type"] = "application/json"
    if cookie:
        headers["Cookie"] = cookie
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as res:
            return res.status, res.headers, res.read()
    except urllib.error.HTTPError as err:
        return err.code, err.headers, err.read()
    except urllib.error.URLError:
        return 0, None, b""


def session_cookie(hdrs):
    """The session cookie, whatever env suffix it carries (spool_session, spool_session_dev)."""
    if hdrs is None:
        return ""
    values = hdrs.get_all("Set-Cookie") if hasattr(hdrs, "get_all") else None
    for value in values or []:
        pair = value.split(";", 1)[0]
        if "=" not in pair:
            continue
        name, token = pair.split("=", 1)
        if token and (name == "spool_session" or name.startswith("spool_session_")):
            return pair
    return ""


def json_field(raw, key):
    try:
        doc = json.loads(raw.decode() if raw else "")
    except (ValueError, UnicodeError):
        return ""
    if not isinstance(doc, dict):
        return ""
    got = doc.get(key)
    return got if isinstance(got, str) else ""


def one_document(origin):
    """GET / and the initial chunks. (status, gzip_kb or None, error)."""
    status, _hdrs, raw = fetch(origin + "/")
    if status != 200:
        return status, None, f"document HTTP {status}"
    names = initial_names(raw.decode("utf-8", "replace"))
    if not names:
        return status, None, "initial JS set is empty"

    def one(name):
        st, _h, body = fetch(origin + "/_nuxt/" + name)
        # One retry for a dropped connection or a 5xx. A 404 is the document
        # naming a chunk this host does not have, and that must fail.
        if st == 0 or st >= 500:
            st, _h, body = fetch(origin + "/_nuxt/" + name)
        return name, st, body

    with ThreadPoolExecutor(max_workers=min(8, len(names))) as pool:
        parts = list(pool.map(one, names))
    bad = [(name, st) for name, st, _body in parts if st != 200]
    if bad:
        name, st = bad[0]
        return 0, None, f"chunk {name} HTTP {st}"
    total = sum(gzip_len(body) for _name, _st, body in parts)
    return 200, kb_of(total), ""


def sample_loop(n, warmup, measure):
    """measure() -> (ok, ms, extra). Returns (samples, first_extra, error)."""
    for _ in range(warmup):
        ok, _ms, extra = measure()
        if not ok:
            return [], None, extra if isinstance(extra, str) else f"HTTP {extra}"
    samples = []
    first_extra = None
    for _ in range(n):
        ok, ms, extra = measure()
        if not ok:
            return samples, first_extra, extra if isinstance(extra, str) else f"HTTP {extra}"
        samples.append(ms)
        if first_extra is None:
            first_extra = extra
    return samples, first_extra, ""


def live_report():
    wui = os.environ.get("PERF_WUI_URL", "").rstrip("/")
    api = os.environ.get("PERF_API_URL", "").rstrip("/")
    email = os.environ.get("PERF_EMAIL", "")
    pw_file = os.environ.get("PERF_PW_FILE", "")
    tenant = os.environ.get("PERF_TENANT", "")
    n = int(os.environ.get("PERF_N", "12"))
    warmup = int(os.environ.get("PERF_WARMUP", "1"))
    if not wui or not api or not email or not pw_file or not tenant:
        raise ValueError("PERF_WUI_URL, PERF_API_URL, PERF_EMAIL, PERF_PW_FILE and PERF_TENANT are required")
    if not (8 <= n <= 40) or not (0 <= warmup <= 5):
        raise ValueError("PERF_N must be 8..40 and PERF_WARMUP 0..5")
    with open(pw_file, encoding="utf-8") as handle:
        password = handle.read().strip()
    if not password:
        raise ValueError("password file is empty")

    _st, _h, built = fetch(wui + "/build.json", accept="application/json")
    _st, _h, ver = fetch(api + "/version", accept="application/json")
    wui_commit = json_field(built, "commit")
    hub_commit = json_field(ver, "commit")
    hub_version = json_field(ver, "version")

    def load_once():
        t0 = time.perf_counter()
        status, gzip_kb, err = one_document(wui)
        ms = (time.perf_counter() - t0) * 1000.0
        if status != 200 or gzip_kb is None:
            return False, ms, err or f"document HTTP {status}"
        return True, ms, gzip_kb

    samples, gzip_kb, err = sample_loop(n, warmup, load_once)
    if err or not samples or gzip_kb is None:
        raise ValueError(err or "first-load produced no sample")

    status, hdrs, _body = fetch(
        api + "/api/v1/auth/login",
        method="POST",
        body={"email": email, "password": password, "tenant": tenant},
        accept="application/json",
    )
    del password
    cookie = session_cookie(hdrs) if status == 200 else ""
    if not cookie:
        raise ValueError(f"sign-in failed HTTP {status}")

    view_rows = {}
    for key, path in ENDPOINTS:
        rows = curl_reused(api + path, cookie, warmup + n)
        scored = rows[warmup:]
        bad = [row for row in scored if row["status"] != 200]
        if bad or len(scored) != n:
            status = bad[0]["status"] if bad else 0
            raise ValueError(f"{path} HTTP {status}")
        view_rows[key] = scored

    metrics = {
        "dev_initial_gzip_kb": gzip_kb,
        "first_load_p50_ms": r1(pct(samples, 50)),
        "first_load_p95_ms": r1(pct(samples, 95)),
    }
    for key, _path in ENDPOINTS:
        ttfb = [row["ttfb_ms"] for row in view_rows[key]]
        metrics[key + "_p50_ms"] = r1(pct(ttfb, 50))
        metrics[key + "_p95_ms"] = r1(pct(ttfb, 95))
    return {
        "kind": "live",
        "env": os.environ.get("PERF_ENV", ""),
        "tenant": tenant,
        "tree": os.environ.get("PERF_TREE", ""),
        "wui": wui,
        "api": api,
        "wui_commit": wui_commit,
        "hub_commit": hub_commit,
        "hub_version": hub_version,
        "n": n,
        "warmup": warmup,
        "endpoints": [path for _key, path in ENDPOINTS],
        "metrics": metrics,
        "samples": {
            "first_load_ms": [r1(x) for x in samples],
            **{key + "_ms": [row["ttfb_ms"] for row in view_rows[key]] for key, _path in ENDPOINTS},
            **{key + "_namelookup_ms": [row["namelookup_ms"] for row in view_rows[key]] for key, _path in ENDPOINTS},
            **{key + "_connect_ms": [row["connect_ms"] for row in view_rows[key]] for key, _path in ENDPOINTS},
        },
    }



def curl_reused(url, cookie, count):
    """count GETs of one URL in one curl process, so the connection is reused.

    Each line is namelookup, connect, starttransfer (TTFB), total, status.
    The cookie is an argument, never printed.
    """
    if count < 1:
        raise ValueError("curl count must be positive")
    fmt = "%{time_namelookup} %{time_connect} %{time_starttransfer} %{time_total} %{http_code}\n"
    cmd = [
        "curl", "-sS", "-w", fmt,
        "-H", "Accept: application/json",
        "-H", "Accept-Encoding: identity",
        "-H", "Cache-Control: no-cache",
        "-A", UA,
        "-H", "Cookie: " + cookie,
        "--http1.1",
        "--max-time", "30",
    ]
    # -o applies only to the next URL. One -o for the whole command would
    # dump later bodies onto the timing lines.
    for _ in range(count):
        cmd.extend(["-o", os.devnull, url])
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=30 * count + 15)
    except subprocess.TimeoutExpired:
        raise ValueError("curl timed out")
    if proc.returncode != 0:
        err = (proc.stderr or "").strip().splitlines()
        detail = err[-1] if err else "curl failed"
        raise ValueError(f"curl exit {proc.returncode}: {detail}")
    rows = []
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) != 5:
            raise ValueError("curl timing line is short")
        lookup, connect, start, _total, code = parts
        try:
            rows.append({
                "namelookup_ms": r1(float(lookup) * 1000.0),
                "connect_ms": r1(float(connect) * 1000.0),
                "ttfb_ms": r1(float(start) * 1000.0),
                "status": int(code),
            })
        except ValueError:
            raise ValueError("curl timing line is not numeric")
    if len(rows) != count:
        raise ValueError(f"curl returned {len(rows)} timings, wanted {count}")
    return rows


def summary_of(report, ok):
    metrics = report.get("metrics") or {}
    bits = [f"{key}={metrics[key]}" for key in sorted(metrics)]
    tree = (report.get("tree") or "")[:12]
    return (
        f"perf-budget {report.get('kind')} env={report.get('env') or '-'} "
        f"tree={tree or '-'} n={report.get('n')} "
        f"hub={((report.get('hub_commit') or '')[:12]) or '-'} "
        f"wui={((report.get('wui_commit') or '')[:12]) or '-'} "
        f"{'PASS' if ok else 'FAIL'} " + " ".join(bits)
    )


def finish(report, ceilings, require, out_path):
    required = required_for(require)
    if require == "ci":
        required += tuple(key for key, _markers in ROUTE_CHUNKS if key in ceilings)
    ok, lines = check(report.get("metrics") or {}, ceilings, required)
    report["ok"] = ok
    report["lines"] = lines
    report["summary"] = summary_of(report, ok)
    text = json.dumps(report, sort_keys=True)
    if out_path:
        parent = os.path.dirname(out_path)
        if parent:
            os.makedirs(parent, exist_ok=True)
        with open(out_path, "w", encoding="utf-8") as handle:
            handle.write(text + "\n")
    for line in lines:
        print(line)
    print(report["summary"])
    return 0 if ok else 1


def route_chunks(pub):
    """{key: {chunks, gzip_kb}} for each ROUTE_CHUNKS entry: the _nuxt/*.js
    files holding one of its markers, gzipped and summed."""
    nuxt = os.path.join(pub, "_nuxt")
    bodies = {}
    for name in sorted(os.listdir(nuxt)):
        if name.endswith(".js"):
            with open(os.path.join(nuxt, name), "rb") as f:
                bodies[name] = f.read()
    out = {}
    for key, markers in ROUTE_CHUNKS:
        names = [n for n, body in bodies.items() if any(mk.encode() in body for mk in markers)]
        total = sum(gzip_len(bodies[n]) for n in names)
        out[key] = {"chunks": len(names), "gzip_kb": kb_of(total), "files": names}
    return out


def bundle_report(pub):
    """Every prerendered document. A gated one that is missing stays out of
    metrics, so the check reports it as not measured."""
    metrics = {}
    documents = {}
    gated = {doc: key for key, doc in CI_DOCS}
    if not os.path.isdir(os.path.join(pub, "_nuxt")):
        raise ValueError(f"no _nuxt directory in {pub}")
    for doc in sorted(name for name in os.listdir(pub) if name.endswith(".html")):
        try:
            gzip_kb, chunks = bundle_dir(pub, doc)
        except ValueError as err:
            if doc in gated:
                raise
            documents[doc] = {"chunks": 0, "gzip_kb": 0.0, "note": str(err)}
            continue
        documents[doc] = {"chunks": chunks, "gzip_kb": gzip_kb}
        if doc in gated:
            metrics[gated[doc]] = gzip_kb
    routes = route_chunks(pub)
    for key, row in routes.items():
        if row["chunks"]:
            metrics[key] = row["gzip_kb"]
    report = {"kind": "bundle", "n": 1, "documents": documents, "routes": routes, "metrics": metrics}
    if "200.html" in documents:
        report["chunks"] = documents["200.html"]["chunks"]
    return report


def cmd_bundle(args):
    try:
        report = bundle_report(args.pub)
        ceilings = load_ceilings(args.budgets)
    except (OSError, ValueError, json.JSONDecodeError) as err:
        print(f"FAIL {err}")
        return 1
    for doc, row in sorted(report["documents"].items()):
        print(f"DOC {doc} {row['chunks']} chunk(s) gzip {row['gzip_kb']:g} KB")
    for key, row in sorted(report["routes"].items()):
        print(f"ROUTE {key} {row['chunks']} chunk(s) gzip {row['gzip_kb']:g} KB")
    return finish(report, ceilings, "ci", args.out)


def cmd_check(args):
    try:
        with open(args.report, encoding="utf-8") as handle:
            report = json.load(handle)
        ceilings = load_ceilings(args.budgets)
    except (OSError, ValueError, json.JSONDecodeError) as err:
        print(f"FAIL {err}")
        return 1
    if not isinstance(report, dict):
        print("FAIL report is not an object")
        return 1
    report.pop("ok", None)
    report.pop("lines", None)
    report.pop("summary", None)
    return finish(report, ceilings, args.require, args.out)


def cmd_live(args):
    try:
        if args.require != "none":
            if not args.budgets:
                print("FAIL --budgets is required unless --require none")
                return 1
            ceilings = load_ceilings(args.budgets)
        else:
            ceilings = {}
        report = live_report()
    except ValueError as err:
        msg = str(err)
        print(f"FAIL {msg}")
        return 2 if msg.startswith("sign-in failed") else 1
    except (OSError, json.JSONDecodeError) as err:
        print(f"FAIL {err}")
        return 1
    if args.require == "none":
        report["ok"] = True
        report["lines"] = []
        report["summary"] = summary_of(report, True)
        if args.out:
            parent = os.path.dirname(args.out)
            if parent:
                os.makedirs(parent, exist_ok=True)
            with open(args.out, "w", encoding="utf-8") as handle:
                handle.write(json.dumps(report, sort_keys=True) + "\n")
        print(report["summary"])
        return 0
    return finish(report, ceilings, args.require, args.out)


def main(argv):
    parser = argparse.ArgumentParser(prog="perf-budget.py")
    sub = parser.add_subparsers(dest="cmd", required=True)

    bundle = sub.add_parser("bundle")
    bundle.add_argument("--pub", required=True)
    bundle.add_argument("--budgets", required=True)
    bundle.add_argument("--out")
    bundle.set_defaults(fn=cmd_bundle)

    check_p = sub.add_parser("check")
    check_p.add_argument("--report", required=True)
    check_p.add_argument("--budgets", required=True)
    check_p.add_argument("--require", required=True, choices=("ci", "live"))
    check_p.add_argument("--out")
    check_p.set_defaults(fn=cmd_check)

    live = sub.add_parser("live")
    live.add_argument("--budgets")
    live.add_argument("--require", default="live", choices=("live", "ci", "none"))
    live.add_argument("--out")
    live.set_defaults(fn=cmd_live)

    args = parser.parse_args(argv)
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
