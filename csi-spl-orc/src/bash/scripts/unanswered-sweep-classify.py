#!/usr/bin/env python3
"""Classify the unanswered human posts for do_spl_unanswered_sweep.

Run by spl_sweep_classify <rows> <state> <outdir> (spl-unanswered-sweep.func.sh),
which passes its settings as environment (SWEEP_NOW, MIN_AGE, RESEND,
MAX_ITEMS, SKIP_T, SKIP_RE, SKIP_CH, SKIP_HUM, ACKS, SWEEP_TO_ID,
SWEEP_ORCH_ID, ENVN). Writes report.md, holder.md, orch.md (empty = nothing
to send), state.new and last into <outdir>.
"""
import os, re, sys, time

rows_f, state_f, out = sys.argv[1:4]
e = os.environ
now = int(e["SWEEP_NOW"])
min_age = int(e["MIN_AGE"]) * 60
resend = int(e["RESEND"])
max_items = int(e["MAX_ITEMS"])
skip_t = set(e["SKIP_T"].split())
skip_re = re.compile(e["SKIP_RE"], re.I) if e["SKIP_RE"] else None
skip_ch = set(e["SKIP_CH"].split())
skip_hum = set(e["SKIP_HUM"].split())

# dispatcher acks (do_spl_unanswered_ack): <epoch> \t <topic or prefix> \t <by> \t <reason>
done_acks = []
try:
    for line in open(e["ACKS"], encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) >= 2 and f[0].isdigit() and re.fullmatch(r"[0-9a-f-]{8,36}", f[1]):
            done_acks.append((int(f[0]), f[1]))
except OSError:
    pass

def acked(task, ts):
    return any(task.startswith(p) and at >= ts for at, p in done_acks)
to, orch, envn = e["SWEEP_TO_ID"], e["SWEEP_ORCH_ID"], e["ENVN"]

# "ok", "thanks", "thank you", "got it", "👍" ... and nothing else. "yes" is
# NOT here: a yes to an agent's question asks it to act.
ACK = {"ok", "okay", "okey", "k", "kk", "thanks", "thank", "you", "thx", "ty", "tnx", "tx",
       "great", "cool", "nice", "perfect", "good", "fine", "got", "it", "noted", "roger",
       "a", "lot", "much", "so", "very", "super", "awesome", "excellent"}

def is_ack(body, files):
    if files == "files":
        return False
    words = re.findall(r"[^\W_]+", body.lower())
    if not words:
        return body.strip() != ""          # emoji / punctuation only
    return len(words) <= 4 and all(w in ACK for w in words)

def age(s):
    s = max(0, s)
    if s < 3600:
        return "%dm" % (s // 60)
    if s < 86400:
        return "%dh%02dm" % (s // 3600, s % 3600 // 60)
    return "%dd%02dh" % (s // 86400, s % 86400 // 3600)

def cell(s):
    return s.replace("\\", "\\\\").replace("|", "\\|")

def utc(t):
    return time.strftime("%Y-%m-%dT%H:%MZ", time.gmtime(t))

counts, items, acks = {}, [], []
for line in open(rows_f, encoding="utf-8", errors="replace"):
    f = line.rstrip("\n").split("\t")
    if len(f) < 13:
        continue
    tenant, tname, chan, task, msg, ts, who, to_id, by, topic, cstate, files = f[:12]
    body = "\t".join(f[12:])
    ts = int(ts)
    c = counts.setdefault(tenant, {k: 0 for k in
        ("open", "ack", "fresh", "closed", "answered", "terminal", "handled", "test", "to-human", "channel", "human")})
    if tenant in skip_t or (skip_re and (skip_re.search(tenant) or (tname and skip_re.search(tname)))):
        c["test"] += 1; continue
    if by == "terminal":
        c["terminal"] += 1; continue
    if by != "human":
        c["answered"] += 1; continue
    if topic == "archived" or cstate in ("archived", "deleted"):
        c["closed"] += 1; continue
    # Addressed to a person, or a null-channel ALL-0 in a topic no agent has
    # posted in (cstate dm). cstate thread is that null channel once an agent
    # has posted: the human's ALL-0 follow-up is open, not to-human.
    if re.match(r"(HUM|GST)-", to_id) or (cstate == "dm" and to_id == "ALL-0"):
        c["to-human"] += 1; continue
    if chan in skip_ch:
        c["channel"] += 1; continue
    if who in skip_hum:
        c["human"] += 1; continue
    if now - ts < min_age:
        c["fresh"] += 1; continue
    if acked(task, ts):
        c["handled"] += 1; continue
    where = "#" + chan if chan else "dm " + to_id
    row = dict(tenant=tenant, where=where, task=task, msg=msg, ts=ts, who=who,
               text=body[:120] if body else ("(files)" if files == "files" else "(empty)"))
    if is_ack(body, files):
        c["ack"] += 1; acks.append(row)
    else:
        c["open"] += 1; items.append(row)
items.sort(key=lambda r: r["ts"])
acks.sort(key=lambda r: r["ts"])

# state: key \t stage \t first-sent \t last-sent ; stage 1 sent, 2 re-sent, 3 escalated
state = {}
try:
    for line in open(state_f, encoding="utf-8"):
        f = line.rstrip("\n").split("\t")
        if len(f) == 4 and f[1] in ("1", "2", "3"):
            state[f[0]] = [int(f[1]), int(f[2]), int(f[3])]
except OSError:          # no state yet (no file, or no dispatch dir on a report-only box)
    pass

new_state, send_new, send_again, escalate = {}, [], [], []
for r in items:
    k = "%s|%s|%s" % (r["tenant"], r["task"], r["msg"])
    st = state.get(k)
    if st is None:
        send_new.append(r); new_state[k] = [1, now, now]
    elif st[0] == 1 and now - st[2] >= resend:
        send_again.append(r); new_state[k] = [2, st[1], now]
    elif st[0] == 2 and now - st[2] >= resend:
        escalate.append(r); new_state[k] = [3, st[1], now]
    else:
        new_state[k] = st
    r["first"] = new_state[k][1]

HDR = "| | workspace | channel | topic | last human | age | who | first 120 chars |\n|---|---|---|---|---|---|---|---|\n"
def table(rows, tag, limit=None):
    s = ""
    for r in rows[:limit]:
        s += "| %s | %s | %s | %s | %s | %s | %s | %s |\n" % (r.get("tag", tag), cell(r["tenant"]), cell(r["where"]), r["task"],
             utc(r["ts"]), age(now - r["ts"]), cell(r["who"]), cell(r["text"]))
    if limit is not None and len(rows) > limit:
        s += "\n... and %d more (the full list: ENV=%s ./run -a do_spl_unanswered_sweep)\n" % (len(rows) - limit, envn)
    return s

stamp = utc(now)
rep = "## Unanswered sweep %s %s\n\n" % (envn, stamp)
rep += "Topics whose last message is a human's, older than %d min (sent to %s; escalation %s).\n\n" % (min_age // 60, to, orch)
rep += HDR + (table(items, "open") if items else "| - | (none) | | | | | | |\n")
rep += "\n### Acknowledgements only (listed, never sent)\n\n" + HDR + (table(acks, "ack") if acks else "| - | (none) | | | | | | |\n")
COLS = ("open", "ack", "handled", "fresh", "closed", "answered", "terminal", "to-human", "channel", "human", "test")
rep += "\n### Per workspace\n\n| workspace | " + " | ".join(COLS) + " |\n|" + "---|" * (len(COLS) + 1) + "\n"
for t in sorted(counts):
    rep += "| %s | " % cell(t) + " | ".join(str(counts[t][k]) for k in COLS) + " |\n"
n_open = sum(c["open"] for c in counts.values())
n_ack = sum(c["ack"] for c in counts.values())
rep += "\nSUM open=%d ack=%d new=%d resend=%d escalate=%d\n" % (n_open, n_ack, len(send_new), len(send_again), len(escalate))
open(os.path.join(out, "report.md"), "w").write(rep)

holder = ""
if send_new or send_again:
    holder = "**Unanswered sweep** (%s, %s): %d new, %d still unanswered after %s.\n\n" % (
        envn, stamp, len(send_new), len(send_again), age(resend))
    holder += ("A human posted last in each topic below and no agent answered. Answer or route each one "
               "(one discussion per lane). Taking one posts its take line in the topic first: "
               "`./run -a do_spl_take DESK_AGENT=<you> DESK_TO=<HUM-n> DESK_TASK=<uuid> TAKE_PLAN=<plan>`. "
               "An item that needs no agent reply: "
               "`./run -a do_spl_unanswered_ack TOPIC=<uuid> REASON=<why>` and it is not sent again. "
               "An item still open %s after this note is sent once more, then escalated to %s.\n\n" % (age(resend), orch))
    holder += HDR + table([dict(r, tag="NEW") for r in send_new] +
                          [dict(r, tag="AGAIN") for r in send_again], "", max_items)
open(os.path.join(out, "holder.md"), "w").write(holder)

esc = ""
if escalate:
    esc = "**Unanswered sweep ESCALATION** (%s, %s): %d topic(s) still unanswered after two notes to %s.\n\n" % (
        envn, stamp, len(escalate), to)
    esc += HDR + table(escalate, "ESC", max_items)
open(os.path.join(out, "orch.md"), "w").write(esc)

with open(os.path.join(out, "state.new"), "w") as fh:
    for k in sorted(new_state):
        fh.write("%s\t%d\t%d\t%d\n" % (k, *new_state[k]))
per = ",".join("%s=%d" % (t, counts[t]["open"]) for t in sorted(counts) if counts[t]["open"])
with open(os.path.join(out, "last"), "w") as fh:
    fh.write("ts=%d\nopen=%d\nack=%d\nnew=%d\nresend=%d\nescalate=%d\nper=%s\n" % (
        now, n_open, n_ack, len(send_new), len(send_again), len(escalate), per))
