#!/usr/bin/env python3
"""Read-only detector for decided/signed specs with unqueued build rows.

Lists each spec on origin/master (or a fixture specs dir) whose status header
reads decided or signed and whose open build rows have:
  - no citing non-spec-doc commit on master,
  - no queued or placed ask in the spawn queue / asks book, and
  - no live lane in the fleet lane map.
"""

import argparse
import json
import os
import re
import subprocess
from pathlib import Path

SPEC_DIR_RX = re.compile(r"^(\d{3})-[A-Za-z0-9._-]+$")
NEGATED_RX = re.compile(
    r"\b(?:not|never|not\s+yet)\s+(?:signed|decided)\b|\b(?:unsigned|undecided)\b",
    re.I,
)
MD_SPEC_LINK_RX = re.compile(r"\[[^\]]*\]\([^)]*\)\s*(?:v[\d.]+\s*)?\([^)]*\)")
STATUS_LINE_RX = re.compile(r"(?:^|[\s·*>-])status\*{0,2}\s*:", re.I)
VERSION_LINE_RX = re.compile(r"^(?:version\b|v\d+\.\d+)", re.I)
NON_ACTIVE_STATUS_RX = re.compile(
    r"status\*{0,2}\s*:\s*\*{0,2}\s*(?:draft|superseded|paused|implemented|archived)\b",
    re.I,
)
DECIDED_SIGNED_RX = re.compile(r"\b(decided|signed)\b", re.I)

BUILD_HEADING_RX = re.compile(
    r"\b(?:build\s+(?:order|rows|lanes|split|tasks)|code\s+lanes"
    r"|tasks\s+for\s+the\s+build|planned\s+build\s+rows|phased\s+build\s+tasks)\b",
    re.I,
)
EXCLUDE_HEADING_RX = re.compile(
    r"\b(?:row\s+status|status\s+table|contracts|changes\s+from|review|gaps|seams)\b",
    re.I,
)
ROW_COL_HDR_RX = re.compile(r"^(?:#|row|lane|id|task|step)$", re.I)
ROW_ID_RX = re.compile(r"^([A-Z]{1,3}\d+[a-z]?)$")
CLOSED_WORD_RX = re.compile(r"\b(?:implemented|built|done|dropped|superseded)\b", re.I)
CLOSED_START_RX = re.compile(
    r"^(?:dropped|implemented|built|done|superseded|landed)\b", re.I
)
BULLET_CLOSED_RX = re.compile(
    r"^\s*-\s+\*{0,2}([A-Z]{1,3}\d+[a-z]?)\*{0,2}\s*[:\-]\s*\*{0,2}\s*"
    r"(?:implemented|built|done|dropped|superseded)\b",
    re.I,
)


def parse_status(lines):
    """Return a short status label if the spec header reads decided or signed."""
    header = []
    for line in lines[:30]:
        if line.startswith("## "):
            break
        header.append(line)
    for idx, raw in enumerate(header):
        line = raw.strip()
        if not line:
            continue
        is_status = bool(STATUS_LINE_RX.search(line))
        is_version = bool(VERSION_LINE_RX.match(line))
        if not (is_status or (idx < 25 and is_version)):
            continue
        cleaned = MD_SPEC_LINK_RX.sub("", line)
        cleaned = NEGATED_RX.sub("", cleaned)
        if NON_ACTIVE_STATUS_RX.search(cleaned):
            continue
        m = DECIDED_SIGNED_RX.search(cleaned)
        if not m:
            continue
        word = m.group(1).lower()
        ver = re.search(r"\bv\d+(?:\.\d+)*\b", cleaned)
        return f"{word} {ver.group(0)}" if ver else word
    return None


def _strip_md(cell):
    return re.sub(r"[*`]", "", cell).strip()


def _row_closed_in_cells(cols, status_col_idx):
    c0 = _strip_md(cols[0])
    parts = c0.split(None, 1)
    if len(parts) > 1 and CLOSED_WORD_RX.search(parts[1]):
        return True
    if status_col_idx is not None and status_col_idx < len(cols):
        if CLOSED_START_RX.match(_strip_md(cols[status_col_idx])):
            return True
    for idx in (1, 2):
        if idx < len(cols) and CLOSED_START_RX.match(_strip_md(cols[idx])):
            return True
    return False


def extract_open_build_rows(text):
    """Extract open build row IDs from build tables in spec.md."""
    lines = text.splitlines()
    closed_bullets = set()
    for line in lines:
        m = BULLET_CLOSED_RX.match(line)
        if m:
            closed_bullets.add(m.group(1).upper())

    found = []
    seen = set()
    cur_heading = ""
    i = 0
    while i < len(lines):
        line = lines[i]
        if re.match(r"^#{1,4}\s+", line):
            cur_heading = line.strip()
            i += 1
            continue
        if (
            line.lstrip().startswith("|")
            and i + 1 < len(lines)
            and re.match(r"^\|\s*[-:]+", lines[i + 1].lstrip())
        ):
            hdr = [_strip_md(c) for c in line.strip().strip("|").split("|")]
            j = i + 2
            raw_rows = []
            while j < len(lines) and lines[j].lstrip().startswith("|"):
                cols = [c.strip() for c in lines[j].strip().strip("|").split("|")]
                raw_rows.append(cols)
                j += 1
            i = j
            if not hdr or not ROW_COL_HDR_RX.match(hdr[0]):
                continue
            if not BUILD_HEADING_RX.search(cur_heading) or EXCLUDE_HEADING_RX.search(
                cur_heading
            ):
                continue
            status_idx = next(
                (k for k, h in enumerate(hdr) if h.lower() == "status"), None
            )
            for cols in raw_rows:
                if not cols:
                    continue
                first = _strip_md(cols[0]).split()
                if not first:
                    continue
                m_id = ROW_ID_RX.match(first[0])
                if not m_id:
                    continue
                rid = m_id.group(1)
                key = rid.upper()
                if key in seen:
                    continue
                seen.add(key)
                if key in closed_bullets or _row_closed_in_cells(cols, status_idx):
                    continue
                found.append(rid)
            continue
        i += 1
    return found


def compile_spec_patterns(spec_num):
    num = str(int(spec_num))
    spec_rx = re.compile(
        rf"(?<![A-Za-z0-9])(?:spec[\s-]*0*{num}|s0*{num})(?![0-9])", re.I
    )
    spec_doc_subj_rx = re.compile(
        rf"^docs\((?:spec-0*{num}\b|[^)]*\):\s*spec\s+0*{num}\s+v\d)", re.I
    )
    slug_row_rx = re.compile(
        rf"(?<![A-Za-z0-9])s0*{num}[-_ ]([A-Za-z]{{1,3}}\d+[a-z]?)(?![A-Za-z0-9])",
        re.I,
    )
    return num, spec_rx, spec_doc_subj_rx, slug_row_rx


def compile_row_patterns(num, row_id):
    esc = re.escape(row_id)
    row_rx = re.compile(rf"(?<![A-Za-z0-9]){esc}(?![A-Za-z0-9])", re.I)
    paired_rx = re.compile(
        rf"(?<![A-Za-z0-9])(?:spec[\s-]*0*{num}[\s,:;/()-]*(?:v[\d.]+\s+)?"
        rf"(?:(?:build|code|plan)\s+)?(?:row|lane|task|slice)?\s*{esc}"
        rf"|s0*{num}[-_ ]{esc})(?![A-Za-z0-9])",
        re.I,
    )
    return row_rx, paired_rx


def has_citing_commit(spec_rx, spec_doc_subj_rx, row_rx, paired_rx, commits):
    for subj, body in commits:
        if spec_doc_subj_rx.match(subj):
            continue
        if spec_rx.search(subj) and row_rx.search(subj):
            return True
        if paired_rx.search(body):
            return True
    return False


def has_queued_or_placed_ask(spec_rx, slug_row_rx, row_rx, paired_rx, row_id, asks):
    want = row_id.upper()
    for ask in asks:
        state = str(ask.get("state") or "").lower()
        reason = str(ask.get("reason") or "")
        is_queued = state in ("queued", "acked", "placing")
        is_placed = state == "done" and reason.lower().startswith("placed:")
        if not (is_queued or is_placed):
            continue
        placement = str(ask.get("placement") or "")
        slug_rows = [m.group(1).upper() for m in slug_row_rx.finditer(placement)]
        if slug_rows:
            if want in slug_rows:
                return True
            continue
        text = " ".join(
            str(ask.get(k) or "") for k in ("placement", "topic", "summary")
        )
        if paired_rx.search(text):
            return True
        if spec_rx.search(text) and row_rx.search(text):
            return True
    return False


def has_live_lane(spec_rx, slug_row_rx, row_rx, paired_rx, row_id, lanes):
    want = row_id.upper()
    for lane in lanes:
        if str(lane.get("state") or "live").lower() != "live":
            continue
        branch = str(lane.get("branch") or "")
        slug_rows = [m.group(1).upper() for m in slug_row_rx.finditer(branch)]
        if want in slug_rows:
            return True
        text = " ".join(str(lane.get(k) or "") for k in ("scope", "branch", "topic"))
        if paired_rx.search(text):
            return True
        if spec_rx.search(text) and row_rx.search(text):
            return True
    return False


def load_specs_from_dir(specs_dir):
    specs = []
    root = Path(specs_dir)
    if not root.is_dir():
        return specs
    for entry in sorted(root.iterdir()):
        if not entry.is_dir():
            continue
        m = SPEC_DIR_RX.match(entry.name)
        spec_file = entry / "spec.md"
        if m and spec_file.is_file():
            specs.append(
                (m.group(1), entry.name, spec_file.read_text("utf-8", errors="replace"))
            )
    return specs


def load_specs_from_git(repo, ref):
    out = subprocess.check_output(
        [
            "git",
            "-c",
            "safe.directory=*",
            "-C",
            repo,
            "ls-tree",
            "--name-only",
            ref,
            "csi-spl-doc/specs/",
        ],
        text=True,
    )
    specs = []
    for path in sorted(out.splitlines()):
        name = os.path.basename(path)
        m = SPEC_DIR_RX.match(name)
        if not m:
            continue
        blob = f"{ref}:{path}/spec.md"
        proc = subprocess.run(
            ["git", "-c", "safe.directory=*", "-C", repo, "show", blob],
            capture_output=True,
            text=True,
            errors="replace",
        )
        if proc.returncode == 0:
            specs.append((m.group(1), name, proc.stdout))
    return specs


def load_commits(commits_file, repo, ref):
    if commits_file:
        raw = Path(commits_file).read_text("utf-8", errors="replace")
    elif repo and ref:
        raw = subprocess.check_output(
            [
                "git",
                "-c",
                "safe.directory=*",
                "-C",
                repo,
                "log",
                "-z",
                ref,
                "--format=%s%x09%b",
            ],
            text=True,
            errors="replace",
        )
    else:
        return []
    commits = []
    for rec in raw.split("\0"):
        rec = rec.lstrip("\n")
        if not rec:
            continue
        subj, _, body = rec.partition("\t")
        commits.append((subj, body))
    return commits


def load_list_json(path, keys):
    if not path:
        return []
    doc = json.loads(Path(path).read_text("utf-8"))
    if isinstance(doc, list):
        return doc
    if isinstance(doc, dict):
        for key in keys:
            val = doc.get(key)
            if isinstance(val, list):
                return val
    raise ValueError(f"expected list or object with one of {keys} in {path}")


def format_digest_line(results):
    if not results:
        return ""
    parts = []
    max_specs = 6
    max_rows = 6
    for item in results[:max_specs]:
        rows = item["unqueued"]
        shown = ", ".join(rows[:max_rows])
        if len(rows) > max_rows:
            shown += f" +{len(rows) - max_rows}"
        parts.append(f"**{item['spec']}** ({shown})")
    more = f" (+{len(results) - max_specs} more)" if len(results) > max_specs else ""
    return (
        "Unqueued decided/signed spec rows (dispatch holder): "
        + ", ".join(parts)
        + more
        + " — run `cd csi-spl-orc && ./run -a do_spl_spec_rows_unqueued`"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--specs-dir", default="")
    ap.add_argument("--repo", default="")
    ap.add_argument("--ref", default="origin/master")
    ap.add_argument("--sha", default="")
    ap.add_argument("--commits-file", default="")
    ap.add_argument("--asks-file", required=True)
    ap.add_argument("--lanes-file", required=True)
    ap.add_argument("--format", choices=("table", "json", "digest"), default="table")
    args = ap.parse_args()

    if args.specs_dir:
        specs = load_specs_from_dir(args.specs_dir)
    else:
        specs = load_specs_from_git(args.repo, args.ref)
    commits = load_commits(args.commits_file, args.repo, args.ref)
    asks = load_list_json(args.asks_file, ("asks", "queue"))
    lanes = load_list_json(args.lanes_file, ("lanes",))

    results = []
    for spec_num, spec_name, text in specs:
        status = parse_status(text.splitlines())
        if not status:
            continue
        open_rows = extract_open_build_rows(text)
        if not open_rows:
            continue
        num, spec_rx, spec_doc_subj_rx, slug_row_rx = compile_spec_patterns(spec_num)
        unqueued = []
        for rid in open_rows:
            row_rx, paired_rx = compile_row_patterns(num, rid)
            if has_citing_commit(spec_rx, spec_doc_subj_rx, row_rx, paired_rx, commits):
                continue
            if has_queued_or_placed_ask(
                spec_rx, slug_row_rx, row_rx, paired_rx, rid, asks
            ):
                continue
            if has_live_lane(spec_rx, slug_row_rx, row_rx, paired_rx, rid, lanes):
                continue
            unqueued.append(rid)
        if unqueued:
            results.append({"spec": spec_name, "status": status, "unqueued": unqueued})

    total_rows = sum(len(r["unqueued"]) for r in results)
    sha = args.sha or args.ref
    if args.format == "json":
        print(
            json.dumps(
                {
                    "ref": args.ref,
                    "sha": sha,
                    "total_specs": len(results),
                    "total_rows": total_rows,
                    "specs": results,
                }
            )
        )
    elif args.format == "digest":
        line = format_digest_line(results)
        if line:
            print(line)
    else:
        print("SPEC\tSTATUS\tCOUNT\tROWS")
        for item in results:
            print(
                f"{item['spec']}\t{item['status']}\t{len(item['unqueued'])}\t{','.join(item['unqueued'])}"
            )
        print(f"# total ref={sha} specs={len(results)} rows={total_rows}")


if __name__ == "__main__":
    main()
