#!/usr/bin/env python3
"""The Markdown side of the qto doc <-> md file round trip.

Helper of do_spl_doctree_import_md and do_spl_doctree_export_md; run by them,
never by hand. Two verbs:

  split <md> <out dir>
      A numbered md page (one '# ' title, a preamble, then '## 1. ...',
      '### 1.1 ...' sections) cut into what the import writes: <out>/title,
      <out>/preamble.md and per section <out>/NNNN.body.md, plus one TSV line
      per section on stdout: level, outline, title, body file ('' = none).
      Refused (exit 1): no title, a heading deeper than '####', a section with
      no number, or numbers that are not the outline the qto doc will derive
      (the import must never renumber a section others cite).

  compose <head.json> <root read.json> <export.md> <doc id>
      The md file the export writes: the title, the "generated from" line,
      the preamble (the hidden root's body), then `spool doctree export` with
      every heading one level down (outside code fences), so the sections
      are '##' under the page's '#'. One trailing newline: byte-stable.
"""

import json
import os
import re
import sys

HEAD = re.compile(r"^(#{1,6}) (.*)$")
NUM = re.compile(r"^(\d+(?:\.\d+)*)\.? +(.+)$")
FENCE = re.compile(r"^(```|~~~)")


def split(md_path, out):
    lines = open(md_path, encoding="utf-8").read().split("\n")
    title, sections, pre, cur, fence = None, [], [], None, False
    for line in lines:
        m = None if fence else HEAD.match(line)
        if FENCE.match(line):
            fence = not fence
        if m and len(m.group(1)) == 1 and title is None:
            title = m.group(2).strip()
            continue
        if m and len(m.group(1)) > 1:
            cur = section(md_path, m, line)
            sections.append(cur)
            continue
        (cur["body"] if cur else pre).append(line)
    if title is None:
        sys.exit(f"FATAL {md_path}: no '# ' title line")
    check_outline(md_path, sections)
    os.makedirs(out, exist_ok=True)
    write(os.path.join(out, "title"), title)
    write(os.path.join(out, "preamble.md"), "\n".join(pre).strip() + "\n")
    for i, s in enumerate(sections, 1):
        body, name = "\n".join(s["body"]).strip(), ""
        if body:
            name = os.path.join(out, f"{i:04d}.body.md")
            write(name, body + "\n")
        print("\t".join([str(s["level"]), s["outline"], s["title"], name]))


def section(md_path, m, line):
    level = len(m.group(1)) - 1
    if level > 3:
        sys.exit(f"FATAL {md_path}: heading deeper than ####: {line}")
    n = NUM.match(m.group(2).strip())
    if not n:
        sys.exit(f"FATAL {md_path}: a section with no number: {line}")
    return {
        "level": level,
        "outline": n.group(1),
        "title": n.group(2).strip(),
        "body": [],
    }


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def check_outline(md_path, sections):
    """The numbers must be the outline the doc derives: 1, 1.1, 1.2, 2, ..."""
    counts = []
    for s in sections:
        lvl = s["level"]
        if lvl > len(counts) + 1:
            sys.exit(f"FATAL {md_path}: section {s['outline']} skips a level")
        counts = counts[:lvl]
        if len(counts) < lvl:
            counts.append(0)
        counts[-1] += 1
        want = ".".join(str(c) for c in counts)
        if s["outline"] != want:
            sys.exit(
                f"FATAL {md_path}: section '{s['outline']} {s['title']}' would become {want} in the qto doc"
            )


def compose(head_path, root_path, export_path, doc):
    head = json.load(open(head_path, encoding="utf-8"))
    items = json.load(open(root_path, encoding="utf-8")).get("items") or []
    root = items[0] if items and not items[0].get("parent") else {}
    out, fence = [], False
    for line in open(export_path, encoding="utf-8").read().split("\n"):
        if FENCE.match(line):
            fence = not fence
            out.append(line)
            continue
        down = not fence and HEAD.match(line) and not line.startswith("######")
        out.append("#" + line if down else line)
    parts = [
        "# " + (head.get("title") or "Untitled"),
        f"> Generated from qto doc `{doc}`; edit it there. This file is its export: "
        "`cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.",
    ]
    for text in ((root.get("body") or "").strip(), "\n".join(out).strip()):
        if text:
            parts.append(text)
    sys.stdout.write("\n\n".join(parts) + "\n")


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "split":
        split(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 6 and sys.argv[1] == "compose":
        compose(*sys.argv[2:])
    else:
        sys.exit(__doc__)
