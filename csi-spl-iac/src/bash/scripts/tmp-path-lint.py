#!/usr/bin/env python3
"""Flag a fixed shared /tmp or /var/tmp write in a test file.

A hit is code, not a comment:

  - in an e2e .mjs or a Go _test.go, a quoted string whose whole value is
    /tmp/<name> or /var/tmp/<name>
  - in a .tst.sh, a redirect onto such a path, or an assignment of one,
    including a name that still contains $ (a pid is not a private dir)

A line that calls mktemp, mkdtemp, MkdirTemp, TempDir or tmpdir() is the
per-run dir the gate asks for, and is not a hit. SHOT_DIR and OUT, read
from the environment, have no literal, so they are not hits either.

Ratchet: <repo>/.tmp-path-baseline.txt rows are
  <file>|<literal>|<count>
A hit whose count is above its baseline fails. A missing baseline fails
closed. A baselined hit that is gone does not fail.

Exit 0 clean, 1 findings or a missing baseline, 2 usage.
"""
import re
import sys
from collections import Counter

# A quoted path is a static name: no expansion, no glob, no space.
PATH_EXACT = re.compile(r"^/(?:tmp|var/tmp)/[A-Za-z0-9._/-]+$")
# A redirect or an assignment may still carry a shell expansion.
PATH_WORD = re.compile(r"^/(?:tmp|var/tmp)/\S+$")
REDIR = re.compile(r">>?\s*(/(?:tmp|var/tmp)/\S+)")
ASSIGN = re.compile(
    r"(?:^|[;\s])[A-Za-z_][A-Za-z0-9_]*="
    r"(?:(/(?:tmp|var/tmp)/\S+)|\"(/(?:tmp|var/tmp)/[^\"]*)\"|'(/(?:tmp|var/tmp)/[^']*)')"
)
ALLOW = ("mktemp", "mkdtemp", "MkdirTemp", "TempDir", "tmpdir(")
TRAIL = ");|&,"


def forbidden(token):
    """A fixed shared temp path. The mutation test replaces this return."""
    return token.startswith("/tmp/") or token.startswith("/var/tmp/")


def _strip_trail(token):
    return token.rstrip(TRAIL)


def _kind(path):
    if path.endswith(".tst.sh") or path.endswith(".sh"):
        return "sh"
    return "c"


def _quote_is_write(line, lit):
    if f"={lit}" in line or f"='{lit}'" in line or f'="{lit}"' in line:
        return True
    return re.search(
        r">>?\s*['\"]?" + re.escape(lit) + r"['\"]?(?:\s|$|[);|&])", line
    ) is not None


def _scan_line(kind, line, in_block):
    """Return (hits, still_in_block) for one physical line."""
    quoted = []
    unquoted = []
    i, n = 0, len(line)
    while i < n:
        if in_block:
            end = line.find("*/", i)
            if end < 0:
                return [], True
            in_block = False
            i = end + 2
            continue
        c = line[i]
        if kind == "c" and c == "/" and i + 1 < n and line[i + 1] == "/":
            break
        if kind == "c" and c == "/" and i + 1 < n and line[i + 1] == "*":
            in_block = True
            i += 2
            continue
        if kind == "sh" and c == "#":
            break
        if c in "'\"`":
            q = c
            j = i + 1
            body = []
            while j < n:
                if line[j] == "\\":
                    body.append("\\")
                    j += 2
                    continue
                if line[j] == q:
                    break
                body.append(line[j])
                j += 1
            text = "".join(body)
            if "\\" not in text and j < n and PATH_EXACT.match(text) and forbidden(text):
                quoted.append(text)
            unquoted.append(" ")
            i = j + 1 if j < n else n
            continue
        unquoted.append(c)
        i += 1
    bare = "".join(unquoted)
    if any(mark in bare for mark in ALLOW):
        return [], in_block
    hits = []
    if kind == "c":
        hits.extend(quoted)
    else:
        for lit in quoted:
            if _quote_is_write(line, lit):
                hits.append(lit)
        for rx in (REDIR, ASSIGN):
            for match in rx.finditer(bare):
                token = _strip_trail(next(group for group in match.groups() if group))
                if PATH_WORD.match(token) and forbidden(token) and token not in hits:
                    hits.append(token)
    return hits, in_block


def scan_file(path):
    kind = _kind(path)
    hits = []
    try:
        lines = open(path, encoding="utf-8", errors="replace").read().splitlines()
    except OSError as exc:
        print(f"tmp-path: {path}: {exc}", file=sys.stderr)
        return hits
    in_block = False
    for number, line in enumerate(lines, 1):
        found, in_block = _scan_line(kind, line, in_block)
        for lit in found:
            hits.append((number, lit))
    return hits


def load_baseline(path):
    base = Counter()
    try:
        handle = open(path, encoding="utf-8")
    except OSError:
        return None
    with handle:
        for line in handle:
            row = line.strip()
            if not row or row.startswith("#"):
                continue
            parts = row.split("|")
            if len(parts) != 3:
                print(f"tmp-path: bad baseline row: {row}", file=sys.stderr)
                return None
            try:
                base[(parts[0], parts[1])] = int(parts[2])
            except ValueError:
                print(f"tmp-path: bad baseline count: {row}", file=sys.stderr)
                return None
    return base


def main(argv):
    baseline_path = ".tmp-path-baseline.txt"
    args = argv[1:]
    if args and args[0] == "--baseline":
        if len(args) < 2:
            print("usage: tmp-path-lint.py [--baseline FILE] <file>...", file=sys.stderr)
            return 2
        baseline_path = args[1]
        args = args[2:]
    if not args:
        print("usage: tmp-path-lint.py [--baseline FILE] <file>...", file=sys.stderr)
        return 2
    base = load_baseline(baseline_path)
    if base is None:
        print(
            f"tmp-path: no {baseline_path} -- a scan without a baseline is not this gate",
            file=sys.stderr,
        )
        return 1
    found = []
    for path in args:
        for number, lit in scan_file(path):
            found.append((path, number, lit))
    counts = Counter((path, lit) for path, _number, lit in found)
    bad = 0
    for path, number, lit in found:
        allowed = base.get((path, lit), 0)
        if counts[(path, lit)] > allowed:
            bad += 1
            print(
                f"tmp-path: {path}:{number}: {lit} "
                f"({counts[(path, lit)]} found, {allowed} baselined) "
                "-- use mkdtemp / mktemp -d / t.TempDir / SHOT_DIR"
            )
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
