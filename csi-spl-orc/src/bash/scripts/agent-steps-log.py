#!/usr/bin/env python3
"""agent-steps-log.py - an agent's claude session as a readable steps file
(spec 160 section 3.9, SPL-4693).

  agent-steps-log.py --session <jsonl> --out <log> --state <json>

Appends one line per step of the session jsonl to <log>:

  <UTC time> <kind> <detail>

  prompt   the first ~200 chars of a prompt the agent was given
  tool     the tool name and a short argument (a command's first line, a
           file's path, a pattern), at most ~120 chars
  result   ok | error, and the tool it answers; never the result's content
           (a file a tool read is named by its path on the tool line only)
  text     the first ~200 chars of the agent's own text

Thinking, sidechains and the harness's bookkeeping records are skipped.
Every line passes spool_redact.redact(), the box's one redaction list,
before it is written. Incremental: <state> keeps the session path and the
byte offset after the last complete jsonl line read, so a re-run appends
only new steps; a different session (a newer jsonl) starts at its first
byte, after one `session` line. <log> is created mode 0644: the file
follower reads it.

Exit: 0 written (or nothing new), 3 the session file is missing, 4 it is
not readable, 2 a usage error.
"""

import argparse
import json
import os
import re
import sys
import time

sys.path.insert(
    0,
    os.path.join(
        os.path.dirname(os.path.realpath(__file__)),
        "..",
        "features",
        "spawn-agents",
        "lib",
    ),
)
from spool_redact import redact  # noqa: E402  (the one redaction list)

TEXT_MAX = 200
ARG_MAX = 120
READ_MAX_BYTES = 16 << 20
NAMES_KEPT = 200
# The input key that names a tool call best, in order.
ARG_KEYS = (
    "command",
    "file_path",
    "notebook_path",
    "path",
    "pattern",
    "url",
    "query",
    "skill",
    "description",
)


def short(text, limit):
    s = re.sub(r"\s+", " ", str(text)).strip()
    return s if len(s) <= limit else s[: limit - 1] + "…"


def stamp(rec):
    m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)", str(rec.get("timestamp") or ""))
    return (m.group(1) + "Z") if m else "-"


def tool_arg(inp):
    if not isinstance(inp, dict):
        return ""
    for k in ARG_KEYS:
        v = inp.get(k)
        if isinstance(v, str) and v.strip():
            return short(v.strip().splitlines()[0], ARG_MAX)
    return ""


def user_steps(rec, content, names):
    if isinstance(content, str):
        if not rec.get("isMeta") and content.strip():
            yield "prompt", short(content, TEXT_MAX)
        return
    for c in content if isinstance(content, list) else []:
        if not isinstance(c, dict):
            continue
        if c.get("type") == "tool_result":
            ok = "error" if c.get("is_error") else "ok"
            yield (
                "result",
                (ok + " " + names.get(str(c.get("tool_use_id")), "")).strip(),
            )
        elif c.get("type") == "text" and not rec.get("isMeta"):
            if str(c.get("text", "")).strip():
                yield "prompt", short(c.get("text", ""), TEXT_MAX)


def assistant_steps(content, names):
    for c in content if isinstance(content, list) else []:
        if not isinstance(c, dict):
            continue
        if c.get("type") == "tool_use":
            name = short(c.get("name", "?"), 48)
            names[str(c.get("id"))] = name
            arg = tool_arg(c.get("input"))
            yield "tool", (name + ": " + arg) if arg else name
        elif c.get("type") == "text" and str(c.get("text", "")).strip():
            yield "text", short(c.get("text", ""), TEXT_MAX)


def steps(rec, names):
    """-> [(kind, detail)] for one jsonl record."""
    if not isinstance(rec, dict) or rec.get("isSidechain"):
        return []
    msg = rec.get("message")
    if not isinstance(msg, dict):
        return []
    if rec.get("type") == "user":
        return list(user_steps(rec, msg.get("content"), names))
    if rec.get("type") == "assistant":
        return list(assistant_steps(msg.get("content"), names))
    return []


def load_state(path):
    try:
        with open(path, encoding="utf-8") as f:
            st = json.load(f)
        return st if isinstance(st, dict) else {}
    except (OSError, ValueError):
        return {}


def save_state(path, st):
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(st, f)
    os.replace(tmp, path)


def line(ts, kind, detail):
    text, _ = redact(f"{ts} {kind:<6} {detail}".rstrip())
    return text + "\n"


def read_new(session, offset):
    """-> (complete jsonl lines, new offset); a shrunk file restarts at 0."""
    with open(session, "rb") as f:
        if offset > os.fstat(f.fileno()).st_size:
            offset = 0
        f.seek(offset)
        buf = f.read(READ_MAX_BYTES)
    end = buf.rfind(b"\n")
    if end < 0:
        return [], offset
    return buf[: end + 1].splitlines(), offset + end + 1


def run(args):
    session = os.path.realpath(args.session)
    if not os.path.isfile(session):
        print(f"FATAL agent-steps-log: no session file {args.session}")
        return 3
    st = load_state(args.state)
    out = []
    if st.get("session") != session:
        st = {"session": session, "offset": 0, "names": {}}
        out.append(
            line(
                time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                "session",
                os.path.basename(session),
            )
        )
    names = st.get("names") or {}
    try:
        raw, offset = read_new(session, int(st.get("offset") or 0))
    except OSError as e:
        print(
            f"FATAL agent-steps-log: session file {args.session} is not readable: {e.strerror}"
        )
        return 4
    for b in raw:
        try:
            rec = json.loads(b)
        except ValueError:
            continue
        for kind, detail in steps(rec, names):
            out.append(line(stamp(rec), kind, detail))
    fd = os.open(args.out, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
    if os.fstat(fd).st_uid == os.geteuid():
        os.fchmod(fd, 0o644)
    with os.fdopen(fd, "a", encoding="utf-8") as f:
        f.writelines(out)
    st["offset"] = offset
    st["names"] = dict(list(names.items())[-NAMES_KEPT:])
    save_state(args.state, st)
    print(f"OK agent-steps-log: {len(out)} line(s) -> {args.out} (offset {offset})")
    return 0


def main(argv):
    p = argparse.ArgumentParser(description="an agent's claude session as a steps file")
    p.add_argument("--session", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--state", required=True)
    return run(p.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
