#!/usr/bin/env python3
"""SPL-2138: a bounded load / soak driver for the deployed hub (dev only).

Open loop: one scheduler sends LOAD_RPS requests a second for LOAD_SECONDS,
round-robin over LOAD_PATHS, into at most LOAD_CONCURRENCY workers. A request
is timed from the moment it was DUE, not from when a worker took it, so a hub
that slows down shows in the percentiles instead of slowing the sender (no
coordinated omission). A request that finds every worker busy waits for one
and counts as late.

Read-only: GET only, after one sign-in (POST /api/v1/auth/login), or with a
session cookie file. Every worker keeps its own keep-alive connection.

Env:
  LOAD_URL           https://<api host> (http://127.0.0.1:<port> in the tests)
  LOAD_AUTH_URL      sign-in base, default LOAD_URL
  LOAD_TENANT        the workspace of the test login
  LOAD_EMAIL + LOAD_PW_FILE (0600) or LOAD_PW, or LOAD_COOKIE_FILE (0600)
  LOAD_PATHS         comma-separated GET paths
  LOAD_RPS 1..50, LOAD_CONCURRENCY 1..50, LOAD_SECONDS 1..900 (hard caps)
  LOAD_MAX_ERR_PCT   fail above this error rate, percent (default 1)
  LOAD_MAX_P95_MS    fail above this overall p95, ms (default 500)
  LOAD_TIMEOUT_S     one request's timeout, s (default 10)
An error is a transport failure, a timeout, or any status outside 2xx/3xx.
Prints a table per path, the totals, one JSON line, then PASS or FAIL.
Exit 0 PASS, 1 FAIL (a threshold, or the sign-in), 2 usage.
The password and the cookie are never printed.
"""

import http.client
import json
import os
import queue
import stat
import sys
import threading
import time
from urllib.parse import urlsplit

CAPS = {"LOAD_RPS": 50, "LOAD_CONCURRENCY": 50, "LOAD_SECONDS": 900}


def usage(msg):
    print(f"FATAL {msg}", file=sys.stderr)
    return 2


def int_env(name, default, lo, hi):
    raw = os.environ.get(name, "") or str(default)
    if not raw.isdigit() or not lo <= int(raw) <= hi:
        raise ValueError(f"{name} must be {lo}..{hi}, got '{raw}'")
    return int(raw)


def num_env(name, default):
    raw = os.environ.get(name, "") or str(default)
    try:
        v = float(raw)
    except ValueError:
        raise ValueError(f"{name} must be a number, got '{raw}'") from None
    if v < 0:
        raise ValueError(f"{name} must be >= 0, got '{raw}'")
    return v


def secret(path):
    mode = os.stat(path).st_mode
    if mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise ValueError(
            f"{path} is mode {oct(mode & 0o777)}; a credential file must be 0600"
        )
    with open(path) as f:
        return f.read().strip()


def connect(base, timeout):
    u = urlsplit(base)
    cls = (
        http.client.HTTPSConnection
        if u.scheme == "https"
        else http.client.HTTPConnection
    )
    return cls(u.hostname, u.port, timeout=timeout)


def sign_in(auth, tenant, email, pw, timeout):
    """name=value of the session cookie, or '' (the status goes to stderr)."""
    body = {"email": email, "password": pw}
    if tenant:
        body["tenant"] = tenant
    c = connect(auth, timeout)
    try:
        c.request(
            "POST",
            urlsplit(auth).path.rstrip("/") + "/api/v1/auth/login",
            json.dumps(body),
            {"Content-Type": "application/json", "Accept": "application/json"},
        )
        r = c.getresponse()
        r.read()
    except (OSError, http.client.HTTPException) as e:
        print(f"sign-in failed: {type(e).__name__}", file=sys.stderr)
        return ""
    finally:
        c.close()
    if r.status != 200:
        print(
            f"sign-in refused: POST /api/v1/auth/login answered {r.status}",
            file=sys.stderr,
        )
        return ""
    for v in r.headers.get_all("Set-Cookie") or []:
        pair = v.split(";", 1)[0].strip()
        if pair.startswith("spool_session") and "=" in pair and pair.split("=", 1)[1]:
            return pair
    print("sign-in answered 200 but set no spool_session cookie", file=sys.stderr)
    return ""


def pct(sorted_ms, p):
    """Nearest-rank percentile of an ascending list."""
    if not sorted_ms:
        return 0.0
    k = -(-p * len(sorted_ms) // 100)
    return sorted_ms[max(0, min(len(sorted_ms), int(k)) - 1)]


def send(c, base, timeout, path, hdrs):
    """(connection to keep or None, status or error name)."""
    for attempt in (0, 1):
        try:
            c = c or connect(base, timeout)
            c.request("GET", urlsplit(base).path.rstrip("/") + path, headers=hdrs)
            r = c.getresponse()
            r.read()
            if (r.getheader("Connection") or "").lower() == "close":
                c.close()
                c = None
            return c, str(r.status)
        except (
            http.client.RemoteDisconnected,
            BrokenPipeError,
            ConnectionResetError,
        ) as e:
            # a keep-alive the server closed between two requests: one retry
            if c:
                c.close()
            c, err = None, type(e).__name__
            if attempt:
                return None, err
        except (OSError, http.client.HTTPException) as e:
            if c:
                c.close()
            return None, "timeout" if "timed out" in str(e) else type(e).__name__
    return None, "unreachable"


def run(base, paths, cookie, rps, conc, seconds, timeout):
    """([(path, latency_ms, status, late)], wall seconds) for every request sent."""
    jobs = queue.Queue(maxsize=conc)
    out, lock = [], threading.Lock()
    hdrs = {"Accept": "application/json", "User-Agent": "spl-hub-load-test"}
    if cookie:
        hdrs["Cookie"] = cookie

    def worker():
        c = None
        while True:
            job = jobs.get()
            if job is None:
                break
            path, due, late = job
            c, status = send(c, base, timeout, path, hdrs)
            ms = (time.monotonic() - due) * 1000.0
            with lock:
                out.append((path, ms, status, late))
        if c:
            c.close()

    threads = [threading.Thread(target=worker, daemon=True) for _ in range(conc)]
    for t in threads:
        t.start()
    start = time.monotonic()
    for i in range(rps * seconds):
        due = start + i / float(rps)
        if due > time.monotonic():
            time.sleep(due - time.monotonic())
        path = paths[i % len(paths)]
        try:
            jobs.put_nowait((path, due, False))
        except queue.Full:
            jobs.put((path, due, True))
    for _ in threads:
        jobs.put(None)
    for t in threads:
        t.join(timeout * 2 + 5)
    return out, time.monotonic() - start


def ok_status(s):
    return s.isdigit() and 200 <= int(s) < 400


def summarise(rows):
    ms = sorted(r[1] for r in rows)
    st = {}
    for r in rows:
        st[r[2]] = st.get(r[2], 0) + 1
    err = sum(n for s, n in st.items() if not ok_status(s))
    return {
        "n": len(rows),
        "p50_ms": round(pct(ms, 50), 1),
        "p95_ms": round(pct(ms, 95), 1),
        "p99_ms": round(pct(ms, 99), 1),
        "max_ms": round(ms[-1], 1) if ms else 0.0,
        "errors": err,
        "err_pct": round(100.0 * err / len(rows), 2) if rows else 0.0,
        "late": sum(1 for r in rows if r[3]),
        "status": dict(sorted(st.items())),
    }


def row(name, s):
    return (
        f"{name[:44]:<44} {s['n']:>6} {s['p50_ms']:>8.1f} {s['p95_ms']:>8.1f} {s['p99_ms']:>8.1f} "
        f"{s['max_ms']:>8.1f} {s['err_pct']:>6.2f}  {json.dumps(s['status'])}"
    )


def session(base, timeout):
    """The session cookie ('' = no session wanted), or None when it failed."""
    if os.environ.get("LOAD_COOKIE_FILE"):
        return secret(os.environ["LOAD_COOKIE_FILE"])
    if not os.environ.get("LOAD_EMAIL"):
        return ""
    pw = os.environ.get("LOAD_PW", "")
    if not pw and os.environ.get("LOAD_PW_FILE"):
        pw = secret(os.environ["LOAD_PW_FILE"])
    if not pw:
        raise ValueError("LOAD_EMAIL needs LOAD_PW_FILE (0600) or LOAD_PW")
    auth = os.environ.get("LOAD_AUTH_URL", "").rstrip("/") or base
    return (
        sign_in(
            auth,
            os.environ.get("LOAD_TENANT", ""),
            os.environ["LOAD_EMAIL"],
            pw,
            timeout,
        )
        or None
    )


def main():
    base = os.environ.get("LOAD_URL", "").rstrip("/")
    if not base.startswith(("http://", "https://")):
        return usage(f"LOAD_URL must be http(s)://<host>, got '{base}'")
    try:
        rps = int_env("LOAD_RPS", 20, 1, CAPS["LOAD_RPS"])
        conc = int_env("LOAD_CONCURRENCY", 10, 1, CAPS["LOAD_CONCURRENCY"])
        seconds = int_env("LOAD_SECONDS", 60, 1, CAPS["LOAD_SECONDS"])
        max_err = num_env("LOAD_MAX_ERR_PCT", 1)
        max_p95 = num_env("LOAD_MAX_P95_MS", 500)
        timeout = num_env("LOAD_TIMEOUT_S", 10) or 10
    except ValueError as e:
        return usage(str(e))
    paths = [
        p.strip() for p in os.environ.get("LOAD_PATHS", "").split(",") if p.strip()
    ]
    if not paths or any(not p.startswith("/") for p in paths):
        return usage("LOAD_PATHS must be a comma-separated list of /paths")
    try:
        cookie = session(base, timeout)
    except (OSError, ValueError) as e:
        return usage(str(e))
    if cookie is None:
        print("FAIL sign-in: no session, no load was sent")
        return 1

    print(
        f"load: {rps} rps x {seconds} s = {rps * seconds} GETs, <= {conc} in flight, "
        f"{len(paths)} paths, session={'yes' if cookie else 'no'}; "
        f"fail when err > {max_err:g} % or p95 > {max_p95:g} ms",
        flush=True,
    )
    rows, wall = run(base, paths, cookie, rps, conc, seconds, timeout)

    print(
        f"{'path':<44} {'n':>6} {'p50':>8} {'p95':>8} {'p99':>8} {'max':>8} {'err%':>6}  status"
    )
    for p in dict.fromkeys(paths):
        print(row(p, summarise([r for r in rows if r[0] == p])))
    tot = summarise(rows)
    print(row("TOTAL", tot))
    achieved = round(tot["n"] / wall, 2) if wall > 0 else 0.0
    print(
        f"achieved {achieved} rps over {wall:.1f} s; late (every worker busy) {tot['late']}"
    )

    why = []
    if tot["n"] < rps * seconds:
        why.append(f"only {tot['n']} of {rps * seconds} requests finished")
    if tot["err_pct"] > max_err:
        why.append(f"error rate {tot['err_pct']} % > {max_err:g} %")
    if tot["p95_ms"] > max_p95:
        why.append(f"p95 {tot['p95_ms']} ms > {max_p95:g} ms")
    print(
        json.dumps(
            {
                "rps": rps,
                "concurrency": conc,
                "seconds": seconds,
                "achieved_rps": achieved,
                "total": tot,
                "verdict": "FAIL" if why else "PASS",
                "why": why,
            },
            sort_keys=True,
        )
    )
    print(("FAIL " + "; ".join(why)) if why else "PASS")
    return 1 if why else 0


if __name__ == "__main__":
    sys.exit(main())
