#!/usr/bin/env python3
"""The verdicts of do_spl_issue_stale_sweep (spl-issue-stale-sweep.func.sh).

argv: WORK CAP IDLE_DAYS SPOOL_ROOT [NOW]. WORK holds issues.json (the wip
issues), lanes.json (the fleet lane map), asks.json (the ask book) and
cited.txt (every issue key an origin/master commit message names, one a
line). Prints, oldest last update first, one TSV line per wip issue:
  end  KEY  updated_at  title  held   (all 10 conditions held, under CAP)
  keep KEY  c<N>|cap    why           (the first condition that failed)
A fixed rule, no judgement per item: an issue is ended only when ALL hold:
  c1 created_by is an agent id, not HUM-* (nor empty)
  c2 kind issue, not epic or feature
  c3 status wip
  c4 assignee is not HUM-*
  c5 not a discussion issue (the card LANE_ISSUE_OP=discussion files)
  c6 no live lane names the key (its hub row, or its brief / seed on this box)
  c7 no origin/master commit message names the key
  c8 no open ask names the key
  c9 last update IDLE_DAYS or more days ago
  c10 the title does not start "Seat brief:" (a standing seat's brief issue,
      ended by the closer or LANE_ISSUE_OP=end, never by this sweep; SPL-5940)
"""

import datetime as dt, json, re, sys

work, cap, idle, root = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
now_arg = sys.argv[5] if len(sys.argv) > 5 else ""
AGENT = re.compile(r"^([a-z]-[0-9]+|(CLE|GRK|AGY|QWN)-[0-9]+)(@[A-Za-z0-9.-]+)?$")
LIVE_ASK = {"open", "acked", "queued", "placing", "needs_owner"}
DISCUSSION = ("next: the first answer in the topic", "\n- Taken by: ")
SEAT_BRIEF = "Seat brief:"


def load(name):
    with open(f"{work}/{name}", encoding="utf-8") as f:
        return json.load(f)


def ts(s):
    if not s:
        return 0.0
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None


def brief(lane):
    """The lane's brief, seed, issue file and the brief files its seed names, on this box."""
    aid = (lane.get("agent_id") or "").split("@")[0]
    branch = lane.get("branch") or ""
    slug = branch[len(aid) + 1 :] if aid and branch.startswith(aid + "-") else ""
    parts = [read(f"{root}/dispatch/briefs/{slug}.md") if slug else None]
    seed = read(f"{root}/{aid}/lifetime/prompt.txt") if aid else None
    parts += [seed, read(f"{root}/{aid}/lifetime/issue") if aid else None]
    for p in sorted(
        set(re.findall(re.escape(root) + r"/[A-Za-z0-9._/-]+\.md", seed or ""))
    ):
        if ".." not in p:
            parts.append(read(p))
    return "\n".join(x for x in parts if x)


def names(text, key):
    return (
        re.search(r"(?<![A-Za-z0-9-])" + re.escape(key) + r"(?![0-9])", text or "")
        is not None
    )


now = ts(now_arg) if now_arg else dt.datetime.now(dt.timezone.utc).timestamp()
doc = load("issues.json")
issues = (doc.get("result", doc) if isinstance(doc, dict) else {}).get("issues") or []
lanes = [
    l for l in load("lanes.json").get("lanes") or [] if l.get("state", "live") == "live"
]
lane_text = []
for l in lanes:
    fields = [
        l.get(k) or ""
        for k in ("issue_key", "origin_issue", "scope", "topic", "branch")
    ]
    lane_text.append(
        (
            f"{l.get('agent_id', '?')}@{l.get('agent_box', '?')}",
            " ".join(fields + list(l.get("files") or []) + [brief(l)]),
        )
    )
asks = [a for a in load("asks.json").get("asks") or [] if a.get("state") in LIVE_ASK]
with open(f"{work}/cited.txt", encoding="utf-8") as f:
    cited = {x.strip() for x in f if x.strip()}


def why_kept(i):
    key, desc = i.get("key") or "", i.get("description") or ""
    by, who = i.get("created_by") or "", i.get("assignee") or ""
    if not AGENT.match(by):
        return "c1", f"created by {by or 'nobody'}, not an agent"
    if i.get("kind", "issue") != "issue":
        return "c2", f"kind {i.get('kind')}"
    if i.get("status") != "wip":
        return "c3", f"status {i.get('status')}"
    if who.startswith("HUM-"):
        return "c4", f"assignee {who}"
    if any(m in desc for m in DISCUSSION):
        return "c5", "a discussion issue"
    for lane, text in lane_text:
        if names(text, key):
            return "c6", f"live lane {lane}"
    if key in cited:
        return "c7", "an origin/master commit names it"
    for a in asks:
        if names(json.dumps(a, ensure_ascii=False), key):
            return "c8", f"open ask {a.get('ask_id', '?')}"
    if ts(i.get("updated_at")) > now - idle * 86400:
        return "c9", f"updated {i.get('updated_at', '')[:19]}, under {idle} d"
    if (i.get("title") or "").lstrip().startswith(SEAT_BRIEF):
        return "c10", "a standing seat's brief (Seat brief:)"
    return None


n = 0
for i in sorted(
    (x for x in issues if isinstance(x, dict) and x.get("key")),
    key=lambda x: x.get("updated_at") or "",
):
    kept = why_kept(i)
    if kept is None and n >= cap:
        kept = ("cap", f"over the cap of {cap}")
    if kept:
        print(f"keep\t{i['key']}\t{kept[0]}\t{kept[1]}")
        continue
    n += 1
    title = re.sub(r"[\t\r\n]+", " ", i.get("title") or "")[:100]
    held = f"c1-c10 held: created_by {i.get('created_by')}, assignee {i.get('assignee') or 'none'}, no live lane, open ask or master commit names it"
    print(f"end\t{i['key']}\t{i.get('updated_at', '')}\t{title}\t{held}")
