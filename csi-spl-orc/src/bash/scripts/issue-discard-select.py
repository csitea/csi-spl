#!/usr/bin/env python3
"""The plan of do_spl_issue_discard_stale (spl-issue-discard-stale.func.sh).

argv: WORK CUTOFF KEEP_LABELS WIP_DAYS TRIAGE_MIN_VOTES NOW [KEYS_ONLY]. WORK holds
open.json (the open issues), lanes.txt, commits.txt ("<sha> <unix time>
<KEY>...") and triage.tsv. Prints one TSV line per item to discard: key,
status, last update, reason code, reason, title; the kept counts per guard go
to stderr. A fixed rule, no judgement per item. KEYS_ONLY, a keys file (first
word a line), makes it the selection: only those keys, no recency cutoff, no
wip window, no landed-sha guard; the keep label, the live assignee and the
open child still keep an item.
"""

import datetime as dt, json, re, sys

work, cut, labels, wipdays, minvotes, now = sys.argv[1:7]
keys_only = sys.argv[7] if len(sys.argv) > 7 else ""


def ts(s):
    if not s:
        return 0.0
    s = s if "T" in s else s + "T00:00:00Z"
    return dt.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


cut = ts(cut)
now = ts(now) if now else dt.datetime.now(dt.timezone.utc).timestamp()
keep_labels = {x.strip() for x in labels.split(",") if x.strip()}
lanes = {l.strip() for l in open(work + "/lanes.txt") if l.strip()}
doc = json.load(open(work + "/open.json", encoding="utf-8"))
issues = [
    i
    for i in ((doc.get("result") or {}).get("issues") or [])
    if isinstance(i, dict) and i.get("key") and i.get("status") not in ("done", "diss")
]
commits, named = {}, {}
for line in open(work + "/commits.txt"):
    p = line.split()
    if len(p) < 2:
        continue
    commits[p[0]] = int(p[1])
    for k in p[2:]:
        named[k] = max(named.get(k, 0), int(p[1]))
triage = {}
for line in open(work + "/triage.tsv", encoding="utf-8"):
    f = line.rstrip("\n").split("\t")
    if len(f) > 4 and f[4].isdigit() and int(f[4]) >= int(minvotes):
        triage[f[0]] = int(f[4])


def landed_after(i, up):
    if named.get(i["key"], 0) > up:
        return True
    for h in set(re.findall(r"\b[0-9a-f]{7,40}\b", i.get("description") or "")):
        if any(sha.startswith(h) and t > up for sha, t in commits.items()):
            return True
    return False


def guard(i, up):
    if keep_labels & set(i.get("labels") or []):
        return "label"
    if i.get("assignee") and i["assignee"] in lanes:
        return "live-lane"
    if i.get("status") == "wip" and up >= now - int(wipdays) * 86400:
        return "wip-recent"
    return "sha" if landed_after(i, up) else ""


cand, kept = {}, {}
listed = set()
if keys_only:
    listed = {l.split()[0] for l in open(keys_only, encoding="utf-8") if l.split()}


def keep(why):
    kept[why] = kept.get(why, 0) + 1


for i in issues:
    up = ts(i.get("updated_at"))
    if keys_only:
        if i["key"] not in listed:
            continue
        g = guard(i, up)
        if g in ("label", "live-lane"):
            keep(g)
        else:
            cand[i["key"]] = ("KEYS", "the issue check's verdict: outdated")
        continue
    g = guard(i, up)
    if i["key"] in triage and g != "label":
        cand[i["key"]] = (
            "TRIAGE",
            "the triage panel's %d seats voted discard" % triage[i["key"]],
        )
    elif up >= cut:
        keep("recent")
    elif g:
        keep(g)
    else:
        cand[i["key"]] = (
            "STALE",
            "open, not updated since %s" % (i.get("updated_at") or "")[:10],
        )

children = {}
for i in issues:
    for p in {i.get("epic"), i.get("parent")} - {None, "", i["key"]}:
        children.setdefault(p, set()).add(i["key"])
changed = True
while changed:
    changed = False
    for k in list(cand):
        if children.get(k, set()) - set(cand):
            del cand[k]
            keep("open-child")
            changed = True


def clean(s):
    return re.sub(r"\s+", " ", s or "").strip()


for i in issues:
    if i["key"] in cand:
        code, why = cand[i["key"]]
        print(
            "\t".join(
                [
                    i["key"],
                    i.get("status") or "",
                    (i.get("updated_at") or "")[:19],
                    code,
                    why,
                    clean(i.get("title")),
                ]
            )
        )
if keys_only:
    keep_open = {i["key"] for i in issues}
    kept["not-open"] = len(listed - keep_open)
sys.stderr.write(
    "KEPT open=%d %s\n"
    % (len(issues), " ".join("%s=%d" % kv for kv in sorted(kept.items())))
)
