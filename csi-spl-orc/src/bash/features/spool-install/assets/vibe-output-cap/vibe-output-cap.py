#!/usr/bin/env python3
"""Mistral Vibe post_tool hook: cap the shell output fed back to the model.

Why (SPL-2217, measured 2026-10-16 on 35 m- lane sessions, 1211 completions,
spawn-agents/scripts/vibe-loop-cost.py): vibe resends the whole context on
every completion, so a tool result rides along in every later turn of the
lane. bash results made up about a quarter of all input tokens; capping each
at 4000 chars would have cut the input by about a tenth. vibe 2.26 keeps the
HEAD 16000 bytes of each stream, while a test run's verdict is at its tail.

A bash result longer than VIBE_OUTPUT_CAP_CHARS (default 4000, 0 = off) is
written in full to a log file (VIBE_OUTPUT_CAP_DIR, default
$XDG_STATE_HOME/vibe-tool-output, kept 2 days) and the model sees the return
code, the first lines, the last lines and the log path instead. vibe's
post_tool "deny" replaces the model-visible result with the reason; the
command already ran. Fail open: any error prints nothing and exits 0, so vibe
keeps the result as it was.
"""

import json
import os
import re
import sys
import time

CAP = 4000
KEEP_DAYS = 2


def cap_chars():
    try:
        return max(int(os.environ.get("VIBE_OUTPUT_CAP_CHARS", CAP)), 0)
    except ValueError:
        return CAP


def log_dir():
    d = os.environ.get("VIBE_OUTPUT_CAP_DIR")
    if d:
        return d
    state = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local", "state"
    )
    return os.path.join(state, "vibe-tool-output")


def safe(s):
    return re.sub(r"[^A-Za-z0-9._-]", "_", str(s or ""))[:80] or "x"


def prune(root):
    old = time.time() - KEEP_DAYS * 86400
    for name in os.listdir(root):
        p = os.path.join(root, name)
        try:
            if os.path.isdir(p) and os.path.getmtime(p) < old:
                for f in os.listdir(p):
                    os.unlink(os.path.join(p, f))
                os.rmdir(p)
        except OSError:
            pass


def head_tail(text, budget):
    """The first quarter and the last three quarters of budget, cut at lines."""
    if len(text) <= budget:
        return text
    head = text[: budget // 4]
    head = head[: head.rfind("\n") + 1] or head
    tail = text[len(text) - (budget - len(head)) :]
    tail = tail[tail.find("\n") + 1 :] or tail
    return "%s[... %d chars cut ...]\n%s" % (
        head,
        len(text) - len(head) - len(tail),
        tail,
    )


def shape(out, size, cap, path):
    stdout = str(out.get("stdout") or "")
    stderr = str(out.get("stderr") or "")
    err = head_tail(stderr, cap // 3)
    note = (
        " (vibe had already kept only the first 16000 bytes of a stream)"
        if out.get("was_truncated")
        else ""
    )
    return (
        "returncode: %s\n"
        "[spool output cap: %d chars of output, about %d shown; the full output is in %s%s."
        " grep or sed -n it, never cat it whole]\n"
        "stdout:\n%s\nstderr:\n%s"
        % (
            out.get("returncode"),
            size,
            cap,
            path,
            note,
            head_tail(stdout, cap - len(err)),
            err,
        )
    )


def main():
    raw = sys.stdin.read()  # always drain it: vibe writes the payload first
    cap = cap_chars()
    if cap == 0:
        return 0
    d = json.loads(raw)
    out = d.get("tool_output")
    if not str(d.get("tool_name") or "").lower().endswith("bash") or not isinstance(
        out, dict
    ):
        return 0
    size = len(str(out.get("stdout") or "")) + len(str(out.get("stderr") or ""))
    if size <= cap:
        return 0
    root = log_dir()
    sdir = os.path.join(root, safe(d.get("session_id")))
    os.makedirs(sdir, mode=0o700, exist_ok=True)
    path = os.path.join(sdir, safe(d.get("tool_call_id")) + ".log")
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        f.write(
            "$ %s\nreturncode: %s\n--- stdout ---\n%s\n--- stderr ---\n%s"
            % (
                out.get("command", ""),
                out.get("returncode"),
                out.get("stdout") or "",
                out.get("stderr") or "",
            )
        )
    prune(root)
    print(
        json.dumps(
            {
                "decision": "deny",
                "reason": shape(out, size, cap, path),
                "system_message": "spool output cap: %d -> about %d chars"
                % (size, cap),
            }
        )
    )
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception:  # fail open: vibe keeps the uncapped result
        sys.exit(0)
