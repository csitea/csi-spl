#!/usr/bin/env python3
"""alert-issue-fold.py: fold the fleet's alerts into prio 1 issues, in code
with no model (SPL-4828, spec 146 "An alert files its issue"; owner HUM-10, t1 6c9aa54b msg
84726fdc "BUILD", on the c-002 proposal f520f8bb). Pure: it reads files and
prints JSON, it calls nothing. do_spl_alert_issue_tick does the I/O.

  alert-issue-fold.py keys SRC_DIR STATE
  alert-issue-fold.py plan SRC_DIR STATE NOW ISSUES

SRC_DIR  the sources one tick read, each file optional:
         alerts.json  `spool topics --channel alerts --json`: {"topics": [
                      {"task_id", "subject", "last_ts"}]}; a recovery notice
                      (ALERT_ISSUE_IGNORE_RX, default RECOVERY) is skipped
         disk.ndjson  `spool tail --task disk-headroom --json`: v:1 notes
         gcp.txt      `do_gcp_list_alert_incidents` output ("== <env> (..)",
                      then "<start> .. <end>  <policy>  peak=<v>  <res>")
         since        the window start, epoch s: older alerts are ignored
STATE    the fold state (JSON; missing or empty = a first tick)
NOW      epoch seconds
ISSUES   {"<key>": {"status": "<hub status>", "fixed_at": <epoch|null>},
          "hub": {"<fp hash>": "<key>"},
          "hub_lanes": {"<fp hash>": <epoch of its last lane>}}: what the
         tick read for the lines `keys` printed

keys prints one "key <SPL-n>" line per issue whose status the plan needs,
and "hub 1" when an alert has no issue in the state: the tick then reads the
hub's prio 1 issues of EVERY status for a "fp:<hash>" title (the tick also
reads them whenever its state is missing or stale, a holder that moved to
this box). A done one goes the done path and a lane recorded in an issue's
description ("alert-lane-at: <epoch>") counts toward both caps, so the
fleet files once and keeps one lane budget over a lease move.

plan prints {"actions": [...], "state": {...}}, one action per fingerprint:
  comment  its issue is open: one comment with the count, no lane
  file     no issue: file it prio 1; "lane" says whether one lane is enqueued
  reopen   its issue is done and an alert came after the fix landed
  hold     its issue is done and every alert came before the fix landed
Caps (env): ALERT_ISSUE_LANES_PER_DAY (default 3, rolling 24 h, fleet-wide)
and ALERT_ISSUE_LANE_GAP_S (default 86400, per fingerprint). Over a cap the
issue is still filed or reopened, with no lane.
"""

import hashlib
import json
import os
import re
import sys
from datetime import datetime, timezone

SEEN_KEEP_S = 7 * 86400
DAY_S = 86400
OPEN = {"eval", "todo", "wip", "blocked", "onhold", "qas"}

UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
HEX = re.compile(r"\b[0-9a-f]{7,40}\b")
TIME = re.compile(
    r"\b\d{4}-\d{2}-\d{2}(t\d{2}:\d{2}(:\d{2})?(\.\d+)?z?)?\b|\b\d{1,2}:\d{2}(:\d{2})?z?\b"
)
SEVERITY = re.compile(r"\b(warn|warning|critical|crit|alert|cleared|error|fatal)\b")
DISK = re.compile(
    r"^DISK HEADROOM (\S+) \([^)]*\): (?:CRITICAL )?(\S+) \(.*?\) (blocks|inodes)\b"
)
# a notice that something recovered is not an alert (ALERT_ISSUE_IGNORE_RX)
RECOVERY = r"\b(back after|is back|recovered|cleared|resolved)\b"
GCP_ENV = re.compile(r"^== (\S+) \((\S+)\)$")
GCP_ROW = re.compile(
    r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}Z) \.\. \S+\s+(.+?)\s+peak=\S+\s*(.*)$"
)


def norm(text):
    """The alert text with its times, ids, digits, severity words and
    (parenthesised detail) stripped: one alert names other seats or counts in
    its brackets each time it fires."""
    t = text.lower().replace("**", " ").replace("`", " ")
    for _ in range(3):
        t = re.sub(r"\([^()]*\)", " ", t)
    t = re.sub(r"\(.*$", " ", t)
    for rx in (UUID, TIME, HEX, SEVERITY):
        t = rx.sub(" ", t)
    t = re.sub(r"\d+", "", t)
    t = re.sub(r"[^a-z/_.:@ -]+", " ", t)
    return re.sub(r"\s+", " ", t).strip()[:120]


def epoch(ts):
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y-%m-%dT%H:%MZ"):
        try:
            return int(
                datetime.strptime(re.sub(r"\.\d+Z$", "Z", ts), fmt)
                .replace(tzinfo=timezone.utc)
                .timestamp()
            )
        except ValueError:
            continue
    raise ValueError("not a UTC time: %r" % ts)


def read(path):
    try:
        with open(path, encoding="utf-8") as f:
            return f.read()
    except OSError:
        return ""


def alerts_topics(raw):
    try:
        page = json.loads(raw) if raw.strip() else {}
    except ValueError:
        return []
    out = []
    skip = re.compile(os.environ.get("ALERT_ISSUE_IGNORE_RX") or RECOVERY, re.I)
    for t in page.get("topics") or []:
        subj = t.get("subject") or ""
        if skip.search(subj):
            continue
        out.append(
            {
                "src": "alerts",
                "ref": "alerts:" + t["task_id"],
                "at": epoch(t["last_ts"]),
                "text": subj,
                "fp": "alerts|" + norm(subj),
                "topic": t["task_id"],
            }
        )
    return out


def disk_notes(raw):
    out = []
    for line in raw.splitlines():
        try:
            m = json.loads(line)
        except ValueError:
            continue
        body = m.get("body") or ""
        d = DISK.match(body)
        fp = "disk|%s|%s|%s" % d.groups() if d else "disk|" + norm(body)
        out.append(
            {
                "src": "disk",
                "ref": "disk:" + m.get("msg_id", ""),
                "at": epoch(m["ts"]),
                "text": body.split("; top growers")[0],
                "fp": fp,
                "topic": "",
            }
        )
    return out


def gcp_incidents(raw):
    out, env = [], ""
    for line in raw.splitlines():
        e = GCP_ENV.match(line)
        if e:
            env = e.group(1)
            continue
        r = GCP_ROW.match(line)
        if r and env:
            start, policy, res = r.groups()
            out.append(
                {
                    "src": "gcp",
                    "ref": "gcp:%s:%s:%s" % (env, policy, start),
                    "at": epoch(start),
                    "text": ("GCP alert %s in %s %s" % (policy, env, res)).rstrip(),
                    "fp": "gcp|%s|%s" % (env, policy),
                    "topic": "",
                }
            )
    return out


def collect(src_dir):
    def j(name):
        return read(os.path.join(src_dir, name))

    return (
        alerts_topics(j("alerts.json"))
        + disk_notes(j("disk.ndjson"))
        + gcp_incidents(j("gcp.txt"))
    )


def fp_hash(fp):
    return hashlib.sha1(fp.encode()).hexdigest()[:8]


def load_state(path):
    raw = read(path)
    st = json.loads(raw) if raw.strip() else {}
    for k, v in (("v", 1), ("seen", {}), ("fps", {}), ("lanes", [])):
        st.setdefault(k, v)
    return st


def since(src_dir):
    """The tick's window start (SRC_DIR/since, epoch s), 0 = none."""
    try:
        return int(read(os.path.join(src_dir, "since")).strip() or 0)
    except ValueError:
        return 0


def fresh(alerts, st, start=0):
    """The alerts this state has not seen, from START on, per fingerprint hash."""
    groups = {}
    for a in sorted(alerts, key=lambda a: a["at"]):
        if a["ref"] not in st["seen"] and a["at"] >= start:
            groups.setdefault(fp_hash(a["fp"]), []).append(a)
    return groups


def lane_ok(st, rec, now, why):
    per_day = int(os.environ.get("ALERT_ISSUE_LANES_PER_DAY", "3"))
    gap = int(os.environ.get("ALERT_ISSUE_LANE_GAP_S", str(DAY_S)))
    last = rec.get("last_lane_at") or 0
    if last and now - last < gap:
        why.append(
            "one lane per fingerprint per %d h: the last ran %d h ago"
            % (gap // 3600, (now - last) // 3600)
        )
        return False
    if len([t for t in st["lanes"] if now - t < DAY_S]) >= per_day:
        why.append(
            "the %d lanes a day are used (ALERT_ISSUE_LANES_PER_DAY): issue only"
            % per_day
        )
        return False
    return True


def closed_op(act, rec, group, info, st, now):
    fixed = info.get("fixed_at") or rec.setdefault("closed_seen_at", now)
    if not [a for a in group if a["at"] > fixed]:
        act["op"] = "hold"
        act["why"].append("every alert is older than the fix (landed %s)" % fixed)
        return
    act["op"] = "reopen"
    rec.pop("closed_seen_at", None)
    act["lane"] = lane_ok(st, rec, now, act["why"])


def decide(h, group, st, issues, now):
    first = group[0]
    rec = st["fps"].get(h) or {
        "fp": first["fp"],
        "key": "",
        "count": 0,
        "first_at": first["at"],
    }
    hub_at = (st.get("hub_lane_at") or {}).get(h, 0)
    if hub_at > (rec.get("last_lane_at") or 0):
        rec["last_lane_at"] = hub_at
    rec["count"] = rec.get("count", 0) + len(group)
    rec["last_at"] = group[-1]["at"]
    rec["key"] = rec.get("key") or (issues.get("hub") or {}).get(h, "")
    status = (issues.get(rec["key"]) or {}).get("status", "")
    act = {
        "fp": rec["fp"],
        "hash": h,
        "n": len(group),
        "count": rec["count"],
        "key": rec["key"],
        "src": first["src"],
        "text": group[-1]["text"],
        "topic": first["topic"],
        "refs": [a["ref"] for a in group],
        "lane": False,
        "why": [],
    }
    if rec["key"] and (status in OPEN or not status):
        # an unknown status (a hub read that failed) comments, never files twice
        act["op"] = "comment"
    elif rec["key"] and status == "done":
        closed_op(act, rec, group, issues[rec["key"]], st, now)
    else:
        # no issue, or a dismissed one (diss): a new issue
        act["op"], act["key"], rec["key"] = "file", "", ""
        act["lane"] = lane_ok(st, rec, now, act["why"])
    if act["lane"]:
        rec["last_lane_at"] = now
        st["lanes"].append(now)
    st["fps"][h] = rec
    return act


def seed_lanes(st, issues, now):
    """The lanes the hub's issues record (another box's holder placed them):
    into the day's count and each fingerprint's last lane, once per
    fingerprint and lane (one tick places several lanes at the same NOW).
    hub_lane_at keeps the seeded lane of a fingerprint this state has no
    record of, for a day, so a second stale read does not count it again."""
    known = st.setdefault("hub_lane_at", {})
    for h, at in (issues.get("hub_lanes") or {}).items():
        if not isinstance(at, int) or now - at >= DAY_S:
            continue
        rec = st["fps"].get(h)
        if (rec and (rec.get("last_lane_at") or 0) >= at) or known.get(h, 0) >= at:
            continue
        st["lanes"].append(at)
        known[h] = at
        if rec:
            rec["last_lane_at"] = at
    st["hub_lane_at"] = {h: t for h, t in known.items() if now - t < DAY_S}


def plan(src_dir, state_path, now, issues_path):
    st = load_state(state_path)
    issues = json.loads(read(issues_path) or "{}")
    st["lanes"] = [t for t in st["lanes"] if now - t < DAY_S]
    seed_lanes(st, issues, now)
    actions = []
    for h, group in fresh(collect(src_dir), st, since(src_dir)).items():
        actions.append(decide(h, group, st, issues, now))
        for a in group:
            st["seen"][a["ref"]] = a["at"]
    st["seen"] = {r: t for r, t in st["seen"].items() if now - t < SEEN_KEEP_S}
    st["last_tick"] = now
    # the next window starts here; the tick moves it back when an action failed
    st["window_from"] = now
    return {"actions": actions, "state": st}


def keys(src_dir, state_path):
    st = load_state(state_path)
    out, hub = set(), False
    for h in fresh(collect(src_dir), st, since(src_dir)):
        k = (st["fps"].get(h) or {}).get("key", "")
        if k:
            out.add(k)
        else:
            hub = True
    for k in sorted(out):
        print("key " + k)
    if hub:
        print("hub 1")


def main(argv):
    if len(argv) == 3 and argv[0] == "keys":
        keys(argv[1], argv[2])
        return 0
    if len(argv) == 5 and argv[0] == "plan":
        print(json.dumps(plan(argv[1], argv[2], int(argv[3]), argv[4]), sort_keys=True))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
