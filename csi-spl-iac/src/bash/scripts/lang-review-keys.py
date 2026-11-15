#!/usr/bin/env python3
"""The locale keys each commit adds or changes (SPL-5551, wui-lang-review).

Usage: lang-review-keys.py <tree> <locales-dir> <sha>...

For every <sha>, each changed <locales-dir>/*.json is compared at the commit
and at its first parent, key by key (nested keys joined with '.', list items
by index, empty objects and lists hold none). A leaf key that is new, or whose
value or JSON type changed, prints one line:

    <sha><TAB><file><TAB><key>

Removed keys print nothing. A file that is not JSON at the commit prints one
line with the key '(not valid JSON)'; a parent that is not JSON reads as
empty. One process for the whole range: blobs come from one
`git cat-file --batch`, so a 19-locale commit costs milliseconds, not one jq
per file and side.
"""

import json
import subprocess
import sys


_MISSING = object()


def leaves(obj, pre):
    """every leaf key under obj (nested keys joined with '.', list items by
    index; an empty object or list has none)"""
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from leaves(v, f"{pre}.{k}" if pre else str(k))
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from leaves(v, f"{pre}.{i}" if pre else str(i))
    else:
        yield pre


def added_or_changed(old, new, pre=""):
    """the leaf keys of new that old lacks or holds with another value; an
    equal subtree is skipped whole (one C-level ==), so a 3700-key file with
    one new key walks one branch, not every key"""
    if old is not _MISSING and type(old) is type(new) and old == new:
        return
    if isinstance(new, dict) and isinstance(old, dict):
        for k, v in new.items():
            yield from added_or_changed(
                old.get(k, _MISSING), v, f"{pre}.{k}" if pre else str(k)
            )
    elif isinstance(new, list) and isinstance(old, list):
        for i, v in enumerate(new):
            yield from added_or_changed(
                old[i] if i < len(old) else _MISSING, v, f"{pre}.{i}" if pre else str(i)
            )
    else:
        yield from leaves(new, pre)


class Blobs:
    def __init__(self, tree):
        self.p = subprocess.Popen(
            ["git", "-C", tree, "cat-file", "--batch"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
        )

    def get(self, rev):
        self.p.stdin.write((rev + "\n").encode())
        self.p.stdin.flush()
        head = self.p.stdout.readline().decode().split()
        if len(head) < 3 or head[1] != "blob":
            return None
        data = self.p.stdout.read(int(head[2]))
        self.p.stdout.read(1)
        return data


def parse(data):
    """-> the parsed blob, {} for a missing one, _MISSING for one that is not JSON"""
    if data is None:
        return {}
    try:
        return json.loads(data)
    except ValueError:
        return _MISSING


def changed_files(tree, sha, locales):
    out = subprocess.run(
        [
            "git",
            "-C",
            tree,
            "diff-tree",
            "--no-commit-id",
            "--name-only",
            "-r",
            "--no-renames",
            sha,
            "--",
            locales,
        ],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [
        f
        for f in out.splitlines()
        if f.startswith(locales + "/") and f.endswith(".json")
    ]


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    tree, locales, shas = argv[0], argv[1].rstrip("/"), argv[2:]
    blobs = Blobs(tree)
    for sha in shas:
        for f in changed_files(tree, sha, locales):
            new = parse(blobs.get(f"{sha}:{f}"))
            if new is _MISSING:
                print(f"{sha}\t{f}\t(not valid JSON)")
                continue
            old = parse(blobs.get(f"{sha}^:{f}"))
            for k in added_or_changed({} if old is _MISSING else old, new):
                print(f"{sha}\t{f}\t{k}")
    blobs.p.stdin.close()
    blobs.p.wait()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
