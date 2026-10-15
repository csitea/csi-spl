#!/usr/bin/env python3
"""The Markdown side of the qto doc <-> md file round trip.

Helper of do_spl_doctree_import_md and do_spl_doctree_export_md; run by them,
never by hand. Two verbs:

  split <md> <out dir>
      An md page (an optional YAML front matter, one '# ' title, a preamble,
      then '## ' .. '###### ' sections) cut into what the import writes:
      <out>/title, <out>/preamble.md, <out>/front_matter.yml (only when the
      page has one), <out>/no_title (only when it has no title line, below)
      and per section <out>/NNNN.body.md, plus one TSV line per
      section on stdout: level, outline ('-' = unnumbered; '1.' = the author
      wrote '## 1. x', the qto item gets attrs.outline_dot and the export
      writes the dot back, SPL-1900), title, body file ('' = none), gaps
      ('tight' = no blank line under the heading: attrs.tight; 'tight_end' =
      none after its text: attrs.tight_end; comma-separated, '' = both), own
      (the author's number where it is not the one the qto doc derives, ''
      = the same: a section 0, a gap, a restart; the item keeps it as
      written in attrs.outline_author and is never renumbered, since other
      docs cite it, SPL-2024). A body is the section's lines as written,
      less the one blank line under its heading and the one before the
      next: its other blank lines and its first line's indent stay (the
      export writes them back, SPL-1900), each line newline-ended. A
      "generated from qto doc" line in the preamble (a page that is already
      an export) is dropped: compose writes the new one.
      A section is numbered ('## 1. x', '### 1.1 y') or not ('## Overview':
      the qto item gets attrs.numbered false and no outline number); a
      heading under an unnumbered one is unnumbered too, its text kept whole
      as the title. A page has a title line when it opens (its first line
      with text) on a '# ' heading, and a later '# ' line is text; else
      (standard md, SPL-2024) the title is the file name, <out>/no_title holds the md
      heading of a top-level section ('#' when the page has '# ' sections,
      else '##'; the root gets attrs.no_title, and attrs.h1_sections for
      '#') and the export writes no title line. Refused (exit 1): a heading
      that skips a level.

  compose <head.json> <root read.json> <export.md> <doc id>
      The md file the export writes: the front matter (the hidden root's
      attrs.front_matter), the title, the "generated from" line, then
      `spool doctree export` (which opens with the preamble, the root's body;
      added here when an older spool left it out) with every heading one
      level down (outside code fences), so the sections are '##' under the
      page's '#'. A root with attrs.no_title gets no title line, and with
      attrs.h1_sections its headings stay as exported ('#'). It ends as
      the md did (SPL-1900): the last section's trailing blank lines, or
      no final newline (attrs.tight_end), come from the read, since the
      export reaches compose with its trailing newlines cut; one newline
      otherwise. Byte-stable.

Code fences are tracked by their opening run (CommonMark): a fence opened by
'````' closes only on a '````' or longer line of the same character, so a
'```' inside it is text.
"""

import json
import os
import re
import sys

HEAD = re.compile(r"^(#{1,6}) (.*)$")
NUM = re.compile(r"^(\d+(?:\.\d+)*)(\.?) +(.+)$")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})(.*)$")
FM_END = ("---", "...")
# compose's generated-from line; split drops it from a page that is an export
STAMP = re.compile(r"^> Generated from qto doc `[^`]+`; edit it there\.")
# compose's section anchor (spec 138 G4), the line before each heading: the
# WUI's link #ws-doc-<item id> lands in the md too; split drops it
ANCHOR = re.compile(r'^<a id="ws-doc-[^"]+"></a>$')


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


def heading_levels(lines):
    """The md levels of the page's headings outside fences, in order."""
    fences = Fences()
    return [
        len(m.group(1))
        for m in (None if fences.inside(line) else HEAD.match(line) for line in lines)
        if m
    ]


def has_title(lines):
    """True when the page opens (its first line with text) on a '# ' line."""
    first = next((line for line in lines if line.strip()), "")
    return bool(HEAD.match(first)) and first.startswith("# ")


def split(md_path, out):
    fm, lines = front_matter(open(md_path, encoding="utf-8").read().split("\n"))
    levels = heading_levels(lines)
    # a title line: the page opens on '# '; else its sections start at its
    # top heading ('#' when it has any, else '##')
    titled = has_title(lines)
    top = 2 if titled or 1 not in levels else 1
    title, sections, pre, cur, fences = None, [], [], None, Fences()
    for line in lines:
        m = None if fences.inside(line) else HEAD.match(line)
        if m and titled and title is None and len(m.group(1)) == 1:
            title = m.group(2).strip()
            continue
        if m and len(m.group(1)) >= top:
            body = cur["body"] if cur else pre
            if body and ANCHOR.match(body[-1]):
                body.pop()
            cur = section(m, top)
            sections.append(cur)
            continue
        (cur["body"] if cur else pre).append(line)
    if not titled:
        title = os.path.splitext(os.path.basename(md_path))[0]
    # a page that is already an export (a re-import into another tree, spec
    # 137 T030a) drops its old generated-from line: compose writes the new one
    pre = [line for line in pre if not STAMP.match(line)]
    check_outline(md_path, sections)
    os.makedirs(out, exist_ok=True)
    write(os.path.join(out, "title"), title)
    write(os.path.join(out, "preamble.md"), "\n".join(pre).strip() + "\n")
    if fm is not None:
        write(os.path.join(out, "front_matter.yml"), fm)
    if not titled:
        write(os.path.join(out, "no_title"), "#" * top + "\n")
    for i, s in enumerate(sections, 1):
        lines = s["body"]
        tight = not lines or lines[0] != ""
        tight_end = bool("".join(lines).strip()) and lines[-1] != ""
        body, name = section_body(lines, tight), ""
        if body:
            name = os.path.join(out, f"{i:04d}.body.md")
            write(name, body)
        num = s["outline"] + ("." if s["dot"] else "") if s["outline"] else "-"
        gaps = ",".join(
            g for g, on in (("tight", tight), ("tight_end", tight_end)) if on
        )
        own = s["outline"] if s.get("own") else ""
        print("\t".join([str(s["level"]), num, s["title"], name, gaps, own]))


def section_body(lines, tight):
    """A section's body as the qto item stores it (SPL-1900): its lines less
    the blank line under the heading (none when tight) and, when it has text,
    the blank line that closes it, each line newline-ended. The export
    (cmd/spool docTreeBodyLines) frames it with those blank lines again, so a
    blank-line run at either edge and the first line's indent come back."""
    if not tight:
        lines = lines[1:]
    if lines and lines[-1] == "" and "".join(lines).strip():
        lines = lines[:-1]
    return "".join(line + "\n" for line in lines)


def section(m, top=2):
    text = m.group(2).strip()
    n = NUM.match(text)
    return {
        "level": len(m.group(1)) - top + 1,
        "outline": n.group(1) if n else None,
        "dot": bool(n and n.group(2)),
        "title": n.group(3).strip() if n else text,
        "text": text,
        "body": [],
    }


def write(path, text):
    with open(path, "w", encoding="utf-8") as f:
        f.write(text)


def check_outline(md_path, sections):
    """Marks own the numbers that are not the outline the doc derives (1,
    1.1, 1.2, 2, ...): the item keeps the author's (attrs.outline_author).
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
            s["outline"], s["title"], s["dot"] = None, s["text"], False
            numbered.append(False)
            continue
        counts[-1] += 1
        numbered.append(True)
        s["own"] = s["outline"] != ".".join(str(c) for c in counts)


def heading_text(it):
    """The export's heading text for one item, after the '#'s: its outline
    number when it has one ('1.' with attrs.outline_dot), its title."""
    num = it.get("outline") or ""
    if num and (it.get("attrs") or {}).get("outline_dot") is True:
        num += "."
    return (num + " " if num else "") + (it.get("title") or "Untitled")


def first_heading(items):
    """The export's line for the doc's first section (items[1] of the root
    read)."""
    if len(items) < 2:
        return None
    return "# " + heading_text(items[1])


def anchored(lines, items):
    """The export's section lines with '<a id="ws-doc-<item id>"></a>' before
    each heading (spec 138 G4): the headings outside fences are the items
    after the root, in order; one whose text is not the next item's gets
    none."""
    out, fences, todo = [], Fences(), list(items[1:])
    for line in lines:
        m = None if fences.inside(line) else HEAD.match(line)
        if m and todo and todo[0].get("id") and m.group(2) == heading_text(todo[0]):
            out.append(f'<a id="ws-doc-{todo.pop(0)["id"]}"></a>')
        out.append(line)
    return out


def compose(head_path, root_path, export_path, doc):
    head = json.load(open(head_path, encoding="utf-8"))
    items = json.load(open(root_path, encoding="utf-8")).get("items") or []
    root = items[0] if items and not items[0].get("parent") else {}
    lines = open(export_path, encoding="utf-8").read().split("\n")
    # the export opens with the preamble (the root's body, SPL-1612), kept as
    # it is: only the sections, from the first one's heading on, go one level
    # down. An installed spool older than that starts at that heading and
    # leaves the preamble out, so the root's body is taken then.
    want, cut, fences = first_heading(items), len(lines), Fences()
    if want:
        cut = 0
        for i, line in enumerate(lines):
            if not fences.inside(line) and line == want:
                cut = i
                break
    pre = "\n".join(lines[:cut]).strip() or (root.get("body") or "").strip()
    out, fences = [], Fences()
    keep = (root.get("attrs") or {}).get("h1_sections") is True
    for line in anchored(lines[cut:], items):
        down = (
            not keep
            and not fences.inside(line)
            and HEAD.match(line)
            and not line.startswith("######")
        )
        out.append("#" + line if down else line)
    parts = []
    fm = (root.get("attrs") or {}).get("front_matter")
    if isinstance(fm, str):
        parts.append("---\n" + fm + "\n---" if fm else "---\n---")
    if (root.get("attrs") or {}).get("no_title") is not True:
        parts.append("# " + (head.get("title") or "Untitled"))
    parts += [
        f"> Generated from qto doc `{doc}`; edit it there. This file is its export: "
        "`cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.",
    ]
    for text in (pre, "\n".join(out).strip()):
        if text:
            parts.append(text)
    sys.stdout.write("\n\n".join(parts) + page_end(items))


def page_end(items):
    """What follows the export's last line (SPL-1900): the last section's
    body as stored ends the page as the md did, its trailing blank lines
    kept, no newline when it had none (attrs.tight_end, or a tight empty
    section); one newline otherwise (no section, or a code block or image
    after the body)."""
    it = items[-1] if len(items) > 1 else {}
    attrs, body = it.get("attrs") or {}, it.get("body") or ""
    if not it or attrs.get("src") or attrs.get("img_http_path"):
        return "\n"
    if body.strip():
        return (
            ""
            if attrs.get("tight_end") is True
            else "\n" * (len(body) - len(body.rstrip("\n")))
        )
    if not body:
        return "" if attrs.get("tight") is True else "\n"
    return "\n" * (len(body) + 1)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "split":
        split(sys.argv[2], sys.argv[3])
    elif len(sys.argv) == 6 and sys.argv[1] == "compose":
        compose(*sys.argv[2:])
    else:
        sys.exit(__doc__)
