#!/usr/bin/env python3
"""box-crons-desk-reach.py <orc dir> [manifest] - the box-crons rows whose job
reaches a desk, measured from the code (SPL-4558, spec 069 section 8.3.1).

One line per such row: `<name> <call path>`, e.g.
`issue-close-landed do_spl_issue_close_landed > spl_issue_list_fetch > ...`.
install-box-crons.tst.sh compares the names with the rows marked `desk`.

A row reaches a desk when a call path from its cron script ends in
spl_desk_dir, spl_desk_glob or spl_desk_roots (lib/bash/funcs/
spl-cloud-cnf.func.sh). The edges, over the bash of <orc dir> (tests left out,
comments stripped):
  - a call of a function defined in exactly one file, whose name holds a `_`
    (a local helper such as `say` or `log` is defined in many files and would
    join every script to every other)
  - a do_* action named anywhere but after "run " (`./run -a do_x`,
    `"${FN:-do_x}"`; "Run do_spl_desk_up first" in a message is no call)
  - a helper .sh script the cron script names (topic-status-card.sh)
It is a static over-approximation of what runs: a path may sit behind a
branch a tick never takes. It is narrow on purpose (no edge through a file
that is only sourced, or a script only named in a message), so a hit is a real
call chain a reviewer can follow.
"""

import os
import re
import sys
from collections import deque

TARGETS = {"spl_desk_dir", "spl_desk_glob", "spl_desk_roots"}
FUNC_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*\(\)\s*\{", re.M)
CALL_RE = re.compile(
    r"(?:^|[;&|({`]|\$\(|\bthen|\bdo|\belse|!)\s*(?:[A-Z_]+=\S*\s+)*([a-z_][a-z0-9_]*)\b",
    re.M,
)
ACTION_RE = re.compile(r"(?<![Rr]un )\b(do_[a-z0-9_]+)")
SCRIPT_RE = re.compile(r"([a-z0-9-]+\.sh)\b")


def code(text):
    return "\n".join(re.sub(r"(^|\s)#.*", "", line) for line in text.split("\n"))


def index(orc):
    funcs, defs, scripts = {}, {}, {}
    for d, _, files in os.walk(orc):
        if "/tests" in d or "/node_modules" in d:
            continue
        for f in files:
            if not f.endswith(".sh"):
                continue
            p = os.path.join(d, f)
            scripts.setdefault(f, p)
            with open(p, errors="ignore") as fh:
                t = fh.read()
            ms = list(FUNC_RE.finditer(t))
            for i, m in enumerate(ms):
                end = ms[i + 1].start() if i + 1 < len(ms) else len(t)
                defs.setdefault(m.group(1), set()).add(p)
                funcs[m.group(1)] = funcs.get(m.group(1), "") + code(t[m.end() : end])
    return funcs, defs, scripts


def callees(text, funcs, defs):
    names = CALL_RE.findall(text) + ACTION_RE.findall(text)
    return {
        w
        for w in names
        if w in TARGETS or (w in funcs and "_" in w and len(defs[w]) == 1)
    }


def reach(starts, funcs, defs):
    prev = {s: None for s in starts}
    q = deque(sorted(starts))
    while q:
        u = q.popleft()
        if u in TARGETS:
            path = []
            while u:
                path.append(u)
                u = prev[u]
            return list(reversed(path))
        for v in sorted(callees(funcs.get(u, ""), funcs, defs)):
            if v not in prev:
                prev[v] = u
                q.append(v)
    return None


def main():
    orc = sys.argv[1]
    man = (
        sys.argv[2]
        if len(sys.argv) > 2
        else os.path.join(orc, "cnf/box-crons/box-crons.manifest")
    )
    funcs, defs, scripts = index(orc)
    with open(man) as fh:
        rows = [ln for ln in fh if not re.match(r"\s*(#|$)", ln)]
    for line in rows:
        f = [x.strip() for x in line.split("|")]
        name, script = f[0], f[2]
        with open(os.path.join(orc, script), errors="ignore") as fh:
            t = code(fh.read())
        starts = callees(t, funcs, defs)
        for s in SCRIPT_RE.findall(t):
            if s in scripts and s != os.path.basename(script):
                with open(scripts[s], errors="ignore") as fh:
                    starts |= callees(code(fh.read()), funcs, defs)
        path = reach(starts, funcs, defs)
        if path:
            print(name, " > ".join(path))


if __name__ == "__main__":
    main()
