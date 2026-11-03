#!/usr/bin/env python3
"""incomes-tsv-to-json.py TENANT TSV: the body of PUT /v1/operator/incomes
(SPL-4697, rdb 0259) from a TSV of invoices, checked with the table's rules.

The TSV has one header line naming these columns, in any order:
invoice_no payer period issue_date due_date hours unit_price net vat_pct vat
total currency. Prints the JSON body on stdout and one summary line on
stderr (the row count and the period span, never a figure). A bad row exits
2 naming its line and the rule; nothing is printed on stdout then.
"""

import csv
import datetime
import json
import re
import sys
from decimal import Decimal, InvalidOperation

COLS = [
    "invoice_no",
    "payer",
    "period",
    "issue_date",
    "due_date",
    "hours",
    "unit_price",
    "net",
    "vat_pct",
    "vat",
    "total",
    "currency",
]
AMOUNTS = ["hours", "unit_price", "net", "vat_pct", "vat", "total"]
MAX_ROWS = 500


def is_date(v, fmt):
    try:
        return datetime.datetime.strptime(v, fmt).strftime(fmt) == v
    except ValueError:
        return False


def amount(v, decimals):
    try:
        d = Decimal(v)
    except InvalidOperation:
        return None
    if not d.is_finite() or d.as_tuple().exponent < -decimals:
        return None
    return d


def why_bad(r):
    """the first rule row r breaks, or None (store.CheckIncomeInvoice)"""
    if not 1 <= len(r["invoice_no"].strip()) <= 64:
        return "invoice_no must be 1..64 characters"
    if not 1 <= len(r["payer"].strip()) <= 100:
        return "payer must be 1..100 characters"
    if not is_date(r["period"], "%Y-%m"):
        return "period must be a month YYYY-MM"
    if not (
        is_date(r["issue_date"], "%Y-%m-%d") and is_date(r["due_date"], "%Y-%m-%d")
    ):
        return "issue_date and due_date must be dates YYYY-MM-DD"
    if r["due_date"] < r["issue_date"]:
        return "due_date must not be before issue_date"
    n = {c: amount(r[c], 4 if c == "unit_price" else 2) for c in AMOUNTS}
    bad = [c for c, d in n.items() if d is None]
    if bad:
        return f"{', '.join(bad)} must be numbers (unit_price up to 4 decimals, the rest up to 2)"
    if n["hours"] < 0 or n["unit_price"] < 0:
        return "hours and unit_price must be 0 or more"
    if not 0 <= n["vat_pct"] <= 100:
        return "vat_pct must be 0..100"
    if n["net"] + n["vat"] != n["total"]:
        return "net + vat must equal total"
    if not re.fullmatch(r"[A-Z]{3}", r["currency"]):
        return "currency must be an ISO 4217 code such as EUR"
    return None


def main(argv):
    if len(argv) != 3:
        print("usage: incomes-tsv-to-json.py TENANT TSV", file=sys.stderr)
        return 2
    tenant, path = argv[1], argv[2]
    with open(path, newline="", encoding="utf-8") as f:
        rd = csv.DictReader(f, delimiter="\t")
        missing = [c for c in COLS if c not in (rd.fieldnames or [])]
        if missing:
            print(f"{path}: the header lacks {', '.join(missing)}", file=sys.stderr)
            return 2
        rows, seen = [], set()
        for line, r in enumerate(rd, start=2):
            r = {c: (r[c] or "").strip() for c in COLS}
            why = (
                why_bad(r)
                or (r["invoice_no"] in seen and "invoice_no appears twice")
                or None
            )
            if why:
                print(f"{path} line {line}: {why}", file=sys.stderr)
                return 2
            seen.add(r["invoice_no"])
            rows.append({c: (float(r[c]) if c in AMOUNTS else r[c]) for c in COLS})
    if not 1 <= len(rows) <= MAX_ROWS:
        print(f"{path}: {len(rows)} rows, want 1..{MAX_ROWS}", file=sys.stderr)
        return 2
    periods = sorted(r["period"] for r in rows)
    print(json.dumps({"tenant": tenant, "invoices": rows}, separators=(",", ":")))
    print(
        f"{len(rows)} invoice(s), periods {periods[0]}..{periods[-1]}", file=sys.stderr
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
