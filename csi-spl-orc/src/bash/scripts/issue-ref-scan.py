#!/usr/bin/env python3
"""issue-ref-scan.py - the classifier of csi-spl-orc do_spl_issue_ref_scan.

A workspace whose issue prefix changed (csitea: SPL -> CSI, owner HUM-10,
csitea topic 26a21b5a) still carries its old keys in message, doc and issue
text. Another workspace (t1) uses the same old prefix with its own numbers,
so `SPL-44` may be either. This decides, per key, without writing anything:

  rewrite  the key is the workspace's own:
             link   inside (or the label of) an issues link on the
                    workspace's own host, or a relative /issues?issue= link
             named  the line names the workspace and no other one
             plain  n is a live issue number of the workspace, the text
                    holds no key above the workspace's range and the line
                    names no other workspace
  keep     the key is not the workspace's:
             other-link   an issues link on another host
             not-ours     n is above the workspace's counter (no such issue)
  ambiguous  listed apart, never rewritten:
             mixed        n is the workspace's, but the same text also holds
                          keys above its range (t1's), e.g. a lane table
             names-other  the line names t1, the spool-hub project /
                          workspace / tracker, or "on dev" / "in dev"
             commit       a commit scope `(area, SPL-n)` or a trailer
                          `Closes:/Refs:/Fixes: SPL-n` (commits cite t1)
             deleted      n was allocated by the workspace's counter, but
                          that issue is gone
  archived   a key that would be rewrite, in the title or description of an
             archived or deleted issue: listed apart, never in the plan (the
             hub's update path answers not_found for such an issue)

stdin: JSON lines. One {"src":"meta","tenant","prefix","last_number",
"numbers":[...]} row, then one row per text field:
{"src":"msg|issue|doc_item|doc_node","id","field","text"[,"archived"]};
"archived" is true on the field of an archived or deleted issue.

  issue-ref-scan.py --old SPL [--samples 10] [--plan <file>]

stdout: the report (counts per source and class, samples per class, every
ambiguous hit). --plan: JSON, per field the rewrite offsets, for the writer.
Exit 0; exit 2 on bad input (no meta row, bad prefix).
"""

import argparse, json, re, sys

PREFIX_RE = re.compile(r"[A-Z][A-Z0-9]{0,9}")
URL_RE = re.compile(
    r"https?://[^\s<>)\]\"'`]+"
    r"|(?<![\w/.])/(?:[a-z]{2}(?:-[A-Za-z]{2,4})?/)?issues\?issue=[^\s<>)\]\"'`]+"
)
MDLINK_RE = re.compile(r"\[([^\]\n]+)\]\(([^)\n\s]+)\)")
OTHER_NAME_RE = re.compile(
    r"(?<![\w.-])(?:t1|spool[- ]hub(?:'s)? (?:project|workspace|tracker)|(?:on|in) dev)(?![\w-])",
    re.I,
)


def key_re(old):
    """The WUI's key boundary (csi-spl-wui/src/utils/issue-key-links.mjs keyRe)."""
    return re.compile(
        r"(?<![0-9A-Za-z_\-/.#@])"
        + old
        + r"-([1-9][0-9]{0,8})(?![0-9A-Za-z_\-/@]|\.[0-9A-Za-z])"
    )


def issues_link(url, old):
    """-> (number, host or '') when url is an issues link to old-n, else None."""
    m = re.search(
        r"/issues\?(?:[^#\s]*&)?issue=" + old + r"-([1-9][0-9]{0,8})(?![0-9])", url
    )
    if not m:
        return None
    h = re.match(r"https?://([^/?#:]+)", url)
    return int(m.group(1)), (h.group(1).lower() if h else "")


def own_host(host, tenant):
    """A relative link, or a host whose first label is the workspace."""
    return host == "" or host.split(".")[0] == tenant


def line_at(text, pos):
    a = text.rfind("\n", 0, pos) + 1
    b = text.find("\n", pos)
    return text[a:] if b < 0 else text[a:b]


class Ctx:
    def __init__(self, meta, old):
        self.tenant = meta["tenant"]
        self.prefix = meta["prefix"]
        self.last = int(meta.get("last_number") or 0)
        self.numbers = set(int(n) for n in meta.get("numbers") or [])
        self.old = old
        self.krx = key_re(old)
        self.own_name = re.compile(
            r"(?<![\w.-])" + re.escape(self.tenant) + r"(?![\w-])", re.I
        )
        self.commit = re.compile(
            r"\(\s*[a-z][a-z0-9/_ -]*,\s*" + old + r"-\d+\s*\)"
            r"|(?:Closes|Refs|Fixes):\s*" + old + r"-\d+"
        )


def link_spans(text, c):
    """-> [(start, end, n, own)]: every issues link, and the label of a markdown one."""
    out = []
    for m in URL_RE.finditer(text):
        lk = issues_link(m.group(0), c.old)
        if lk:
            out.append((m.start(), m.end(), lk[0], own_host(lk[1], c.tenant)))
    for m in MDLINK_RE.finditer(text):
        lk = issues_link(m.group(2), c.old)
        if lk:
            out.append((m.start(1), m.end(1), lk[0], own_host(lk[1], c.tenant)))
    return out


def classify(text, c):
    """-> [(offset, n, class, reason)] for every old-prefix key in text."""
    hits = [(m.start(), int(m.group(1))) for m in c.krx.finditer(text)]
    if not hits:
        return []
    links = link_spans(text, c)
    commits = [(m.start(), m.end()) for m in c.commit.finditer(text)]
    mixed = any(n > c.last for _, n in hits)
    return [
        (pos, n) + decide(text, pos, n, c, (links, commits, mixed)) for pos, n in hits
    ]


def decide(text, pos, n, c, facts):
    links, commits, mixed = facts
    for a, b, ln, own in links:
        if a <= pos < b and ln == n:
            return ("rewrite", "link") if own else ("keep", "other-link")
    if n > c.last:
        return ("keep", "not-ours")
    if any(a <= pos < b for a, b in commits):
        return ("ambiguous", "commit")
    if n not in c.numbers:
        return ("ambiguous", "deleted")
    line = URL_RE.sub(" ", line_at(text, pos))
    if OTHER_NAME_RE.search(line):
        return ("ambiguous", "names-other")
    if c.own_name.search(line):
        return ("rewrite", "named")
    if mixed:
        return ("ambiguous", "mixed")
    return ("rewrite", "plain")


def snippet(text, pos, width=60):
    a, b = max(0, pos - width), min(len(text), pos + width)
    return (
        ("…" if a else "")
        + text[a:b].replace("\n", " ⏎ ")
        + ("…" if b < len(text) else "")
    )


def read_rows(stream):
    meta, rows = None, []
    for raw in stream:
        raw = raw.strip()
        if not raw.startswith("{"):
            continue
        r = json.loads(raw)
        if r.get("src") == "meta":
            meta = r
        else:
            rows.append(r)
    return meta, rows


def scan(c, rows, nsamples):
    counts, samples, ambiguous, plan = {}, {}, [], []
    for r in rows:
        text = r.get("text") or ""
        edits = []
        for pos, n, cls, why in classify(text, c):
            if cls == "rewrite" and r.get("archived"):
                cls = "archived"
            counts[(r["src"], cls)] = counts.get((r["src"], cls), 0) + 1
            item = {
                "src": r["src"],
                "id": r["id"],
                "field": r.get("field", ""),
                "offset": pos,
                "old": "%s-%d" % (c.old, n),
                "class": cls,
                "reason": why,
                "context": snippet(text, pos),
            }
            if len(samples.setdefault(cls, [])) < nsamples:
                samples[cls].append(item)
            if cls in ("ambiguous", "archived"):
                ambiguous.append(item)
            if cls == "rewrite":
                edits.append(
                    {
                        "offset": pos,
                        "old": item["old"],
                        "new": "%s-%d" % (c.prefix, n),
                        "reason": why,
                    }
                )
        if edits:
            plan.append(
                {
                    "src": r["src"],
                    "id": r["id"],
                    "field": r.get("field", ""),
                    "text_len": len(text),
                    "edits": edits,
                }
            )
    return counts, samples, ambiguous, plan


def report(c, counts, samples, ambiguous, nrows):
    print(
        "SCAN tenant=%s old=%s new=%s last_number=%d live_issues=%d fields_read=%d (read-only)"
        % (c.tenant, c.old, c.prefix, c.last, len(c.numbers), nrows)
    )
    print("COUNT source rewrite keep ambiguous archived")
    for s in sorted({s for s, _ in counts}):
        print(
            "COUNT %s %d %d %d %d"
            % (
                s,
                counts.get((s, "rewrite"), 0),
                counts.get((s, "keep"), 0),
                counts.get((s, "ambiguous"), 0),
                counts.get((s, "archived"), 0),
            )
        )
    tot = {
        k: sum(v for (_, cl), v in counts.items() if cl == k)
        for k in ("rewrite", "keep", "ambiguous", "archived")
    }
    print(
        "COUNT total %d %d %d %d"
        % (tot["rewrite"], tot["keep"], tot["ambiguous"], tot["archived"])
    )
    for cls in ("rewrite", "keep", "ambiguous", "archived"):
        for it in samples.get(cls, []):
            print(
                "SAMPLE %s %s %s %s:%s@%d %s"
                % (
                    cls,
                    it["reason"],
                    it["old"],
                    it["src"],
                    it["id"],
                    it["offset"],
                    it["context"],
                )
            )
    for it in ambiguous:
        print(
            "%s %s %s %s:%s@%d %s"
            % (
                it["class"].upper(),
                it["reason"],
                it["old"],
                it["src"],
                it["id"],
                it["offset"],
                it["context"],
            )
        )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--old", required=True)
    ap.add_argument("--samples", type=int, default=10)
    ap.add_argument("--plan", default="")
    a = ap.parse_args()
    if not PREFIX_RE.fullmatch(a.old):
        print("FATAL --old must be an issue prefix, got: %r" % a.old)
        return 2
    meta, rows = read_rows(sys.stdin)
    if not meta or not PREFIX_RE.fullmatch(meta.get("prefix") or ""):
        print("FATAL no meta row with the workspace's prefix on stdin")
        return 2
    c = Ctx(meta, a.old)
    if c.prefix == c.old:
        print(
            "FATAL workspace %s still uses prefix %s: nothing to rewrite"
            % (c.tenant, c.old)
        )
        return 2
    counts, samples, ambiguous, plan = scan(c, rows, a.samples)
    report(c, counts, samples, ambiguous, len(rows))
    if a.plan:
        with open(a.plan, "w") as f:
            json.dump(
                {"tenant": c.tenant, "old": c.old, "new": c.prefix, "fields": plan},
                f,
                ensure_ascii=False,
                indent=1,
            )
    return 0


if __name__ == "__main__":
    sys.exit(main())
