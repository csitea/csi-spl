#!/usr/bin/env python3
"""Repeatable performance numbers, and the ceiling check that fails when one is over.

Three measurements, nothing else:

  ci / dev initial JS gzip   the chunks the document names with src= or
                             modulepreload href=, gzipped at level 6 and
                             summed. The same set as
                             csi-spl-wui/src/node/test/bundle-size.mjs. A JS
                             file that is only a dynamic import is not in it.
  first-load transfer        wall time to GET the WUI document and then those
                             chunks in parallel, each on a new connection,
                             Accept-Encoding identity. Not a browser paint.
  three view reads           GET /v1/view/me, /v1/view/channels and
                             /v1/view/roster — the signed-in shell's first
                             view calls — p50 and p95 over PERF_N samples
                             after PERF_WARMUP discards.

`bundle` reads a nuxt generate directory and checks ci_initial_gzip_kb.
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
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor

INITIAL_RE = re.compile(r'(?:src|href)="/_nuxt/([A-Za-z0-9._-]+\.js)"')
# access.ts load() -> /v1/view/me; shell-bootstrap.mjs start() -> channels, roster.
ENDPOINTS = (
    ("view_me", "/v1/view/me"),
    ("view_channels", "/v1/view/channels"),
    ("view_roster", "/v1/view/roster"),
)
CI_KEYS = ("ci_initial_gzip_kb",)
LIVE_KEYS = (
    "dev_initial_gzip_kb",
    "first_load_p95_ms",
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


def gzip_len(data):
    if isinstance(data, str):
        data = data.encode()
    buf = io.BytesIO()
    # Level 6 is node zlib.gzipSync's setting. Two zlib builds do not emit
    # identical bytes (under 1 KB on a full initial set). The ceiling applies
    # to this sum. The chunk set is the one bundle-size.mjs selects.
    with gzip.GzipFile(fileobj=buf, mode="wb", compresslevel=6, mtime=0) as z:
        z.write(data)
    return buf.tell()


def kb_of(n):
    return r1(n / 1024.0)


def initial_names(html):
    seen = []
    for name in INITIAL_RE.findall(html):
        if name not in seen:
            seen.append(name)
    return seen


def bundle_dir(pub):
    """Return (gzip_kb, chunk_count). ValueError names what is missing."""
    nuxt = os.path.join(pub, "_nuxt")
    html_path = os.path.join(pub, "200.html")
    if not os.path.isfile(html_path):
        raise ValueError(f"no 200.html in {pub}")
    if not os.path.isdir(nuxt):
        raise ValueError(f"no _nuxt directory in {pub}")
    on_disk = {name for name in os.listdir(nuxt) if name.endswith(".js")}
    with open(html_path, encoding="utf-8", errors="replace") as f:
        html = f.read()
    names = [name for name in initial_names(html) if name in on_disk]
    if not names:
        raise ValueError("initial JS set is empty")
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

    view_samples = {}
    for key, path in ENDPOINTS:
        def hit(path=path):
            t0 = time.perf_counter()
            st, _h, _b = fetch(api + path, cookie=cookie, accept="application/json")
            return st == 200, (time.perf_counter() - t0) * 1000.0, st

        got, _extra, verr = sample_loop(n, warmup, hit)
        if verr or len(got) != n:
            raise ValueError(f"{path} {verr or 'short sample'}")
        view_samples[key] = got

    metrics = {
        "dev_initial_gzip_kb": gzip_kb,
        "first_load_p50_ms": r1(pct(samples, 50)),
        "first_load_p95_ms": r1(pct(samples, 95)),
    }
    for key, _path in ENDPOINTS:
        metrics[key + "_p50_ms"] = r1(pct(view_samples[key], 50))
        metrics[key + "_p95_ms"] = r1(pct(view_samples[key], 95))
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
            **{key + "_ms": [r1(x) for x in view_samples[key]] for key, _path in ENDPOINTS},
        },
    }


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
    ok, lines = check(report.get("metrics") or {}, ceilings, required_for(require))
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


def cmd_bundle(args):
    try:
        gzip_kb, chunks = bundle_dir(args.pub)
        ceilings = load_ceilings(args.budgets)
    except (OSError, ValueError, json.JSONDecodeError) as err:
        print(f"FAIL {err}")
        return 1
    report = {
        "kind": "bundle",
        "n": 1,
        "chunks": chunks,
        "metrics": {"ci_initial_gzip_kb": gzip_kb},
    }
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
