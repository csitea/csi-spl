#!/usr/bin/env python3
"""y13-force-push-guard.py - spool-install step y13, the JSON half.

  y13-force-push-guard.py <home> <guard-dir> <dry 0|1> <hook-src> <lib-src>

Copies the hook and the ONE shared matcher into <guard-dir>, then wires every
harness that has a config dir in <home> to it (claude, grok, qwen, agy):
a PreToolUse hook on the shell tool, failing CLOSED, plus deny rules where
the harness reads them. Our entries are found by the marker
"force-push-guard-hook" and replaced; every other key and hook is kept.
Prints one line per change ("would: ..." when dry); exit 0, or 7 when a file
cannot be read as JSON (left alone, named).
"""

import json
import os
import shlex
import shutil
import sys

MARK = "force-push-guard-hook"
# The cheap layer behind the hook, in the Bash(<glob>) form claude, grok and
# qwen all read. The hook is the real guard: it reads wrapped forms these
# globs cannot. Every pattern needs "git push" first, so a plain push and
# every other command never match.
DENY = [
    "Bash(git push --force*)",
    "Bash(git push * --force*)",
    "Bash(git push -f*)",
    "Bash(git push * -f*)",
    "Bash(git push --mirror*)",
    "Bash(git push * --mirror*)",
    "Bash(git push * +*)",
    "Bash(git push * :master*)",
    "Bash(git push * :refs/heads/master*)",
]


def hook_cmd(guard_dir, harness):
    hook = os.path.join(guard_dir, "force-push-guard-hook.sh")
    f = shlex.quote(hook)
    why = f"force-push-guard: refused: {hook} is missing (fail closed)"
    deny = shlex.quote(json.dumps({"decision": "deny", "reason": why}))
    return f"[ -r {f} ] && exec bash {f} {harness}; echo {shlex.quote(why)} >&2; echo {deny}; exit 2"


def entry(guard_dir, harness, matcher):
    return {
        "matcher": matcher,
        "hooks": [
            {"type": "command", "command": hook_cmd(guard_dir, harness), "timeout": 10}
        ],
    }


class Step:
    def __init__(self, dry):
        self.dry = dry
        self.rc = 0

    def say(self, what):
        print(("would: " if self.dry else "spool-install: force-push-guard: ") + what)

    def load(self, path):
        try:
            with open(path) as f:
                d = json.load(f)
        except FileNotFoundError:
            return {}
        except ValueError:
            d = None
        if not isinstance(d, dict):
            print(
                f"spool-install: force-push-guard: {path} is not a JSON object: left alone",
                file=sys.stderr,
            )
            self.rc = 7
            return None
        return d

    def save(self, path, old, new, what):
        if old == new:
            return
        self.say(f"{what} ({path})")
        if self.dry:
            return
        os.makedirs(os.path.dirname(path), exist_ok=True)
        tmp = f"{path}.tmp.{os.getpid()}"
        mode = os.stat(path).st_mode & 0o777 if os.path.exists(path) else 0o600
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, mode)
        with os.fdopen(fd, "w") as f:
            f.write(json.dumps(new, indent=2) + "\n")
        os.replace(tmp, path)

    def copy(self, src, dst):
        try:
            with open(src, "rb") as a, open(dst, "rb") as b:
                if a.read() == b.read():
                    return
        except FileNotFoundError:
            pass
        self.say(f"copy {os.path.basename(src)} -> {dst}")
        if self.dry:
            return
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        tmp = f"{dst}.tmp.{os.getpid()}"
        shutil.copyfile(src, tmp)
        os.chmod(tmp, 0o755)
        os.replace(tmp, dst)


def with_pre_hook(hooks, new):
    """hooks: an event -> [entry] map; ours replaced, others kept."""
    hooks = dict(hooks or {})
    hooks["PreToolUse"] = [
        e for e in hooks.get("PreToolUse", []) if MARK not in json.dumps(e)
    ] + [new]
    return hooks


def with_deny(perms):
    perms = dict(perms or {})
    have = list(perms.get("deny") or [])
    perms["deny"] = have + [r for r in DENY if r not in have]
    return perms


def settings_json(st, path, guard_dir, harness, matcher, what):
    """claude and qwen: hooks.PreToolUse + permissions.deny in settings.json."""
    old = st.load(path)
    if old is None:
        return
    new = dict(old)
    new["hooks"] = with_pre_hook(old.get("hooks"), entry(guard_dir, harness, matcher))
    new["permissions"] = with_deny(old.get("permissions"))
    st.save(path, old, new, what)


def main():
    home, guard_dir, dry, hook_src, lib_src = sys.argv[1:6]
    st = Step(dry == "1")
    st.copy(hook_src, os.path.join(guard_dir, "force-push-guard-hook.sh"))
    st.copy(lib_src, os.path.join(guard_dir, "force-push-guard.inc.sh"))
    done = []
    if os.path.isdir(os.path.join(home, ".claude")):
        # grok reads this file too (hooks and permissions.deny): its payload is
        # camelCase, which the hook reads as well.
        settings_json(
            st,
            os.path.join(home, ".claude", "settings.json"),
            guard_dir,
            "claude",
            "Bash",
            "claude: PreToolUse hook + deny rules",
        )
        done.append("claude")
    if os.path.isdir(os.path.join(home, ".grok")):
        # ~/.grok/hooks/*.json is always trusted and read even when grok's
        # scan of ~/.claude/settings.json is turned off.
        p = os.path.join(home, ".grok", "hooks", "force-push-guard.json")
        old = st.load(p)
        if old is not None:
            st.save(
                p,
                old,
                {"hooks": {"PreToolUse": [entry(guard_dir, "grok", "Bash")]}},
                "grok: PreToolUse hook",
            )
        done.append("grok")
    if os.path.isdir(os.path.join(home, ".qwen")):
        settings_json(
            st,
            os.path.join(home, ".qwen", "settings.json"),
            guard_dir,
            "qwen",
            "run_shell_command",
            "qwen: PreToolUse hook + deny rules",
        )
        done.append("qwen")
    if os.path.isdir(os.path.join(home, ".gemini", "config")) or os.path.isdir(
        os.path.join(home, ".gemini", "antigravity-cli")
    ):
        p = os.path.join(home, ".gemini", "config", "hooks.json")
        old = st.load(p)
        if old is not None:
            new = dict(old)
            new["force-push-guard"] = {
                "PreToolUse": [entry(guard_dir, "agy", "run_command")]
            }
            st.save(p, old, new, "agy: named PreToolUse hook force-push-guard")
        done.append("agy")
    what = ", ".join(done) or "no harness config dir"
    print(
        f"spool-install: force-push-guard: {what} in {home}{' (dry run)' if st.dry else ''}",
        file=sys.stderr,
    )
    return st.rc


if __name__ == "__main__":
    sys.exit(main())
