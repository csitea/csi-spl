"""delivery-probe.py - how late does a person's message reach the OTHER person?

Bug B (t1 #spool-hub-bugs 4ecb4b0d): messages reach the other person late,
with an old send time, while the hub accepts every send in under a second
(CLE-35004). So the time is not in the write. This prices the read side the
way a person sees it, with two member sessions of the same human (two logins,
two sockets - a phone and a laptop):

  RECEIVER  one socket opened at the start and kept for the whole run, like a
            tab left open. It is never re-dialled by this probe except when the
            hub closes it, and then it catches up the way the WUI does.
  SENDER    a FRESH socket per send by default (PROBE_FRESH_SENDER=1), like a
            person who just opened the app: it lands on whichever hub revision
            is live NOW.

Per send it stamps, on this one clock:
  t_ack     the sender's ack frame        (the hub has stored it)
  t_live    the receiver's message frame  (the other person's socket event)
  t_caught  the receiver's catch-up read  (only when the live frame never came)

A send whose live frame does not arrive within PROBE_WAIT seconds is a MISS:
the receiver's socket stayed open and silent, which is what a browser socket
left on a retired Cloud Run revision looks like (it still pongs, but the post
was fanned out by another process). The hub's welcome names its `revision`
(after the bug-B fix), so each row says which revision each side was on.

Env (set by ./run -a do_spl_delivery_probe):
  M3_HUB_URL M3_AUTH_URL M3_TENANT M3_STATE M3_HUMAN_EMAIL   as m3-e2e.py
  PROBE_N             sends                                 default 20
  PROBE_GAP           seconds between sends                 default 20
  PROBE_WAIT          seconds a live frame may take         default 30
  PROBE_FRESH_SENDER  1 = new sender socket per send        default 1
  PROBE_CHECK_EVERY   0 = a raw socket; N = the receiver does what the WUI
                      does since the bug-B fix: every N s it asks GET
                      /v1/wui/revision and, when that is not its welcome's
                      revision, re-dials and runs the catch-up read
  PROBE_OUT           results.json path
"""
import importlib.util
import json
import os
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("m3_e2e", os.path.join(HERE, "m3-e2e.py"))
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)

N = int(os.environ.get("PROBE_N", "20"))
GAP = float(os.environ.get("PROBE_GAP", "20"))
WAIT = float(os.environ.get("PROBE_WAIT", "30"))
FRESH = os.environ.get("PROBE_FRESH_SENDER", "1") != "0"
OUT = os.environ.get("PROBE_OUT", "")
CHECK = float(os.environ.get("PROBE_CHECK_EVERY", "0"))


def pct(xs, p):
    """Nearest-rank percentile; None for an empty sample."""
    if not xs:
        return None
    xs = sorted(xs)
    k = max(0, min(len(xs) - 1, int(round(p / 100.0 * len(xs) + 0.5)) - 1))
    return xs[k]


def summary(rows):
    """p50/p90/max per hop, over the sends that HAVE that hop, plus the misses."""
    out = {}
    for hop, a, b in (("send->ack", "t_send", "t_ack"), ("send->other socket", "t_send", "t_live"),
                      ("send->other sees it (live or catch-up)", "t_send", "t_seen")):
        xs = [r[b] - r[a] for r in rows if r.get(a) is not None and r.get(b) is not None]
        out[hop] = {"n": len(xs), "p50": pct(xs, 50), "p90": pct(xs, 90), "max": max(xs) if xs else None}
    out["missed_live"] = sum(1 for r in rows if r.get("t_live") is None)
    out["n"] = len(rows)
    return out


def dial(cookie, tries=3):
    """One socket and its welcome; a transient TLS / network error is retried."""
    for n in range(tries):
        try:
            return dial_once(cookie)
        except (OSError, RuntimeError):
            if n + 1 == tries:
                raise
            time.sleep(2)


def dial_once(cookie):
    w = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    put = w.q.put
    w.q.put = lambda f: put(dict(f, _t=time.time()))  # the ARRIVAL time, stamped by the reader thread
    w.send({"type": "hello"})
    welcome = w.wait(lambda f: f.get("type") == "welcome", 15)
    if not welcome:
        raise RuntimeError("no welcome")
    return w, welcome


def catch_up(cookie, task, msg_id):
    """The WUI's reconnect catch-up: one topic read; True when msg_id is in it."""
    st, _, out = m3.http("GET", "%s/v1/view/topics/%s?order=desc&limit=50" % (m3.HUB, task),
                         headers={"Cookie": cookie, "Origin": m3.HUB})
    rows = (out or {}).get("messages", []) if isinstance(out, dict) else []
    return st == 200 and any((r.get("msg") or r).get("msg_id") == msg_id or r.get("msg_id") == msg_id for r in rows)


def live_revision():
    st, _, out = m3.http("GET", m3.HUB + "/v1/wui/revision")
    return (out or {}).get("revision", "") if st == 200 and isinstance(out, dict) else ""


def is_msg(msg_id):
    return lambda f: f.get("type") == "message" and (f.get("msg_id") == msg_id or
                                                     ((f.get("env") or {}).get("msg") or {}).get("msg_id") == msg_id)


def save(rows, task):
    if OUT:
        res = {"hub": m3.HUB, "tenant": m3.TENANT, "task_id": task, "fresh_sender": FRESH, "wait": WAIT,
               "check_every": CHECK, "summary": summary(rows), "rows": rows}
        with open(OUT, "w") as f:
            json.dump(res, f, indent=1, sort_keys=True)


def main():
    m3.need("M3_HUB_URL", "M3_AUTH_URL", "M3_STATE", "M3_HUMAN_EMAIL")
    email = os.environ["M3_HUMAN_EMAIL"]
    cookies = []
    for tag in ("human", "human"):  # two logins = two sessions, one stored password
        st, body, cookie = m3.native_login(email, m3.TENANT, tag)
        if st != 200 or not cookie:
            m3.log("FAIL login %s %s" % (st, json.dumps(body)[:200]))
            return 1
        cookies.append(cookie)
    recv_cookie, send_cookie = cookies
    task = str(uuid.uuid4())
    rx, rx_welcome = dial(recv_cookie)
    rx.send({"type": "subscribe", "task_id": task})
    m3.log("INFO receiver on revision %s, topic %s" % (rx_welcome.get("revision", "?"), task))
    tx = None
    rows = []
    for i in range(N):
        if tx is None or FRESH or tx.closed is not None:
            if tx is not None:
                tx.close()
            tx, tx_welcome = dial(send_cookie)
        if rx.closed is not None:  # the hub closed it: re-dial and re-subscribe, as the WUI does
            rx, rx_welcome = dial(recv_cookie)
            rx.send({"type": "subscribe", "task_id": task})
        msg_id = str(uuid.uuid4())
        row = {"i": i, "msg_id": msg_id, "rx_revision": rx_welcome.get("revision", ""),
               "tx_revision": tx_welcome.get("revision", ""), "t_send": time.time()}
        tx.send({"type": "send", "msg_id": msg_id, "task_id": task, "kind": "note",
                 "body": "delivery probe %d/%d" % (i + 1, N), "files": []})
        ack = tx.wait(lambda f: f.get("msg_id") == msg_id and f.get("type") in ("ack", "error"), 15)
        if ack and ack.get("type") == "ack":
            row["t_ack"] = ack["_t"]
        live, end = None, time.time() + WAIT
        while live is None and time.time() < end:
            live = rx.wait(is_msg(msg_id), min(CHECK or WAIT, max(0.05, end - time.time())))
            if live is None and CHECK and rx_welcome.get("revision") and live_revision() not in ("", rx_welcome.get("revision")):
                rx.close()  # the WUI's checkRevision: re-dial onto the live revision, then catch up
                rx, rx_welcome = dial(recv_cookie)
                rx.send({"type": "subscribe", "task_id": task})
                row["redialled"] = True
                if catch_up(recv_cookie, task, msg_id):
                    row["t_seen"] = row["t_caught"] = time.time()
                    break
        if live:
            row["t_live"] = row["t_seen"] = live["_t"]
        elif "t_seen" not in row and catch_up(recv_cookie, task, msg_id):
            row["t_seen"] = row["t_caught"] = time.time()
        m3.log("%s %d rx=%s tx=%s ack=%s live=%s" % (
            "OK  " if live else "MISS", i + 1, row["rx_revision"] or "?", row["tx_revision"] or "?",
            "%.3f" % (row["t_ack"] - row["t_send"]) if "t_ack" in row else "-",
            "%.3f" % (row["t_live"] - row["t_send"]) if "t_live" in row else "never (waited %ss)" % int(WAIT)))
        rows.append(row)
        save(rows, task)
        if i + 1 < N:
            time.sleep(GAP)
    if tx is not None:
        tx.close()
    rx.close()
    save(rows, task)
    m3.log(json.dumps(summary(rows), indent=1, sort_keys=True))
    return 0 if rows else 1


if __name__ == "__main__":
    sys.exit(main())
