#!/usr/bin/env python3
"""The hand-copy check of the public repository (SPL-3541, spec 114
section 9.4, guard 2): a private workspace's doc text pasted into a md file
by hand carries no generated-from stamp, so the map check cannot see it.
This one compares every tracked md file against an index of the private
workspaces' doc ids, titles and section headings, held OUTSIDE the repo.

The index holds HASHES only: sha256 of the normalised text, first 16 hex
(64 bits), one per line, so no private title is in the index, a log, a
FAIL line or a commit. Text counts only at 3+ words and 16+ characters
(normalised), so a common heading ("Overview", "Open questions") never
matches; a doc id (a uuid) always counts. A line matches when the whole
normalised line equals an entry: a title quoted inside a longer sentence
is not caught.

Verbs:
  build <records.jsonl> <out> <public tree>
      records: one JSON object per line, {"kind": "id"|"text", "value": ..}
      (do_spl_private_doc_index writes them); out is written mode 600. An
      entry whose text a tracked md line of <public tree> already holds is
      dropped: text already public is no leak, and the fleet's template
      headings ("Files you must not touch") would else fail every brief.
  check <tree> <index> <cnf>
      FAIL <file>:<line> per match, never the text; exit 1 on any. No index
      file: cnf docs.private_index_required true -> FAIL (exit 1), else a
      WARN that the check was NOT RUN (exit 0). An unreadable cnf, a bad
      index, or an index file tracked in the tree -> FAIL.
  measure <tree> [<older tree>]
      the false-positive count on this tree: the headings of every second
      md file as a synthetic index, the other half checked; with <older
      tree>, the index drops what that tree held (an index built then).
"""

import hashlib
import importlib.util
import json
import os
import re
import subprocess
import sys

HEADER = "# qto-private-index v1"
UUID = re.compile(r"\b[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\b")
HEX = re.compile(r"^[0-9a-f]{16}$")
NUMBER = re.compile(r"^\d+(?:\.\d+)*\.?\s+")
MARKUP = re.compile(r"[*_`~>#|\[\]]+")
MIN_WORDS, MIN_CHARS = 3, 16


def norm(text):
    """The text a title and a md line share: no heading marks, no outline
    number, no emphasis or link brackets, lower case, single spaces."""
    t = text.strip().lstrip("#").strip()
    t = NUMBER.sub("", t)
    t = MARKUP.sub(" ", t)
    return " ".join(t.lower().split())


def counts(t):
    return len(t.split()) >= MIN_WORDS and len(t) >= MIN_CHARS


def h(kind, value):
    return hashlib.sha256(f"{kind}\0{value}".encode("utf-8")).hexdigest()[:16]


def line_hashes(line):
    """The entries one md line can match: its whole text, each uuid in it."""
    out = [h("i", u) for u in UUID.findall(line.lower())]
    t = norm(line)
    if counts(t):
        out.append(h("t", t))
    return out


def drift_module():
    here = os.path.dirname(os.path.abspath(__file__))
    spec = importlib.util.spec_from_file_location(
        "qdd", os.path.join(here, "check-qto-doc-drift.py")
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def public_hashes(tree):
    """Every entry a tracked md line of the tree already matches."""
    got = set()
    for rel in drift_module().md_files(tree):
        try:
            with open(
                os.path.join(tree, rel), encoding="utf-8", errors="replace"
            ) as fh:
                for line in fh:
                    got.update(line_hashes(line))
        except OSError:
            continue
    return got


def build(records, out, tree):
    entries = set()
    with open(records, encoding="utf-8") as fh:
        for line in fh:
            if not line.strip():
                continue
            r = json.loads(line)
            v = str(r.get("value") or "")
            if r.get("kind") == "id":
                for u in UUID.findall(v.lower()):
                    entries.add(h("i", u))
            else:
                t = norm(v)
                if counts(t):
                    entries.add(h("t", t))
    public = entries & public_hashes(tree)
    entries -= public
    old = os.umask(0o077)
    try:
        with open(out, "w", encoding="utf-8") as fh:
            fh.write(HEADER + " (SPL-3541): hashes only, never commit\n")
            fh.writelines(e + "\n" for e in sorted(entries))
    finally:
        os.umask(old)
    os.chmod(out, 0o600)
    print(
        f"OK private doc index: {len(entries)} entries written"
        f" ({len(public)} dropped: already in the public tree)"
    )
    return 0


def read_index(path):
    with open(path, encoding="utf-8") as fh:
        lines = fh.read().splitlines()
    if not lines or not lines[0].startswith(HEADER):
        return None
    got = {x.strip() for x in lines[1:] if x.strip()}
    return got if got and all(HEX.match(x) for x in got) else None


def required(cnf):
    """cnf docs.private_index_required: True, False, or None (unreadable)."""
    try:
        import yaml

        with open(cnf, encoding="utf-8") as fh:
            env = (yaml.safe_load(fh) or {}).get("env") or {}
        return (env.get("docs") or {}).get("private_index_required") is True
    except ImportError:
        try:
            v = subprocess.run(
                ["yq", "-r", ".env.docs.private_index_required // false", cnf],
                capture_output=True,
                check=True,
                text=True,
            ).stdout.strip()
        except (OSError, subprocess.CalledProcessError):
            return None
        return v == "true"
    except (OSError, ValueError, AttributeError):
        return None


def tracked_index(tree, index):
    try:
        rel = os.path.relpath(os.path.abspath(index), os.path.abspath(tree))
        out = subprocess.run(
            ["git", "-C", tree, "ls-files", "--", rel, "*qto-private-index*"],
            capture_output=True,
            check=True,
            text=True,
        ).stdout
    except (OSError, ValueError, subprocess.CalledProcessError):
        return ""
    return out.strip()


def check(tree, index, cnf):
    req = required(cnf)
    if req is None:
        print(f"FAIL {cnf}: cnf docs.private_index_required is not readable")
        return 1
    leaked = tracked_index(tree, index) if index else ""
    if leaked:
        print(
            f"FAIL {leaked.splitlines()[0]}: a private doc index is tracked: git rm --cached it, never commit it"
        )
        return 1
    if not index or not os.path.isfile(index):
        steps = (
            'seed it from a seated desk (cd csi-spl-orc && ENV=prd PRIVATE_INDEX_TENANTS="<private ws ...>" PRIVATE_INDEX_SEAT=<seat> DRY_RUN=0'
            " ./run -a do_spl_private_doc_index), then set the repo secret QTO_PRIVATE_INDEX_B64"
            " (base64 of that file) for CI"
        )
        if req:
            print(
                f"FAIL no private doc index ({index or 'QTO_PRIVATE_INDEX unset'}) and cnf docs.private_index_required is true: {steps}"
            )
            return 1
        print(f"WARN no private index: hand-copy check NOT RUN ({steps})")
        return 0
    entries = read_index(index)
    if entries is None:
        print(
            f"FAIL {index}: not a private doc index ({HEADER}, then 16-hex hashes): rebuild it"
        )
        return 1
    qdd, rc, files = drift_module(), 0, 0
    for rel in qdd.md_files(tree):
        files += 1
        try:
            with open(
                os.path.join(tree, rel), encoding="utf-8", errors="replace"
            ) as fh:
                for n, line in enumerate(fh, 1):
                    if entries.intersection(line_hashes(line)):
                        print(
                            f"FAIL {rel}:{n}: matches a private workspace doc's id, title or heading (index entry): remove it, it never goes to the public repository"
                        )
                        rc = 1
        except OSError:
            continue
    if rc == 0:
        print(
            f"OK private doc index: {files} md files, {len(entries)} entries, no match"
        )
    return rc


def measure(tree, older=None):
    qdd = drift_module()
    files = sorted(qdd.md_files(tree))
    half_a, half_b = files[0::2], files[1::2]
    index, seen = set(), 0
    for rel in half_a:
        with open(os.path.join(tree, rel), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                if line.startswith("#"):
                    seen += 1
                    t = norm(line)
                    if counts(t):
                        index.add(h("t", t))
    dropped = 0
    if older:
        before = len(index)
        index -= public_hashes(older)
        dropped = before - len(index)
    hits, hit_files, lines = 0, set(), 0
    for rel in half_b:
        with open(os.path.join(tree, rel), encoding="utf-8", errors="replace") as fh:
            for line in fh:
                lines += 1
                t = norm(line)
                if counts(t) and h("t", t) in index:
                    hits += 1
                    hit_files.add(rel)
    print(
        f"measure: synthetic index = {len(index)} headings over the floor (of {seen}; {dropped} dropped as"
        f" already public{' in ' + older if older else ''}) from {len(half_a)} md files;"
        f" checked {len(half_b)} md files ({lines} lines): {hits} matching lines in {len(hit_files)} files"
    )
    return 0


if __name__ == "__main__":
    a = sys.argv[1:]
    if len(a) == 4 and a[0] == "build":
        sys.exit(build(a[1], a[2], a[3]))
    if len(a) == 4 and a[0] == "check":
        sys.exit(check(a[1], a[2], a[3]))
    if len(a) in (2, 3) and a[0] == "measure":
        sys.exit(measure(*a[1:]))
    sys.exit(__doc__)
