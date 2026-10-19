#!/usr/bin/env bash
# kill-target-guard.inc.sh — the ONE decision "may an agent's shell command
# send this kill?", run by the harness pre-tool hooks (claude / grok / agy /
# qwen: force-push-guard-hook.sh). SPL-2583.
#
#   kill_target_guard_check "<command>"
#       rc 0  allow (prints nothing)
#       rc 2  refuse; one line "kill-guard: refused: <reason>" on stderr
#   bash kill-target-guard.inc.sh --check "<command>"   the same, run directly
#
# Why: on 2026-10-18 11:57Z an agent on sat ran
#   pids=$(ps -eo pid=,ppid= | awk '... a[p[k]] ...'); sudo kill $pids
# The awk test created a[<every parent pid>], so the list held 0, 1, the tmux
# server, cron and the user systemd: the box was down ~19 h 40 min. sudo runs
# /usr/bin/kill by its secure_path and kill is a shell builtin, so no PATH
# wrapper (the y11 pkill / killall guard) sees it: this check runs in the
# harness, before the command reaches any shell.
#
# Refused, wherever the command reaches kill / pkill / killall (after ; && ||
# | & newlines, $( ) and backticks, the wrappers sudo, env, timeout, nohup,
# exec, command, ..., and inside bash -c, eval, su -c, ssh):
#   - kill with target pid 0, pid 1 or a negative pid (a process group;
#     -1 is every process the caller may signal)
#   - kill with a target the hook cannot read before it runs: $var, $( ),
#     backticks, xargs ... kill. Only $! (the shell's own last background
#     job), $$ and %job are read as own. Name literal pids instead.
#   - kill of a literal pid that is a tmux, cron, systemd or sshd process, or
#     another agent's claude / grok / vibe / agy / qwen process, unless it is
#     the caller agent itself or one of its descendants (own children stay
#     killable). The process table is one `ps -eo pid=,ppid=,args=` call.
#   - killall in any form; pkill -f / --full; pkill with a computed pattern
#     or one whose regex matches a protected or agent process name
# Heredoc bodies are data, unless a shell or eval on the same line reads them.
# A script file that runs kill is not read: an action's own stop code is its
# own. Fails CLOSED: no python3, a guard error or an untokenizable command
# that runs kill is refused. KILL_GUARD_SELF_PID names the caller agent's pid
# (tests); else it is the nearest agent process above the hook.

kill_target_guard_check() {
  case "${1-}" in *kill*) ;; *) return 0 ;; esac
  if ! command -v python3 >/dev/null 2>&1; then
    echo "kill-guard: refused: python3 is missing, the guard cannot read the command (fail closed)" >&2
    return 2
  fi
  python3 -c "$_KILL_TARGET_GUARD_PY" "${1-}"
}

# shellcheck disable=SC2016  # python source, never expanded by bash
_KILL_TARGET_GUARD_PY='
import os, re, shlex, subprocess, sys

KILLS = {"kill", "pkill", "killall"}
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish", "busybox"}
WRAP = {"env", "command", "exec", "nohup", "time", "nice", "ionice", "setsid",
        "stdbuf", "timeout", "builtin", "chronic", "unbuffer", "flock",
        "doas", "sudo", "then", "do", "else", "!", "watch", "strace"}
ARG_OPTS = {"sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"},
            "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
            "nice": {"-n", "--adjustment"}, "ionice": {"-c", "-n", "-t"},
            "timeout": {"-s", "--signal", "-k", "--kill-after"},
            "flock": {"-w", "-E", "-c"}, "watch": {"-n", "-d"},
            "stdbuf": {"-i", "-o", "-e"}}
PROTECTED = re.compile(r"^(tmux|cron|crond|systemd|sshd|init)")
AGENTS = {"claude", "grok", "vibe", "agy", "qwen", "gemini"}
OWN = {"$!", "${!}", "$$", "${$}"}
RULE = "never kill pid 0/1, a process group, tmux, cron, systemd, sshd or another agent; name your own child pids"


class Refuse(Exception):
    pass


def split(cmd):
    s = cmd.replace("`", " ; ").replace("\n", " ; ").replace("$(", " ; ( ")
    lx = shlex.shlex(s, posix=True, punctuation_chars=";&|()<>")
    lx.whitespace_split = True
    lx.commenters = ""
    segs, cur = [], []
    for t in lx:
        if t and all(c in ";&|()<>" for c in t):
            if cur:
                segs.append(cur)
            cur = []
            continue
        cur.append(t)
    if cur:
        segs.append(cur)
    return segs


HEREDOC = re.compile(r"(?<!<)<<(-?)\s*([\"\x27]?)([A-Za-z_][A-Za-z0-9_]*)\2")


def heredocs(cmd, depth):
    """Cut heredoc bodies out (data), checking a body a shell or eval on the
    same line reads (bash <<EOF, cat <<EOF | sh)."""
    lines = cmd.split("\n")
    out, i = [], 0
    while i < len(lines):
        line = lines[i]
        out.append(line)
        i += 1
        for m in HEREDOC.finditer(line):
            body = []
            while i < len(lines):
                cur = lines[i]
                i += 1
                if (cur.lstrip("\t") if m.group(1) else cur) == m.group(3):
                    break
                body.append(cur)
            words = re.split(r"[\s;&|()`]+", line)
            if any(w.strip("\"\x27").rsplit("/", 1)[-1] in SHELLS | {"eval"} for w in words):
                check("\n".join(body), depth + 1)
    return "\n".join(out)


def check(cmd, depth=0):
    if depth > 8:
        raise Refuse("the command nests too deep to read (fail closed)")
    if "kill" not in cmd:
        return
    if "<<" in cmd:
        cmd = heredocs(cmd, depth)
    try:
        segs = split(cmd)
    except ValueError as e:
        if re.search(r"(^|[\s;&|(`/])(kill|pkill|killall)(\s|$)", cmd):
            raise Refuse("cannot tokenize a command that runs kill (%s); fail closed" % e)
        return
    for seg in segs:
        segment(seg, depth)
    # split() cuts $( ) and backticks into their own segments, so a kill fed
    # by one shows up with no target there: read the raw text for it.
    if re.search(r"(^|[\s;&|(`/])(kill|pkill)\s[^;&|\n]*(\$\(|`)", cmd):
        raise Refuse("kill with a computed target list ($( ) or backticks); " + RULE)


def skip_wrapper(b, toks, i, depth):
    opts = ARG_OPTS.get(b, set())
    while i < len(toks) and toks[i].startswith("-") and toks[i] != "-":
        if toks[i] in ("-S", "--split-string") and b == "env" and i + 1 < len(toks):
            check(toks[i + 1], depth + 1)
        if toks[i] == "-c" and b == "flock" and i + 1 < len(toks):
            check(toks[i + 1], depth + 1)
        i += 2 if toks[i] in opts else 1
    if b in ("timeout", "flock") and i < len(toks):
        i += 1  # the duration / the lock file
    return i


def segment(toks, depth):
    i = 0
    while i < len(toks):
        t = toks[i]
        b = t.rsplit("/", 1)[-1]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
        elif b == "xargs":
            if any(w.rsplit("/", 1)[-1] in KILLS for w in toks[i + 1:]):
                raise Refuse("xargs ... kill: the targets are computed; " + RULE)
            return
        elif b in WRAP:
            i = skip_wrapper(b, toks, i + 1, depth)
        elif b in SHELLS:
            rest = toks[i + 1:]
            for j, a in enumerate(rest):
                if re.match(r"^-[A-Za-z]*c[A-Za-z]*$", a) and j + 1 < len(rest):
                    check(rest[j + 1], depth + 1)
                    break
            return
        elif b == "eval" or b in ("ssh", "tmux", "screen"):
            check(" ".join(toks[i + 1:]), depth + 1)
            return
        elif b in ("su", "runuser"):
            rest = toks[i + 1:]
            for j, a in enumerate(rest):
                if a in ("-c", "--command") and j + 1 < len(rest):
                    check(rest[j + 1], depth + 1)
                elif a.startswith("--command="):
                    check(a.split("=", 1)[1], depth + 1)
            return
        elif b == "killall":
            raise Refuse("killall matches by name across every seat; " + RULE)
        elif b == "pkill":
            pkill(toks[i + 1:])
            return
        elif b == "kill":
            kill(toks[i + 1:])
            return
        else:
            return


# pkill short options that take a value (pkill -h)
PKILL_ARG = set("gGOPstuUFrnc")
PKILL_FLAG_LONG = ("--exact", "--newest", "--oldest", "--inverse", "--echo", "--count",
                   "--ignore-case", "--list-name", "--list-full", "--require-handler")


def pkill(args):
    pats, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pats.extend(args[i + 1:])
            break
        if a.startswith("--"):
            name = a.split("=", 1)[0]
            if len(name) >= 3 and "--full".startswith(name):
                raise Refuse("pkill --full matches every seat\x27s argv; " + RULE)
            i += 1 if "=" in a or name in PKILL_FLAG_LONG else 2
            continue
        if a.startswith("-") and len(a) > 1:
            if re.match(r"^-([0-9]+|[A-Z][A-Z0-9+-]*)$", a):
                i += 1  # a signal: -9, -TERM, -HUP
                continue
            for n, c in enumerate(a[1:]):
                if c == "f":
                    raise Refuse("pkill -f matches every seat\x27s argv; " + RULE)
                if c in PKILL_ARG:
                    if n == len(a) - 2:
                        i += 1  # the value is the next word
                    break
            i += 1
            continue
        pats.append(a)
        i += 1
    for p in pats:
        if "$" in p or "`" in p:
            raise Refuse("pkill with a computed pattern %s; %s" % (p, RULE))
        for name in ("tmux", "cron", "systemd", "sshd", "init") + tuple(sorted(AGENTS)):
            try:
                hit = re.search(p, name)
            except re.error:
                hit = p in name
            if hit:
                raise Refuse("pkill %s matches %s; %s" % (p, name, RULE))


def kill(args):
    targets, i, sig = [], 0, False
    while i < len(args):
        a = args[i]
        if a == "--":
            targets.extend(args[i + 1:])
            break
        if a in ("-l", "-L", "--list", "--table"):
            return
        if a in ("-s", "-n", "--signal") and not targets:
            sig = True
            i += 2
            continue
        if a.startswith("-") and len(a) > 1 and not targets and not sig:
            sig = True  # the first -X is the signal: -9, -TERM, -SIGKILL
            i += 1
            continue
        targets.append(a)
        i += 1
    for t in targets:
        if t in OWN or t.startswith("%"):
            continue
        if "$" in t or "`" in t or "*" in t:
            raise Refuse("kill with a computed target %s cannot be read before it runs; %s" % (t, RULE))
        if not re.match(r"^-?[0-9]+$", t):
            raise Refuse("kill target %s is not a pid; %s" % (t, RULE))
        n = int(t)
        if n < 0:
            raise Refuse("kill %s signals a process group; %s" % (t, RULE))
        if n == 0:
            raise Refuse("kill 0 signals the caller\x27s whole process group; " + RULE)
        if n == 1:
            raise Refuse("kill 1 targets init; " + RULE)
        literal(n)


_PS = None


def table():
    global _PS
    if _PS is None:
        out = subprocess.run(["ps", "-eo", "pid=,ppid=,args="], capture_output=True,
                             text=True, timeout=10, check=True).stdout
        _PS = {}
        for line in out.splitlines():
            f = line.split(None, 2)
            if len(f) >= 2 and f[0].isdigit() and f[1].isdigit():
                _PS[int(f[0])] = (int(f[1]), f[2] if len(f) > 2 else "")
    return _PS


def names(args):
    w = args.split()
    first = w[0].rstrip(":").rsplit("/", 1)[-1].lower() if w else ""
    second = w[1].rsplit("/", 1)[-1].lower() if len(w) > 1 else ""
    return first, second


def is_agent(args):
    a, b = names(args)
    if a in AGENTS:
        return a
    if re.match(r"^(node|bun|python[0-9.]*)$", a) and b in AGENTS:
        return b
    return None


def self_pid(ps):
    v = os.environ.get("KILL_GUARD_SELF_PID", "")
    if v.isdigit():
        return int(v)
    p, seen = os.getppid(), set()
    while p > 1 and p in ps and p not in seen:
        seen.add(p)
        if is_agent(ps[p][1]):
            return p
        p = ps[p][0]
    return None


def literal(n):
    ps = table()
    if n not in ps:
        return  # no such process: kill fails on its own
    me = self_pid(ps)
    p, seen = n, set()
    while me is not None and p > 0 and p in ps and p not in seen:
        if p == me:
            return  # the caller agent or one of its descendants
        seen.add(p)
        p = ps[p][0]
    args = ps[n][1]
    first, _ = names(args)
    if PROTECTED.match(first):
        raise Refuse("kill %d targets %s; %s" % (n, first, RULE))
    who = is_agent(args)
    if who:
        raise Refuse("kill %d targets another agent\x27s %s process; %s" % (n, who, RULE))


def main():
    try:
        check(sys.argv[1])
    except Refuse as e:
        print("kill-guard: refused: %s" % e, file=sys.stderr)
        sys.exit(2)
    except Exception as e:
        print("kill-guard: refused: guard error %s (fail closed)" % type(e).__name__, file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
'

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1-}" = --check ] && [ $# -eq 2 ]; then
    kill_target_guard_check "$2"
    exit $?
  fi
  echo "usage: bash kill-target-guard.inc.sh --check \"<command>\"  (rc 0 allow, 2 refuse)" >&2
  exit 64
fi
