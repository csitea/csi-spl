#!/usr/bin/env python3
"""
vendor-terms-check.py - monthly vendor terms watch (spec 159 row T9, SPL-4097)

Fetches the nine URLs of spec 159 section 4.1, compares the quoted sentences,
and reports when one changes or goes missing.
"""

import argparse
import datetime
import html
import json
import os
import re
import subprocess
import sys


def parse_spec_table(spec_path):
    """Parse the 9 URLs and their quotes from spec 159 section 4.1."""
    with open(spec_path, "r", encoding="utf-8") as f:
        text = f.read()

    section_match = re.search(
        r"###\s*4\.1\s*The vendors.*?own words(.*?)(?=###\s*4\.2|\Z)",
        text,
        re.DOTALL,
    )
    if not section_match:
        raise ValueError(f"Could not find section 4.1 in {spec_path}")

    s41 = section_match.group(1)
    rows = [line for line in s41.splitlines() if line.strip().startswith("| `")]

    items = []
    for r in rows:
        parts = [p.strip() for p in r.split("|")]
        if len(parts) < 5:
            continue
        kind = parts[1].strip("`")
        col4 = parts[4]
        subparts = re.split(r";?\s*(?=`https://)", col4)
        for sp in subparts:
            m_url = re.search(r"`(https://[^`]+)`", sp)
            if m_url:
                url = m_url.group(1)
                qs = re.findall(r"\"([^\"]+)\"", sp)
                if qs:
                    items.append((kind, url, qs))
    return items


def fetch_url(url, fetch_cmd=None):
    """Fetch URL content via custom fetcher command or curl."""
    if fetch_cmd:
        res = subprocess.run(
            [fetch_cmd, url],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=30,
        )
        if res.returncode != 0:
            raise RuntimeError(
                f"Custom fetcher failed for {url} with code {res.returncode}: {res.stderr.decode('utf-8', errors='ignore')}"
            )
        return res.stdout.decode("utf-8", errors="ignore")

    cmd = [
        "curl",
        "-sL",
        "--max-time",
        "20",
        "-A",
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64)",
        url,
    ]
    res = subprocess.run(
        cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=25
    )
    if res.returncode != 0:
        raise RuntimeError(f"curl failed for {url} with exit code {res.returncode}")
    return res.stdout.decode("utf-8", errors="ignore")


def normalize_text(text):
    """Normalize HTML and unicode characters for consistent comparison."""
    text = html.unescape(text)
    text = re.sub(r"<[^>]+>", " ", text)
    # Quotes
    for ch in ["\u2018", "\u2019", "`", "\u00b4"]:
        text = text.replace(ch, "'")
    for ch in ["\u201c", "\u201d", "\u00ab", "\u00bb"]:
        text = text.replace(ch, '"')
    # Dashes
    for ch in ["\u2013", "\u2014", "\u2212"]:
        text = text.replace(ch, "-")
    # Ellipsis
    text = text.replace("\u2026", "...")
    # Collapse whitespace
    text = re.sub(r"\s+", " ", text).strip()
    # Remove whitespace before common punctuation introduced by stripped HTML tags
    text = re.sub(r"\s+([.,;:?!\]\)])", r"\1", text)
    text = re.sub(r"(\[|\()\s+", r"\1", text)
    return text


def quote_matches(quote, norm_page):
    """Check if quote exists in the normalized page content."""
    qn = normalize_text(quote)
    if " [...] " in quote or "[...]" in qn:
        parts = [
            re.escape(normalize_text(p))
            for p in re.split(r"\s*\[\.\.\.\]\s*", quote)
            if p.strip()
        ]
        pattern = r".*?".join(parts)
        return bool(re.search(pattern, norm_page, re.DOTALL | re.IGNORECASE))
    if qn in norm_page:
        return True
    if qn.startswith("(i) ") and qn[4:] in norm_page:
        return True
    return False


def main():
    parser = argparse.ArgumentParser(description="Vendor terms watch")
    parser.add_argument("--spec", help="Path to spec 159 spec.md")
    parser.add_argument("--report", help="Path to write JSON findings report")
    args = parser.parse_args()

    spec_path = args.spec or os.environ.get("VENDOR_TERMS_SPEC")
    if not spec_path:
        here = os.path.dirname(os.path.abspath(__file__))
        repo_root = os.path.abspath(os.path.join(here, "../../../.."))
        spec_path = os.path.join(repo_root, "csi-spl-doc/specs/159-byo-ai-keys/spec.md")

    if not os.path.isfile(spec_path):
        print(f"FATAL: spec file not found: {spec_path}", file=sys.stderr)
        sys.exit(2)

    items = parse_spec_table(spec_path)
    if len(items) != 9:
        print(
            f"WARN: expected 9 URLs from spec 159 section 4.1, found {len(items)}",
            file=sys.stderr,
        )

    fetch_cmd = os.environ.get("VENDOR_TERMS_FETCH_CMD")

    missing = []
    total_quotes = 0
    now_iso = datetime.datetime.now(datetime.timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )

    for kind, url, quotes in items:
        try:
            content = fetch_url(url, fetch_cmd=fetch_cmd)
            norm_content = normalize_text(content)
        except Exception as e:
            print(f"WARN fetch failed for {url}: {e}", file=sys.stderr)
            for q in quotes:
                total_quotes += 1
                missing.append(
                    {
                        "kind": kind,
                        "url": url,
                        "quote": q,
                        "reason": f"Fetch error: {e}",
                    }
                )
            continue

        for q in quotes:
            total_quotes += 1
            if not quote_matches(q, norm_content):
                missing.append(
                    {
                        "kind": kind,
                        "url": url,
                        "quote": q,
                        "reason": "Quote not found in page text",
                    }
                )

    if not missing:
        print(
            f"OK vendor terms check: all {total_quotes} quotes match across {len(items)} URLs"
        )
        sys.exit(0)

    # Build report
    print(
        f"WARN vendor terms check: {len(missing)} of {total_quotes} quote(s) missing or changed",
        file=sys.stderr,
    )

    kinds_affected = sorted(list(set(m["kind"] for m in missing)))
    if len(kinds_affected) == 1 and len(missing) == 1:
        title = f"Vendor terms changed: {missing[0]['kind']} ({missing[0]['url']})"
    else:
        title = f"Vendor terms changed: {', '.join(kinds_affected)} ({len(missing)} quotes missing)"

    desc_lines = [
        "Spec: csi-spl-doc/specs/159-byo-ai-keys",
        "",
        "Monthly vendor terms watch (spec 159 row T9, SPL-4097) detected changed or missing quoted terms.",
        "",
        f"Checked at: {now_iso}",
        "",
        "### Missing or changed quotes:",
    ]
    for m in missing:
        desc_lines.append(f"- **Vendor**: `{m['kind']}`")
        desc_lines.append(f"  **URL**: {m['url']}")
        desc_lines.append(f"  **Status**: {m['reason']}")
        desc_lines.append("  **Quote**:")
        desc_lines.append(f"  > {m['quote']}")
        desc_lines.append("")

    desc_lines.append(
        "Action: review the vendor's updated terms and align spec 159 section 4.1."
    )
    description = "\n".join(desc_lines)

    report_data = {
        "status": "changed",
        "missing_count": len(missing),
        "total_quotes": total_quotes,
        "missing": missing,
        "title": title,
        "description": description,
    }

    if args.report:
        with open(args.report, "w", encoding="utf-8") as f:
            json.dump(report_data, f, indent=2)

    sys.exit(1)


if __name__ == "__main__":
    main()
