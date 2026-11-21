#!/usr/bin/env python3
"""Does a commit's 'Lang-review: gct <run id>' line hold (SPL-6174,
wui-lang-review)?

Usage: lang-review-gct-check.py <tree> <locales-dir> <report-dir> <sha> <run id>

The report <report-dir>/<run id>.json (written by do_spl_lang_review_gct,
csi-spl-orc) must be in the commit's tree, be a gct report of that run id
with no row marked 'placeholder', and cover every key the commit adds or
changes in a non-English locale file with that key's text as committed. The
{placeholders} of each such string are checked again against en.json at the
commit: a missing or an extra one fails, whatever the report says.

Prints one 'FAIL <why>' line per problem; exit 0 when there is none, 1
otherwise, 2 for a bad call.
"""

import importlib.util
import json
import pathlib
import subprocess
import sys

_spec = importlib.util.spec_from_file_location(
    "lang_review_keys", pathlib.Path(__file__).resolve().parent / "lang-review-keys.py"
)
keys_lib = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(keys_lib)


def show(tree, rev):
    r = subprocess.run(["git", "-C", tree, "show", rev], capture_output=True)
    return r.stdout if r.returncode == 0 else None


def load_report(tree, sha, path, run_id):
    """-> (report, []) or (None, [why])"""
    data = show(tree, f"{sha}:{path}")
    if data is None:
        return None, [
            f"no report {path} in the commit's tree (run do_spl_lang_review_gct and commit its report)"
        ]
    try:
        rep = json.loads(data)
    except ValueError:
        return None, [f"report {path} is not valid JSON"]
    if (
        not isinstance(rep, dict)
        or rep.get("engine") != "gct"
        or rep.get("run_id") != run_id
    ):
        return None, [f"report {path} is not the gct report of run {run_id}"]
    return rep, []


def problems(tree, locales, report_dir, sha, run_id):
    path = f"{report_dir.rstrip('/')}/{run_id}.json"
    rep, why = load_report(tree, sha, path, run_id)
    if rep is None:
        return why
    rows = {
        (r.get("file"), r.get("key")): r
        for r in rep.get("rows", [])
        if isinstance(r, dict)
    }
    out = [
        f"{f} {k}: marked placeholder in {path}"
        for (f, k), r in rows.items()
        if r.get("mark") == "placeholder"
    ]
    en = keys_lib.parse(show(tree, f"{sha}:{locales}/en.json"))
    for f in keys_lib.changed_files(tree, sha, locales):
        if f.endswith("/en.json"):
            continue
        new = keys_lib.parse(show(tree, f"{sha}:{f}"))
        if new is keys_lib._MISSING:
            out.append(f"{f}: not valid JSON")
            continue
        old = keys_lib.parse(show(tree, f"{sha}^:{f}"))
        for k in keys_lib.added_or_changed(
            {} if old is keys_lib._MISSING else old, new
        ):
            text = keys_lib.lookup(new, k)
            row = rows.get((f, k))
            if row is None:
                out.append(f"{f} {k}: not in {path}")
            elif row.get("text") != text:
                out.append(
                    f"{f} {k}: the committed text is not the text {path} checked (run it again)"
                )
            src = keys_lib.lookup(en, k) if isinstance(en, dict) else keys_lib._MISSING
            if (
                isinstance(text, str)
                and isinstance(src, str)
                and keys_lib.placeholders(text) != keys_lib.placeholders(src)
            ):
                out.append(
                    f"{f} {k}: placeholders {sorted(keys_lib.placeholders(text))} differ from en {sorted(keys_lib.placeholders(src))}"
                )
    return out


def main(argv):
    if len(argv) != 5:
        print(__doc__.strip().splitlines()[3], file=sys.stderr)
        return 2
    out = problems(*argv)
    for line in out:
        print(f"FAIL {line}")
    return 1 if out else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
