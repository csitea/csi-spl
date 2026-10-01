#!/usr/bin/env python3
"""agent-mirror-check.py - per live agent: is its terminal mirrored into its
web UI DM (specs/036, owner 2026-10-01 "per launch")?

stdin: the live agents, one JSON object per line, as `agent-identity.py facts`
prints them (id, kind, pid, user). One row per agent, then one summary line.

An agent is mirrored when ALL of these hold:
  hooks   its CLI loads the mirror hook, and the hook script it names exists:
            claude  `--settings <file>` in its argv naming spool-mirror.py, else
                    the user's ~/.claude/settings.json
            grok    ~/.grok/hooks/spool-mirror.json, else ~/.claude/settings.json
            agy     ~/.gemini/config/hooks.json (the named hook spool-mirror)
            qwen    ~/.qwen/settings.json
  env     its process env names it: SPOOL_AGENT_ID, else MCP_BOT_AGENT_ID, = its id
          (the hook never reads a window name)
  seat    a desk seat <seat>/spool/<ID> without .no-mirror (else nothing posts)
  on      no $SPOOL_ROOT/.mirror-off

Usage: agent-mirror-check.py [--json]
Env:   AMC_PROC_ROOT (default /proc), AMC_SEATS (default
       <box user home>/.local/share/csi-spl/cloud/*/desk/*/*), SPOOL_ROOT,
       AMC_HOME_OF (tests: a dir holding <user>/ homes)
Exit:  0 every live agent is mirrored, 1 one is not, 2 usage.
A process of another user whose env cannot be read is retried with sudo -n.
"""
import glob
import json
import os
import pwd
import re
import subprocess
import sys

HOOK_RE = re.compile(r"""([^\s'"]*spool-mirror\.py)""")
PROC = os.environ.get("AMC_PROC_ROOT") or "/proc"


def read_bytes(path):
    try:
        with open(path, "rb") as f:
            return f.read()
    except PermissionError:
        try:
            r = subprocess.run(["sudo", "-n", "cat", path], capture_output=True, timeout=5)
            return r.stdout if r.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired):
            return None
    except OSError:
        return None


def home_of(user):
    base = os.environ.get("AMC_HOME_OF")
    if base:
        return os.path.join(base, user)
    try:
        return pwd.getpwnam(user).pw_dir
    except KeyError:
        return ""


def read_text(path):
    b = read_bytes(path)
    return b.decode(errors="replace") if b is not None else None


def hook_in(path):
    """The spool-mirror.py a hooks/settings file runs, '' when none, None unreadable."""
    t = read_text(path)
    if t is None:
        return None
    m = HOOK_RE.search(t)
    return m.group(1) if m else ""


def argv_settings(argv):
    out = []
    for i, a in enumerate(argv):
        if a == "--settings" and i + 1 < len(argv):
            out.append(argv[i + 1])
        elif a.startswith("--settings="):
            out.append(a.split("=", 1)[1])
    return out


def hooks_of(kind, argv, home):
    """-> (where, script) of the first hook source this CLI reads, or ('', '')."""
    cands = []
    if kind == "claude":
        cands = argv_settings(argv) + [os.path.join(home, ".claude", "settings.json")]
    elif kind == "grok":
        cands = [os.path.join(home, ".grok", "hooks", "spool-mirror.json"), os.path.join(home, ".claude", "settings.json")]
    elif kind == "agy":
        cands = [os.path.join(home, ".gemini", "config", "hooks.json")]
    elif kind == "qwen":
        cands = [os.path.join(home, ".qwen", "settings.json")]
    for c in cands:
        s = hook_in(c)
        if s:
            return c, s
    return "", ""


def env_of(pid):
    b = read_bytes(os.path.join(PROC, str(pid), "environ"))
    if b is None:
        return None
    env = {}
    for kv in b.split(b"\0"):
        k, _, v = kv.decode(errors="replace").partition("=")
        if k:
            env[k] = v
    return env


def argv_of(pid):
    b = read_bytes(os.path.join(PROC, str(pid), "cmdline"))
    return [a.decode(errors="replace") for a in b.split(b"\0") if a] if b else []


def seats_of(agent):
    pat = os.environ.get("AMC_SEATS") or os.path.join(
        home_of(os.environ.get("SPOOL_BOX_USER") or pwd.getpwuid(os.getuid()).pw_name),
        ".local/share/csi-spl/cloud/*/desk/*/*")
    out = []
    for d in sorted(glob.glob(pat)):
        a = os.path.join(d, "spool", agent)
        if os.path.isdir(a) and not os.path.exists(os.path.join(a, ".no-mirror")):
            parts = d.rstrip("/").split("/")
            out.append("%s/%s" % (parts[-4], parts[-2]) if len(parts) >= 4 else d)
    return out


def check(fact, off):
    aid, kind, pid, user = fact.get("id", ""), fact.get("kind", ""), fact.get("pid"), fact.get("user", "")
    home = home_of(user)
    argv = argv_of(pid)
    env = env_of(pid)
    where, script = hooks_of(kind, argv, home)
    why = []
    if not where:
        why.append("no mirror hook loaded (relaunch through spawn/restore)")
    elif not os.path.isfile(script):
        why.append("the hook names a missing %s" % script)
    if env is None:
        env_id = "?"
        why.append("process env unreadable")
    else:
        env_id = env.get("SPOOL_AGENT_ID") or env.get("MCP_BOT_AGENT_ID") or ""
        if env_id != aid:
            why.append("process env names %s" % (env_id or "no agent id"))
    seats = seats_of(aid)
    if not seats:
        why.append("no desk seat (the desk reconcile seats a live window within 3 min)")
    if off:
        why.append("box kill switch .mirror-off")
    return {"agent": aid, "kind": kind, "pid": pid, "user": user, "hooks": where, "env_id": env_id,
            "seats": seats, "mirrored": "yes" if not why else "no", "why": "; ".join(why),
            "relaunch": bool(not where or (where and not os.path.isfile(script)))}


def main(argv):
    as_json = "--json" in argv[1:]
    if [a for a in argv[1:] if a != "--json"]:
        print(__doc__, file=sys.stderr)
        return 2
    off = os.path.exists(os.path.join(os.environ.get("SPOOL_ROOT") or "/var/spool-hub", ".mirror-off"))
    rows = []
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            fact = json.loads(line)
        except ValueError:
            continue
        if isinstance(fact, dict) and fact.get("id") and fact.get("pid"):
            rows.append(check(fact, off))
    rows.sort(key=lambda r: r["agent"])
    n_yes = sum(r["mirrored"] == "yes" for r in rows)
    relaunch = [r["agent"] for r in rows if r["relaunch"]]
    if as_json:
        for r in rows:
            print(json.dumps(r, sort_keys=True))
    else:
        print("%-11s %-6s %-8s %-8s %-11s %-9s %s" % ("AGENT", "KIND", "USER", "MIRRORED", "ENV-ID", "SEATS", "WHY / HOOKS"))
        for r in rows:
            print("%-11s %-6s %-8s %-8s %-11s %-9s %s" % (r["agent"], r["kind"], r["user"], r["mirrored"], r["env_id"],
                                                         len(r["seats"]), r["why"] or r["hooks"]))
    print(json.dumps({"agents": len(rows), "mirrored": n_yes, "not_mirrored": len(rows) - n_yes,
                      "need_relaunch": relaunch, "kill_switch": off}, sort_keys=True))
    return 0 if n_yes == len(rows) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
