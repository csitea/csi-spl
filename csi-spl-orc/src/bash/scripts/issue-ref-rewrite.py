#!/usr/bin/env python3
"""issue-ref-rewrite.py - the planner of csi-spl-orc do_spl_issue_ref_rewrite.

do_spl_issue_ref_scan wrote a plan: per text field (message body, issue
title/description) the offsets of the workspace's own old keys (SPL-n) and
what each becomes (CSI-n). The owner OKed it (HUM-10, csitea topic 26a21b5a,
msg 642a2179). This reads the plan and the fields' CURRENT text, re-checks
every edit, and sorts each field into one route:

  edit      a message this desk box sent: its desk edits it (`spool edit`,
            the hub keeps the old body as a revision)
  issue     an issue title/description: `spool issue update` from a desk
  other-box a message another live desk box sent: run this on that box
  human     a message a person typed in the WUI (box-wui): only its author,
            the workspace owner or an admin can edit it, in the WUI
  no-pin    a message from a box whose pin is revoked: no box can re-sign it
  done      every key already reads the new prefix (an earlier run): skipped
  stale     the text changed since the scan (length, or a key is no longer
            at its offset): skipped, scan again
  gone      the message or issue is no longer there: skipped
  archived  an archived or deleted issue: the hub's update path finds only
            live issues (not_found), so its keys stay as they are; reported

Only the plan's offsets change: every other byte, every other key (t1's
SPL-n, the ambiguous ones) stays as it is.

stdin: JSON lines. One {"src":"meta","prefix","pins":[live box ids]} row,
then one row per field: {"src":"msg|issue","id","field","text"[,"box","from"]
[,"archived"]}; "archived" is true for an archived or deleted issue.

  issue-ref-rewrite.py --plan <file> --box <this desk box> --out <dir>

stdout: before/after per edit, then COUNT <route> <fields> <edits> lines.
<dir>/work.tsv: route src id field agent box file, one line per edit/issue
field; <dir>/<n>.txt holds that field's new text. Exit 0; 2 on bad input.
"""

import argparse, json, os, re, sys

PREFIX_RE = re.compile(r"[A-Z][A-Z0-9]{0,9}")
ROUTES = (
    "edit",
    "issue",
    "other-box",
    "human",
    "no-pin",
    "done",
    "stale",
    "gone",
    "archived",
)
WUI_BOX = "box-wui"
CTX = 30


def key_at(text, off, key):
    """True when key (OLD-n) stands at off with the WUI key boundary on both sides."""
    if text[off : off + len(key)] != key:
        return False
    before = text[off - 1] if off > 0 else ""
    after = text[off + len(key) : off + len(key) + 2]
    if before and re.match(r"[0-9A-Za-z_\-/.#@]", before):
        return False
    return not re.match(r"[0-9A-Za-z_\-/@]|\.[0-9A-Za-z]", after)


def apply(text, edits):
    """-> the text with every edit applied, from the last offset back."""
    for e in sorted(edits, key=lambda e: -e["offset"]):
        text = text[: e["offset"]] + e["new"] + text[e["offset"] + len(e["old"]) :]
    return text


def check(f, text):
    """-> 'ok', 'done' or 'stale' for plan field f against its current text."""
    if len(text) != f["text_len"]:
        return "stale"
    if all(key_at(text, e["offset"], e["old"]) for e in f["edits"]):
        return "ok"
    # An earlier run left the same length and the new key at each offset
    # (only when old and new prefix are as long, SPL/CSI).
    if all(len(e["old"]) == len(e["new"]) for e in f["edits"]) and all(
        key_at(text, e["offset"], e["new"]) for e in f["edits"]
    ):
        return "done"
    return "stale"


def route(f, row, local_box, pins):
    if row is None:
        return "gone"
    if f["src"] == "issue" and row.get("archived"):
        return "archived"
    state = check(f, row["text"])
    if state != "ok":
        return state
    if f["src"] == "issue":
        return "issue"
    box = row.get("box") or ""
    if box == WUI_BOX:
        return "human"
    if box not in pins:
        return "no-pin"
    return "edit" if box == local_box else "other-box"


def show(text, e, new_text, shift):
    a = max(0, e["offset"] - CTX)
    before = text[a : e["offset"] + len(e["old"]) + CTX]
    after = new_text[a : e["offset"] + shift + len(e["new"]) + CTX]
    return before.replace("\n", " | "), after.replace("\n", " | ")


def read_rows(fh):
    meta, rows = None, {}
    for line in fh:
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        if r.get("src") == "meta":
            meta = r
        else:
            rows[(r["src"], str(r["id"]), r["field"])] = r
    return meta, rows


def plan_ok(plan, prefix):
    if not PREFIX_RE.fullmatch(plan.get("old") or "") or plan.get("new") != prefix:
        return False
    for f in plan.get("fields") or []:
        if f.get("src") not in ("msg", "issue") or not f.get("edits"):
            return False
        for e in f["edits"]:
            n = e["old"][len(plan["old"]) + 1 :]
            if e["old"] != plan["old"] + "-" + n or e["new"] != prefix + "-" + n:
                return False
    return True


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan", required=True)
    ap.add_argument("--box", required=True)
    ap.add_argument("--out", required=True)
    a = ap.parse_args()
    plan = json.load(open(a.plan))
    meta, rows = read_rows(sys.stdin)
    if not meta or not PREFIX_RE.fullmatch(meta.get("prefix") or ""):
        print("FATAL no meta row with the workspace's prefix on stdin")
        return 2
    if not plan_ok(plan, meta["prefix"]):
        print(
            "FATAL the plan does not rewrite %s-n to the workspace's prefix %s-n (or holds a field it cannot edit)"
            % (plan.get("old"), meta["prefix"])
        )
        return 2
    pins = set(meta.get("pins") or [])
    counts = {r: [0, 0] for r in ROUTES}
    work = []
    for i, f in enumerate(plan["fields"]):
        row = rows.get((f["src"], str(f["id"]), f["field"]))
        r = route(f, row, a.box, pins)
        counts[r][0] += 1
        counts[r][1] += len(f["edits"])
        where = "%s:%s:%s" % (f["src"], f["id"], f["field"])
        if r in ("done", "stale", "gone", "archived"):
            print("SKIP %s %s (%d keys)" % (r, where, len(f["edits"])))
            continue
        text = row["text"]
        new_text = apply(text, f["edits"])
        who = "%s %s" % (row.get("box") or "-", row.get("from") or "-")
        shift = 0
        for e in sorted(f["edits"], key=lambda e: e["offset"]):
            b, n = show(text, e, new_text, shift)
            print(
                "EDIT %s %s @%d %s -> %s [%s]"
                % (r, where, e["offset"], e["old"], e["new"], who)
            )
            print("  before: %s" % b)
            print("  after:  %s" % n)
            shift += len(e["new"]) - len(e["old"])
        if r in ("edit", "issue"):
            path = os.path.join(a.out, "%d.txt" % i)
            with open(path, "w", encoding="utf-8", newline="") as fh:
                fh.write(new_text)
            work.append(
                "\t".join(
                    [
                        r,
                        f["src"],
                        str(f["id"]),
                        f["field"],
                        row.get("from") or "-",
                        row.get("box") or "-",
                        path,
                    ]
                )
            )
    with open(os.path.join(a.out, "work.tsv"), "w") as fh:
        fh.write("".join(w + "\n" for w in work))
    for r in ROUTES:
        print("COUNT %s %d %d" % (r, counts[r][0], counts[r][1]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
