#!/usr/bin/env python3
"""The public dataset gate core (spec 091 T005, sections 5.5 and 5.6).

Run by do_spl_public_dataset_gate (src/bash/run/spl-public-dataset-gate.func.sh),
which reads the database facts (the live catalog, the RLS re-read) and passes
them here as files. This script opens no database and no network.

Input: a candidate seed file of `COPY <table> (<cols>) FROM stdin;` blocks in
Postgres text format (spec 5.7). Each class fails closed:
  C3      shape: every table is an allow-list table, every column a public
          one (or a constant the projection emits, or tenant_id), every
          constant holds its fixed value, every LIVE column of a listed table
          is classified public or withheld
  C1      workspace: no tenant_id but the cnf workspaces (--workspace a,b,..);
          tenants has exactly one row per listed workspace and no other; with
          more than one listed, every block but humans carries tenant_id (a
          row must name its workspace)
  C2      every row of the file is found by a re-read pinned by RLS alone,
          matched by (workspace, key): the re-read runs once per workspace
  MEMBER  every member is a HUM-n id, display_name = human_id, no e-mail;
          every HUM-n a message names, and every membership, is an exported
          member (Q1b)
  C4      content scan: the patterns below, gitleaks with the repo's config,
          every other workspace's id and display name as whole words (in a
          body not an id of BODY_WORD_IDS, a plain word there). A hit
          in messages.body (or in msg, the v:1 object rebuilt from it) drops
          that message and counts it by class (Q3); a hit anywhere else is
          FATAL. The scan runs again on what is left and must be clean; more
          than --drop-cap-pct of the messages dropped is FATAL
  SIZE    row counts within --size-tol-pct of the previous manifest, unless
          the allow-list version changed or there is no previous manifest

Output (section 5.6, CI logs are public): a line names the class, the table
and the row's key, never the matched text. A key that is itself the hit, or a
foreign workspace id, is shown as the row number instead.
Exit 0 = PASS (the cleaned file and the report written), 1 = FAIL (the report
written, no cleaned file), 2 = bad arguments.
"""

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import tempfile

KEYS = {
    "tenants": "tenant_id",
    "humans": "human_id",
    "tenant_memberships": "human_id",
    "channels": "channel_id",
    "messages": "msg_id",
}
HUM = re.compile(r"^HUM-[0-9]+$")
COPY = re.compile(r"^COPY ([a-z_]+) \(([a-z_, ]+)\) FROM stdin;$")
SAFE_KEY = re.compile(r"^[A-Za-z0-9._:-]{1,80}$")
BODY_COLS = ("body", "msg")
MSG_KEYS = {"v", "msg_id", "task_id", "ts", "from", "to", "kind", "body", "files"}
MSG_SAME = (
    ("msg_id", "msg_id"),
    ("task_id", "task_id"),
    ("from", "from_id"),
    ("to", "to_id"),
    ("kind", "kind"),
    ("body", "body"),
)
PATTERNS = [
    (
        "email",
        re.compile(
            r"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}"
        ),
    ),
    (
        "ipv4",
        re.compile(
            r"(?<![0-9.])(?:(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])\.){3}"
            r"(?:25[0-5]|2[0-4][0-9]|1?[0-9]?[0-9])(?![0-9.])"
        ),
    ),
    (
        "ipv6",
        re.compile(
            r"(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){7}[0-9A-Fa-f]{1,4}(?![0-9A-Fa-f:])"
            r"|(?<![0-9A-Fa-f:])(?:[0-9A-Fa-f]{1,4}:){1,6}:(?:[0-9A-Fa-f]{1,4}:){0,5}"
            r"[0-9A-Fa-f]{1,4}(?![0-9A-Fa-f:])"
        ),
    ),
    (
        "jwt",
        re.compile(r"eyJ[A-Za-z0-9_-]{8,}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}"),
    ),
    (
        "pem",
        re.compile(
            r"-----BEGIN [A-Z0-9 ]*(?:PRIVATE KEY|CERTIFICATE|PUBLIC KEY)[A-Z0-9 ]*-----"
        ),
    ),
    (
        "cloud-token",
        re.compile(
            r"\b(?:AKIA|ASIA)[0-9A-Z]{16}\b|\bAIza[0-9A-Za-z_-]{35}\b|\bya29\.[0-9A-Za-z_-]{20,}"
        ),
    ),
    (
        "slack-token",
        re.compile(
            r"\bxox[abprs]-[0-9A-Za-z-]{10,}|hooks\.slack\.com/services/[A-Za-z0-9/]+"
        ),
    ),
    (
        "github-token",
        re.compile(r"\b(?:gh[pousr]_[0-9A-Za-z]{36,}|github_pat_[0-9A-Za-z_]{40,})"),
    ),
    ("service-account", re.compile(r"iam\.gserviceaccount\.com", re.I)),
]
NAME_EDGE = r"A-Za-z0-9_-"
# workspace ids that are a plain word in message text, so not matched in a body
# (owner answer A, SPL-3671): the built-in docs workspace. Its display name, and
# the id in every other column, are still matched.
BODY_WORD_IDS = ("system",)


def unescape(v):
    """A Postgres COPY text-format field -> its value; None for \\N."""
    if v == "\\N":
        return None
    esc = {"t": "\t", "n": "\n", "r": "\r", "\\": "\\", "b": "\b", "f": "\f", "v": "\v"}
    out, i = [], 0
    while i < len(v):
        if v[i] == "\\" and i + 1 < len(v):
            out.append(esc.get(v[i + 1], v[i + 1]))
            i += 2
        else:
            out.append(v[i])
            i += 1
    return "".join(out)


def constant_ok(kind, v, r):
    """Does value v hold the allow-list constant `kind`? r is the row by column."""
    if isinstance(kind, tuple):
        return v == kind[1]
    simple = {
        "null_value": lambda: v is None,
        "empty_bytea": lambda: v in ("\\x", ""),
        "empty_string": lambda: v == "",
        "zero_bytes_32": lambda: v == "\\x" + "00" * 32,
        "human_id": lambda: v is not None and v == r.get("human_id"),
    }
    if kind in simple:
        return simple[kind]()
    if kind == "v1_object_from_public_columns":
        try:
            o = json.loads(v or "")
        except ValueError:
            return False
        return (
            isinstance(o, dict)
            and set(o) <= MSG_KEYS
            and o.get("files", []) == []
            and all(o.get(a) == r.get(b) for a, b in MSG_SAME if b in r)
        )
    return v == kind


class Gate:
    def __init__(self, a):
        self.a = a
        self.fails = []
        self.lines = []
        self.blocks = {}  # table -> {"cols": [...], "rows": [(line_no, [values])]}
        self.comments = []  # (line_no, text)
        self.names = self.name_patterns()

    def fail(self, cls, table, where):
        msg = "FATAL %s %s %s" % (cls, table, where)
        self.fails.append("%s %s" % (cls, table))
        print(msg)

    def where(self, table, n, row, col=None):
        """The row's key, or its row number when the key is the hit, the hit
        is a workspace id, or the key is not a plain id (never the text)."""
        key = KEYS.get(table)
        cols = self.blocks[table]["cols"]
        if key in cols and col not in (key, "tenant_id"):
            v = row[cols.index(key)]
            if v is not None and SAFE_KEY.match(v) and not self.hits(v):
                return "%s=%s" % (key, v)
        return "row %d" % n

    def hits(self, v, body=False):
        """The scan classes v matches (patterns and names, not gitleaks); a
        body skips the BODY_WORD_IDS ids."""
        out = [cls for cls, rx in PATTERNS if rx.search(v)]
        names = [rx for rx, word in self.names if not (body and word)]
        return out + (["other-workspace"] if any(rx.search(v) for rx in names) else [])

    def rows(self, table):
        b = self.blocks.get(table)
        return (
            []
            if b is None
            else [
                (n, row, dict(zip(b["cols"], row)))
                for n, (_, row) in enumerate(b["rows"], 1)
            ]
        )

    # --- parse -------------------------------------------------------------------
    def parse(self):
        with open(self.a.file, encoding="utf-8", errors="strict") as fh:
            self.lines = fh.read().split("\n")
        if self.lines and self.lines[-1] == "":
            self.lines.pop()
        table = None
        for i, line in enumerate(self.lines, 1):
            if table is not None:
                table = self.parse_data(table, i, line)
            elif line.startswith("--"):
                self.comments.append((i, line))
            elif line != "":
                table = self.parse_copy(i, line)
                if table == "":
                    return
        if table:
            self.fail("C3", table, "the COPY block has no end marker")

    def parse_data(self, table, i, line):
        if line == "\\.":
            return None
        vals = [unescape(v) for v in line.split("\t")]
        b = self.blocks[table]
        if len(vals) != len(b["cols"]):
            self.fail(
                "C3",
                table,
                "line %d: %d values for %d columns" % (i, len(vals), len(b["cols"])),
            )
        else:
            b["rows"].append((i, vals))
        return table

    def parse_copy(self, i, line):
        m = COPY.match(line)
        if not m:
            self.fail("C3", "-", "line %d: not a COPY block" % i)
            return None
        table = m.group(1)
        if table in self.blocks:
            self.fail("C3", table, "line %d: a second COPY into the table" % i)
            return ""
        self.blocks[table] = {
            "cols": [c.strip() for c in m.group(2).split(",")],
            "rows": [],
        }
        return table

    # --- C3 ----------------------------------------------------------------------
    def c3(self, allow, catalog):
        tables = allow.get("tables") or {}
        never = set(allow.get("never") or [])
        for t, b in self.blocks.items():
            if t in never:
                self.fail("C3", t, "a never-exported table (spec 4.2)")
            elif t not in tables:
                self.fail("C3", t, "a table outside the allow-list")
            else:
                self.c3_columns(t, b, tables[t], catalog)
                self.c3_constants(t, tables[t])
                self.c3_keys(t)
        for t, spec in tables.items():
            if t not in self.blocks:
                self.fail(
                    "C3", t, "the file has no COPY block for this allow-list table"
                )
            live = catalog.get(t)
            if live is None:
                self.fail("C3", t, "the live catalog has no such table")
                continue
            known = set(spec.get("public") or []) | set(spec.get("withheld") or [])
            for c in sorted(set(live) - known):
                self.fail(
                    "C3",
                    t,
                    "live column %s is neither public nor withheld (unclassified)" % c,
                )
            for c in sorted(known - set(live)):
                self.fail("C3", t, "allow-list column %s is not a live column" % c)

    def c3_columns(self, t, b, spec, catalog):
        ok = set(spec.get("public") or []) | set((spec.get("constants") or {}).keys())
        if "tenant_id" in (catalog.get(t) or []):
            ok.add("tenant_id")
        for c in b["cols"]:
            if c not in ok:
                self.fail(
                    "C3", t, "column %s is not a public column of the allow-list" % c
                )
        if len(set(b["cols"])) != len(b["cols"]):
            self.fail("C3", t, "a column is named twice")
        for c in spec.get("public") or []:
            if c not in b["cols"]:
                self.fail("C3", t, "public column %s is missing from the file" % c)

    def c3_keys(self, t):
        """A key twice in one table and workspace: C1 and C2 match by
        (workspace, key), so a second row with a public row's key would pass
        both with any other content."""
        key, seen = KEYS.get(t), set()
        if key is None:
            self.fail("C3", t, "the gate knows no key for this table")
            return
        for n, _, r in self.rows(t):
            k = (self.row_ws(r), r.get(key))
            if k in seen:
                self.fail("C3", t, "row %d: a key seen twice in the table" % n)
            seen.add(k)

    def c3_constants(self, t, spec):
        want = dict(spec.get("constants") or {})
        want.update({c: ("forced", k) for c, k in (spec.get("forced") or {}).items()})
        for n, row, r in self.rows(t):
            for c, kind in want.items():
                if c in r and not constant_ok(kind, r[c], r):
                    self.fail(
                        "C3",
                        t,
                        "%s: column %s does not hold its fixed value"
                        % (self.where(t, n, row, c), c),
                    )

    # --- C1 and the member rule -----------------------------------------------------
    def row_ws(self, r):
        """The workspace a row belongs to: its tenant_id, else the one listed
        workspace; None when several are listed and the row names none."""
        if "tenant_id" in r:
            return r["tenant_id"]
        listed = self.a.workspace.split(",")
        return listed[0] if len(listed) == 1 else None

    def c1(self, ws):
        listed = set(ws.split(","))
        if len(listed) > 1:
            for table, b in self.blocks.items():
                if table != "humans" and "tenant_id" not in b["cols"]:
                    self.fail(
                        "C1",
                        table,
                        "the COPY carries no tenant_id: with %d listed workspaces a row must name its own"
                        % len(listed),
                    )
        got = [r.get("tenant_id") for _, _, r in self.rows("tenants")]
        if len(got) != len(set(got)) or set(got) != listed:
            self.fail(
                "C1",
                "tenants",
                "the file must hold exactly one row per listed workspace (%d), it holds %d"
                % (len(listed), len(got)),
            )
        for table in self.blocks:
            for n, _, r in self.rows(table):
                if "tenant_id" in r and r["tenant_id"] not in listed:
                    self.fail(
                        "C1",
                        table,
                        "row %d: tenant_id is not an exported workspace" % n,
                    )

    def members(self):
        ids = set()
        for n, _, r in self.rows("humans"):
            hid = r.get("human_id") or ""
            if not HUM.match(hid):
                self.fail("MEMBER", "humans", "row %d: human_id is not a HUM-n id" % n)
                continue
            ids.add(hid)
            if "display_name" in r and r["display_name"] != hid:
                self.fail(
                    "MEMBER",
                    "humans",
                    "human_id=%s: display_name is not the HUM-n id" % hid,
                )
            if r.get("email") is not None:
                self.fail("MEMBER", "humans", "human_id=%s: e-mail is not NULL" % hid)
        for n, row, r in self.rows("tenant_memberships"):
            if r.get("human_id") not in ids:
                self.fail(
                    "MEMBER",
                    "tenant_memberships",
                    "row %d: a membership of a member that is not exported" % n,
                )
        for n, row, r in self.rows("messages"):
            for c in ("from_id", "to_id"):
                if HUM.match(r.get(c) or "") and r[c] not in ids:
                    self.fail(
                        "MEMBER",
                        "messages",
                        "%s: %s names a member that is not exported"
                        % (self.where("messages", n, row, c), c),
                    )

    # --- C2 ----------------------------------------------------------------------------
    def c2(self, reread):
        """reread: {table: [[workspace, key], ...]}, one re-read per listed
        workspace. humans has no RLS: its key is looked up in the
        memberships of any listed workspace."""
        for table in self.blocks:
            src = "tenant_memberships" if table == "humans" else table
            pairs = reread.get(src)
            if pairs is None:
                self.fail(
                    "C2", table, "the RLS re-read returned nothing for this table"
                )
                continue
            seen = {tuple(p) for p in pairs}
            if table == "humans":
                seen = {k for _, k in seen}
            for n, row, r in self.rows(table):
                k = r.get(KEYS[table])
                if (k if table == "humans" else (self.row_ws(r), k)) not in seen:
                    self.fail(
                        "C2",
                        table,
                        "%s: not found by the re-read pinned by RLS alone"
                        % self.where(table, n, row),
                    )

    # --- C4 ------------------------------------------------------------------------------
    def name_patterns(self):
        """[(pattern, is a BODY_WORD_IDS id)] for each id and display name."""
        pats = []
        with open(self.a.names, encoding="utf-8") as fh:
            for line in fh:
                for i, w in enumerate(line.rstrip("\n").split("\t")):
                    if w.strip():
                        rx = re.compile(
                            r"(?<![%s])%s(?![%s])"
                            % (NAME_EDGE, re.escape(w.strip()), NAME_EDGE),
                            re.I,
                        )
                        pats.append((rx, i == 0 and w.strip() in BODY_WORD_IDS))
        return pats

    def cells(self, dropped):
        """[(table, n, row, col, text)] for every comment and non-empty value."""
        out = [("comment", i, None, None, text) for i, text in self.comments]
        for table in self.blocks:
            for n, row, r in self.rows(table):
                if table == "messages" and n in dropped:
                    continue
                out += [(table, n, row, c, v) for c, v in r.items() if v]
        return out

    def scan(self, dropped):
        """-> [(table, n, row, col, class)] hits."""
        cells = self.cells(dropped)
        found = [
            (table, n, row, c, cls)
            for table, n, row, c, v in cells
            for cls in self.hits(v, table == "messages" and c in BODY_COLS)
        ]
        return found + self.gitleaks(cells)

    def gitleaks(self, cells):
        if not self.a.gitleaks:
            return []
        with tempfile.TemporaryDirectory() as d:
            src, rep = os.path.join(d, "cells.txt"), os.path.join(d, "report.json")
            with open(src, "w", encoding="utf-8") as fh:
                fh.writelines(
                    v.replace("\r", " ").replace("\n", " ") + "\n"
                    for _, _, _, _, v in cells
                )
            cmd = [
                self.a.gitleaks,
                "dir",
                "--no-banner",
                "--redact",
                "--exit-code",
                "0",
                "--log-level",
                "error",
                "--report-format",
                "json",
                "--report-path",
                rep,
            ]
            if self.a.gitleaks_config:
                cmd += ["--config", self.a.gitleaks_config]
            r = subprocess.run(
                cmd + [src],
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                check=False,
            )
            if r.returncode != 0 or not os.path.exists(rep):
                self.fail("C4", "-", "gitleaks did not run (exit %d)" % r.returncode)
                return []
            with open(rep, encoding="utf-8") as fh:
                found = json.load(fh) or []
        out = []
        for f in found:
            ln = int(f.get("StartLine") or 0)
            if 1 <= ln <= len(cells):
                t, n, row, c, _ = cells[ln - 1]
                out.append((t, n, row, c, "gitleaks"))
        return out

    def c4(self):
        dropped, removed = set(), {}
        for table, n, row, c, cls in self.scan(set()):
            if table == "messages" and c in BODY_COLS:
                if n not in dropped:
                    removed[cls] = removed.get(cls, 0) + 1
                    print(
                        "DROP C4 %s messages %s: a body hit, the message is removed"
                        % (cls, self.where("messages", n, row, c))
                    )
                dropped.add(n)
            elif table == "comment":
                self.fail("C4", "-", "line %d (a comment): %s hit" % (n, cls))
            else:
                self.fail(
                    "C4",
                    table,
                    "%s: column %s: %s hit" % (self.where(table, n, row, c), c, cls),
                )
        if dropped and not self.fails:
            for table, n, row, c, cls in self.scan(dropped):
                at = self.where(table, n, row, c) if row is not None else "line %d" % n
                self.fail(
                    "C4", table, "second scan: %s: column %s: %s hit" % (at, c, cls)
                )
        total = len(self.rows("messages"))
        pct = (100.0 * len(dropped) / total) if total else 0.0
        if pct > self.a.drop_cap_pct:
            self.fail(
                "C4",
                "messages",
                "%d of %d messages dropped (%.2f%%), above the %s%% cap: the day fails"
                % (len(dropped), total, pct, self.a.drop_cap_pct),
            )
        return dropped, removed, pct

    # --- SIZE ------------------------------------------------------------------------------
    def size(self, counts, allow_version):
        if not self.a.prev_manifest:
            print(
                "INFO SIZE no previous manifest: the size check is skipped (the first file)"
            )
            return
        with open(self.a.prev_manifest, encoding="utf-8") as fh:
            prev = json.load(fh)
        if str(prev.get("allow_list_version")) != str(allow_version):
            print(
                "INFO SIZE the allow-list version changed (%s -> %s): the size check is skipped"
                % (prev.get("allow_list_version"), allow_version)
            )
            return
        was_counts = prev.get("row_counts") or {}
        for t in sorted(set(counts) | set(was_counts)):
            now, was = counts.get(t, 0), was_counts.get(t)
            if not isinstance(was, int) or was == 0:
                print("INFO SIZE %s: no previous count to compare" % t)
            elif abs(now - was) * 100.0 > self.a.size_tol_pct * was:
                self.fail(
                    "SIZE",
                    t,
                    "%d rows against %d in the previous file, beyond %s%%"
                    % (now, was, self.a.size_tol_pct),
                )

    # --- run ---------------------------------------------------------------------------------
    def write_clean(self, dropped):
        msgs = (self.blocks.get("messages") or {"rows": []})["rows"]
        drop_lines = {i for n, (i, _) in enumerate(msgs, 1) if n in dropped}
        fd = os.open(self.a.out, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.writelines(
                line + "\n"
                for i, line in enumerate(self.lines, 1)
                if i not in drop_lines
            )
        with open(self.a.out, "rb") as fh:
            return hashlib.sha256(fh.read()).hexdigest()

    def checks(self):
        with open(self.a.allow_list, encoding="utf-8") as fh:
            allow = json.load(fh)
        with open(self.a.catalog, encoding="utf-8") as fh:
            catalog = json.load(fh)
        with open(self.a.reread, encoding="utf-8") as fh:
            reread = json.load(fh)
        self.parse()
        if not self.fails:
            self.c3(allow, catalog)
            self.c1(self.a.workspace)
            self.members()
            self.c2(reread)
        dropped, removed, pct = self.c4() if not self.fails else (set(), {}, 0.0)
        counts = {
            t: len(b["rows"]) - (len(dropped) if t == "messages" else 0)
            for t, b in self.blocks.items()
        }
        if not self.fails:
            self.size(counts, allow.get("version"))
        return allow, dropped, removed, pct, counts

    def run(self):
        allow, dropped, removed, pct, counts = self.checks()
        report = {
            "v": 1,
            "result": "FAIL" if self.fails else "PASS",
            "row_counts": counts,
            "removed_by_class": removed,
            "messages_dropped": len(dropped),
            "messages_dropped_pct": round(pct, 4),
            "allow_list_version": allow.get("version"),
            "fatal": len(self.fails),
            "fatal_classes": sorted(set(self.fails)),
        }
        if not self.fails:
            report["sha256"] = self.write_clean(dropped)
        with open(self.a.report, "w", encoding="utf-8") as fh:
            json.dump(report, fh, sort_keys=True)
            fh.write("\n")
        print(
            "%s gate: %d fatal, %d message(s) dropped (%s); rows %s"
            % (
                report["result"],
                len(self.fails),
                len(dropped),
                ", ".join("%s %d" % kv for kv in sorted(removed.items())) or "none",
                ", ".join("%s %d" % kv for kv in sorted(counts.items())),
            )
        )
        return 1 if self.fails else 0


def main():
    p = argparse.ArgumentParser(description="spec 091 public dataset gate (T005)")
    for k in (
        "file",
        "allow-list",
        "catalog",
        "reread",
        "names",
        "workspace",
        "out",
        "report",
    ):
        p.add_argument("--" + k, required=True)
    p.add_argument("--prev-manifest", default="")
    p.add_argument("--drop-cap-pct", type=float, required=True)
    p.add_argument("--size-tol-pct", type=float, required=True)
    p.add_argument("--gitleaks", default="")
    p.add_argument("--gitleaks-config", default="")
    a = p.parse_args()
    if os.path.exists(a.out):
        print("FATAL the cleaned file already exists: a gate never overwrites one")
        return 2
    try:
        return Gate(a).run()
    except Exception as e:  # pylint: disable=broad-except -- the type only, never a value (5.6)
        print("FATAL gate input unreadable (%s)" % type(e).__name__)
        return 1


if __name__ == "__main__":
    sys.exit(main())
