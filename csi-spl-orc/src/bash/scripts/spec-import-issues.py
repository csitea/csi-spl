#!/usr/bin/env python3
"""Parse git-spec tasks.md files into issue records for do_spl_spec_import_issues.

One record per task entry. Title is "[NNN <id>] <first sentence>" (sentence
capped at 120 characters). Description is the entry text plus a Source line.
Status is the hub's own set (eval|todo|wip|diss|blocked|onhold|qas|done):
Implemented / [x] -> done, Partial / [~] -> wip, Planned / [ ] -> eval,
Superseded / Retired -> diss. A fix or defect is label bug; every other task
is label task. An indented checklist under a task is a subtask (label subtask).

Id shapes: T001, T005a, D1, P1, P2-1, US1, 1.2, OA-01, and a struck-through
~~T033~~. A table is the task list when the file has no checklist or heading
for that id (026, 027, 029, 030). A spec dir with cases.tsv and no tasks.md
(031) is read from that register.

--docs (SPEC_IMPORT_DOCS=1) also files every OTHER document of a spec dir
(spec.md, plan.md, research.md, contracts/*, checklists/*, scripts ...) as
"doc" issues under the spec epic: one issue per file, split in parts when a
file is longer than one description holds, title "[NNN doc-<path>] <path> -
<heading>", status done, label doc. The epic's description becomes an index
of those documents and the task count. Issue comments expire with channel
retention; an issue description does not, so the text lives there.

Personal data never travels: an e-mail address shaped like a person's name
(first.last@...) becomes <EMAIL>, and every --redact word (whole word, any
case) becomes <REDACTED>, in titles and descriptions alike.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

TITLE_SENTENCE_MAX = 120
TITLE_MAX = 255
DESC_MAX = 20000
# One doc part: the description cap less the header, the Source line and the
# room a <REDACTED> replacement may add.
DOC_PART_MAX = 18500
DOC_SUFFIXES = {".md": "", ".sh": "bash", ".py": "python", ".yaml": "yaml", ".yml": "yaml", ".sql": "sql"}
DOC_FIRST = ("spec.md", "plan.md")
DOC_SKIP = {"tasks.md", "cases.tsv"}
EMAIL = re.compile(r"(?<![A-Za-z0-9._%+-])([A-Za-z0-9._%+-]+)@([A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})")
PERSONAL_LOCAL = re.compile(r"^[A-Za-z]{2,}[._][A-Za-z]{2,}$")
# --redact words, set once by main(); scrub() reads them.
REDACT: list = []
ID_RE = r"(?:T\d+[a-z]?|US\d+|D\d+|P\d+(?:-\d+)?|OA-\d+|\d+\.\d+)"
# A task id may be wrapped in bold or strikethrough — `**T001**` (pas-psf) or
# `~~T033~~` (a dropped csi-spl task). EMPH swallows either, on both sides.
EMPH = r"(?:\*\*|~~)?"
CHECK = re.compile(rf"^- \[([ xX~])\]\s+{EMPH}({ID_RE}){EMPH}\s*(.*)$")
HEAD = re.compile(rf"^(#{{2,4}})\s+{EMPH}({ID_RE}){EMPH}\s*(.*)$")
NEST = re.compile(rf"^(\s+)-\s+\[([ xX~])\]\s+{EMPH}(?:({ID_RE}){EMPH}\s*)?(.*)$")
ROW = re.compile(r"^\|(.+)\|\s*$")
SPEC_DIR = re.compile(r"^(\d{3})-")
EPIC_TITLE = re.compile(r"^Spec\s+(\d{3})\b")
BRACKET = re.compile(r"^\[(\d{3})\s+([A-Za-z0-9][A-Za-z0-9.-]*)\]")
STATUS_MARK = re.compile(
    r"\*\*Status\*\*\s*:\s*\**\s*(Implemented|Partial|Planned|Superseded|Retired|done|dropped)\b"
    r"|\*\*(Implemented|Partial|Planned|Superseded|Retired)\*\*"
    r"|^\s*(?:\[[^\]]+\]\s*)*\**\s*(Implemented|Partial|Planned|Superseded|Retired)\b",
    re.I | re.M,
)
BUG = re.compile(r"\b(bug|defect|regression)\b|^(fix|correct|repair)\b", re.I)

# Statuses are the hub's own set (store.IssueStatuses, rdb 0055): a task speaks
# the hub vocabulary end to end, so the read-only list filter, the create/update
# calls and the idempotence comparison all agree. eval is the first-set backlog,
# wip is in-progress, diss (discard) is the closest to superseded / retired.
WORD = {
    "implemented": "done",
    "done": "done",
    "partial": "wip",
    "planned": "eval",
    "superseded": "diss",
    "retired": "diss",
    "dropped": "diss",
}
BOX = {"x": "done", "X": "done", " ": "eval", "~": "wip"}
CASE = {
    "pass": "done",
    "fail": "wip",
    "unverified": "wip",
    "pending": "eval",
    "manual": "eval",
}
# The hub's status vocabulary (mirror of store.IssueStatuses); the parser never
# emits anything outside this set.
HUB_STATUSES = ("eval", "todo", "wip", "diss", "blocked", "onhold", "qas", "done")


def scrub(text: str) -> str:
    """Drop personal data: a first.last@ address and every REDACT word."""

    def mail(m: re.Match) -> str:
        if m.group(2).lower().endswith("gserviceaccount.com"):
            return m.group(0)
        return "<EMAIL>" if PERSONAL_LOCAL.match(m.group(1)) else m.group(0)

    text = EMAIL.sub(mail, text)
    for word in REDACT:
        text = re.sub(rf"(?<![A-Za-z0-9]){re.escape(word)}(?![A-Za-z0-9])", "<REDACTED>", text, flags=re.I)
    return text


def _word(raw: str) -> str | None:
    return WORD.get(raw.lower())


def explicit_status(text: str) -> str | None:
    m = STATUS_MARK.search(text[:1200])
    if not m:
        return None
    raw = next(g for g in m.groups() if g)
    return _word(raw)


def cell_status(cell: str) -> str | None:
    s = re.sub(r"[*_`]", "", cell).strip().lower()
    if not s:
        return None
    if any(w in s for w in ("superseded", "retired", "dropped", "canceled", "cancelled", "not ours")):
        return "diss"
    if "partial" in s or "in progress" in s or "in_progress" in s:
        return "wip"
    if (
        s.startswith("done")
        or "implemented" in s
        or s.startswith("checked")
        or s.startswith("closed")
        or s.startswith("finding")
    ):
        return "done"
    if any(w in s for w in ("planned", "deferred", "pending", "owner decision", "open")):
        return "eval"
    return None


def first_sentence(text: str) -> str:
    s = " ".join(text.replace("\n", " ").split())
    # Drop leading requirement tags: [FR-009], [n/a], [FR-001, FR-012] (pas-psf).
    s = re.sub(r"^(?:\[[^\]]*\]\s*)+", "", s)
    s = re.sub(r"^[\s\-\u2014\u2013:]+", "", s).strip()
    s = re.sub(
        r"^(?:\*\*)?(?:Implemented|Partial|Planned|Superseded|Retired)(?:\*\*)?\s*[\-\u2014\u2013:]*\s*",
        "",
        s,
        count=1,
        flags=re.I,
    )
    s = s.strip(" -*")
    cut = len(s)
    for i, ch in enumerate(s):
        if ch == "." and (i + 1 == len(s) or s[i + 1].isspace()):
            cut = i + 1
            break
    s = s[:cut].strip()
    if len(s) > TITLE_SENTENCE_MAX:
        s = s[: TITLE_SENTENCE_MAX - 3].rstrip() + "..."
    return s or "task"


def make_title(spec: str, tid: str, sentence: str) -> str:
    title = f"[{spec} {tid}] {sentence}"
    if len(title) > TITLE_MAX:
        title = title[: TITLE_MAX - 3].rstrip() + "..."
    return title


def clip_desc(body: str, source: str) -> str:
    tail = f"\n\nSource: {source}"
    text = body.strip() + tail
    if len(text) <= DESC_MAX:
        return text
    note = "\n\n[truncated]"
    keep = DESC_MAX - len(note) - len(tail)
    return body.strip()[: max(keep, 0)].rstrip() + note + tail


def is_bug(sentence: str) -> bool:
    return BUG.search(sentence) is not None


class Item:
    def __init__(self, spec, tid, kind, status, sentence, body, source, parent_id, directory=""):
        self.spec = spec
        self.tid = tid
        self.kind = kind
        self.status = status
        self.title = make_title(spec, tid, scrub(sentence))
        if kind == "doc":
            self.labels = ["doc"]
        else:
            self.labels = ["subtask"] if kind == "subtask" else (["bug"] if is_bug(sentence) else ["task"])
        self.description = clip_desc(scrub(body), source)
        self.parent_id = parent_id
        self.directory = directory
        self.key = f"{directory}/{tid}"

    def as_dict(self) -> dict:
        return {
            "spec": self.spec,
            "dir": self.directory,
            "id": self.tid,
            "key": self.key,
            "kind": self.kind,
            "status": self.status,
            "title": self.title,
            "labels": self.labels,
            "description": self.description,
            "parent_id": self.parent_id,
        }


def parse_tasks(text: str, spec: str, source: str) -> list:
    lines = text.splitlines()
    items: list[Item] = []
    seen: set[str] = set()
    fence = False
    i = 0
    n = len(lines)

    def add(item: Item) -> None:
        if item.tid in seen:
            for n, old in enumerate(items):
                if old.tid == item.tid and old.kind == item.kind:
                    items[n] = item
                    return
            return
        seen.add(item.tid)
        items.append(item)

    def override_status(tid: str, status: str) -> None:
        for item in items:
            if item.tid == tid and item.kind == "task":
                item.status = status
                return

    while i < n:
        line = lines[i]
        if line.lstrip().startswith("```"):
            fence = not fence
            i += 1
            continue
        if fence:
            i += 1
            continue
        m = CHECK.match(line)
        if m:
            i = _checklist(lines, i, m, spec, source, add)
            continue
        m = HEAD.match(line)
        if m:
            i = _heading(lines, i, m, spec, source, add)
            continue
        if ROW.match(line) and i + 1 < n and re.match(r"^\|[\s:|-]+\|\s*$", lines[i + 1]):
            i = _table(lines, i, spec, source, add, seen, override_status)
            continue
        i += 1
    return items


def _checklist(lines, i, m, spec, source, add) -> int:
    box, tid, rest = m.group(1), m.group(2), m.group(3)
    body = [lines[i].rstrip()]
    subs = []
    sub_n = 0
    i += 1
    while i < len(lines):
        line = lines[i]
        if line.strip() == "":
            body.append("")
            i += 1
            continue
        if not line[0].isspace():
            break
        nest = NEST.match(line)
        if nest:
            sub_n += 1
            sid = nest.group(3) or f"{tid}.s{sub_n}"
            subs.append((sid, nest.group(2), nest.group(4)))
        body.append(line.rstrip())
        i += 1
    text = "\n".join(body).strip()
    status = explicit_status(text) or BOX[box]
    sentence = first_sentence((rest + "\n" + "\n".join(body[1:])).strip() or text)
    add(Item(spec, tid, "task", status, sentence, text, source, ""))
    for sid, sbox, srest in subs:
        stext = srest.strip() or sid
        add(Item(spec, sid, "subtask", explicit_status(stext) or BOX.get(sbox, "eval"), first_sentence(stext), stext, source, tid))
    return i


def _heading(lines, i, m, spec, source, add) -> int:
    level = len(m.group(1))
    tid, rest = m.group(2), m.group(3)
    body = [lines[i].rstrip()]
    subs = []
    sub_n = 0
    i += 1
    while i < len(lines):
        line = lines[i]
        if CHECK.match(line):
            break
        if line[:1] == "|" and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|\s*$", lines[i + 1]):
            break
        hm = HEAD.match(line)
        if hm and len(hm.group(1)) <= level:
            break
        if re.match(r"^#{2,4}\s+\S", line) and not hm:
            hashes = len(re.match(r"^#+", line).group(0))
            if hashes <= level:
                break
        nest = NEST.match(line)
        if nest:
            sub_n += 1
            sid = nest.group(3) or f"{tid}.s{sub_n}"
            subs.append((sid, nest.group(2), nest.group(4)))
        body.append(line.rstrip())
        i += 1
    text = "\n".join(body).strip()
    status = explicit_status(text) or "eval"
    sentence = first_sentence((rest + "\n" + "\n".join(body[1:])).strip() or text)
    add(Item(spec, tid, "task", status, sentence, text, source, ""))
    for sid, sbox, srest in subs:
        stext = srest.strip() or sid
        add(Item(spec, sid, "subtask", explicit_status(stext) or BOX.get(sbox, "eval"), first_sentence(stext), stext, source, tid))
    return i


def _table(lines, i, spec, source, add, seen, override_status) -> int:
    header = [c.strip() for c in ROW.match(lines[i]).group(1).split("|")]
    i += 2
    status_at = next((k for k, c in enumerate(header) if c.lower() == "status"), None)
    title_at = next(
        (k for k, c in enumerate(header) if k > 0 and c.lower() in ("what", "task", "item", "title", "description")),
        1 if len(header) > 1 else 0,
    )
    while i < len(lines) and ROW.match(lines[i]):
        cells = [c.strip() for c in ROW.match(lines[i]).group(1).split("|")]
        raw_id = re.sub(r"[*_`~]", "", cells[0]).strip() if cells else ""
        if re.fullmatch(ID_RE, raw_id):
            stat_cell = cells[status_at] if status_at is not None and status_at < len(cells) else ""
            status = cell_status(stat_cell)
            if raw_id in seen:
                if status:
                    override_status(raw_id, status)
            else:
                title_cell = cells[title_at] if title_at < len(cells) else ""
                sentence = first_sentence(re.sub(r"[*_`]", "", title_cell))
                body = "| " + " | ".join(cells) + " |"
                add(Item(spec, raw_id, "task", status or "eval", sentence, body, source, ""))
        i += 1
    return i


def parse_cases(text: str, spec: str, source: str) -> list:
    items = []
    seen: set[str] = set()
    for line in text.splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        if len(cells) < 7 or not re.fullmatch(r"OA-\d+", cells[0]):
            continue
        tid, title, status = cells[0], cells[2].strip(), cells[6].strip().lower()
        if tid in seen:
            continue
        seen.add(tid)
        body = "\t".join(cells[:7])
        items.append(Item(spec, tid, "task", CASE.get(status, "eval"), first_sentence(title), body, source, ""))
    return items


def _heading_of(directory: Path) -> str:
    for name in ("spec.md", "tasks.md"):
        path = directory / name
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8").splitlines():
            if line.startswith("#"):
                head = line.lstrip("#").strip()
                # Drop the git-spec boilerplate so the epic title reads clean:
                # 'Feature Specification: GCP Bootstrap' -> 'GCP Bootstrap'.
                head = re.sub(r"^(?:Feature Specification|Feature Spec|Spec|Tasks)\s*:\s*", "", head, flags=re.I)
                return head or directory.name
    return directory.name


def _doc_files(directory: Path) -> list:
    """Every document of a spec dir but its task register, spec.md and plan.md
    first, then the rest by path (contracts/, checklists/ ... included)."""
    files = []
    for path in directory.rglob("*"):
        if path.is_file() and path.suffix in DOC_SUFFIXES and path.name not in DOC_SKIP:
            files.append(path)

    def order(path: Path) -> tuple:
        rel = path.relative_to(directory).as_posix()
        return (DOC_FIRST.index(rel) if rel in DOC_FIRST else len(DOC_FIRST), rel)

    return sorted(files, key=order)


def doc_id(rel: str) -> str:
    return "doc-" + re.sub(r"[^A-Za-z0-9.-]+", "-", rel).strip("-")


def split_parts(text: str, size: int) -> list:
    """Line-boundary parts of at most `size` characters; a longer line is cut."""
    parts: list[str] = []
    cur = ""
    for line in text.splitlines(keepends=True):
        while len(line) > size:
            if cur:
                parts.append(cur)
                cur = ""
            parts.append(line[:size])
            line = line[size:]
        if len(cur) + len(line) > size:
            parts.append(cur)
            cur = ""
        cur += line
    if cur.strip() or not parts:
        parts.append(cur)
    return parts


def _doc_heading(text: str) -> str:
    for line in text.splitlines():
        if line.startswith("# "):
            return line[2:].strip()
    return ""


def parse_docs(directory: Path, spec: str, src_root: str) -> list:
    """One "doc" Item per document part of a spec dir (see the module doc)."""
    items = []
    for path in _doc_files(directory):
        rel = path.relative_to(directory).as_posix()
        source = f"{src_root}/{directory.name}/{rel}"
        raw = path.read_text(encoding="utf-8", errors="replace")
        lang = DOC_SUFFIXES[path.suffix]
        heading = _doc_heading(raw) if path.suffix == ".md" else ""
        parts = split_parts(raw, DOC_PART_MAX)
        for n, part in enumerate(parts, 1):
            tid = doc_id(rel) + (f"-p{n}" if len(parts) > 1 else "")
            name = rel + (f" (part {n}/{len(parts)})" if len(parts) > 1 else "")
            sentence = f"{name} - {heading}" if heading else name
            text = part.strip("\n") if not lang else f"```{lang}\n{part.rstrip()}\n```"
            body = f"Spec {spec} document `{name}`, migrated from git.\n\n{text}"
            it = Item(spec, tid, "doc", "done", sentence, body, source, "", directory.name)
            items.append(it)
    return items


def epic_index(spec: str, heading: str, rel_dir: str, docs: list, tasks: int) -> str:
    """The spec epic's description: where it came from and what is under it."""
    lines = [f"# {heading}", "", f"Spec {spec}, migrated from git: `{rel_dir}/`.", ""]
    if docs:
        lines.append(f"**Documents** - {len(docs)} `doc` issue(s) under this epic; each holds the full text in its description:")
        lines.append("")
        lines.extend(f"- {scrub(it.title)}" for it in docs)
        lines.append("")
    if tasks:
        lines.append(f"**Tasks** - {tasks} issue(s) titled `[{spec} <id>]`, one per tasks.md entry; the status mirrors its checkbox.")
    else:
        lines.append("**Tasks** - none: this spec has no tasks.md.")
    return clip_desc("\n".join(lines), f"{rel_dir}/")


def _words(text: str) -> set:
    return {w.lower() for w in re.findall(r"[A-Za-z]{4,}", text)}



def _pinned_epic(directory: Path) -> str:
    """A spec that names its epic in the first lines, e.g. 'Epic SPL-74'."""
    spec = directory / "spec.md"
    if not spec.is_file():
        return ""
    head = "\n".join(spec.read_text(encoding="utf-8").splitlines()[:40])
    m = re.search(r"\bEpic\s+(SPL-\d+)\b", head)
    return m.group(1) if m else ""


def parse_tree(specs: Path, docs: bool = False) -> dict:
    out_specs = []
    items = []
    if not specs.is_dir():
        raise SystemExit(f"specs dir is not a directory: {specs}")
    # The Source line names the doc repo this tree lives in, derived from the
    # SPEC_DIR (…/<doc-repo>/specs) — csi-spl-doc/specs here, pas-psf-doc/specs
    # for that tree — never hardcoded to one repo.
    base = specs.resolve()
    src_root = f"{base.parent.name}/{base.name}"
    for d in sorted(p for p in specs.iterdir() if p.is_dir()):
        m = SPEC_DIR.match(d.name)
        if not m:
            continue
        spec = m.group(1)
        tasks = d / "tasks.md"
        cases = d / "cases.tsv"
        if tasks.is_file():
            rel = f"{src_root}/{d.name}/tasks.md"
            found = parse_tasks(tasks.read_text(encoding="utf-8"), spec, rel)
        elif cases.is_file():
            rel = f"{src_root}/{d.name}/cases.tsv"
            found = parse_cases(cases.read_text(encoding="utf-8"), spec, rel)
        else:
            found = []
        for it in found:
            it.directory = d.name
            it.key = f"{d.name}/{it.tid}"
        items.extend(found)
        doc_items = parse_docs(d, spec, src_root) if docs else []
        items.extend(doc_items)
        row = {
            "spec": spec,
            "dir": d.name,
            "heading": _heading_of(d),
            "pinned": _pinned_epic(d),
            "parsed": len(found),
            "t_parsed": sum(1 for it in found if it.tid.startswith("T") and it.kind == "task"),
            "subtasks": sum(1 for it in found if it.kind == "subtask"),
            "docs": len(doc_items),
        }
        if docs:
            row["epic_description"] = epic_index(spec, row["heading"], f"{src_root}/{d.name}", doc_items, len(found))
        out_specs.append(row)
    return {"specs": out_specs, "items": [it.as_dict() for it in items]}


def _json_line(path: Path) -> dict:
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if line.startswith("{") and line.endswith("}"):
            try:
                return json.loads(line)
            except json.JSONDecodeError:
                continue
    raise SystemExit(f"no JSON object in {path}")


def _issues_from_list(doc: dict) -> tuple:
    res = doc.get("result", doc)
    if isinstance(res, str):
        res = json.loads(res)
    issues = res.get("issues") or []
    epic_rule = "epics" in res or any("kind" in i or "epic" in i for i in issues)
    return issues, epic_rule


def _label_ids(doc: dict) -> set:
    res = doc.get("result", doc)
    if isinstance(res, str):
        res = json.loads(res)
    return {lb.get("id") for lb in (res.get("labels") or [])}


def _epics_of_list(doc: dict) -> list:
    """The list reply's epics summary (always present, over the whole tenant)."""
    res = doc.get("result", doc)
    if isinstance(res, str):
        res = json.loads(res)
    return res.get("epics") or []


def select_epic_refs(plan: dict, list_doc: dict) -> list:
    """The epic keys to scope the read-only child list to: the epics titled
    'Spec NNN' for the NNN in this (already filtered) plan. Reading per epic
    keeps a big tenant's done set out of a single list response (it closes the
    hub socket, SPL-963/CLE-001 2026-09-30). The epics summary is the source;
    the filtered `issues` (a KIND=epic reply) is the fallback."""
    want = {s["spec"] for s in plan.get("specs", [])}
    refs: list[str] = []
    seen: set[str] = set()

    def take(title: str, key: str) -> None:
        m = EPIC_TITLE.match(title or "")
        if m and m.group(1) in want and key and key not in seen:
            seen.add(key)
            refs.append(key)

    for e in _epics_of_list(list_doc):
        take(e.get("title") or "", e.get("key") or "")
    issues, _ = _issues_from_list(list_doc)
    for i in issues:
        labels = i.get("labels") or []
        if "epic" in labels or i.get("kind") in ("epic", "feature") or not i.get("parent"):
            take(i.get("title") or "", i.get("key") or "")
    return refs


def missing_epics(plan: dict, list_doc: dict) -> list:
    """The plan spec dirs that have no 'Spec NNN - ...' epic yet, as
    (spec, heading) — what SPEC_IMPORT_CREATE_EPIC creates. Same epic->dir
    matching reconcile uses, so a dir that shares a number is judged on its own."""
    issues, _ = _issues_from_list(list_doc)
    assigned = _assign_epics(plan, issues)
    out = []
    for row in plan.get("specs", []):
        if row["dir"] not in assigned and (row.get("parsed", 0) > 0 or row.get("docs", 0) > 0):
            out.append((row["spec"], row.get("heading") or row["dir"]))
    return out


def merge_lists(paths: list) -> dict:
    """One list reply from several epic-scoped ones: the first is the base
    (it carries prefix / epics / labels / channel); the rest add their issues,
    deduped by key. Preserves the base's shape (result-wrapped or flat)."""
    base = _json_line(Path(paths[0]))
    res = base["result"] if isinstance(base.get("result"), dict) else base
    issues = res.get("issues") or []
    seen = {i.get("key") for i in issues if i.get("key")}
    for p in paths[1:]:
        more, _ = _issues_from_list(_json_line(Path(p)))
        for i in more:
            k = i.get("key")
            if k and k in seen:
                continue
            if k:
                seen.add(k)
            issues.append(i)
    res["issues"] = issues
    return base


def _assign_epics(plan: dict, issues: list) -> dict:
    """Map spec dir -> epic key. Two dirs can share a number; the epic title
    'Spec NNN - ...' goes to the dir whose heading shares its words."""
    by_num: dict[str, list] = {}
    for issue in issues:
        title = issue.get("title") or ""
        em = EPIC_TITLE.match(title)
        labels = issue.get("labels") or []
        if em and ("epic" in labels or not issue.get("parent")):
            by_num.setdefault(em.group(1), []).append(issue)
    dirs: dict[str, list] = {}
    headings = {}
    for row in plan["specs"]:
        dirs.setdefault(row["spec"], []).append(row["dir"])
        headings[row["dir"]] = row.get("heading") or row["dir"]
    assigned: dict[str, str] = {}
    for spec, dir_names in dirs.items():
        cands = by_num.get(spec) or []
        if len(dir_names) == 1 and len(cands) == 1:
            assigned[dir_names[0]] = cands[0]["key"]
            continue
        used = set()
        scored = []
        for name in dir_names:
            hw = _words(headings.get(name, ""))
            for issue in cands:
                suffix = EPIC_TITLE.sub("", issue.get("title") or "")
                scored.append((len(hw & _words(suffix)), name, issue["key"]))
        scored.sort(reverse=True)
        for score, name, key in scored:
            if score <= 0 or name in assigned or key in used:
                continue
            assigned[name] = key
            used.add(key)
    by_key = {i.get("key"): i for i in issues}
    for row in plan["specs"]:
        if row["dir"] in assigned or not row.get("pinned"):
            continue
        issue = by_key.get(row["pinned"])
        if not issue:
            continue
        labels = issue.get("labels") or []
        if "epic" in labels or issue.get("kind") == "epic":
            assigned[row["dir"]] = row["pinned"]
    return assigned


def reconcile(plan: dict, list_doc: dict, desc_dir: Path) -> dict:
    issues, epic_rule = _issues_from_list(list_doc)
    epics = _assign_epics(plan, issues)
    by_prefix: dict[tuple, dict] = {}
    for issue in issues:
        bm = BRACKET.match(issue.get("title") or "")
        if bm:
            by_prefix[(bm.group(1), bm.group(2))] = issue
    labels_have = _label_ids(list_doc)
    desc_dir.mkdir(parents=True, exist_ok=True)
    ops = []
    known = {}
    rows = {s["dir"]: dict(s, create=0, update=0, unchanged=0, missing_epic=False, epic="") for s in plan["specs"]}
    missing = []
    # Flag a plan spec that has task rows (or docs) but no 'Spec NNN' epic, in
    # spec order, so the report and SPEC_IMPORT_CREATE_EPIC agree. A spec with
    # nothing to file needs no epic, so it is never MISSING nor auto-created.
    for s in plan["specs"]:
        d = s["dir"]
        rows[d]["epic"] = epics.get(d) or ""
        if d not in epics and (s.get("parsed", 0) > 0 or s.get("docs", 0) > 0):
            rows[d]["missing_epic"] = True
            if d not in missing:
                missing.append(d)
    for item in plan["items"]:
        spec, tid = item["spec"], item["id"]
        directory = item["dir"]
        row = rows[directory]
        epic = epics.get(directory)
        row["epic"] = epic or ""
        if not epic:
            row["missing_epic"] = True
            if directory not in missing:
                missing.append(directory)
            continue
        # A hub that already enforces "parent is an epic" refuses a subtask
        # (bad_epic). Leave those for the 3-level model; do not file them as
        # extra level-2 issues.
        if item["kind"] == "subtask" and epic_rule:
            row["deferred"] = row.get("deferred", 0) + 1
            continue
        existing = by_prefix.get((spec, tid))
        parent_key = ""
        parent_item = ""
        if item["kind"] == "subtask" and not epic_rule:
            parent_item = f"{directory}/{item['parent_id']}"
            parent_existing = by_prefix.get((spec, item["parent_id"]))
            parent_key = (parent_existing or {}).get("key") or ""
        else:
            parent_key = epic
        safe = re.sub(r"[^A-Za-z0-9._-]", "_", f"{spec}-{tid}")
        path = desc_dir / f"{safe}.md"
        path.write_text(item["description"], encoding="utf-8")
        want_labels = item["labels"]
        if existing:
            known[item["key"]] = existing["key"]
            changes = []
            if (existing.get("title") or "") != item["title"]:
                changes.append("title")
            if (existing.get("status") or "") != item["status"]:
                changes.append("status")
            if (existing.get("description") or "").strip() != item["description"].strip():
                changes.append("description")
            have = set(existing.get("labels") or [])
            if not set(want_labels) <= have:
                changes.append("labels")
            if parent_key and (existing.get("parent") or "") != parent_key:
                changes.append("parent")
            action = "update" if changes else "skip"
        else:
            changes = ["create"]
            action = "create"
        if action == "create":
            row["create"] += 1
        elif action == "update":
            row["update"] += 1
        else:
            row["unchanged"] += 1
        ops.append(
            {
                "action": action,
                "item": item["key"],
                "spec": spec,
                "id": tid,
                "kind": item["kind"],
                "title": item["title"],
                "status": item["status"],
                "labels": want_labels,
                "description_path": str(path),
                "parent_key": parent_key,
                "parent_item": parent_item,
                "ref": (existing or {}).get("key") or "",
                "changes": changes,
            }
        )
    # --docs: the epic's description is the index of its documents. Only the
    # description is written; the epic's title, status and labels stay the owner's.
    by_key = {i.get("key"): i for i in issues}
    for s in plan["specs"]:
        want = s.get("epic_description")
        epic = epics.get(s["dir"])
        if not want or not epic:
            continue
        have = (by_key.get(epic) or {}).get("description") or ""
        row = rows[s["dir"]]
        path = desc_dir / f"epic-{re.sub(r'[^A-Za-z0-9._-]', '_', s['dir'])}.md"
        path.write_text(want, encoding="utf-8")
        if have.strip() == want.strip():
            row["unchanged"] += 1
            action = "skip"
        else:
            row["update"] += 1
            action = "update"
        ops.append(
            {
                "action": action,
                "item": f"{s['dir']}/epic",
                "spec": s["spec"],
                "id": "epic",
                "kind": "epic",
                "title": (by_key.get(epic) or {}).get("title") or "",
                "status": "",
                "labels": [],
                "description_path": str(path),
                "parent_key": "",
                "parent_item": "",
                "ref": epic,
                "changes": ["description"] if action == "update" else [],
            }
        )
    samples = []
    for op in ops:
        if op["kind"] == "task" and op["title"] not in samples:
            samples.append(op["title"])
        if len(samples) == 5:
            break
    # Every label a non-skip op will write and the catalogue lacks — task / bug /
    # subtask AND any SPEC_IMPORT_LABELS tag (e.g. security). First-seen order.
    needed = []
    for op in ops:
        if op["action"] == "skip":
            continue
        for name in op["labels"]:
            if name not in labels_have and name not in needed:
                needed.append(name)
    kept = [r for r in rows.values() if not r["missing_epic"]]
    totals = {
        "parsed": sum(r["parsed"] for r in kept),
        "t_parsed": sum(r["t_parsed"] for r in kept),
        "create": sum(r["create"] for r in rows.values()),
        "update": sum(r["update"] for r in rows.values()),
        "unchanged": sum(r["unchanged"] for r in rows.values()),
        "subtasks": sum(r["subtasks"] for r in kept),
        "docs": sum(r.get("docs", 0) for r in kept),
    }
    return {
        "epic_rule": epic_rule,
        "epics": epics,
        "missing_epics": missing,
        "needed_labels": needed,
        "known_keys": known,
        "rows": [rows[s["dir"]] for s in plan["specs"]],
        "samples": samples,
        "totals": totals,
        "ops": ops,
    }


def report_md(doc: dict) -> str:
    lines = [
        "| spec | parsed | T parsed | subtasks | docs | create | update | unchanged | epic |",
        "|---|---:|---:|---:|---:|---:|---:|---:|---|",
    ]
    for row in doc.get("rows") or []:
        epic = row.get("epic") or ("MISSING" if row.get("missing_epic") else "")
        lines.append(
            f"| {row['spec']} | {row.get('parsed', 0)} | {row.get('t_parsed', 0)} | {row.get('subtasks', 0)} "
            f"| {row.get('docs', 0)} | {row.get('create', row.get('parsed', 0))} | {row.get('update', 0)} "
            f"| {row.get('unchanged', 0)} | {epic} |"
        )
    t = doc.get("totals") or {}
    lines.append(
        f"| total | {t.get('parsed', 0)} | {t.get('t_parsed', 0)} | {t.get('subtasks', 0)} | {t.get('docs', 0)} "
        f"| {t.get('create', 0)} | {t.get('update', 0)} | {t.get('unchanged', 0)} | |"
    )
    lines.append("")
    lines.append("Sample titles:")
    for s in doc.get("samples") or []:
        lines.append(f"- {s}")
    if doc.get("missing_epics"):
        rows_by_dir = {r.get("dir"): r for r in (doc.get("rows") or [])}
        lines.append("")
        lines.append("No epic titled 'Spec NNN' for: " + ", ".join(doc["missing_epics"]))
        lines.append("Create it first (then re-run), or re-run with SPEC_IMPORT_CREATE_EPIC=1:")
        for d in doc["missing_epics"]:
            r = rows_by_dir.get(d, {})
            spec = r.get("spec") or d[:3]
            heading = r.get("heading") or d
            lines.append(f'- ISSUE_KIND=epic ISSUE_TITLE="Spec {spec} - {heading}" ./run -a do_spl_issue_create')
    lines.append("")
    if doc.get("epic_rule"):
        lines.append("Hub list carries the epic rule: every filed parent is the spec epic. Subtasks are deferred until a task can be a parent.")
    else:
        lines.append("Hub list has no epic rule yet: a task's parent is its spec epic; a subtask's parent is the task issue.")
    lines.append("Check: issues titled '[NNN T' under each epic equal T parsed. A second run creates 0.")
    return "\n".join(lines) + "\n"


def offline_doc(plan: dict) -> dict:
    rows = []
    for s in plan["specs"]:
        rows.append({**s, "create": s["parsed"] + s.get("docs", 0), "update": 0, "unchanged": 0, "missing_epic": False})
    samples = []
    for item in plan["items"]:
        if item["kind"] == "task":
            samples.append(item["title"])
        if len(samples) == 5:
            break
    return {
        "epic_rule": False,
        "epics": {},
        "missing_epics": [],
        "rows": rows,
        "samples": samples,
        "totals": {
            "parsed": sum(s["parsed"] for s in plan["specs"]),
            "t_parsed": sum(s["t_parsed"] for s in plan["specs"]),
            "docs": sum(s.get("docs", 0) for s in plan["specs"]),
            "create": len(plan["items"]),
            "update": 0,
            "unchanged": 0,
            "subtasks": sum(s["subtasks"] for s in plan["specs"]),
        },
        "ops": [],
    }


def filter_specs(doc: dict, only: str) -> dict:
    """Keep only the specs whose number is in the comma list `only` (NNN,NNN).
    The one place SPEC_IMPORT_SPECS is honoured, so offline and live agree."""
    want = {p for p in only.replace(" ", "").split(",") if p}
    if not want:
        return doc
    doc["specs"] = [s for s in doc["specs"] if s["spec"] in want]
    doc["items"] = [i for i in doc["items"] if i["spec"] in want]
    return doc


def add_labels(doc: dict, extra: str) -> dict:
    """Append the SPEC_IMPORT_LABELS (comma list) to every item, deduped and
    order-preserving. Done in the plan so reconcile's needed_labels, the label
    catalogue and the create call all carry the tag, and a re-run backfills it."""
    tags = [t for t in (x.strip() for x in extra.split(",")) if t]
    if not tags:
        return doc
    for item in doc["items"]:
        for t in tags:
            if t not in item["labels"]:
                item["labels"].append(t)
    return doc


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="parse git-spec tasks into issue records")
    sub = p.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("parse")
    a.add_argument("--specs", type=Path, required=True)
    a.add_argument("--only", default="")
    a.add_argument("--extra-labels", default="")
    a.add_argument("--docs", action="store_true")
    a.add_argument("--redact", default="")
    a.add_argument("--out", type=Path)
    b = sub.add_parser("reconcile")
    b.add_argument("--plan", type=Path, required=True)
    b.add_argument("--list", type=Path, required=True)
    b.add_argument("--desc", type=Path, required=True)
    b.add_argument("--out", type=Path, required=True)
    c = sub.add_parser("report")
    c.add_argument("--specs", type=Path)
    c.add_argument("--only", default="")
    c.add_argument("--docs", action="store_true")
    c.add_argument("--redact", default="")
    c.add_argument("--ops", type=Path)
    c.add_argument("--out", type=Path)
    e = sub.add_parser("epics")
    e.add_argument("--plan", type=Path, required=True)
    e.add_argument("--list", type=Path, required=True)
    g = sub.add_parser("mergelists")
    g.add_argument("--out", type=Path, required=True)
    g.add_argument("lists", nargs="+")
    m = sub.add_parser("missingepics")
    m.add_argument("--plan", type=Path, required=True)
    m.add_argument("--list", type=Path, required=True)
    args = p.parse_args(argv)
    REDACT[:] = [w for w in (x.strip() for x in getattr(args, "redact", "").split(",")) if w]
    if args.cmd == "missingepics":
        plan = json.loads(args.plan.read_text(encoding="utf-8"))
        listed = _json_line(args.list)
        for spec, heading in missing_epics(plan, listed):
            print(f"{spec}\t{heading}")
        return 0
    if args.cmd == "epics":
        plan = json.loads(args.plan.read_text(encoding="utf-8"))
        listed = _json_line(args.list)
        for ref in select_epic_refs(plan, listed):
            print(ref)
        return 0
    if args.cmd == "mergelists":
        merged = merge_lists(args.lists)
        args.out.write_text(json.dumps(merged, ensure_ascii=False), encoding="utf-8")
        return 0
    if args.cmd == "parse":
        doc = add_labels(filter_specs(parse_tree(args.specs, args.docs), args.only), args.extra_labels)
        text = json.dumps(doc, ensure_ascii=False)
        if args.out:
            args.out.write_text(text, encoding="utf-8")
        else:
            print(text)
        return 0
    if args.cmd == "reconcile":
        plan = json.loads(args.plan.read_text(encoding="utf-8"))
        listed = _json_line(args.list)
        doc = reconcile(plan, listed, args.desc)
        args.out.write_text(json.dumps(doc, ensure_ascii=False), encoding="utf-8")
        return 0
    if args.specs:
        doc = offline_doc(filter_specs(parse_tree(args.specs, args.docs), args.only))
    else:
        doc = json.loads(args.ops.read_text(encoding="utf-8"))
    text = report_md(doc)
    if args.out:
        args.out.write_text(text, encoding="utf-8")
    sys.stdout.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
