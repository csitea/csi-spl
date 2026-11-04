#!/usr/bin/env python3
"""issue-close-landed.py: which open issues a commit landed on master closes
(owner HUM-10, t1 dee4081d msg ea519baa: "Done should be the automatic
target"). Reads only: the open-issue list document, the ledger and local git.

  issue-close-landed.py LIST GIT_DIR RANGE LEDGER [EVIDENCE] [--moves MOVED]
                       [--dst TENANT=LIST ...]
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
  - any commit but a revert with a "Closes: SPL-12" trailer (comma list
    allowed), whatever its type: the trailer is the author's explicit word,
    so a docs(...) or chore(...) commit carrying it closes
  A bare mention in the body, a "Refs: SPL-12" trailer, the key in the scope
  of a docs / test / chore subject and a revert (its scope or its trailer)
  never close.

Prints one TSV row per key the range names, its commits newest first:
  <key>\\tclose\\t<sha>[,<older sha>...]\\t<subject of the newest>
  <key>\\tnoop\\t<shas>\\talready done or diss (or no such issue), or in qas:
                        a review a human asked for (spec 135 Q7) closes it,
                        and these shas never act on it again
  <key>\\tskip\\t<shas>\\t<why>
A close or noop row's shas all go to the ledger once acted on.

Moved issue keys (spec 169 W4, row T7g; owner Q2 = A, msg 333aea7b: 30 days of
redirect and old issue key map, then nothing):
MOVED   the `spool issue moved` answer of this workspace (old_key, dst,
        new_key, expires_at, live), or "-" when it could not be read
TENANT=LIST  the open-issue list of a workspace a live row moved keys to
  - a key in LIST closes as above, whatever the map says
  - a key not in LIST that a live row maps closes its new key in that row's
    workspace, judged on the --dst list of it: the row carries a fifth
    column, the tenant. The reused-key check does not apply (the new issue
    was created by the move, after the commits that cite the old key)
  - a key an expired row maps is a noop: an old key then closes nothing
  - a map that was not read ("-"), or a live row whose workspace has no
    --dst list, makes a "retry" row for each key not in LIST: never a noop on
    a guess, never in the ledger; the run fails, so its cursor stays. A
    retry row for a missing --dst list names that tenant in column five, so
    the caller fetches that list and plans again
  With no --moves at all no key is mapped (the old rule).
"""

import json
import re
import subprocess
import sys
from datetime import datetime

TYPES = ("fix", "feat", "perf", "refactor")
SUBJECT = re.compile(r"^(?P<type>[a-z]+)\((?P<scope>[^)]*)\)!?:")
REVERT = re.compile(r"^(Revert\b|revert(\([^)]*\))?!?:)")
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
    if REVERT.match(subject):
        return keys
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


def verdict(k, cs, issue, done, moved=False):
    """One key's row from the commits naming it (newest first). A moved key's
    issue was created by the move, so its created_at says nothing."""
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
    if (issue.get("status") or "") == "qas":
        return (
            k,
            "noop",
            ",".join(c[0] for c in fresh),
            "in qas: a review a human asked for closes it, not a commit (spec 135 Q7)",
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
    created = 0 if moved else iso_epoch(issue.get("created_at"))
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


def moved_keys(path):
    """old key -> its moved row, from the `spool issue moved` answer; None when
    the map was not read ("-", no file, not JSON, no moved list)."""
    if path == "-":
        return None
    try:
        text = open(path, encoding="utf-8").read().strip()
    except OSError:
        return None
    doc = None
    for cand in (text, text.splitlines()[-1] if text else ""):
        try:
            doc = json.loads(cand)
            break
        except ValueError:
            continue
    res = doc.get("result", doc) if isinstance(doc, dict) else None
    rows = res.get("moved") if isinstance(res, dict) else None
    if not isinstance(rows, list):
        return None
    return {
        m["old_key"]: m
        for m in rows
        if isinstance(m, dict)
        and m.get("old_key")
        and m.get("new_key")
        and m.get("dst")
    }


def moved_verdict(k, cs, moves, dsts, done):
    """The row of a key that is not open here: mapped, expired or a retry."""
    shas = ",".join(c[0] for c in cs)
    if moves is None:
        return (
            k,
            "retry",
            shas,
            "the moved issue key map was not read: not judged on a guess, the next run retries",
        )
    m = moves.get(k)
    if m is None:
        return None
    new, dst = m["new_key"], m["dst"]
    if m.get("live") is not True:
        return (
            k,
            "noop",
            shas,
            "moved to %s in %s; its redirect expired %s: an old key closes nothing"
            % (new, dst, m.get("expires_at") or "?"),
        )
    if dst not in dsts:
        return (
            k,
            "retry",
            shas,
            "moved to %s: the open list of %s was not read" % (new, dst),
            dst,
        )
    row = verdict(new, cs, dsts[dst].get(new), done, moved=True)
    return row[:3] + ("%s (moved from %s)" % (row[3], k), dst)


def plan(issues, done, rows, extra=None, moves=None, dsts=None, mapped=False):
    named = {}
    for sha, ct, subject, closes in rows:
        for k in commit_keys(subject, closes):
            named.setdefault(k, []).append((sha, ct, subject))
    for k, cs in (extra or {}).items():
        have = {c[0] for c in named.get(k, [])}
        named.setdefault(k, []).extend(c for c in cs if c[0] not in have)
    out = []
    for k, cs in named.items():
        row = None
        if mapped and k not in issues:
            row = moved_verdict(k, cs, moves, dsts or {}, done)
        out.append(row or verdict(k, cs, issues.get(k), done))
    return out


def options(argv):
    """argv without --moves / --dst, the map path (None: not given) and the
    tenant -> list path of each --dst."""
    rest, moves, dsts, i = [], None, {}, 0
    while i < len(argv):
        a = argv[i]
        if a in ("--moves", "--dst") and i + 1 < len(argv):
            if a == "--moves":
                moves = argv[i + 1]
            else:
                t, _, p = argv[i + 1].partition("=")
                dsts[t] = p
            i += 2
            continue
        rest.append(a)
        i += 1
    return rest, moves, dsts


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
    argv, mpath, dpaths = options(argv)
    if len(argv) not in (5, 6):
        print(__doc__, file=sys.stderr)
        return 2
    issues = open_issues(argv[1])
    done = ledger_pairs(argv[4])
    tip = argv[3].split("..")[-1]
    extra, bad = cited(argv[2], tip, argv[5] if len(argv) == 6 else "")
    moves = moved_keys(mpath) if mpath is not None else None
    dsts = {t: open_issues(p) for t, p in dpaths.items()}
    rows = plan(
        issues, done, commits(argv[2], argv[3]), extra, moves, dsts, mpath is not None
    )
    for row in rows + bad:
        print("\t".join(x.replace("\t", " ") for x in row))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
