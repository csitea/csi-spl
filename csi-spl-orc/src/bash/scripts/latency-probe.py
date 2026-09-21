"""latency-probe.py - where the 0.3 s goes, hop by hop, on the live path.

The owner asked for chat under 0.3 s. Every answer before this was a single
end-to-end number, which cannot be acted on: it says the trip is slow without
saying which leg is. This walks one message at a time and prices each hop.

The trick that makes it honest is that the probe runs ON THE RECEIVING BOX.
The sender's clock and the sidecar's clock are then the SAME clock, so every
reading below is a subtraction of two stamps from one source - no NTP skew, no
agreement needed from the hub about what time it is. The box-side stamps come
from $SPOOL_TRACE (internal/trace), which the sidecar and the notifier both
append to.

What that buys, and what it does not: the hub's own internal split (parse,
verify, quota, commit, fan-out) is NOT separable here, because it happens on a
clock this probe cannot read. It is reported as one hop - send -> the frame is
back on this box - which contains the hub's work and two network legs. The
transport half of that is measured separately (CLE-3436).

Run it through `./run -a do_spl_latency_probe`, which sets the environment.
The login and the WS client come from m3-e2e.py: one renderer of that protocol
on this box, not two.

Env (all set by the action):
  M3_HUB_URL M3_AUTH_URL M3_TENANT M3_STATE M3_SPOOL M3_HUMAN_EMAIL  as m3-e2e.py
  LAT_AGENT     the desk agent to DM
  LAT_BOX       its box id
  LAT_ROOT      that desk's SPOOL_ROOT
  LAT_TRACE     the trace file the sidecar and notifier append to
  LAT_N         how many single sends           default 12
  LAT_GAP       seconds between single sends    default 1.5
  LAT_BURST     how many back-to-back sends     default 4 (0 skips the control)
  LAT_OUT       where to write results.json
"""
import importlib.util
import json
import os
import statistics
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("m3_e2e", os.path.join(HERE, "m3-e2e.py"))
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)

AGENT = os.environ.get("LAT_AGENT", "")
BOX = os.environ.get("LAT_BOX", "")
ROOT = os.environ.get("LAT_ROOT", "")
TRACE = os.environ.get("LAT_TRACE", "")
N = int(os.environ.get("LAT_N", "12"))
GAP = float(os.environ.get("LAT_GAP", "1.5"))
BURST = int(os.environ.get("LAT_BURST", "4"))
OUT = os.environ.get("LAT_OUT", "")

# The hops, in the order a message crosses them, and what each one contains.
# The name on the left is what the report prints; the pair on the right is the
# two stamps it subtracts.
HOPS = [
    ("send -> hub ack", "t_send", "t_ack",
     "the hub has stored it: 2 network legs + everything onSend does"),
    ("send -> frame on this box", "t_send", "ws_recv",
     "2 network legs + the hub's work + fan-out to the box socket"),
    ("frame -> inbox file", "ws_recv", "inbox_written",
     "verify the envelope against the pinned key, then the mailbox write"),
    ("inbox file -> notifier starts", "inbox_written", "notify_start",
     "the handoff to the terminal leg"),
    ("notifier -> line on screen", "notify_start", "notify_visible",
     "resolve the pane, refuse-checks, type the line"),
    ("DELIVERED AND VISIBLE", "t_send", "notify_visible",
     "the owner's budget: send pressed -> the message is on the agent's screen"),
    ("visible -> notifier returns", "notify_visible", "notify_done",
     "the TUI paste debounce before Enter; NOT visibility"),
]


def pct(xs, p):
    if not xs:
        return None
    xs = sorted(xs)
    if len(xs) == 1:
        return xs[0]
    k = (len(xs) - 1) * p / 100.0
    lo, hi = int(k), min(int(k) + 1, len(xs) - 1)
    return xs[lo] + (xs[hi] - xs[lo]) * (k - lo)


def read_trace(path):
    """msg_id -> {stage: ts_nano}. Last stamp of a stage wins: a re-poke would
    otherwise make the first, real one invisible."""
    out = {}
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                mid = e.get("msg_id") or ""
                if not mid:
                    continue
                out.setdefault(mid, {})[e.get("stage", "")] = e.get("ts_nano", 0)
    except OSError:
        pass
    return out


def wait_trace(mid, stage, timeout=20.0):
    """The trace file is appended by two other processes, so poll it. The poll
    interval is NOT part of any hop: every hop is a subtraction of stamps those
    processes wrote themselves."""
    end = time.time() + timeout
    while time.time() < end:
        got = read_trace(TRACE).get(mid, {})
        if got.get(stage):
            return got
        time.sleep(0.02)
    return read_trace(TRACE).get(mid, {})


def send_one(ws, task, body):
    """One DM. Returns the per-message stamp dict, in nanoseconds, box clock."""
    mid = str(uuid.uuid4())
    t_send = time.time_ns()
    ws.send({"type": "send", "task_id": task, "kind": "note", "to": AGENT,
             "body": body, "msg_id": mid})
    ack = ws.wait(lambda f: f.get("msg_id") == mid and f.get("type") in ("ack", "error"), 25)
    t_ack = time.time_ns()
    rec = {"msg_id": mid, "t_send": t_send,
           "t_ack": t_ack if ack and ack.get("type") == "ack" else 0,
           "ack": (ack or {}).get("type", "none")}
    return rec


def collect(rec):
    """Fill rec with the box-side stamps once the message has finished its trip."""
    got = wait_trace(rec["msg_id"], "notify_done")
    for stage in ("ws_recv", "inbox_written", "notify_start", "notify_visible", "notify_done"):
        rec[stage] = got.get(stage, 0)
    return rec


def table(rows, title):
    """One markdown table of p50/p95 per hop, in ms."""
    out = ["", "### %s (n=%d)" % (title, len(rows)), "",
           "| hop | p50 ms | p95 ms | n | what is in it |",
           "|---|---:|---:|---:|---|"]
    summary = {}
    for name, a, b in [(h[0], h[1], h[2]) for h in HOPS]:
        what = next(h[3] for h in HOPS if h[0] == name)
        vals = [(r[b] - r[a]) / 1e6 for r in rows
                if r.get(a) and r.get(b) and r[b] >= r[a]]
        p50, p95 = pct(vals, 50), pct(vals, 95)
        summary[name] = {"p50_ms": p50, "p95_ms": p95, "n": len(vals)}
        out.append("| %s | %s | %s | %d | %s |" % (
            name,
            "%.1f" % p50 if p50 is not None else "-",
            "%.1f" % p95 if p95 is not None else "-",
            len(vals), what))
    out.append("")
    return "\n".join(out), summary


def main():
    for name, v in (("LAT_AGENT", AGENT), ("LAT_BOX", BOX), ("LAT_ROOT", ROOT), ("LAT_TRACE", TRACE)):
        if not v:
            sys.exit("%s is required" % name)

    st, body, cookie = m3.native_login(m3.HUMAN, m3.TENANT, "human")
    if st != 200 or not cookie:
        sys.exit("member login failed: %s %s" % (st, str(body)[:300]))
    st, _, sess = m3.http("GET", m3.AUTH + "/api/v1/auth/session", headers={"Cookie": cookie})
    hum = (sess or {}).get("hum", "") if st == 200 else ""
    if not hum.startswith("HUM-"):
        sys.exit("no member session: %s %s" % (st, sess))

    ws = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    report, results = [], {"agent": AGENT, "box": BOX, "human": hum,
                           "hub": m3.HUB, "tenant": m3.TENANT}
    try:
        ws.send({"type": "hello", "as": "latency-probe"})
        wel = ws.wait(lambda f: f.get("type") in ("welcome", "error"))
        if not wel or wel.get("type") != "welcome":
            sys.exit("no welcome: %s" % wel)
        task = str(uuid.uuid4())
        ws.send({"type": "subscribe", "task_id": task})
        ws.wait(lambda f: f.get("type") == "subscribed" and f.get("task_id") == task)
        results["task_id"] = task

        # ---- single sends, spaced: each one is an isolated round trip -------
        singles = []
        for i in range(N):
            r = send_one(ws, task, "latency-probe single %d %s" % (i, time.strftime("%H:%M:%S")))
            singles.append(r)
            time.sleep(GAP)
        singles = [collect(r) for r in singles]
        results["singles"] = singles
        t, s = table(singles, "One message at a time")
        report.append(t)
        results["singles_summary"] = s

        # ---- the burst control ---------------------------------------------
        # The terminal leg used to run INSIDE the sidecar's read loop, so the
        # second of two messages paid the first one's poke before its own hop
        # started. Sending with no gap is what makes that visible: if the leg
        # is still serialised, "DELIVERED AND VISIBLE" climbs with position in
        # the burst; if it is off the loop, it stays flat.
        if BURST > 0:
            burst = [send_one(ws, task, "latency-probe burst %d" % i) for i in range(BURST)]
            burst = [collect(r) for r in burst]
            results["burst"] = burst
            t, s = table(burst, "A burst with no gap - the head-of-line control")
            report.append(t)
            results["burst_summary"] = s
            per = [(r["notify_visible"] - r["t_send"]) / 1e6 for r in burst
                   if r.get("notify_visible") and r.get("t_send")]
            if len(per) >= 2:
                report.append("Per position in the burst, delivered-and-visible: " +
                              ", ".join("#%d %.0f ms" % (i, v) for i, v in enumerate(per)))
                results["burst_by_position_ms"] = per
                report.append("")
                report.append("A rising series means the terminal leg is still serialised "
                              "behind the read loop; a flat one means it is not.")
    finally:
        ws.close()

    text = "\n".join(report)
    print(text)
    if OUT:
        with open(OUT, "w") as f:
            json.dump({"results": results, "report_md": text,
                       "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                      f, indent=1, sort_keys=True)
        print("\nwrote %s" % OUT)
    # A run that measured nothing must not read as a pass.
    ok = results.get("singles_summary", {}).get("DELIVERED AND VISIBLE", {}).get("n", 0)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
