#!/usr/bin/env python3
"""Report i18n leaf keys that no WUI source can reach.

Refactoring report item A4. A key counts as REACHABLE when any of these
holds in ``csi-spl-wui/src`` or ``csi-spl-wui/tests``:

  1. the full dotted key appears as a literal string — ``t('a.b.c')``;
  2. it matches a template-literal key — ``t(`a.b.status_${s}`)`` — with
     each ``${...}`` hole standing for any run of key characters. The
     the donor WUI uses this for invoice statuses, order carriers, payment
     method labels/hints, password errors, role names and social buttons,
     so a literal-only grep scores those keys as dead when they are not;
  3. it matches a string-concatenation prefix — ``'a.b.' + x``;
  4. its bare leaf segment appears anywhere as an identifier, which covers
     a key completed from a variable whose value is spelled out somewhere.

Rules 2-4 deliberately over-approximate reachability: the report is a list
of keys that are safe to delete, not a list of every unused key. Python
under ``src/python`` is excluded — the already-applied one-offs there
mention keys they removed long ago.

Usage:
  find_dead_keys.py [--wui DIR] [--locale CODE] [--json]

Exit code is 0 whatever it finds; deletion stays a human decision.
"""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path

SOURCE_ROOTS = ("src", "tests", "server", "app", "i18n")
SOURCE_SUFFIXES = {".vue", ".ts", ".js", ".mjs", ".cjs", ".json", ".md", ".html"}
SKIP_DIRS = {".nuxt", ".output", "node_modules", "locales", "python"}

LITERAL = re.compile(r"""['"]([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]+)+)['"]""")
TEMPLATE = re.compile(r"`([A-Za-z_][A-Za-z0-9_.]*\.[A-Za-z0-9_.]*\$\{[^`]*)`", re.S)
HOLE = re.compile(r"(\$\{(?:[^{}]|\{[^}]*\})*\})", re.S)
CONCAT = re.compile(r"""['"]([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z0-9_]*)+)['"]\s*\+""")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


def default_wui() -> Path:
    # csi-spl-wui/src/python/i18n/this.py → csi-spl-wui
    return Path(__file__).resolve().parents[3]


def flatten(d: dict, prefix: str = "") -> dict:
    out = {}
    for k, v in d.items():
        full = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict):
            out.update(flatten(v, full))
        else:
            out[full] = v
    return out


def read_sources(wui: Path) -> str:
    chunks = []
    for root in SOURCE_ROOTS:
        base = wui / root
        if not base.is_dir():
            continue
        for path in base.rglob("*"):
            if not path.is_file() or path.suffix not in SOURCE_SUFFIXES:
                continue
            if SKIP_DIRS & set(path.relative_to(base).parts):
                continue
            chunks.append(path.read_text(encoding="utf-8", errors="ignore"))
    return "\n".join(chunks)


def reachability(blob: str) -> tuple[set[str], list[re.Pattern], set[str]]:
    literals = set(LITERAL.findall(blob))
    patterns = []
    for tpl in set(TEMPLATE.findall(blob)):
        rx = "".join(
            "[A-Za-z0-9_.]*" if part.startswith("${") else re.escape(part)
            for part in HOLE.split(tpl)
        )
        try:
            patterns.append(re.compile(f"^{rx}$"))
        except re.error:
            pass
    for prefix in set(CONCAT.findall(blob)):
        patterns.append(re.compile(f"^{re.escape(prefix)}[A-Za-z0-9_.]*$"))
    return literals, patterns, set(WORD.findall(blob))


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--wui", type=Path, default=default_wui(), help="csi-spl-wui root")
    ap.add_argument(
        "--locale", default="en", help="locale whose key set is scanned (default: en)"
    )
    ap.add_argument(
        "--json", action="store_true", help="print the dead keys as a JSON array"
    )
    args = ap.parse_args()

    locale_file = args.wui / "i18n" / "locales" / f"{args.locale}.json"
    keys = sorted(flatten(json.loads(locale_file.read_text(encoding="utf-8"))))
    literals, patterns, words = reachability(read_sources(args.wui))

    dead = [
        k
        for k in keys
        if k not in literals
        and not any(p.match(k) for p in patterns)
        and k.rsplit(".", 1)[-1] not in words
    ]

    if args.json:
        print(json.dumps(dead, indent=2))
    else:
        print(f"{locale_file.name}: {len(keys)} leaf keys, {len(dead)} unreachable")
        for k in dead:
            print(f"  {k}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
