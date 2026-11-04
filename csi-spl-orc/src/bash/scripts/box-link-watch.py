#!/usr/bin/env python3
"""box-link-watch.py - the 7-min box link watcher (SPL-4816), the core of
do_spl_box_link_watch. Read-only on the relay: it reads the hub's own logs, the
received box logs, the results dir and the process list, and never touches
the relay, its queues or the box.

For each box the hub serves (a dir under GW_ROOT with inbound/ and outbound/)
it raises ONE incident when one of these lasts longer than GW_LIMIT_MIN:
  a  a queued or sent bundle/command with no receipt (`delivered <name>`); a
     command also clears on its box START, its exit line or
     results/<id>/result.json
  b  a box apply or command refused or timed out (a `box: deploy:` / `box:
     exec:` REFUSED / timed out line, or a command whose result exits non-zero
     with REFUSED / timed out in its output, or exit 124) with no later
     success of its kind (`box: deploy: APPLIED`, an exec `-> exit 0`)
  c  the box log not advancing: no <x>-log.box.* received for more than
     GW_QUIET_S; it counts from the last one received
  d  the link down: no radiate process, or the hub log ended the session
ONE incident per box: one spool message (kind blocker) to the seat of the
topic that owns the box, listing every condition over the limit, and one more
(kind note) when none is left ("cleared after N min"). The state file keeps what
was sent, so a second run on the same state sends nothing.

Environment (the action sets the defaults):
  GW_ROOT, GW_LOG_DIR, GW_LOG_GLOB, GW_RESULTS, GW_STATE, GW_LIMIT_MIN, GW_WINDOW_H,
  GW_QUIET_S, GW_TOPICS ("box=topic8,..."), GW_LANES_CMD, GW_FALLBACK,
  GW_SEND, GW_FROM, GW_PS_CMD, GW_RADIATE_RX, GW_NOW (tests),
  DRY_RUN (1 = print the plan only)
Exit: 0 ran, 1 a send failed or a box has no topic (retried next run),
2 usage.
"""

import glob
import hashlib
import json
import os
import re
import shlex
import subprocess
import sys
import time

ANSI = re.compile(r"\x1b\[[0-9;]*m")
LINE = re.compile(
    r"(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d) \S+ \[[a-z][a-z0-9-]*\]\[@([^\]]+)\] \[\d+\] (.*)"
)
CMD_NAME = re.compile(r"^gr-cmd-(?:\d{8}T\d{6}Z-)?([0-9a-f]{12})\.zip$")
SECRETISH = re.compile(r"https?://\S+|\b(token|sig|signature|key)=\S+", re.I)


def env(name, default=""):
    return os.environ.get(name, default) or default


def ts_of(stamp):
    return int(time.mktime(time.strptime(stamp, "%Y-%m-%d %H:%M:%S")))


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def clean(text):
    """One evidence line: no colour, no URL or token, at most 300 chars."""
    return (
        SECRETISH.sub("<redacted>", ANSI.sub("", text)).replace("`", "'").strip()[:300]
    )


def boxes(root):
    out = []
    for d in sorted(glob.glob(os.path.join(root, "*"))):
        if os.path.isdir(os.path.join(d, "inbound")) and os.path.isdir(
            os.path.join(d, "outbound")
        ):
            out.append(os.path.basename(d))
    return out


def hub_lines(log_dir, root, box, since):
    """(epoch, text, raw) of the live hub log lines of BOX since SINCE, oldest
    first. Only logs that name <root>/<box>/ count: a relay test run logs
    into the same dir, but names its own temp queues."""
    mark = os.path.join(root, box) + "/"
    rows = []
    for f in sorted(glob.glob(os.path.join(log_dir, env("GW_LOG_GLOB", "*.out.log")))):
        try:
            if os.path.getmtime(f) < since:
                continue
            with open(f, encoding="utf-8", errors="replace") as fh:
                body = fh.read()
        except OSError:
            continue
        if mark not in body:
            continue
        for raw in ANSI.sub("", body).splitlines():
            m = LINE.search(raw)
            if m and m.group(2) == box:
                t = ts_of(m.group(1))
                if t >= since:
                    rows.append((t, m.group(3), raw))
    rows.sort(key=lambda r: r[0])
    return rows


def has_result(results, cid):
    return bool(results) and os.path.isfile(os.path.join(results, cid, "result.json"))


def result_refused(results, cid):
    text = ""
    for n in ("stdout.txt", "stderr.txt"):
        try:
            with open(
                os.path.join(results, cid, n), encoding="utf-8", errors="replace"
            ) as fh:
                text += fh.read()
        except OSError:
            pass
    m = re.search(r".*(REFUSED|timed out|timeout).*", text)
    return clean(m.group(0)) if m else ""


def pending_items(rows, results):
    """Condition a: key -> (since, what, evidence) of what is unreceipted."""
    items, done = {}, set()
    for t, text, raw in rows:
        m = (
            re.search(r"run-on-box: queued (gr-cmd-\S+\.zip)", text)
            or re.search(r"queued \S+/outbound/launch/(\S+\.zip)", text)
            or re.search(r"^sent (\S+) hub -> \S+ .*waiting for", text)
        )
        if m:
            if m.group(1) not in items:
                items[m.group(1)] = (t, clean(raw))
            continue
        m = re.search(r"^delivered (\S+) to ", text) or re.search(
            r"^outbound: (\S+) not sent: same content", text
        )
        if m:
            done.add(m.group(1))
            continue
        m = re.search(r"exec: request ([0-9a-f]{12}) (START|DONE|-> exit)", text)
        if m:
            done.add("cmd:" + m.group(1))
    out = {}
    for name, (t, ev) in items.items():
        cm = CMD_NAME.match(name)
        if name in done or (
            cm and ("cmd:" + cm.group(1) in done or has_result(results, cm.group(1)))
        ):
            continue
        what = (
            ("command %s sent, no receipt and no result" % cm.group(1))
            if cm
            else ("bundle %s sent, no receipt" % name)
        )
        out["a:" + name] = (t, what, ev)
    return out


def refusal_kind(text, raw, results):
    """('deploy'|'exec'|'', evidence) for one hub line."""
    if re.search(r"^box: deploy: .*(REFUSED|refused|timed out)", text):
        return "deploy", raw
    if re.search(r"^box: exec: .*(REFUSED|refused|timed out)", text):
        return "exec", raw
    m = re.search(r"^exec: request ([0-9a-f]{12}) -> exit ([1-9][0-9]*)", text)
    if m:
        why = result_refused(results, m.group(1)) or (
            "exit 124" if m.group(2) == "124" else ""
        )
        if why:
            return "exec", raw + " | " + why
    return "", raw


def refusals(rows, results):
    """Condition b: refusals with no later success of their kind."""
    out = {}
    for i, (t, text, raw) in enumerate(rows):
        kind, ev = refusal_kind(text, raw, results)
        if not kind:
            continue
        ok = (
            r"^box: deploy: APPLIED "
            if kind == "deploy"
            else r"^(box: )?exec: request \S+ (DONE .*)?-> exit 0\b"
        )
        if any(re.search(ok, later[1]) for later in rows[i + 1 :]):
            continue
        key = "b:%s:%s" % (kind, hashlib.sha1(raw.encode()).hexdigest()[:12])
        out[key] = (
            t,
            "box %s refused or timed out"
            % ("apply" if kind == "deploy" else "command"),
            clean(ev),
        )
    return out


def box_log_seen(root, box, rows):
    """Condition c input: the newest received box log, (epoch, evidence)."""
    best, ev = 0, ""
    for f in glob.glob(os.path.join(root, box, "inbound", "*", "*-log.box.*")):
        try:
            mt = int(os.path.getmtime(f))
        except OSError:
            continue
        if mt > best:
            best, ev = (
                mt,
                "newest box log file inbound/%s"
                % os.path.relpath(f, os.path.join(root, box, "inbound")),
            )
    for t, text, raw in rows:
        if t > best and re.search(r"^received \S+-log\.box\.", text):
            best, ev = t, clean(raw)
    return best, ev


def link_down(rows, ps_out, radiate_rx):
    """Condition d: (True, evidence) when no radiate runs or the log ended it."""
    if not re.search(radiate_rx, ps_out, re.M):
        return True, "no process matches %s" % radiate_rx
    last_up = max(
        (t for t, x, _ in rows if x.startswith("radiating session ")), default=0
    )
    for t, text, raw in rows:
        if t >= last_up and re.search(
            r"^(interrupted: closing the session|session wiped:)", text
        ):
            return True, clean(raw)
    return False, ""


def conditions(box, now):
    root, results = env("GW_ROOT"), env("GW_RESULTS")
    window = int(float(env("GW_WINDOW_H", "6")) * 3600)
    rows = hub_lines(env("GW_LOG_DIR"), root, box, now - window)
    cur = pending_items(rows, results)
    cur.update(refusals(rows, results))
    seen, ev = box_log_seen(root, box, rows)
    if not seen:
        cur["c:box-log"] = (
            None,
            "no box log received in the last %s h" % env("GW_WINDOW_H", "6"),
            "no <x>-log.box.* under inbound/",
        )
    elif now - seen > int(env("GW_QUIET_S", "180")):
        cur["c:box-log"] = (
            seen,
            "the box log is not advancing (last received %s)" % iso(seen),
            ev,
        )
    ps_out = subprocess.run(
        shlex.split(env("GW_PS_CMD", "ps -eo args=")), capture_output=True, text=True
    ).stdout
    down, ev = link_down(rows, ps_out, env("GW_RADIATE_RX"))
    if down:
        cur["d:link"] = (None, "the relay link/session is down", ev)
    return cur


def seat_of(topic):
    """(to, why): the live seat of TOPIC from the lane map (the newest live row
    on that topic whose scope starts with `Seat`), else GW_FALLBACK."""
    try:
        out = subprocess.run(
            shlex.split(env("GW_LANES_CMD")),
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=120,
        ).stdout
        doc = json.loads(out or "{}")
    except (OSError, ValueError, subprocess.TimeoutExpired):
        doc = {}
    rows = [
        r
        for r in doc.get("lanes", [])
        if r.get("state") == "live"
        and str(r.get("topic", "")).startswith(topic)
        and re.match(r"(?i)\W*seat\b", str(r.get("scope", "")))
    ]
    if rows:
        r = max(rows, key=lambda x: str(x.get("updated_at", "")))
        to = (
            "%s@%s" % (r["agent_id"], r["agent_box"])
            if r.get("agent_box")
            else r["agent_id"]
        )
        return to, "seat of topic %s" % topic
    return env(
        "GW_FALLBACK"
    ), "dispatch lease holder: no live seat row on topic %s" % topic


def send(to, kind, task, body):
    cmd = [
        "bash",
        env("GW_SEND"),
        "--from",
        env("GW_FROM"),
        "--to",
        to,
        "--kind",
        kind,
        "--task",
        task,
        "--body",
        body,
    ]
    return subprocess.run(cmd, capture_output=True, text=True).returncode == 0


class Run:
    def __init__(self):
        self.now = int(env("GW_NOW") or time.time())
        self.limit = int(float(env("GW_LIMIT_MIN", "7")) * 60)
        self.dry = env("DRY_RUN", "1") != "0"
        self.topics = dict(
            p.split("=", 1) for p in env("GW_TOPICS").split(",") if "=" in p
        )
        self.seats, self.rc = {}, 0

    def deliver(self, box, kind, body):
        """True when sent (never in a dry run)."""
        topic = self.topics.get(box, "")
        if not topic:
            print("WARN box %s has no topic in GW_TOPICS: not sent: %s" % (box, body))
            self.rc = 1
            return False
        if topic not in self.seats:
            self.seats[topic] = seat_of(topic)
        to, why = self.seats[topic]
        if self.dry:
            print(
                "PLAN %s to %s (%s) on dispatch-%s: %s" % (kind, to, why, topic, body)
            )
            return False
        if to and send(to, kind, "dispatch-" + topic, body):
            print("SENT %s to %s (%s): %s" % (kind, to, why, body))
            return True
        print(
            "WARN the %s to '%s' did not send; retried next run: %s" % (kind, to, body)
        )
        self.rc = 1
        return False

    def box(self, box, old):
        """One incident per box: open (one blocker) when any condition is
        older than the limit, cleared (one note) when none is."""
        cur, conds = conditions(box, self.now), {}
        for key, (since, what, ev) in sorted(cur.items()):
            prev = old.get("conds", {}).get(key, {})
            conds[key] = {
                "since": since or prev.get("since") or self.now,
                "what": what,
                "ev": ev,
            }
            print(
                "INFO %s %s: %s, %d min"
                % (box, key, what, (self.now - conds[key]["since"]) // 60)
            )
        stuck = [c for c in conds.values() if self.now - c["since"] > self.limit]
        inc = old.get("incident")
        if stuck and not inc:
            first = min(c["since"] for c in stuck)
            lines = "".join(
                "\n- %s, since %s (%d min). Evidence: `%s`"
                % (c["what"], iso(c["since"]), (self.now - c["since"]) // 60, c["ev"])
                for c in sorted(stuck, key=lambda c: c["since"])
            )
            body = (
                "LINK STUCK > %d min on box `%s` since %s:%s\nOwner order 7e8d02b4: alert the owner in the topic now. "
                "(do_spl_box_link_watch, SPL-4816: one message per incident, one more when it clears)"
                % (self.limit // 60, box, iso(first), lines)
            )
            if self.deliver(box, "blocker", body):
                inc = {
                    "since": first,
                    "alerted": self.now,
                    "what": "; ".join(c["what"] for c in stuck),
                }
        elif inc and not stuck:
            body = (
                "LINK CLEARED on box `%s` after %d min (stuck since %s: %s). (do_spl_box_link_watch, SPL-4816)"
                % (box, (self.now - inc["since"]) // 60, iso(inc["since"]), inc["what"])
            )
            if self.deliver(box, "note", body):
                inc = None
        if inc:
            print(
                "INFO %s: incident open since %s, alerted %s"
                % (box, iso(inc["since"]), iso(inc["alerted"]))
            )
        return {"conds": conds, "incident": inc} if inc else {"conds": conds}


def main():
    path = env("GW_STATE")
    try:
        with open(path, encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        state = {}
    run = Run()
    new_state = {b: run.box(b, state.get(b, {})) for b in boxes(env("GW_ROOT"))}
    if not new_state:
        print(
            "OK no relay box under %s: nothing to watch on this machine"
            % env("GW_ROOT")
        )
    if run.dry:
        print("OK DRY_RUN: nothing sent, no state written. Re-run with DRY_RUN=0.")
        return run.rc
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(new_state, fh, indent=1, sort_keys=True)
    os.replace(tmp, path)
    return run.rc


if __name__ == "__main__":
    for need in ("GW_ROOT", "GW_LOG_DIR", "GW_STATE", "GW_RADIATE_RX"):
        if not env(need):
            print("FATAL %s must be set" % need, file=sys.stderr)
            sys.exit(2)
    sys.exit(main())
