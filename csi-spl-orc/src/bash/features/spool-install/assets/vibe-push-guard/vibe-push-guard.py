#!/usr/bin/env python3
"""spool push guard: Mistral Vibe pre_tool hook (owner order, t1 4e373f5d).

Vibe 2.26.0 runs it from ~/.vibe/hooks.toml as
    [[hooks]] name = "spool-push-guard", type = "pre_tool", match = "*", strict = true
and writes the pre_tool payload on stdin:
    {"hook_event_name": "pre_tool", "tool_name": "bash", "tool_input": {"command": ...}, ...}

Every shell-text field of tool_input (command for bash, text for the
experimental bash_stdin, cmd / script for others) goes through the shared
matcher force-push-guard.inc.sh, installed beside this file. A forbidden push
form prints {"decision": "deny", "reason": ...} and exits 0: vibe denies the
call before the permission check, so --auto-approve does not skip it.
The same field then goes through the heredoc-collision matcher
heredoc-collision-guard.inc.sh (SPL-2474), when it holds "<<": a heredoc
nested in one with the same delimiter is denied the same way. And through
the kill-target matcher kill-target-guard.inc.sh (SPL-2583), when it holds
"kill": a kill of pid 0/1, a process group, tmux / cron / systemd / sshd or
another agent is denied the same way.
Allowed: prints nothing, exits 0. Anything else (bad payload, no matcher, a
matcher rc other than 0 / 2) exits 1, which strict = true turns into a deny:
the guard fails CLOSED.
"""

import json
import os
import subprocess
import sys

FIELDS = ("command", "text", "cmd", "script")
HERE = os.path.dirname(os.path.abspath(__file__))
MATCHER = os.environ.get(
    "SPOOL_PUSH_GUARD_MATCHER", os.path.join(HERE, "force-push-guard.inc.sh")
)
HEREDOC = os.environ.get(
    "SPOOL_HEREDOC_GUARD_MATCHER",
    os.path.join(HERE, "heredoc-collision-guard.inc.sh"),
)
KILL = os.environ.get(
    "SPOOL_KILL_GUARD_MATCHER", os.path.join(HERE, "kill-target-guard.inc.sh")
)


def matcher_deny(matcher, cmd, name):
    """The deny reason from a --check matcher, None to allow; raises on a
    matcher failure (strict = true makes that a deny)."""
    res = subprocess.run(
        ["bash", matcher, "--check", cmd], capture_output=True, text=True, timeout=20
    )
    if res.returncode == 0:
        return None
    if res.returncode == 2:
        lines = res.stderr.strip().splitlines()
        return lines[-1] if lines else name + ": refused"
    raise RuntimeError(
        "%s matcher rc %d: %s" % (name, res.returncode, res.stderr.strip())
    )


def heredoc_deny(cmd):
    """The deny reason for a heredoc collision, None to allow."""
    if "<<" not in cmd:
        return None
    return matcher_deny(HEREDOC, cmd, "heredoc-collision")


def kill_deny(cmd):
    """The deny reason for a forbidden kill target, None to allow."""
    if "kill" not in cmd:
        return None
    return matcher_deny(KILL, cmd, "kill-guard")


def main():
    payload = json.load(sys.stdin)
    tool_input = payload.get("tool_input")
    if not isinstance(tool_input, dict):
        return 0
    for key in FIELDS:
        cmd = tool_input.get(key)
        if not isinstance(cmd, str) or not cmd.strip():
            continue
        res = subprocess.run(
            ["bash", MATCHER, "--check", cmd],
            capture_output=True,
            text=True,
            timeout=20,
        )
        if res.returncode == 2:
            reason = (
                res.stderr.strip().splitlines()[-1]
                if res.stderr.strip()
                else "force-push-guard: refused"
            )
            print(
                json.dumps(
                    {
                        "decision": "deny",
                        "reason": reason
                        + " (owner order: no force push to master without the owner's explicit approval)",
                    }
                )
            )
            return 0
        if res.returncode != 0:
            print(
                "push guard: matcher rc %d: %s" % (res.returncode, res.stderr.strip()),
                file=sys.stderr,
            )
            return 1
        try:
            reason = heredoc_deny(cmd) or kill_deny(cmd)
        except (OSError, RuntimeError, subprocess.SubprocessError) as e:
            print("push guard: %s" % e, file=sys.stderr)
            return 1
        if reason:
            print(json.dumps({"decision": "deny", "reason": reason}))
            return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
