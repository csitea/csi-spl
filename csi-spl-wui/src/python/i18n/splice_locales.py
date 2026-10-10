#!/usr/bin/env python3
"""Merge per-locale JSON files back into ``i18n/locales/<code>.json``.

Storefront contract: one nested JSON file per locale, identical leaf-key
sets, no empty string values (19 locales under ``csi-spl-wui/i18n/locales/``).

Usage:
  splice_locales.py --dir /path/with/<code>.json [--codes es,fi,...] [--delta]

  * without --delta: every locale file must contain the FULL leaf-key set of
    ``en.json`` in --dir (parity assertion). The file replaces the locale.
  * with    --delta: locale files contain only NEW/CHANGED keys (nested
    subset or full tree); they are deep-merged into the existing locale.
    Every dotted delta key must already exist in the target locale (or in
    ``en.delta.json`` in --dir, which may introduce keys present there).

Examples:
  splice_locales.py --dir /tmp/i18n --codes es,fi,sv
  splice_locales.py --dir /tmp/i18n --delta --codes es,fi
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


def deep_merge(base: dict, overlay: dict) -> dict:
    for k, v in overlay.items():
        if isinstance(v, dict) and isinstance(base.get(k), dict):
            deep_merge(base[k], v)
        else:
            base[k] = v
    return base


def die(msg: str) -> None:
    print(msg, file=sys.stderr)
    sys.exit(1)


def dump_json(path: Path, obj: dict) -> None:
    path.write_text(
        json.dumps(obj, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )


def load_obj(path: Path) -> dict:
    if not path.is_file():
        die(f"missing file: {path}")
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        die(f"{path}: expected a JSON object")
    return data


def assert_leaves(d: dict, label: str) -> dict:
    flat = flatten(d)
    if not flat:
        die(f"{label}: no leaf keys")
    bad = [k for k, v in flat.items() if not (isinstance(v, str) and v.strip())]
    if bad:
        die(f"empty or non-string value in {label}: {', '.join(bad[:20])}")
    return flat


def discover_codes(locales_dir: Path, workdir: Path, requested: str) -> list[str]:
    known = sorted(p.stem for p in locales_dir.glob("*.json") if p.is_file())
    if requested:
        codes = [c.strip() for c in requested.split(",") if c.strip()]
        unknown = [c for c in codes if c not in known]
        if unknown:
            die(f"unknown locale code(s): {', '.join(unknown)}")
        return codes
    return [c for c in known if (workdir / f"{c}.json").is_file()]


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        formatter_class=argparse.RawDescriptionHelpFormatter,
        description=__doc__,
    )
    ap.add_argument(
        "--locales-dir",
        default=str(default_locales_dir()),
        help="directory of live <code>.json locale files (default: csi-spl-wui/i18n/locales)",
    )
    ap.add_argument(
        "--dir",
        required=True,
        help="translator workdir containing <code>.json (and en.json / en.delta.json)",
    )
    ap.add_argument(
        "--codes",
        default="",
        help="comma-separated locale codes (default: every <code>.json in --dir that is a known locale)",
    )
    ap.add_argument(
        "--delta",
        action="store_true",
        help="merge only the keys present in the workdir files into the live locales",
    )
    a = ap.parse_args(argv)

    locales_dir = Path(a.locales_dir)
    workdir = Path(a.dir)
    if not locales_dir.is_dir():
        die(f"locales dir not found: {locales_dir}")
    if not workdir.is_dir():
        die(f"workdir not found: {workdir}")

    codes = discover_codes(locales_dir, workdir, a.codes)
    if not codes:
        die("no locale files to splice (pass --codes or put <code>.json in --dir)")

    extra_allowed: set[str] = set()
    ref: set[str] | None = None
    if a.delta:
        delta_ref = workdir / "en.delta.json"
        if delta_ref.is_file():
            extra_allowed = set(assert_leaves(load_obj(delta_ref), "en.delta.json"))
    else:
        en_path = workdir / "en.json"
        ref = set(assert_leaves(load_obj(en_path), "en.json"))

    n = 0
    for c in codes:
        incoming = load_obj(workdir / f"{c}.json")
        inc_flat = assert_leaves(incoming, c)
        live_path = locales_dir / f"{c}.json"
        cur = load_obj(live_path)
        if a.delta:
            cur_flat = set(flatten(cur))
            unknown = sorted(set(inc_flat) - cur_flat - extra_allowed)
            if unknown:
                die(
                    f"{c}: delta keys not in the live locale (add them to all "
                    f"locales first, or list them in en.delta.json): {', '.join(unknown[:20])}"
                )
            deep_merge(cur, incoming)
        else:
            mismatch = set(inc_flat) ^ ref
            if mismatch:
                die(f"key mismatch in {c}: {', '.join(sorted(mismatch)[:40])}")
            cur = incoming
        dump_json(live_path, cur)
        n += 1
    print("spliced", n, "locale(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
