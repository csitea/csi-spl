#!/usr/bin/env python3
"""Spec 123 section 16.6.7 row L3, first commit: measure Google Cloud
Translation v3 on dev for the 18 non-master locales of the hub (i18n.Supported
minus en) and the no-translate span of section 16.6.5, n = 20 synthetic texts.

Usage: TRANSLATE_URL=<base>/v3/projects/<project>/locations/global \
       TRANSLATE_TOKEN=<access token> python3 -I measure-dev.py

Prints a markdown report; the texts are synthetic (no person, no estate data).
"""

import concurrent.futures
import html
import json
import os
import re
import sys
import time
import urllib.request

LOCALES = [
    "bg",
    "fi",
    "ru",
    "sv",
    "he",
    "tr",
    "mk",
    "el",
    "lt",
    "et",
    "lv",
    "sr",
    "ro",
    "uk",
    "sk",
    "pl",
    "es",
    "nl",
]
TEXTS = [
    "Monthly salary of [NAME_1]",
    "Cloud hosting for [WORKSPACE_1]",
    "Travel costs of [NAME_1] and [NAME_2]",
    "Phone bill [PHONE_1]",
    "Invoice from [EMAIL_1]",
    "Office rent",
    "Accounting services",
    "Health insurance",
    "Pension contribution",
    "Holiday pay",
    "Laptop for [NAME_1]",
    "Training course & certification",
    "Domain names and DNS",
    "Database backups",
    "Meal vouchers for [WORKSPACE_1] staff",
    "Bonus Q3",
    "Social security costs",
    "Recruitment fee",
    "Consulting by [NAME_1] for [WORKSPACE_1]",
    "Electricity <100 kWh>",
]
TOKEN = re.compile(r"\[(?:EMAIL|PHONE|NAME|WORKSPACE|OTHER)_[0-9]+\]")
SPAN = re.compile(
    r'<span translate="no">\s*(\[(?:EMAIL|PHONE|NAME|WORKSPACE|OTHER)_[0-9]+\])\s*</span>'
)


def wrap(masked):
    esc = html.escape(masked, quote=False)
    return TOKEN.sub(lambda m: '<span translate="no">' + m.group(0) + "</span>", esc)


def call(base, tok, content, target):
    body = json.dumps(
        {
            "contents": [content],
            "mimeType": "text/html",
            "sourceLanguageCode": "en",
            "targetLanguageCode": target,
        }
    ).encode()
    req = urllib.request.Request(
        base + ":translateText",
        data=body,
        method="POST",
        headers={"Authorization": "Bearer " + tok, "Content-Type": "application/json"},
    )
    t0 = time.monotonic()
    with urllib.request.urlopen(req, timeout=10) as r:
        out = json.load(r)["translations"][0]["translatedText"]
    return out, time.monotonic() - t0


def main():
    base, tok = os.environ["TRANSLATE_URL"].rstrip("/"), os.environ["TRANSLATE_TOKEN"]
    per = {l: {"ok": 0, "span": 0, "tokens": 0, "same": 0, "err": 0} for l in LOCALES}
    lat, wall, chars, samples = [], [], 0, {}
    for text in TEXTS:
        content = wrap(text)
        t0 = time.monotonic()
        with concurrent.futures.ThreadPoolExecutor(len(LOCALES)) as ex:
            futs = {ex.submit(call, base, tok, content, l): l for l in LOCALES}
            for f, l in futs.items():
                try:
                    out, dt = f.result()
                except Exception as e:  # noqa: BLE001 - counted, never fatal
                    per[l]["err"] += 1
                    print(f"error {l}: {type(e).__name__}", file=sys.stderr)
                    continue
                lat.append(dt)
                chars += len(content)
                per[l]["ok"] += 1
                want = TOKEN.findall(text)
                per[l]["span"] += sorted(SPAN.findall(out)) == sorted(want)
                plain = html.unescape(SPAN.sub(lambda m: m.group(1), out))
                per[l]["tokens"] += (
                    sorted(TOKEN.findall(plain)) == sorted(want)
                    and "<span" not in plain
                )
                per[l]["same"] += plain == text
                if text == TEXTS[0]:
                    samples[l] = plain
        wall.append(time.monotonic() - t0)
    lat.sort()
    wall.sort()
    n = len(TEXTS)
    print(
        f"n = {n} texts x {len(LOCALES)} locales = {n * len(LOCALES)} calls, "
        f"{chars} characters sent"
    )
    print(
        f"per call latency s: p50 {lat[len(lat) // 2]:.2f}, p95 {lat[int(len(lat) * 0.95)]:.2f}, max {lat[-1]:.2f}"
    )
    print(
        f"per text wall (18 in parallel) s: p50 {wall[n // 2]:.2f}, max {wall[-1]:.2f}"
    )
    print()
    print(
        "| locale | answered | span kept | tokens intact, no span left | equal to English |"
    )
    print("|---|---|---|---|---|")
    for l in LOCALES:
        p = per[l]
        print(
            f"| {l} | {p['ok']}/{n} | {p['span']}/{n} | {p['tokens']}/{n} | {p['same']}/{n} |"
        )
    print()
    print(f"sample, text 1 ({TEXTS[0]!r}):")
    for l in LOCALES:
        print(f"- {l}: {samples.get(l, '-')}")


if __name__ == "__main__":
    main()
