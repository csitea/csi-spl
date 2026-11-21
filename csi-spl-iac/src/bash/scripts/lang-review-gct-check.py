#!/usr/bin/env python3
"""Does a commit's 'Lang-review: gct <run id>' line hold (SPL-6174,
wui-lang-review)?

Usage: lang-review-gct-check.py <tree> <locales-dir> <report-dir> <sha> <run id>

The report <report-dir>/<run id>.json (written by do_spl_lang_review_gct,
csi-spl-orc) must be in the commit's tree, be a gct report of that run id
with no row marked 'placeholder', every row shaped as the action writes it
(mark match or differs; en, text, reference and back non-empty), and cover
every key the commit adds or changes in a non-English locale file, and every
key it adds or changes in en.json for each locale holding it, with that
key's en and locale text as committed. The
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


def locale_files(tree, sha, locales):
    """every non-en <locales>/*.json at the commit"""
    r = subprocess.run(
        ["git", "-C", tree, "ls-tree", "--name-only", sha, f"{locales}/"],
        capture_output=True,
        text=True,
    )
    return [
        f
        for f in r.stdout.split()
        if f.endswith(".json") and not f.endswith("/en.json")
    ]


def bad_shape(row):
    """why a report row is not one do_spl_lang_review_gct writes, or None"""
    if row.get("mark") not in ("match", "differs", "placeholder"):
        return f"mark {row.get('mark')!r} is not match or differs"
    for field in ("en", "text", "reference", "back"):
        if not isinstance(row.get(field), str) or not row[field]:
            return f"no {field} text"
    return None


def wanted(tree, locales, sha, en):
    """-> ({(file, key): text}, [why]): each key a non-en locale file adds or
    changes, and each key the commit adds or changes in en.json for every
    locale holding it (an en edit asks its translations again), where the en
    and the locale text are both strings, as the action's rows are"""
    en_path = f"{locales}/en.json"
    changed = keys_lib.changed_files(tree, sha, locales)
    en_keys = []
    if en_path in changed and isinstance(en, dict):
        old_en = keys_lib.parse(show(tree, f"{sha}^:{en_path}"))
        en_keys = list(
            keys_lib.added_or_changed({} if old_en is keys_lib._MISSING else old_en, en)
        )
    files = set(changed) - {en_path}
    if en_keys:
        files |= set(locale_files(tree, sha, locales))
    want, out = {}, []
    for f in sorted(files):
        new = keys_lib.parse(show(tree, f"{sha}:{f}"))
        if new is keys_lib._MISSING:
            if f in changed:
                out.append(f"{f}: not valid JSON")
            continue
        keys = list(en_keys)
        if f in changed:
            old = keys_lib.parse(show(tree, f"{sha}^:{f}"))
            keys += keys_lib.added_or_changed(
                {} if old is keys_lib._MISSING else old, new
            )
        for k in keys:
            text = keys_lib.lookup(new, k)
            src = keys_lib.lookup(en, k) if isinstance(en, dict) else keys_lib._MISSING
            if isinstance(text, str) and isinstance(src, str):
                want[(f, k)] = text
    return want, out


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
    out += [
        f"{f} {k}: {bad} in {path} (not a row do_spl_lang_review_gct writes)"
        for (f, k), r in rows.items()
        if (bad := bad_shape(r))
    ]
    en = keys_lib.parse(show(tree, f"{sha}:{locales}/en.json"))
    want, why = wanted(tree, locales, sha, en)
    out += why
    for (f, k), text in want.items():
        src = keys_lib.lookup(en, k)
        row = rows.get((f, k))
        if row is None:
            out.append(f"{f} {k}: not in {path}")
        elif row.get("text") != text:
            out.append(
                f"{f} {k}: the committed text is not the text {path} checked (run it again)"
            )
        elif row.get("en") != src:
            out.append(
                f"{f} {k}: the committed en text is not the en {path} checked (run it again)"
            )
        if keys_lib.placeholders(text) != keys_lib.placeholders(src):
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
