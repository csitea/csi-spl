#!/usr/bin/env python3
"""invoice-pdf-month-totals.py: read one Google Cloud invoice's text (what
`pdftotext -layout` printed) and print its month total as one TSV row
(SPL-5802, spec 123 section 15.6). Pure: it reads a file, calls nothing.

  invoice-pdf-month-totals.py TEXT_FILE PDF_PATH

PDF_PATH is only read as a name: its parent dir (pdf/<billing account id>/,
how do_gcp_billing_invoices_browser saves it) and its "YYYY-MM-DD-" prefix
are the fallbacks when the text lacks the account or the service period.

Prints: file  month  account_last4  net  currency  status
  file      the PDF's base name (never its dir: that is the account id)
  month     YYYY-MM, the service period ("Summary for Nov 1, 2025 - Nov 30,
            2025" and the like); else the month before the file's date prefix
            (the invoice is issued in the month after the one it bills)
  account   the last 4 characters of the billing account id, never more
  net       the subtotal before VAT, as a plain decimal (1234.50)
  currency  the ISO 4217 code ("Subtotal in EUR", "Total in EUR"), else
            the amount's symbol (EUR, USD, GBP)
  status    ok, or unparsed:<field>[,<field>] for each field not found; a
            field not found reads "-", never a guess
"""

import os
import re
import sys

MONTHS = {
    m: i + 1
    for i, m in enumerate(
        [
            "jan",
            "feb",
            "mar",
            "apr",
            "may",
            "jun",
            "jul",
            "aug",
            "sep",
            "oct",
            "nov",
            "dec",
        ]
    )
}
SYMBOLS = {"€": "EUR", "$": "USD", "£": "GBP"}
ACCOUNT_RX = re.compile(r"\b([0-9A-F]{6}-[0-9A-F]{6}-[0-9A-F]{6})\b")
# one amount: digits in groups of 3 (one ".", ",", space or no-break space
# between groups), an optional 1..2 digit decimal part; two numbers on one
# line ("1   64.80") never merge into one
AMOUNT_RX = (
    r"(?P<sym>[€$£])?\s*(?P<num>-?(?:[0-9]{1,3}(?:[.,  ][0-9]{3})+|[0-9]+)(?:[.,][0-9]{1,2})?)"
    r"\s*(?P<sym2>[€$£])?(?:\s+(?P<cur2>[A-Z]{3}))?"
)
NET_RX = [
    re.compile(
        r"^\s*Subtotal(?:\s+in\s+(?P<cur>[A-Z]{3}))?\s*:?\s+" + AMOUNT_RX + r"\s*$",
        re.I,
    ),
    re.compile(
        r"^\s*(?:Total\s+)?(?:amount\s+)?(?:excl(?:uding|\.)?\s+(?:VAT|tax)|before\s+tax|net\s+amount)"
        r"(?:\s+in\s+(?P<cur>[A-Z]{3}))?\s*:?\s+" + AMOUNT_RX + r"\s*$",
        re.I,
    ),
]
CURRENCY_RX = re.compile(r"\b(?:Sub)?[Tt]otal\s+in\s+([A-Z]{3})\b")


def _month_name(word):
    return MONTHS.get(word[:3].lower())


def _same_month(pairs):
    for a, ya, b, yb in pairs:
        ma, mb = _month_name(a), _month_name(b)
        if ma and ma == mb and ya == yb:
            return "%s-%02d" % (ya, ma)
    return None


def service_month(text):
    """YYYY-MM of a period line inside one month, else None."""
    md = r"([A-Za-z]{3,9})\.?\s+\d{1,2},?\s+(\d{4})"
    dm = r"\d{1,2}\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})"
    dash = r"\s*[-–]\s*"
    found = _same_month(re.findall(md + dash + md, text)) or _same_month(
        re.findall(dm + dash + dm, text)
    )
    if found:
        return found
    for ya, ma, yb, mb in re.findall(
        r"(\d{4})-(\d{2})-\d{2}" + dash + r"(\d{4})-(\d{2})-\d{2}", text
    ):
        if (ya, ma) == (yb, mb) and 1 <= int(ma) <= 12:
            return "%s-%s" % (ya, ma)
    return None


def file_month(name):
    """The month before the name's YYYY-MM-DD prefix, else None."""
    m = re.match(r"(\d{4})-(\d{2})-\d{2}", name)
    if not m or not 1 <= int(m.group(2)) <= 12:
        return None
    y, mo = int(m.group(1)), int(m.group(2)) - 1
    if mo == 0:
        y, mo = y - 1, 12
    return "%04d-%02d" % (y, mo)


def number(raw):
    """1.234,56 / 1,234.56 / 1 234,56 / 64.80 / 12 -> "1234.56"; None when
    it cannot tell (a lone separator with 3 digits after it: 1,234)."""
    s = raw.replace(" ", "").replace(" ", "")
    neg = s.startswith("-")
    s = s.lstrip("-")
    last = max(s.rfind("."), s.rfind(","))
    tail = len(s) - last - 1
    if last >= 0 and tail in (1, 2):
        whole, frac = s[:last], s[last + 1 :]
    elif (
        last >= 0
        and tail == 3
        and not (s.count(".") and s.count(","))
        and s.count(s[last]) == 1
    ):
        return None
    else:
        whole, frac = s, ""
    whole = whole.replace(".", "").replace(",", "")
    if not whole.isdigit() or (frac and not frac.isdigit()):
        return None
    v = "%d.%s" % (int(whole), (frac + "00")[:2])
    return "-" + v if neg else v


def net_and_currency(text):
    for line in text.splitlines():
        for rx in NET_RX:
            m = rx.match(line)
            if not m:
                continue
            sym = m.group("sym") or m.group("sym2")
            cur = m.group("cur") or m.group("cur2") or SYMBOLS.get(sym or "")
            if not cur:
                c = CURRENCY_RX.search(text)
                cur = c.group(1) if c else None
            return number(m.group("num")), cur
    return None, None


def account(text, pdf_path):
    m = ACCOUNT_RX.search(text)
    if m:
        return m.group(1)
    parent = os.path.basename(os.path.dirname(os.path.abspath(pdf_path)))
    return parent if ACCOUNT_RX.fullmatch(parent) else None


def row(text, pdf_path):
    name = os.path.basename(pdf_path)
    acct = account(text, pdf_path)
    net, cur = net_and_currency(text)
    fields = [
        ("month", service_month(text) or file_month(name)),
        ("account", acct[-4:] if acct else None),
        ("net", net),
        ("currency", cur),
    ]
    missing = [k for k, v in fields if not v]
    status = "ok" if not missing else "unparsed:" + ",".join(missing)
    return "\t".join(
        [re.sub(r"\s", " ", name)] + [v or "-" for _, v in fields] + [status]
    )


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: invoice-pdf-month-totals.py TEXT_FILE PDF_PATH\n")
        return 2
    with open(argv[1], encoding="utf-8", errors="replace") as f:
        print(row(f.read(), argv[2]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
