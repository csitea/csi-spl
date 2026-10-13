#!/usr/bin/env python3
"""Decide which imported spec issues a tasks.md reconcile may close.

The match is the importer's, not a second one: spec-import-issues.py
BRACKET (``[NNN <id>]``) plus that module's CHECK / NEST checkbox
regexes and its ``{parent}.sN`` subtask ids. A task is closed only when
its checkbox is ``x`` and the issue is still open. An unticked task whose
issue is done, a missing task, and anything that was not imported from a
tasks.md are reported and never written.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

OPEN = {"eval", "todo", "wip", "blocked", "onhold", "qas"}
COLS = ("spec", "task", "issue", "action", "why", "status", "line")


def _importer():
    path = Path(__file__).resolve().parent / "spec-import-issues.py"
    spec = importlib.util.spec_from_file_location("spec_import_issues", path)
    if spec is None or spec.loader is None:
        raise SystemExit(f"cannot load the importer: {path}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_doc(path: Path, mod) -> dict:
    text = path.read_text(encoding="utf-8")
    try:
        doc = json.loads(text)
        if isinstance(doc, dict):
            return doc
    except json.JSONDecodeError:
        pass
    return mod._json_line(path)


def task_id_shape(mod, tid: str) -> bool:
    """An id the importer would file from a tasks.md line, including ``.sN``."""
    return re.fullmatch(rf"(?:{mod.ID_RE})(?:\.s\d+)?", tid) is not None


def checkbox_lines(text: str, mod) -> dict:
    """tid -> (1-based line, box). Fence skipping matches parse_tasks.

    A nested line with no id of its own is ``{parent}.sN``, the same shape
    ``_checklist`` / ``_heading`` emit. The last checkbox for an id wins,
    which is the importer's replace-the-same-id rule.
    """
    found: dict[str, tuple[int, str]] = {}
    fence = False
    parent = ""
    sub_n = 0
    for n, line in enumerate(text.splitlines(), 1):
        if line.lstrip().startswith("```"):
            fence = not fence
            continue
        if fence:
            continue
        top = mod.CHECK.match(line)
        if top:
            parent = top.group(2)
            sub_n = 0
            found[parent] = (n, top.group(1))
            continue
        head = mod.HEAD.match(line)
        if head:
            parent = head.group(2)
            sub_n = 0
            continue
        nest = mod.NEST.match(line)
        if nest and parent:
            sub_n += 1
            sid = nest.group(3) or f"{parent}.s{sub_n}"
            found[sid] = (n, nest.group(2))
            continue
        if line.strip() and not line[0].isspace():
            parent = ""
            sub_n = 0
    return found


def _decide(box: str, parsed_status: str, issue_status: str) -> tuple[str, str]:
    if box in ("x", "X"):
        if issue_status in OPEN:
            return "close", "ticked-open"
        if issue_status == "done":
            return "aligned", "ticked-done"
        return "report", "ticked-not-open"
    if box == " ":
        if issue_status == "done":
            return "report", "unticked-done"
        if issue_status in OPEN:
            return "aligned", "unticked-open"
        return "report", "unticked-not-open"
    if box == "~":
        if issue_status == "done":
            return "report", "partial-done"
        return "aligned", "partial-open"
    if parsed_status == "done" and issue_status in OPEN:
        return "report", "marked-done-open"
    if parsed_status != "done" and issue_status == "done":
        return "report", "unmarked-done"
    if issue_status in OPEN or issue_status == "done":
        return "aligned", "no-box"
    return "report", "no-box-other"


def reconcile(plan: dict, list_doc: dict, specs: Path, sha: str, mod) -> dict:
    issues, _epic_rule = mod._issues_from_list(list_doc)
    items = {}
    for item in plan.get("items") or []:
        items[(item["spec"], item["id"])] = item
    boxes: dict[tuple, tuple] = {}
    specs_with: dict[str, str] = {}
    for row in plan.get("specs") or []:
        directory = specs / row["dir"]
        tasks = directory / "tasks.md"
        if not tasks.is_file():
            continue
        specs_with[row["spec"]] = row["dir"]
        for tid, (line, box) in checkbox_lines(
            tasks.read_text(encoding="utf-8"), mod
        ).items():
            boxes[(row["spec"], tid)] = (row["dir"], line, box)
    rows = []
    not_imported = 0
    for issue in issues:
        title = issue.get("title") or ""
        mark = mod.BRACKET.match(title)
        if not mark:
            not_imported += 1
            continue
        spec, tid = mark.group(1), mark.group(2)
        if spec not in specs_with or tid.startswith("doc-"):
            not_imported += 1
            continue
        key = issue.get("key") or ""
        status = issue.get("status") or ""
        item = items.get((spec, tid))
        if item is None:
            if not task_id_shape(mod, tid):
                not_imported += 1
                continue
            rows.append(
                {
                    "spec": specs_with[spec],
                    "task": tid,
                    "issue": key,
                    "action": "gone",
                    "why": "task-gone",
                    "status": status,
                    "line": "-",
                    "comment": "",
                }
            )
            continue
        directory, line, box = boxes.get(
            (spec, tid), (item.get("dir") or specs_with[spec], 0, "")
        )
        action, why = _decide(box, item.get("status") or "", status)
        if action == "close" and line <= 0:
            action, why = "report", "ticked-no-line"
        comment = ""
        if action == "close":
            comment = (
                f"closed by tasks.md reconcile ({directory}/tasks.md:{line}, {sha})"
            )
        rows.append(
            {
                "spec": directory,
                "task": tid,
                "issue": key,
                "action": action,
                "why": why,
                "status": status,
                "line": str(line) if line else "-",
                "comment": comment,
            }
        )
    rows.sort(key=lambda r: (r["spec"], r["task"], r["issue"]))
    counts = {"close": 0, "report": 0, "gone": 0, "aligned": 0}
    for row in rows:
        counts[row["action"]] = counts.get(row["action"], 0) + 1
    counts["not_imported"] = not_imported
    return {"sha": sha, "counts": counts, "rows": rows}


def write_tsv(path: Path, rows: list, cols: tuple) -> None:
    lines = ["\t".join(cols)]
    for row in rows:
        lines.append("\t".join(str(row.get(c, "")).replace("\t", " ") for c in cols))
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="tasks.md reconcile plan")
    p.add_argument("--plan", type=Path, required=True)
    p.add_argument("--list", type=Path, required=True)
    p.add_argument("--specs", type=Path, required=True)
    p.add_argument("--sha", required=True)
    p.add_argument("--table", type=Path, required=True)
    p.add_argument("--close", type=Path, required=True)
    args = p.parse_args(argv)
    if not re.fullmatch(r"[A-Za-z0-9._-]+", args.sha):
        print(f"sha must be one token, got {args.sha!r}", file=sys.stderr)
        return 1
    mod = _importer()
    plan = json.loads(args.plan.read_text(encoding="utf-8"))
    listed = load_doc(args.list, mod)
    doc = reconcile(plan, listed, args.specs, args.sha, mod)
    write_tsv(args.table, doc["rows"], COLS)
    closing = [r for r in doc["rows"] if r["action"] == "close"]
    write_tsv(
        args.close,
        closing,
        ("issue", "status", "spec", "task", "line", "comment"),
    )
    c = doc["counts"]
    print(
        "COUNTS close={close} report={report} gone={gone} "
        "aligned={aligned} not_imported={not_imported}".format(**c)
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
