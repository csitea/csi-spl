#!/usr/bin/env python3
"""The Markdown side of the qto doc <-> md file round trip.

Helper of do_spl_doctree_import_md and do_spl_doctree_export_md; run by them,
never by hand. Two verbs:

  split <md> <out dir>
      An md page (an optional YAML front matter, one '# ' title, a preamble,
      then '## ' .. '###### ' sections) cut into what the import writes:
      <out>/title, <out>/preamble.md, <out>/front_matter.yml (only when the
      page has one) and per section <out>/NNNN.body.md, plus one TSV line per
      section on stdout: level, outline ('-' = unnumbered), title, body file
      ('' = none). A "generated from qto doc" line in the preamble (a page
      that is already an export) is dropped: compose writes the new one.
      A section is numbered ('## 1. x', '### 1.1 y') or not ('## Overview':
      the qto item gets attrs.numbered false and no outline number); a
      heading under an unnumbered one is unnumbered too, its text kept whole
      as the title. Refused (exit 1): no title, a heading that skips a level,
      or numbers that are not the outline the qto doc will derive (the import
      must never renumber a section others cite).

  compose <head.json> <root read.json> <export.md> <doc id>
      The md file the export writes: the front matter (the hidden root's
      attrs.front_matter), the title, the "generated from" line, the preamble
      (the root's body), then `spool doctree export` with every heading one
      level down (outside code fences), so the sections are '##' under the
      page's '#'. One trailing newline: byte-stable.

Code fences are tracked by their opening run (CommonMark): a fence opened by
'````' closes only on a '````' or longer line of the same character, so a
'```' inside it is text.
"""

import json
import os
import re
import sys

HEAD = re.compile(r"^(#{1,6}) (.*)$")
NUM = re.compile(r"^(\d+(?:\.\d+)*)\.? +(.+)$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
FM_END = ("---", "...")
# compose's generated-from line; split drops it from a page that is an export
STAMP = re.compile(r"^> Generated from qto doc `[^`]+`; edit it there\.")


class Fences:
    """Whether a line is inside a code fence; feed every line in order."""

    def __init__(self):
        self.open = ""

    def inside(self, line):
        """True when line is in a fence or is one of its fence lines."""
        m = FENCE.match(line)
        if not self.open:
            if m and not (m.group(1)[0] == "`" and "`" in m.group(2)):
                self.open = m.group(1)
                return True
            return False
        if (
            m
            and m.group(1)[0] == self.open[0]
            and len(m.group(1)) >= len(self.open)
            and not m.group(2).strip()
        ):
            self.open = ""
        return True


def front_matter(lines):
    """(the YAML between the page's opening '---' and its end line, the rest)."""
    if not lines or lines[0].rstrip() != "---":
        return None, lines
    for i in range(1, len(lines)):
        if lines[i].rstrip() in FM_END:
            return "\n".join(lines[1:i]), lines[i + 1 :]
    return None, lines


def split(md_path, out):
    fm, lines = front_matter(open(md_path, encoding="utf-8").read().split("\n"))
    title, sections, pre, cur, fences = None, [], [], None, Fences()
    for line in lines:
        m = None if fences.inside(line) else HEAD.match(line)
        if m and len(m.group(1)) == 1 and title is None:
            title = m.group(2).strip()
            continue
        if m and len(m.group(1)) > 1:
            cur = section(m)
            sections.append(cur)
            continue
        (cur["body"] if cur else pre).append(line)
    if title is None:
        sys.exit(f"FATAL {md_path}: no '# ' title line")
    # a page that is already an export (a re-import into another tree, spec
    # 137 T030a) drops its old generated-from line: compose writes the new one
    pre = [line for line in pre if not STAMP.match(line)]
    check_outline(md_path, sections)
    os.makedirs(out, exist_ok=True)
    write(os.path.join(out, "title"), title)
    write(os.path.join(out, "preamble.md"), "\n".join(pre).strip() + "\n")
    if fm is not None:
        write(os.path.join(out, "front_matter.yml"), fm)
    for i, s in enumerate(sections, 1):
        body, name = "\n".join(s["body"]).strip(), ""
        if body:
            name = os.path.join(out, f"{i:04d}.body.md")
            write(name, body + "\n")
        print("\t".join([str(s["level"]), s["outline"] or "-", s["title"], name]))


def section(m):
    text = m.group(2).strip()
    n = NUM.match(text)
    return {
        "level": len(m.group(1)) - 1,
        "outline": n.group(1) if n else None,
        "title": n.group(2).strip() if n else text,
        "text": text,
        "body": [],
    }


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def check_outline(md_path, sections):
    """The numbers must be the outline the doc derives: 1, 1.1, 1.2, 2, ...
    An unnumbered section is not counted among its siblings, and every
    section under it is unnumbered (the qto doc gives them no number)."""
    counts, numbered = [], [True]
    for s in sections:
        lvl = s["level"]
        if lvl > len(numbered):
            sys.exit(f"FATAL {md_path}: section '{s['text']}' skips a level")
        counts, numbered = counts[:lvl], numbered[:lvl]
        while len(counts) < lvl:
            counts.append(0)
        if s["outline"] is None or not numbered[-1]:
            s["outline"], s["title"] = None, s["text"]
            numbered.append(False)
            continue
        counts[-1] += 1
        numbered.append(True)
        want = ".".join(str(c) for c in counts)
        if s["outline"] != want:
            sys.exit(
                f"FATAL {md_path}: section '{s['outline']} {s['title']}' would become {want} in the qto doc"
            )


def compose(head_path, root_path, export_path, doc):
    head = json.load(open(head_path, encoding="utf-8"))
    items = json.load(open(root_path, encoding="utf-8")).get("items") or []
    root = items[0] if items and not items[0].get("parent") else {}
    out, fences = [], Fences()
    for line in open(export_path, encoding="utf-8").read().split("\n"):
        down = (
            not fences.inside(line)
            and HEAD.match(line)
            and not line.startswith("######")
        )
        out.append("#" + line if down else line)
    parts = []
    fm = (root.get("attrs") or {}).get("front_matter")
    if isinstance(fm, str):
        parts.append("---\n" + fm + "\n---" if fm else "---\n---")
    parts += [
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
