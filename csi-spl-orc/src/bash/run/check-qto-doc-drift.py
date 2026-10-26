#!/usr/bin/env python3
"""The map check of do_check_qto_doc_drift (SPL-2164): rules 1-6 of
check-qto-doc-drift.func.sh. Usage:
check-qto-doc-drift.py <tree> <map> <known> [<cnf>], <cnf> default
<tree>/csi-spl-cnf/csi-spl/all.env.yaml (its docs.repo_export_tenants).
Prints one FAIL / WARN line per finding, then OK; exit 1 on any FAIL."""

import os
import re
import subprocess
import sys

UUID = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
STAMP = re.compile(
    r"^> Generated from qto doc `([^`]*)`(?:; edit it there\. Workspace `([^`]*)`\.)?"
)
WS = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
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


def allowed_workspaces(cnf):
    """cnf docs.repo_export_tenants (spec 114 section 9.4.2), or None when it
    cannot be read: the caller FAILs then, never passes (SPL-3541)."""
    try:
        import yaml

        with open(cnf, encoding="utf-8") as fh:
            got = (((yaml.safe_load(fh) or {}).get("env") or {}).get("docs") or {}).get(
                "repo_export_tenants"
            )
    except ImportError:
        try:
            got = subprocess.run(
                ["yq", "-r", ".env.docs.repo_export_tenants // [] | .[]", cnf],
                capture_output=True,
                check=True,
                text=True,
            ).stdout.split()
        except (OSError, subprocess.CalledProcessError):
            return None
    except (OSError, ValueError, AttributeError):
        return None
    if not isinstance(got, list) or not got:
        return None
    return {str(w) for w in got}


def read_map(mapf, fail, hard):
    """hard(path, why): a finding the known-drift list never downgrades."""
    by_path, by_id, ws_of, rows = {}, {}, {}, 0
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
                or not WS.match(fs)
                or fs == "workspace"
                or bad_path(rel)
            ):
                hard(
                    rel or where,
                    f"{where}: a row is <uuid> TAB <repo-relative .md> TAB <repo|workspace id>, got {line!r}",
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
            ws_of[rel] = "system" if fs == "repo" else fs
    return by_path, ws_of, rows


def md_files(tree):
    """The .md files to read: in a git checkout the TRACKED ones only, so a
    git-ignored generated file (a terraform modules/README.md, a docs-public
    copy) never fails a push it is not part of (SPL-2307). A tree that is
    not a git checkout has nothing ignored: every file is walked."""
    try:
        out = subprocess.run(
            ["git", "-C", tree, "ls-files", "-z", "--", "*.md"],
            capture_output=True,
            check=True,
        ).stdout
    except (OSError, subprocess.CalledProcessError):
        for root, dirs, files in os.walk(tree):
            dirs[:] = [d for d in dirs if d not in SKIP]
            for name in files:
                if name.endswith(".md"):
                    yield os.path.relpath(os.path.join(root, name), tree)
        return
    for rel in out.decode("utf-8", "surrogateescape").split("\0"):
        if rel.endswith(".md") and not SKIP.intersection(rel.split("/")[:-1]):
            yield rel


def stamped_files(tree):
    out = {}
    for rel in md_files(tree):
        try:
            with open(
                os.path.join(tree, rel), encoding="utf-8", errors="replace"
            ) as fh:
                ids = [m.groups() for m in map(STAMP.match, fh) if m]
        except OSError:
            continue
        if ids:
            out[rel] = ids
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


def main(tree, mapf, knownf, cnf=None):
    bad, worst = {}, {}

    def fail(p, why):
        bad.setdefault(p, []).append(why)

    def hard(p, why):
        worst.setdefault(p, []).append(why)

    cnf = cnf or os.path.join(tree, "csi-spl-cnf", "csi-spl", "all.env.yaml")
    allowed = allowed_workspaces(cnf)
    if allowed is None:
        print(
            f"FAIL {cnf}: cnf docs.repo_export_tenants is not readable or empty: no workspace can be allowed"
        )
        return 1
    by_path, ws_of, rows = read_map(mapf, fail, hard)
    stamped = stamped_files(tree)
    not_public = (
        "is not in cnf docs.repo_export_tenants ("
        + ", ".join(sorted(allowed))
        + "): its docs never go to the public repository"
    )
    for rel, ws in ws_of.items():
        if ws not in allowed:
            hard(rel, f"mapped to workspace {ws}, which {not_public}")
    for rel, ids in stamped.items():
        for _, ws in ids:
            if ws is None:
                hard(
                    rel,
                    'its generated-from line names no workspace ("Workspace `<ws>`."): export it again',
                )
            elif ws not in allowed:
                hard(
                    rel,
                    f"its generated-from line names workspace {ws}, which {not_public}",
                )
            elif rel in ws_of and ws != ws_of[rel]:
                hard(
                    rel,
                    f"its generated-from line names workspace {ws}, its map row {ws_of[rel]}",
                )
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
                f"{len(ids)} generated-from lines ({', '.join(i for i, _ in ids)}); an export writes one",
            )
        elif ids[0][0] != doc:
            fail(
                rel, f"its generated-from line names qto doc {ids[0][0]}, the map {doc}"
            )
    for rel, ids in sorted(stamped.items()):
        if rel not in by_path:
            fail(
                rel,
                f"says generated from qto doc {ids[0][0]}, but no map row names it: add the row or drop the line",
            )
    known = read_known(knownf)
    rc = 0
    for p in sorted(worst):
        for why in worst[p]:
            print(f"FAIL {p}: {why}")
            rc = 1
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
            f"OK qto doc map: {rows} rows, {len(stamped)} exported md files, each stamp names its row,"
            + f" every workspace in docs.repo_export_tenants ({', '.join(sorted(allowed))})"
            + (f" ({n} known drift)" if n else "")
        )
    return rc


if __name__ == "__main__":
    if len(sys.argv) not in (4, 5):
        sys.exit("usage: check-qto-doc-drift.py <tree> <map> <known> [<cnf>]")
    sys.exit(main(*sys.argv[1:]))
