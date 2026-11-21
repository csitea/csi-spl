#!/usr/bin/env python3
"""The language check of new WUI text through Google Cloud Translation v3
(SPL-6174, owner HUM-10 msg 36b3ff7f: "google translation Api's are now
available - use them - better and cheaper"). Called by
do_spl_lang_review_gct (csi-spl-orc/src/bash/run/spl-lang-review-gct.func.sh).

Usage: lang-review-gct.py --tree <checkout> --locales <dir> --base <rev>
         --out-dir <dir> --project <gcp project> --endpoint <url> [file...]

The "Authorization: Bearer <token>" header line is read ONCE from fd 3 and
kept in memory only: never in argv, the env, a file or the output.

For each non-English locale file (the named ones, else every one that
differs from <base>), the keys it adds or changes against <base>, and the
keys whose en.json source changed, are checked:

- placeholders: the {tokens} of the locale string must equal those of its
  en source. A missing or an extra one is a failure, whatever the API says
  (mark "placeholder").
- reference: a fresh translation en -> <lang> (the placeholders wrapped as
  translate="no", so {name} never comes back as {nimi}).
- back: the written text translated <lang> -> en, for a reader who does not
  know the language.
- mark: "match" when the written text equals the reference after
  normalisation (Unicode NFC, case folded, whitespace collapsed, trailing
  . ! ? : ; ... dropped), else "differs". An exact compare against a fresh
  translation from en is deterministic and needs no similarity threshold,
  which a back-translation compare would; "differs" is a prompt to read the
  row, not a refusal. The author folds the references in by hand.

The report <out-dir>/<run id>.json holds one row per key (file, lang, key,
why, en, text, reference, back, mark) and the summary; the run id is
<UTC yyyymmddThhmmssZ>-<8 hex>. Exit 0 with no placeholder failure, 1 with
one (the report is still written), 2 for a bad call or an API error (no
report; the API's own status and message are printed).
"""

import argparse
import datetime
import html
import importlib.util
import json
import os
import pathlib
import re
import secrets
import subprocess
import sys
import unicodedata
import urllib.error
import urllib.request

_KEYS_PY = (
    pathlib.Path(__file__).resolve().parents[4]
    / "csi-spl-iac/src/bash/scripts/lang-review-keys.py"
)
_spec = importlib.util.spec_from_file_location("lang_review_keys", _KEYS_PY)
keys_lib = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(keys_lib)

# per request: the API takes at most 1024 strings and about 30k code points
_CHUNK_ITEMS = 100
_CHUNK_CHARS = 20000
_NOTRANSLATE_RX = re.compile(r'<span translate="no">(.*?)</span>', re.S)
_TRAILING_PUNCT = ".!?:;…。"


def normalise(text):
    t = unicodedata.normalize("NFC", text).casefold()
    t = " ".join(t.split())
    return t.rstrip(_TRAILING_PUNCT).rstrip()


def to_html(text):
    """text -> html with every {placeholder} marked translate="no" """
    out, pos = [], 0
    for m in keys_lib._PLACEHOLDER_RX.finditer(text):
        out.append(html.escape(text[pos : m.start()], quote=False))
        out.append(
            '<span translate="no">' + html.escape(m.group(0), quote=False) + "</span>"
        )
        pos = m.end()
    out.append(html.escape(text[pos:], quote=False))
    return "".join(out)


def from_html(text):
    return html.unescape(_NOTRANSLATE_RX.sub(r"\1", text))


def git_json(tree, rev, path):
    """the JSON of <rev>:<path>, {} when the file is not there"""
    r = subprocess.run(
        ["git", "-C", tree, "show", f"{rev}:{path}"], capture_output=True
    )
    if r.returncode != 0:
        return {}
    return json.loads(r.stdout)


def work_json(tree, path):
    with open(os.path.join(tree, path), encoding="utf-8") as fh:
        return json.load(fh)


def rows_for(tree, base, path, en_base, en_now):
    """the rows of one locale file: (key, why, en, text) for each key the file
    adds or changes, and each key whose en source changed"""
    old, new = git_json(tree, base, path), work_json(tree, path)
    rows, seen = [], set()
    for k in keys_lib.added_or_changed(old, new):
        seen.add(k)
        why = "new" if keys_lib.lookup(old, k) is keys_lib._MISSING else "changed"
        rows.append((k, why, keys_lib.lookup(en_now, k), keys_lib.lookup(new, k)))
    for k in keys_lib.added_or_changed(en_base, en_now):
        if k in seen:
            continue
        text = keys_lib.lookup(new, k)
        if text is not keys_lib._MISSING:
            rows.append((k, "en-changed", keys_lib.lookup(en_now, k), text))
    return rows


class Api:
    def __init__(self, endpoint, project, header):
        self.url = f"{endpoint.rstrip('/')}/v3/projects/{project}/locations/global:translateText"
        name, _, value = header.partition(":")
        if name.strip().lower() != "authorization" or not value.strip():
            raise SystemExit(
                "lang-review-gct: FATAL no 'Authorization: Bearer <token>' line on fd 3"
            )
        self.auth = value.strip()

    def translate(self, texts, src, dst):
        """texts (plain, with placeholders) -> their translations, in order"""
        out, chunk, size = [], [], 0
        for t in texts:
            if chunk and (len(chunk) >= _CHUNK_ITEMS or size + len(t) > _CHUNK_CHARS):
                out += self._call(chunk, src, dst)
                chunk, size = [], 0
            chunk.append(t)
            size += len(t)
        if chunk:
            out += self._call(chunk, src, dst)
        return out

    def _call(self, chunk, src, dst):
        body = json.dumps(
            {
                "contents": [to_html(t) for t in chunk],
                "sourceLanguageCode": src,
                "targetLanguageCode": dst,
                "mimeType": "text/html",
            }
        ).encode()
        req = urllib.request.Request(
            self.url,
            data=body,
            headers={"Content-Type": "application/json", "Authorization": self.auth},
            method="POST",
        )
        try:
            with urllib.request.urlopen(req, timeout=60) as r:
                answer = json.load(r)
        except urllib.error.HTTPError as e:
            raise ApiError(e.code, e.read().decode("utf-8", "replace"))
        except urllib.error.URLError as e:
            raise ApiError(0, str(e.reason))
        got = [
            from_html(t.get("translatedText", ""))
            for t in answer.get("translations", [])
        ]
        if len(got) != len(chunk):
            raise ApiError(200, f"{len(got)} translations for {len(chunk)} strings")
        return got


class ApiError(Exception):
    def __init__(self, code, text):
        super().__init__(f"http {code}")
        self.code, self.text = code, text


def api_error_line(e):
    msg = e.text
    try:
        err = json.loads(e.text).get("error", {})
        msg = f"{err.get('status', '')} {err.get('message', '')}".strip()
    except (ValueError, AttributeError):
        pass
    line = f"lang-review-gct: FATAL Cloud Translation refused: http {e.code}: {msg}"
    if e.code == 403:
        line += (
            " -- the identity needs roles/cloudtranslate.user on the project"
            " (a terraform grant, applied only on the owner's go) and the API"
            " translate.googleapis.com enabled; never another account"
        )
    return line


def changed_locales(tree, base, locales):
    r = subprocess.run(
        ["git", "-C", tree, "diff", "--name-only", base, "--", locales],
        capture_output=True,
        text=True,
        check=True,
    )
    names = [f for f in r.stdout.split() if f.endswith(".json")]
    if f"{locales}/en.json" in names:  # an en change asks every locale
        names = sorted(
            f"{locales}/{n}"
            for n in os.listdir(os.path.join(tree, locales))
            if n.endswith(".json")
        )
    return [f for f in names if not f.endswith("/en.json")]


def check(args, api):
    en_path = f"{args.locales}/en.json"
    en_base, en_now = (
        git_json(args.tree, args.base, en_path),
        work_json(args.tree, en_path),
    )
    files = args.files or changed_locales(args.tree, args.base, args.locales)
    report_rows = []
    for path in files:
        lang = pathlib.Path(path).stem
        rows = [
            r
            for r in rows_for(args.tree, args.base, path, en_base, en_now)
            if isinstance(r[2], str) and isinstance(r[3], str)
        ]
        if not rows:
            continue
        refs = api.translate([r[2] for r in rows], "en", lang)
        backs = api.translate([r[3] for r in rows], lang, "en")
        for (k, why, en, text), ref, back in zip(rows, refs, backs):
            if keys_lib.placeholders(text) != keys_lib.placeholders(en):
                mark = "placeholder"
            elif normalise(text) == normalise(ref):
                mark = "match"
            else:
                mark = "differs"
            report_rows.append(
                {
                    "file": path,
                    "lang": lang,
                    "key": k,
                    "why": why,
                    "en": en,
                    "text": text,
                    "reference": ref,
                    "back": back,
                    "mark": mark,
                }
            )
    return files, report_rows


def main(argv):
    ap = argparse.ArgumentParser()
    for opt in (
        "--tree",
        "--locales",
        "--base",
        "--out-dir",
        "--project",
        "--endpoint",
    ):
        ap.add_argument(opt, required=True)
    ap.add_argument("files", nargs="*")
    args = ap.parse_args(argv)
    args.locales = args.locales.rstrip("/")
    try:
        with os.fdopen(3, encoding="utf-8") as fd3:
            header = fd3.readline().strip()
    except OSError:
        header = ""
    api = Api(args.endpoint, args.project, header)
    try:
        base_sha = subprocess.run(
            [
                "git",
                "-C",
                args.tree,
                "rev-parse",
                "--verify",
                f"{args.base}^{{commit}}",
            ],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
        files, rows = check(args, api)
    except ApiError as e:
        print(api_error_line(e))
        return 2
    except (subprocess.CalledProcessError, OSError, ValueError) as e:
        print(f"lang-review-gct: FATAL {e}")
        return 2
    now = datetime.datetime.now(datetime.timezone.utc)
    run_id = f"{now:%Y%m%dT%H%M%SZ}-{secrets.token_hex(4)}"
    summary = {
        m: sum(r["mark"] == m for r in rows)
        for m in ("match", "differs", "placeholder")
    }
    summary["rows"] = len(rows)
    report = {
        "v": 1,
        "engine": "gct",
        "run_id": run_id,
        "created_at": f"{now:%Y-%m-%dT%H:%M:%SZ}",
        "api": "Cloud Translation v3 translateText",
        "project": args.project,
        "identity": "project-sa",
        "base": args.base,
        "base_sha": base_sha,
        "files": files,
        "judge": "reference = fresh en -> lang translation; match = equal after NFC, casefold, "
        "whitespace collapse, trailing punctuation dropped; placeholder = the {tokens} "
        "differ from en (a failure)",
        "rows": rows,
        "summary": summary,
    }
    os.makedirs(args.out_dir, exist_ok=True)
    out = os.path.join(args.out_dir, f"{run_id}.json")
    with open(out, "w", encoding="utf-8") as fh:
        json.dump(report, fh, ensure_ascii=False, indent=1)
        fh.write("\n")
    for r in rows:
        print(
            f"LANG_GCT {r['mark']}\t{r['file']}\t{r['key']}\ttext={r['text']}\treference={r['reference']}\tback={r['back']}"
        )
    print(
        f"LANG_GCT run_id={run_id} rows={summary['rows']} match={summary['match']} "
        f"differs={summary['differs']} placeholder={summary['placeholder']} report={out}"
    )
    if summary["placeholder"]:
        print(
            "lang-review-gct: FAIL a placeholder differs from en in the rows marked 'placeholder': fix them and run again"
        )
        return 1
    print(f"Lang-review: gct {run_id}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
