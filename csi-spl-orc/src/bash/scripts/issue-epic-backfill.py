#!/usr/bin/env python3
"""Plan the epic of every orphan issue, for do_spl_issue_epic_backfill (SPL-2354).

Owner HUM-10, t1 7a98c2d1 (msg 52da8fbb): "Go scan all of the issues and
create needed new epics: the whole Jira part of our application should look
consistent." No issue without an epic (spec 135).

An orphan is a live level-2 issue with no epic and no parent. Its epic, in
this order:
  spec      its description names a spec folder <doc>/specs/NNN-... (the
            restart card's "- spec:" line first, else the first mention)
            and that spec has an epic: that epic.
  spec-new  the spec has no epic: ONE new epic per spec, titled from the
            spec's own heading, "Spec NNN - <heading>" (the title
            do_spl_spec_import_issues matches).
  area      no spec: an "Area: <name> - issues with no spec" epic. The area
            is the title's scope prefix "(orc, ...)", else the issue's kind of
            record (unanswered blocker, owner question), else the repo dir
            its text names most (csi-spl-api, -wui, -orc, -iac, -cnf, -doc),
            else a round (refactoring, test, SDLC ...) or a review panel seat
            by its title, else "other". A spec is never guessed.

A link that leaves an open epic with no open issue closes AND archives it
(the hub's SPL-1729 auto-close): an existing open epic that gets only closed
issues, or one whose last open issue closed after the plan. The apply then
restores the epic from the archive (its issues come back with it, statuses
kept) and links the rest; the epic stays closed. The plan counts these.
A new epic whose planned issues are all closed is created closed (done when
any is done, else diss), so a closed issue linked to it closes nothing.
Within an epic, open issues are linked before closed ones.

  plan    --list L --specs DIR --out-dir D  writes D/epics.tsv, D/links.tsv
          and prints the summary.
  verify  --list L --specs DIR [--landed F]...  exit 1 when an orphan is
          left, two live epics share a title (a second epic for one spec), or
          a link an apply wrote (F: its tried.tsv, "<issue> TAB <epic>") did
          not land: the issue is not live under that epic.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from pathlib import Path

CLOSED = ("done", "diss")
OPEN_FIRST = {"wip": 0, "qas": 0, "blocked": 1, "onhold": 1, "todo": 2, "eval": 3}
COMPONENTS = ("api", "wui", "orc", "iac", "cnf", "doc")
ALIASES = {
    "hub": "api",
    "go": "api",
    "cli": "api",
    "web": "wui",
    "ui": "wui",
    "tf": "iac",
    "infra": "iac",
    "docs": "doc",
    "spec": "doc",
    "specs": "doc",
}
AREA_NAMES = {
    "api": "hub API and box CLI (csi-spl-api)",
    "wui": "web UI (csi-spl-wui)",
    "orc": "orchestration and agents (csi-spl-orc)",
    "iac": "infrastructure (csi-spl-iac)",
    "cnf": "configuration (csi-spl-cnf)",
    "doc": "documentation (csi-spl-doc)",
    "blockers": "unanswered blockers",
    "answers": "owner questions and answers",
    "rounds": "refactoring, test, SDLC and hygiene rounds",
    "panels": "review panels and seats",
    "other": "other work",
}
SCOPE = re.compile(r"^[a-z]+\(([A-Za-z0-9_-]+)\s*[,)]")
CARD_SPEC = re.compile(r"^\s*-\s*spec:\s*(\S+)", re.M | re.I)
# a csi-spl-doc/specs/... path names a spec, not documentation work
COMPONENT = re.compile(r"\bcsi-spl-(api|wui|orc|iac|cnf|doc)\b(?!/specs/)")
WUI_WORD = re.compile(r"\b(?:WUI|web UI)\b")
ROUND = re.compile(
    r"\b(?:refactor(?:ing)?|test|sdlc|security|perf|hygiene)\s+round\b", re.I
)
PANEL = re.compile(
    r"\b(?:panel|review)\s+seat\b|\bseat\s+s\d{3}|\bpanel\b.*\bseat\b", re.I
)
HEAD_NUM = re.compile(r"^(?:Spec\s+)?\d{3}\s*[:.-]?\s*", re.I)
SPEC_NUM = re.compile(r"^(\d{3})-")


def _import_helpers():
    path = Path(__file__).with_name("spec-import-issues.py")
    spec = importlib.util.spec_from_file_location("spec_import_issues", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# The spec heading and the epic <-> spec dir match of do_spl_spec_import_issues.
SII = _import_helpers()


def one_line(text) -> str:
    return " ".join(str(text or "").split())


def load_rows(path: str) -> list:
    doc = json.load(open(path, encoding="utf-8"))
    res = doc.get("result") if isinstance(doc, dict) else None
    if isinstance(res, str):
        res = json.loads(res)
    if not isinstance(res, dict) or not isinstance(res.get("issues"), list):
        raise SystemExit(f"FATAL no issue list in {path}")
    return [i for i in res["issues"] if isinstance(i, dict) and i.get("key")]


def is_epic(row: dict) -> bool:
    return row.get("kind") in ("epic", "feature") or row.get("level") == 1


def is_orphan(row: dict) -> bool:
    return (
        not is_epic(row)
        and row.get("level", 2) == 2
        and not row.get("epic")
        and not row.get("parent")
    )


def spec_tree(specs: Path) -> dict:
    """spec dir name -> its plan row {spec, dir, heading, pinned}."""
    out = {}
    if specs.is_dir():
        for d in sorted(p for p in specs.iterdir() if p.is_dir()):
            m = SPEC_NUM.match(d.name)
            if m:
                out[d.name] = {
                    "spec": m.group(1),
                    "dir": d.name,
                    "heading": SII._heading_of(d),
                    "pinned": SII._pinned_epic(d),
                }
    return out


def spec_of(desc: str, root: str, tree: dict) -> tuple:
    """(dir, note): the spec folder the description names, or ("", why)."""
    pat = re.compile(re.escape(root) + r"/(\d{3}-[A-Za-z0-9_-]+)")
    card = CARD_SPEC.search(desc or "")
    if card and card.group(1).strip("`,.;:").lower() in ("none", "-", "n/a"):
        return "", ""
    hay = card.group(1) if card and pat.search(card.group(1)) else (desc or "")
    named = [m.group(1) for m in pat.finditer(hay)]
    for d in named:
        if d in tree:
            return d, ""
    return "", (f"names {root}/{named[0]}, not in the spec tree" if named else "")


def area_of(row: dict) -> str:
    m = SCOPE.match(row.get("title") or "")
    if m:
        a = ALIASES.get(m.group(1).lower(), m.group(1).lower())
        if a in COMPONENTS:
            return a
    labels = set(row.get("labels") or [])
    desc = row.get("description") or ""
    if "blocker" in labels or desc.lstrip().startswith("Unanswered blocker"):
        return "blockers"
    if labels & {"answer", "needs-owner"}:
        return "answers"
    title = row.get("title") or ""
    if ROUND.search(title):
        return "rounds"
    if PANEL.search(title):
        return "panels"
    hits = {}
    for c in COMPONENT.findall(title + "\n" + desc):
        hits[c] = hits.get(c, 0) + 1
    if not hits and WUI_WORD.search(title):
        hits["wui"] = 1
    if hits:
        return max(COMPONENTS, key=lambda c: (hits.get(c, 0), -COMPONENTS.index(c)))
    return "other"


def spec_title(row: dict) -> str:
    """'Spec NNN - <heading>', the heading without a repeated 'Spec NNN:' / 'NNN:'."""
    head = (
        HEAD_NUM.sub("", row["heading"])
        if row["heading"][:3] == row["spec"]
        or row["heading"].lower().startswith("spec " + row["spec"])
        else row["heading"]
    )
    return one_line(f"Spec {row['spec']} - {head or row['heading']}")[:255]


def area_title(area: str) -> str:
    return f"Area: {AREA_NAMES[area]} - issues with no spec"


def discussion_of(row: dict) -> str:
    """The topic a new epic links: the first issue's own discussion."""
    for d in row.get("discussions") or []:
        if isinstance(d, dict) and d.get("task_id"):
            return d["task_id"]
    m = re.search(r"/t/([0-9a-fA-F-]{8,36})", row.get("description") or "")
    return m.group(1) if m else ""


def num(key) -> int:
    try:
        return int(str(key).rsplit("-", 1)[1])
    except (IndexError, ValueError):
        return 0


def _groups(rows: list, tree: dict, root: str) -> tuple:
    groups, notes = {}, []
    for r in sorted((r for r in rows if is_orphan(r)), key=lambda r: num(r["key"])):
        d, note = spec_of(r.get("description") or "", root, tree)
        if note:
            notes.append((r["key"], note))
        if d:
            g = groups.setdefault(
                "spec:" + d, {"label": d, "rows": [], "title": spec_title(tree[d])}
            )
        else:
            a = area_of(r)
            g = groups.setdefault(
                "area:" + a, {"label": a, "title": area_title(a), "rows": []}
            )
        g["rows"].append(r)
    return groups, notes


def plan(rows: list, tree: dict, root: str) -> dict:
    epics = sorted(
        (r for r in rows if is_epic(r) and not r.get("parent")),
        key=lambda e: num(e["key"]),
    )
    by_title = {}
    for e in epics:
        by_title.setdefault(one_line(e.get("title")), e["key"])
    status = {r["key"]: r.get("status") for r in rows}
    open_kids = {}
    for r in rows:
        if r.get("epic") and r.get("status") not in CLOSED:
            open_kids[r["epic"]] = open_kids.get(r["epic"], 0) + 1
    groups, notes = _groups(rows, tree, root)
    named = [g["label"] for k, g in groups.items() if k.startswith("spec:")]
    assigned = (
        SII._assign_epics({"specs": [tree[d] for d in named]}, epics) if named else {}
    )
    out = {
        "epics": [],
        "links": [],
        "closes": [],
        "summary": [],
        "notes": notes,
        "orphans": sum(len(g["rows"]) for g in groups.values()),
        "areas": {
            g["label"]: [r["key"] for r in g["rows"]]
            for k, g in groups.items()
            if k.startswith("area:")
        },
    }
    for gid in sorted(groups, key=lambda g: (g.startswith("area:"), g)):
        g, is_spec = groups[gid], gid.startswith("spec:")
        target = assigned.get(g["label"]) if is_spec else by_title.get(g["title"])
        rws = sorted(
            g["rows"],
            key=lambda r: (
                r.get("status") in CLOSED,
                OPEN_FIRST.get(r.get("status"), 4),
                num(r["key"]),
            ),
        )
        all_closed = all(r.get("status") in CLOSED for r in rws)
        if target:
            rule = "spec" if is_spec else "area"
            if (
                status.get(target) not in CLOSED
                and not open_kids.get(target)
                and all_closed
            ):
                out["closes"].append(target)
        else:
            rule = "spec-new" if is_spec else "area-new"
            target = f"new:{len(out['epics']) + 1}"
            st = (
                ("done" if any(r.get("status") == "done" for r in rws) else "diss")
                if all_closed
                else "wip"
            )
            what = (
                f"spec folder {root}/{g['label']}"
                if is_spec
                else f"the area '{AREA_NAMES[g['label']]}'"
            )
            disc = discussion_of(rws[0])
            desc = (
                f"Epic of the issues of {what}, filed by do_spl_issue_epic_backfill (SPL-2354): "
                f"every issue has an epic (spec 135). First issue: {rws[0]['key']}."
            )
            if disc:
                desc += f" Source: /t/{disc}"
            out["epics"].append([target, st, disc, g["title"], desc])
        for r in rws:
            out["links"].append(
                [r["key"], r.get("status") or "", target, rule, g["label"]]
            )
        out["summary"].append((target, rule, len(rws), g["title"]))
    return out


def write_tsv(path: Path, rows: list) -> None:
    with path.open("w", encoding="utf-8") as f:
        for r in rows:
            f.write("\t".join(one_line(c) for c in r) + "\n")


def cmd_plan(a) -> int:
    p = plan(load_rows(a.list), spec_tree(Path(a.specs)), a.root)
    out = Path(a.out_dir)
    write_tsv(out / "epics.tsv", p["epics"])
    write_tsv(out / "links.tsv", p["links"])
    t = a.tenant
    print(
        f"workspace {t}: {p['orphans']} orphan issues, {len(p['epics'])} epics to create, "
        f"{len(p['links'])} links, {len(p['closes'])} epics close on their first link"
    )
    if p["summary"]:
        print("| workspace | epic | rule | issues | title |")
        print("|---|---|---|---|---|")
    for target, rule, n, title in p["summary"]:
        print(f"| {t} | {target} | {rule} | {n} | {title} |")
    if p["areas"]:
        print(f"no-spec issues of {t}, by area:")
        for area, keys in sorted(p["areas"].items()):
            print(f"- {AREA_NAMES[area]} ({len(keys)}): {' '.join(keys)}")
    for key, note in p["notes"]:
        print(f"note {key}: {note} (grouped by area)")
    for key in p["closes"]:
        print(
            f"closes {key}: an open epic with no open issue gets only closed ones; "
            "the apply restores it from the archive and links the rest (it stays closed)"
        )
    return 0


def cmd_verify(a) -> int:
    rows = load_rows(a.list)
    orphans = [r["key"] for r in rows if is_orphan(r)]
    seen, dups = {}, []
    for e in sorted(
        (r for r in rows if is_epic(r) and not r.get("parent")),
        key=lambda e: num(e["key"]),
    ):
        t = one_line(e.get("title")).lower()
        if t in seen:
            dups.append(f"{seen[t]}={e['key']}")
        else:
            seen[t] = e["key"]
    live = {r["key"]: r.get("epic") or "" for r in rows}
    tried, missed = {}, []
    for f in a.landed or []:
        for line in Path(f).read_text(encoding="utf-8").splitlines():
            key, _, epic = line.partition("\t")
            if key and epic:
                tried[key] = epic
    for key, epic in sorted(tried.items(), key=lambda kv: num(kv[0])):
        if key not in live:
            missed.append(f"{key}->{epic}(not live)")
        elif live[key] != epic:
            missed.append(f"{key}->{epic}(epic {live[key] or 'none'})")
    print(
        f"workspace {a.tenant}: {len(orphans)} orphan issues, {len(dups)} duplicate epic titles, "
        f"{len(tried) - len(missed)} of {len(tried)} written links landed"
    )
    if orphans:
        print("orphans: " + " ".join(orphans))
    if dups:
        print("duplicate epics: " + " ".join(dups))
    if missed:
        print("links not landed: " + " ".join(missed))
    return 1 if orphans or dups or missed else 0


def main(argv: list) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="cmd", required=True)
    for name in ("plan", "verify"):
        s = sub.add_parser(name)
        s.add_argument("--list", required=True)
        s.add_argument("--specs", required=True)
        s.add_argument("--root", default="")
        s.add_argument("--tenant", default="")
        if name == "plan":
            s.add_argument("--out-dir", required=True)
        else:
            s.add_argument("--landed", action="append")
    a = p.parse_args(argv)
    if not a.root:
        base = Path(a.specs).resolve()
        a.root = f"{base.parent.name}/{base.name}"
    return cmd_plan(a) if a.cmd == "plan" else cmd_verify(a)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
