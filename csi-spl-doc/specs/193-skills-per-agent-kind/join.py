#!/usr/bin/env python3
"""Spec 193 join: every count in sections 3.1-3.4 and Appendix B, from the raw files of Appendix A.

The 3.3 labels are labels.tsv next to this file (one labeller, by hand): msg id prefix, class.

Usage: SPAWN_DIR=<dir with serve.log and briefs/> python3 -I join.py <raw dir> <window end, ISO UTC>
Read-only: reads the raw dir and the spawn dir, writes nothing, prints JSON.
"""

import collections, json, os, random, re, statistics, sys
from datetime import datetime

KINDS = [
    "specs_and_docs",
    "complex_coding",
    "simple_coding",
    "tests",
    "secret",
    "i18n",
    "orchestration",
]
START = "2026-09-24"


def ts(s):
    s = re.sub(r"\.\d+", "", s.strip().replace(" ", "T", 1)).replace("Z", "+00:00")
    if re.search(r"[+-]\d\d$", s):
        s += ":00"
    return datetime.fromisoformat(s)


def rows(path, n):
    """psql rows 'a|b|...' with exactly n fields (headers and footers dropped)."""
    out = []
    for line in open(path, errors="replace"):
        f = [x.strip() for x in line.rstrip("\n").split("|", n - 1)]
        if len(f) == n and f[0] and f[0][0].isalnum() and f[0] not in ("r", "number"):
            out.append(f)
    return out


def lanes_from_log(spawn_dir, end):
    """One row per SPAWNED line in the window; kind and issue from the brief's header lines."""
    out = []
    for line in open(os.path.join(spawn_dir, "serve.log")):
        f = line.rstrip("\n").split("\t")
        if len(f) < 5 or f[1] != "SPAWNED" or not (START <= f[0] < end):
            continue
        m = re.match(r"(\S+) %\S+ (\S+) (\S+)", f[4])
        r = dict(
            ts=f[0],
            bid=f[2],
            vendor=m.group(2) if m else "",
            slug=m.group(3) if m else "",
            kind="none",
            issue="",
            issue_src="",
            title="",
        )
        try:
            t = open(
                os.path.join(spawn_dir, "briefs", f[2] + ".md"), errors="replace"
            ).read()
        except OSError:
            t = ""
        km = re.search(r"Kind:\s*([a-z0-9_]+)", t)
        if km:
            k = km.group(1)
            r["kind"] = (
                k
                if k in KINDS
                else ("review" if k in ("review", "code_review") else "other:" + k)
            )
        im = re.search(r"^Issue:\s*(SPL-\d+)", t, re.M) or re.search(
            r"\bIssue:\s*(SPL-\d+)", t
        )
        if im:
            r["issue"], r["issue_src"] = im.group(1), "line"
        r["title"] = (
            re.sub(r"\s+", " ", re.sub(r"^#\s*", "", t.split("\n", 1)[0]))
            .strip()
            .lower()[:120]
        )
        out.append(r)
    return out


def title_match(lanes, raw):
    """A lane with no Issue: line gets the issue whose title equals the brief's first line (lowest number if several)."""
    by_title = collections.defaultdict(list)
    for num, title in rows(os.path.join(raw, "titles.txt"), 2):
        if num.isdigit():
            by_title[re.sub(r"\s+", " ", title).strip().lower()[:120]].append(int(num))
    hit = amb = 0
    for r in lanes:
        if r["issue"] or not r["title"] or r["title"] not in by_title:
            continue
        nums = by_title[r["title"]]
        amb += len(nums) > 1
        r["issue"], r["issue_src"] = "SPL-%d" % min(nums), "title"
        hit += 1
    return hit, amb


def kind_map(lanes, src=("line", "title")):
    """Issue -> kind of its first lane (log order), over lanes whose issue came from src."""
    m = {}
    for r in lanes:
        if r["issue"] and r["issue_src"] in src:
            m.setdefault(r["issue"], r["kind"])
    return m


def commits_of(raw):
    out = []
    for blk in (
        open(os.path.join(raw, "commits.raw"), errors="replace").read().split("\x1f")
    ):
        blk = blk.strip("\n")
        if not blk:
            continue
        head, _, body = blk.partition("\x1e")
        h, ad, cd, subj = head.split("\t", 3)
        m = re.match(r"^(\w+)(?:\(([^)]*)\))?!?:", subj)
        cite = set(re.findall(r"SPL-\d+", subj)) | set(
            re.findall(r"^Closes:\s*(SPL-\d+)", body, re.M)
        )
        out.append(
            dict(h=h, ad=ts(ad), cd=ts(cd), t=m.group(1) if m else "other", cite=cite)
        )
    out.reverse()
    return out


def deploy_times(raw, commits, end):
    """Per commit: the earliest release tag at or after it on the linear trunk."""
    idx = {c["h"]: i for i, c in enumerate(commits)}
    tag = [None] * len(commits)
    for line in open(os.path.join(raw, "tags.tsv")):
        name, when, obj = line.rstrip("\n").split("\t")
        i = idx.get(obj[:40])
        if (
            i is not None
            and ts(when) < ts(end)
            and re.fullmatch(r"v\d+\.\d+\.\d+(-c\d+)?", name)
        ):
            t = ts(when)
            tag[i] = t if tag[i] is None or t < tag[i] else tag[i]
    dep, cur = [None] * len(commits), None
    for i in range(len(commits) - 1, -1, -1):
        if tag[i] and (cur is None or tag[i] < cur):
            cur = tag[i]
        dep[i] = cur
    return dep


def q(v, p):
    v = sorted(v)
    return v[min(len(v) - 1, int(round(p * (len(v) - 1))))]


def hours(a, b):
    return (b - a).total_seconds() / 3600


def fail_rows(raw):
    for f in rows(os.path.join(raw, "fails.txt"), 7):
        if re.fullmatch(r"[0-9a-f]{8}-[0-9a-f-]{27}", f[0]):
            yield dict(
                mid=f[0], keys=["SPL-" + k for k in f[4].split(",") if k], body=f[6]
            )


def review_fails(raw, kmap):
    """3.2: per kind, distinct (issue, FAILed head) pairs from verdicts that name the head ('FAIL <sha>')."""
    heads, any_fail, seen = (
        collections.defaultdict(collections.Counter),
        collections.defaultdict(set),
        set(),
    )
    for m in fail_rows(raw):
        kinds = {kmap[k] for k in m["keys"] if k in kmap}
        if len(kinds) != 1 or not re.search(r"\bFAIL\b", m["body"][:600]):
            continue
        kd = kinds.pop()
        any_fail[kd].add(m["keys"][0])
        h = re.search(r"\bFAIL\b\W{0,3}([0-9a-f]{7,40})", m["body"][:400])
        if h and (m["keys"][0], h.group(1)[:7]) not in seen:
            seen.add((m["keys"][0], h.group(1)[:7]))
            heads[kd][m["keys"][0]] += 1
    return {
        kd: dict(
            issues_fail_msg=len(any_fail[kd]),
            issues_fail_head=len(heads[kd]),
            again_on_2nd_head=sum(1 for x in heads[kd].values() if x >= 2),
            max_heads=max(heads[kd].values(), default=0),
        )
        for kd in KINDS
    }


def sample(raw, kmap):
    """3.3: the first W1/B1 finding per (issues, text) of each FAIL message, drawn with seed 11."""
    pool, seen = collections.defaultdict(list), set()
    for m in fail_rows(raw):
        kinds = {kmap[k] for k in m["keys"] if k in kmap}
        if len(kinds) != 1 or not re.search(r"\bFAIL\b", m["body"][:600]):
            continue
        kd = kinds.pop()
        for w in re.finditer(r"\b(?:W1|B1)\b[^A-Za-z]{0,6}", m["body"]):
            text = m["body"][w.start() : w.start() + 260]
            if re.search(
                r"^.{0,40}\b(fixed|done|folded|closed|confirmed|both|and W2|-W\d)",
                text,
                re.I,
            ):
                continue
            sig = (tuple(m["keys"]), text[:60])
            if sig not in seen:
                seen.add(sig)
                issue = next(k for k in m["keys"] if k in kmap)
                pool[kd].append(dict(mid=m["mid"][:8], issue=issue, kind=kd, text=text))
            break
    random.seed(11)
    quota = {
        "complex_coding": 14,
        "specs_and_docs": 14,
        "tests": 10,
        "simple_coding": 6,
        "secret": 6,
        "i18n": 5,
    }
    drawn = {
        kd: random.sample(pool[kd], min(n, len(pool[kd]))) for kd, n in quota.items()
    }
    return (
        {kd: len(v) for kd, v in pool.items()},
        drawn,
        {kd: pool[kd] for kd in ("simple_coding", "i18n")},
    )


def main():
    if len(sys.argv) != 3:
        sys.exit("usage: join.py <raw dir> <window end, ISO UTC>")
    raw, end = sys.argv[1], sys.argv[2]
    spawn_dir = os.environ.get("SPAWN_DIR") or sys.exit(
        "FATAL SPAWN_DIR must be set (the spawn dir with serve.log and briefs/)"
    )
    lanes = lanes_from_log(spawn_dir, end)
    out = dict(
        lanes=len(lanes),
        lanes_by_kind=collections.Counter(r["kind"] for r in lanes),
        lanes_with_issue_line=sum(r["issue_src"] == "line" for r in lanes),
        lanes_with_kind_and_issue_line=sum(
            r["issue_src"] == "line" and r["kind"] != "none" for r in lanes
        ),
    )
    out["vendor_by_kind"] = {
        k: collections.Counter(r["vendor"] for r in lanes if r["kind"] == k)
        for k in KINDS
    }
    sample_map = kind_map(lanes, ("line",))
    out["title_matched"], out["title_ambiguous"] = title_match(lanes, raw)
    kmap = kind_map(lanes)
    out["issues_by_kind"] = collections.Counter(kmap.values())
    commits, pairs, distinct = commits_of(raw), collections.Counter(), 0
    for c in commits:
        ks = {kmap[k] for k in c["cite"] if k in kmap}
        distinct += bool(ks)
        pairs.update(ks)
    out.update(
        commits=len(commits),
        commits_citing_a_lane_issue=distinct,
        commit_kind_pairs=pairs,
    )
    dep, by_key = deploy_times(raw, commits, end), collections.defaultdict(list)
    for i, c in enumerate(commits):
        for k in c["cite"]:
            by_key[k].append(i)
    issues = {
        "SPL-" + f[0]: dict(created=ts(f[1]), status=f[2], src=f[4])
        for f in rows(os.path.join(raw, "issues.txt"), 6)
        if f[0].isdigit()
    }
    own = collections.defaultdict(list)
    for task, t in rows(os.path.join(raw, "owner_msgs.txt"), 2):
        own[task].append(ts(t))
    seg, waits = collections.defaultdict(lambda: collections.defaultdict(list)), []
    for key, kd in kmap.items():
        placed = min(ts(r["ts"]) for r in lanes if r["issue"] == key)
        i, ci = issues.get(key), by_key.get(key)
        prior = (
            sorted(t for t in own.get(i["src"], []) if t <= i["created"]) if i else []
        )
        ask = prior[-1] if prior else None
        if ask:
            seg[kd]["ask->placed"].append(hours(ask, placed))
            seg[kd]["ask->issue"].append(hours(ask, i["created"]))
        if not ci:
            continue
        first, land = (
            min(commits[j]["ad"] for j in ci),
            min(commits[j]["cd"] for j in ci),
        )
        if first >= placed:
            seg[kd]["placed->first_commit"].append(hours(placed, first))
        if land >= placed:
            seg[kd]["placed->landed"].append(hours(placed, land))
        if ask:
            waits.append(
                (round(hours(ask, land), 1), kd, key, round(hours(placed, land), 1))
            )
        tagged = [
            hours(commits[j]["cd"], dep[j])
            for j in ci
            if dep[j] and commits[j]["t"] in ("feat", "fix", "perf", "refactor")
        ]
        if tagged:
            seg[kd]["landed->tagged"].append(min(tagged))
        shipped = [
            dep[j]
            for j in ci
            if dep[j] and commits[j]["t"] in ("feat", "fix", "perf", "refactor")
        ]
        if ask and shipped:
            seg[kd]["ask->deployed"].append(hours(ask, min(shipped)))
    out["lead"] = {
        kd: {
            s: dict(
                n=len(v), med=round(statistics.median(v), 1), p90=round(q(v, 0.9), 1)
            )
            for s, v in d.items()
        }
        for kd, d in seg.items()
        if kd in KINDS
    }
    out["longest_ask_to_landed"] = sorted(waits, reverse=True)[:12]
    out["review_fails"] = review_fails(raw, kmap)
    out["sample_pool"], drawn, every = sample(raw, sample_map)
    out["sample_drawn"] = {
        kd: [
            dict(d, kind_final=kmap.get(d["issue"], "-"), text=d["text"][:160])
            for d in v
        ]
        for kd, v in drawn.items()
    }
    out["sample_every"] = {
        kd: [
            dict(d, kind_final=kmap.get(d["issue"], "-"), text=d["text"][:160])
            for d in v
        ]
        for kd, v in every.items()
    }
    lane_kinds = collections.defaultdict(set)
    for r in lanes:
        if r["issue"]:
            lane_kinds[r["issue"]].add(r["kind"])
    msgs = {d["mid"]: d for v in list(drawn.values()) + list(every.values()) for d in v}
    out["labels"] = []
    for line in open(
        os.path.join(os.path.dirname(os.path.abspath(__file__)), "labels.tsv")
    ):
        mid, label = line.rstrip("\n").split("\t")
        d = msgs[mid]
        out["labels"].append(
            dict(
                mid=mid,
                issue=d["issue"],
                sample_kind=d["kind"],
                first_lane_kind=kmap.get(d["issue"], "-"),
                lane_kinds=sorted(lane_kinds[d["issue"]]),
                label=label,
            )
        )
    print(json.dumps(out, indent=1, default=str))


if __name__ == "__main__":
    main()
