#!/usr/bin/env python3
"""Export WUI locale JSON (for translators / diffing).

Reads one nested JSON file per locale from ``i18n/locales/<code>.json``
(csi-spl-wui; 19 locales) and writes the same shape to ``--out/<code>.json``.

``--only-keys`` takes dotted paths (``nav.home,footer.legal_line``) and exports
a nested subset. Full-file export is the default.

Examples:
  export_locale.py --out /tmp/i18n --codes en
  export_locale.py --out /tmp/i18n --codes fi,sv --only-keys nav.home,footer.legal_line
"""
from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path


def default_locales_dir() -> Path:
    # csi-spl-wui/src/python/i18n/this.py → csi-spl-wui/i18n/locales
    return Path(__file__).resolve().parents[3] / "i18n" / "locales"


def flatten(d: dict, prefix: str = "") -> dict:
    out = {}
    for k, v in d.items():
        full = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict):
            out.update(flatten(v, full))
        else:
            out[full] = v
    return out


def unflatten(flat: dict) -> dict:
    root: dict = {}
    for key, val in flat.items():
        cur = root
        parts = key.split(".")
        for p in parts[:-1]:
            nxt = cur.get(p)
            if not isinstance(nxt, dict):
                nxt = {}
                cur[p] = nxt
            cur = nxt
        cur[parts[-1]] = val
    return root


def die(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(1)


def dump_json(path: Path, obj: dict) -> None:
    path.write_text(
        json.dumps(obj, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
    )
    ap.add_argument(
        "--locales-dir",
        default=str(default_locales_dir()),
        help="directory of <code>.json locale files (default: csi-spl-wui/i18n/locales)",
    )
    ap.add_argument("--out", required=True, help="directory to write <code>.json into")
    ap.add_argument(
        "--codes",
        default="en",
        help="comma-separated locale codes to export (default: en)",
    )
    ap.add_argument(
        "--only-keys",
        default="",
        help="comma-separated dotted keys to keep (nested subset). Empty = full file",
    )
    a = ap.parse_args(argv)

    locales_dir = Path(a.locales_dir)
    if not locales_dir.is_dir():
        die(f"locales dir not found: {locales_dir}")

    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)

    codes = [c.strip() for c in a.codes.split(",") if c.strip()]
    if not codes:
        die("--codes is empty")

    only = [k.strip() for k in a.only_keys.split(",") if k.strip()] if a.only_keys else []

    for c in codes:
        src = locales_dir / f"{c}.json"
        if not src.is_file():
            die(f"locale file not found: {src}")
        data = json.loads(src.read_text(encoding="utf-8"))
        if not isinstance(data, dict):
            die(f"{src}: expected a JSON object")
        if only:
            flat = flatten(data)
            missing = [k for k in only if k not in flat]
            if missing:
                die(f"{c}: missing keys: {', '.join(missing)}")
            data = unflatten({k: flat[k] for k in only})
        dump_json(out / f"{c}.json", data)
        n = len(flatten(data))
        print(c, n, "keys")
    return 0


if __name__ == "__main__":
    sys.exit(main())
