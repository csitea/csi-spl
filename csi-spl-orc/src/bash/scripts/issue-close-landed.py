#!/usr/bin/env python3
"""issue-close-landed.py: which open issues a commit landed on master closes
(owner HUM-10, t1 dee4081d msg ea519baa: "Done should be the automatic
target"). Reads only: the open-issue list document, the ledger and local git.

  issue-close-landed.py LIST GIT_DIR RANGE LEDGER [EVIDENCE]
  issue-close-landed.py --keys GIT_DIR SHA...   (the exit gate: the keys those
                                                commits close, one per line)

LIST    the do_spl_issue_list JSON line(s) of the OPEN issues (every status
        but done and diss); a key that is not in it is already closed or
        does not exist: a no-op
RANGE   the git revision range read, e.g. <cursor>..origin/master, or a bare
        ref for the whole history (the back-fill)
LEDGER  TSV "<key>\\t<sha>" of every (issue, commit) pair the rule has already
        acted on; a pair in it never acts again, so an issue the owner
        reopened is never closed again by the same sha (it may be by a newer)

EVIDENCE (optional) TSV "<key>\\t<sha>[,<sha>...]\\t<why>": a landing a review
        cited although no commit names the key by the rule (the back-fill of
        a triage); each sha must be an ancestor of the range's tip, and the
        reused-key check does not apply (an issue imported after its work)

Which commits count:
  - a fix / feat / perf / refactor commit whose subject scope carries the key,
    "fix(orc, SPL-12): ..." (a "!" before the colon is allowed)
  - any commit with a "Closes: SPL-12" trailer (comma list allowed), whatever
    its type: the trailer is the author's explicit word, so a docs(...) or
    chore(...) commit carrying it closes
  A bare mention in the body, a "Refs: SPL-12" trailer, the key in the scope
  of a docs / test / chore subject and a revert never close.

Prints one TSV row per key the range names, its commits newest first:
  <key>\\tclose\\t<sha>[,<older sha>...]\\t<subject of the newest>
  <key>\\tnoop\\t<shas>\\talready done or diss (or no such issue)
  <key>\\tskip\\t<shas>\\t<why>
A close or noop row's shas all go to the ledger once acted on.
"""

import json
import re
import subprocess
import sys
from datetime import datetime

TYPES = ("fix", "feat", "perf", "refactor")
SUBJECT = re.compile(r"^(?P<type>[a-z]+)\((?P<scope>[^)]*)\)!?:")
KEY = re.compile(r"\b([A-Z][A-Z0-9]{0,9}-[1-9][0-9]*)\b")
SEP = "\x1f"
END = "\x1e"


def open_issues(path):
    """key -> issue, from the last JSON line of the list document."""
    text = open(path, encoding="utf-8").read().strip()
    if not text:
        return {}
    doc = json.loads(text.splitlines()[-1])
    res = doc.get("result", doc)
    rows = res.get("issues") or [] if isinstance(res, dict) else res or []
    return {i["key"]: i for i in rows if isinstance(i, dict) and i.get("key")}


def ledger_pairs(path):
    pairs = set()
    try:
        with open(path, encoding="utf-8") as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 2 and p[0] and p[1]:
                    pairs.add((p[0], p[1]))
    except FileNotFoundError:
        pass
    return pairs


def commit_keys(subject, closes):
    """The keys one commit closes by the rule, in order, no repeats."""
    keys = []
    m = SUBJECT.match(subject)
    if m and m.group("type") in TYPES:
        keys += KEY.findall(m.group("scope"))
    for v in closes:
        keys += KEY.findall(v)
    seen = set()
    return [k for k in keys if not (k in seen or seen.add(k))]


def commits(gdir, rng):
    """(sha, unix time, subject, [Closes values]) newest first, no merges."""
    fmt = (
        SEP.join(["%H", "%ct", "%s", "%(trailers:key=Closes,valueonly,separator=%x2C)"])
        + END
    )
    out = subprocess.run(
        ["git", "-C", gdir, "log", "--no-merges", "--format=" + fmt, rng],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    for rec in out.split(END):
        rec = rec.strip("\n")
        if not rec:
            continue
        sha, ct, subject, closes = (rec.split(SEP) + ["", "", "", ""])[:4]
        yield sha, int(ct or 0), subject, [c for c in closes.split(",") if c.strip()]


def iso_epoch(s):
    """An RFC 3339 created_at as unix seconds, 0 when it does not parse."""
    try:
        return int(datetime.fromisoformat((s or "").replace("Z", "+00:00")).timestamp())
    except ValueError:
        return 0


def verdict(k, cs, issue, done):
    """One key's row from the commits naming it (newest first)."""
    shas = ",".join(c[0] for c in cs)
    if issue is None:
        return (k, "noop", shas, "already done or diss (or no such issue)")
    fresh = [c for c in cs if (k, c[0]) not in done]
    if not fresh:
        return (
            k,
            "skip",
            shas,
            "every commit naming it acted once already (reopened by hand: stays open)",
        )
    kind = issue.get("kind") or "issue"
    if kind in ("epic", "feature"):
        return (
            k,
            "skip",
            shas,
            "%s %s closes with its children, not by one commit"
            % ("an" if kind == "epic" else "a", kind),
        )
    created = iso_epoch(issue.get("created_at"))
    fresh = [c for c in fresh if not created or c[1] < 0 or c[1] >= created]
    if not fresh:
        return (
            k,
            "skip",
            shas,
            "every commit naming it is older than the issue (a reused key)",
        )
    return (k, "close", ",".join(c[0] for c in fresh), fresh[0][2])


def cited(gdir, tip, path):
    """key -> [(sha, -1, "cited: <why>")] from the evidence file; ct -1 marks a
    citation. A sha that is not an ancestor of tip makes a skip row instead."""
    out, bad = {}, []
    if not path:
        return out, bad
    with open(path, encoding="utf-8") as f:
        for line in f:
            p = line.rstrip("\n").split("\t")
            if len(p) < 2 or not KEY.fullmatch(p[0].strip()):
                continue
            key, why = (
                p[0].strip(),
                (p[2].strip() if len(p) > 2 else "") or "cited by a review",
            )
            for short in [x.strip() for x in p[1].split(",") if x.strip()]:
                r = subprocess.run(
                    [
                        "git",
                        "-C",
                        gdir,
                        "rev-parse",
                        "-q",
                        "--verify",
                        short + "^{commit}",
                    ],
                    capture_output=True,
                    text=True,
                )
                sha = r.stdout.strip()
                anc = (
                    r.returncode == 0
                    and subprocess.run(
                        ["git", "-C", gdir, "merge-base", "--is-ancestor", sha, tip]
                    ).returncode
                    == 0
                )
                if not anc:
                    bad.append(
                        (key, "skip", short, "the cited sha is not on the trunk read")
                    )
                    continue
                out.setdefault(key, []).append((sha, -1, "cited: " + why))
    return out, bad


def plan(issues, done, rows, extra=None):
    named = {}
    for sha, ct, subject, closes in rows:
        for k in commit_keys(subject, closes):
            named.setdefault(k, []).append((sha, ct, subject))
    for k, cs in (extra or {}).items():
        have = {c[0] for c in named.get(k, [])}
        named.setdefault(k, []).extend(c for c in cs if c[0] not in have)
    return [verdict(k, cs, issues.get(k), done) for k, cs in named.items()]


def keys_of(gdir, shas):
    """The keys the given commits close by the rule, in order, no repeats."""
    keys = []
    for sha in shas:
        fmt = "%s" + SEP + "%(trailers:key=Closes,valueonly,separator=%x2C)"
        out = subprocess.run(
            ["git", "-C", gdir, "log", "-1", "--format=" + fmt, sha],
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip("\n")
        subject, _, closes = out.partition(SEP)
        keys += [
            k
            for k in commit_keys(subject, [c for c in closes.split(",") if c.strip()])
            if k not in keys
        ]
    return keys


def main(argv):
    if len(argv) >= 3 and argv[1] == "--keys":
        for k in keys_of(argv[2], argv[3:]):
            print(k)
        return 0
    if len(argv) not in (5, 6):
        print(__doc__, file=sys.stderr)
        return 2
    issues = open_issues(argv[1])
    done = ledger_pairs(argv[4])
    tip = argv[3].split("..")[-1]
    extra, bad = cited(argv[2], tip, argv[5] if len(argv) == 6 else "")
    for row in plan(issues, done, commits(argv[2], argv[3]), extra) + bad:
        print("\t".join(x.replace("\t", " ") for x in row))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
