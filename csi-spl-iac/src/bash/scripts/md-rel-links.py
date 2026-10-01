#!/usr/bin/env python3
"""Relative markdown links must point at a file that exists. Args: md files."""
import os, re, sys
LINK = re.compile(r'\[[^\]]*\]\(([^)\s]+)(?:\s+"[^"]*")?\)')
bad = 0
for f in sys.argv[1:]:
    fence = False
    for n, line in enumerate(open(f, encoding='utf-8', errors='replace'), 1):
        if line.lstrip().startswith(('```', '~~~')):
            fence = not fence
        if fence:
            continue
        for t in LINK.findall(re.sub(r'`[^`]*`', '', line)):
            if re.match(r'^([a-z][a-z0-9+.-]*:|#|<|/|\{)', t, re.I):
                continue
            p = os.path.normpath(os.path.join(os.path.dirname(f), t.split('#')[0]))
            if not os.path.exists(p):
                print(f'{f}:{n}: broken relative link -> {t}'); bad += 1
sys.exit(1 if bad else 0)
