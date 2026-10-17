#!/usr/bin/env python3
"""The map check of do_check_qto_doc_drift (SPL-2164): rules 1-5 of
check-qto-doc-drift.func.sh. Usage: check-qto-doc-drift.py <tree> <map> <known>.
Prints one FAIL / WARN line per finding, then OK; exit 1 on any FAIL."""

import os
import re
import sys

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
STAMP = re.compile(r"^> Generated from qto doc `([^`]*)`")
SKIP = {".git", "node_modules", "tpl-gen", ".output", ".nuxt"}


def bad_path(rel):
    p = f"/{rel}/"
    return (
        not rel.endswith(".md")
        or rel.startswith("/")
        or "/../" in p
        or "/./" in p
        or "//" in rel
    )


def read_map(mapf, fail):
    by_path, by_id, rows = {}, {}, 0
    with open(mapf, encoding="utf-8") as fh:
        for n, line in enumerate(fh, 1):
            line = line.rstrip("\n")
            if not line or line.startswith("#"):
                continue
            rows += 1
            f = line.split("\t")
            doc, rel, fs = (f + ["", "", ""])[:3]
            where = f"{os.path.basename(mapf)}:{n}"
            if (
                len(f) > 3
                or not UUID.match(doc)
                or fs not in ("", "workspace", "repo")
                or bad_path(rel)
            ):
                fail(
                    rel or where,
                    f"{where}: a row is <uuid> TAB <repo-relative .md> [TAB workspace|repo], got {line!r}",
                )
                continue
            if doc in by_id:
                fail(rel, f"{where}: qto doc {doc} is mapped twice (also {by_id[doc]})")
            if rel in by_path:
                fail(
                    rel,
                    f"{where}: the path is mapped twice (also qto doc {by_path[rel]})",
                )
            by_id[doc], by_path[rel] = rel, doc
    return by_path, rows


def stamped_files(tree):
    out = {}
    for root, dirs, files in os.walk(tree):
        dirs[:] = [d for d in dirs if d not in SKIP]
        for name in files:
            if not name.endswith(".md"):
                continue
            p = os.path.join(root, name)
            try:
                with open(p, encoding="utf-8", errors="replace") as fh:
                    ids = [m.group(1) for m in map(STAMP.match, fh) if m]
            except OSError:
                continue
            if ids:
                out[os.path.relpath(p, tree)] = ids
    return out


def read_known(knownf):
    known = {}
    if os.path.exists(knownf):
        with open(knownf, encoding="utf-8") as fh:
            for line in fh:
                line = line.rstrip("\n")
                if line and not line.startswith("#"):
                    p, _, why = line.partition("\t")
                    known[p] = why
    return known


def main(tree, mapf, knownf):
    bad = {}

    def fail(p, why):
        bad.setdefault(p, []).append(why)

    by_path, rows = read_map(mapf, fail)
    stamped = stamped_files(tree)
    for rel, doc in by_path.items():
        ids = stamped.get(rel)
        if not os.path.isfile(os.path.join(tree, rel)):
            fail(rel, f"mapped to qto doc {doc}, but the file does not exist")
        elif not ids:
            fail(
                rel,
                f"mapped to qto doc {doc}, but it has no generated-from line: its export never landed",
            )
        elif len(ids) > 1:
            fail(
                rel,
                f"{len(ids)} generated-from lines ({', '.join(ids)}); an export writes one",
            )
        elif ids[0] != doc:
            fail(rel, f"its generated-from line names qto doc {ids[0]}, the map {doc}")
    for rel, ids in sorted(stamped.items()):
        if rel not in by_path:
            fail(
                rel,
                f"says generated from qto doc {ids[0]}, but no map row names it: add the row or drop the line",
            )
    known = read_known(knownf)
    rc = 0
    for p in sorted(bad):
        for why in bad[p]:
            if p in known:
                print(f"WARN {p}: {why} (known drift: {known[p]})")
            else:
                print(f"FAIL {p}: {why}")
                rc = 1
    for p in sorted(set(known) - set(bad)):
        print(
            f"FAIL {p}: listed in {os.path.basename(knownf)}, but it no longer drifts: remove its line"
        )
        rc = 1
    if rc == 0:
        n = len(set(known) & set(bad))
        print(
            f"OK qto doc map: {rows} rows, {len(stamped)} exported md files, each stamp names its row"
            + (f" ({n} known drift)" if n else "")
        )
    return rc


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit("usage: check-qto-doc-drift.py <tree> <map> <known>")
    sys.exit(main(*sys.argv[1:]))
