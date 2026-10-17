#!/usr/bin/env python3
"""The compare of do_check_baseline_growth (SPL-2153).

Usage: baseline-growth.py <tree> <anchor> <head> <file>...
Prints NO-TICKET <file>:<line>: <entry> per changed block of <file> that adds
an entry with no SPL-<n> on its added lines, then one BASELINE_GROWTH summary
line. Exit 0 either way; non-zero only when git fails.
"""

import difflib, re, subprocess, sys

tree, anchor, head, files = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
TICKET = re.compile(r"\bSPL-[0-9]+\b")


def git(*a, ok=False):
    r = subprocess.run(["git", "-C", tree, *a], capture_output=True, text=True)
    if r.returncode and not ok:
        sys.exit(f"git {' '.join(a)}: {r.stderr.strip()}")
    return r.stdout if r.returncode == 0 else None


def show(rev, path):
    s = git("show", f"{rev}:{path}", ok=True)
    return [] if s is None else s.splitlines()


def is_comment(path, line):
    s = line.strip()
    if not s:
        return True
    if path.endswith(".checkov.baseline"):
        return not re.search(r'"[^"]+"', s) or s.startswith(
            ('"failed_checks"', '"findings"', '"check_ids"')
        )
    return s.startswith("#")


def count_key(path, line):
    # <rule>|<path>|<count> baselines: (key, count), else None
    if not path.endswith(".txt"):
        return None
    s = line.split("#", 1)[0].strip()
    try:
        k, n = s.rsplit("|", 1)
        return k, int(n)
    except ValueError:
        return None


bad = 0
for path in files:
    old, new = show(anchor, path), show(head, path)
    if old == new:
        continue
    sm = difflib.SequenceMatcher(None, old, new, autojunk=False)
    gone = [
        old[i].strip()
        for t, i1, i2, _, _ in sm.get_opcodes()
        if t in ("replace", "delete")
        for i in range(i1, i2)
    ]
    pool = {}
    for g in gone:
        pool[g] = pool.get(g, 0) + 1
    oldcount = {}
    for l in old:
        kc = count_key(path, l)
        if kc:
            oldcount[kc[0]] = oldcount.get(kc[0], 0) + kc[1]
    msgs = None
    # adjacent non-equal opcodes form one hunk
    hunks, cur = [], None
    for t, i1, i2, j1, j2 in sm.get_opcodes():
        if t == "equal":
            cur = None
            continue
        if cur is None:
            cur = [j1, j2]
            hunks.append(cur)
        else:
            cur[1] = j2
    for j1, j2 in hunks:
        added = new[j1:j2]
        grown = []
        for l in added:
            if is_comment(path, l):
                continue
            s = l.strip()
            if pool.get(s, 0) > 0:  # a moved line
                pool[s] -= 1
                continue
            kc = count_key(path, l)
            if kc and kc[1] <= oldcount.get(kc[0], 0):  # a count that went down
                continue
            grown.append(s)
        if not grown:
            continue
        if any(TICKET.search(l) for l in added):
            continue
        if path.endswith(".checkov.baseline"):
            if msgs is None:
                msgs = git("log", "--format=%B", f"{anchor}..{head}", "--", path) or ""
            if TICKET.search(msgs):
                continue
        bad += 1
        print(
            f"NO-TICKET {path}:{j1 + 1}: {grown[0]}"
            + (f" (+{len(grown) - 1} more)" if len(grown) > 1 else "")
        )
print(
    f"BASELINE_GROWTH anchor={anchor[:9]} head={git('rev-parse', '--short', head).strip()} files={len(files)} no_ticket={bad}"
)
