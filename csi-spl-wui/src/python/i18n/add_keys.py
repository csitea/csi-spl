#!/usr/bin/env python3
"""Add new keys to every locale (donor workflow step 1).

Reads a nested JSON delta of English values, writes them into
``i18n/locales/en.json`` and copies each NEW key into the other 18 locales
with the English value as a placeholder (existing values are never
overwritten). Translators then replace the placeholders
(``splice_locales.py --delta``).

Usage:
  add_keys.py --delta <file.json> [--locales-dir DIR] [--overwrite-en]
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path


def default_locales_dir() -> Path:
    # csi-spl-wui/src/python/i18n/this.py → csi-spl-wui/i18n/locales
    return Path(__file__).resolve().parents[3] / "i18n" / "locales"


def merge(dst: dict, src: dict, overwrite: bool) -> int:
    n = 0
    for k, v in src.items():
        if isinstance(v, dict):
            node = dst.setdefault(k, {})
            if not isinstance(node, dict):
                raise SystemExit(f"key {k} is a leaf in the target, a group in the delta")
            n += merge(node, v, overwrite)
        elif k not in dst or overwrite:
            if k not in dst:
                n += 1
            dst[k] = v
    return n


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--delta", type=Path, required=True, help="nested JSON of English values")
    ap.add_argument("--locales-dir", type=Path, default=default_locales_dir())
    ap.add_argument("--overwrite-en", action="store_true", help="also replace existing en values")
    a = ap.parse_args()
    delta = json.loads(a.delta.read_text(encoding="utf-8"))
    for f in sorted(a.locales_dir.glob("*.json")):
        data = json.loads(f.read_text(encoding="utf-8"))
        n = merge(data, delta, a.overwrite_en and f.stem == "en")
        f.write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(f"{f.stem}: +{n}")


if __name__ == "__main__":
    main()
