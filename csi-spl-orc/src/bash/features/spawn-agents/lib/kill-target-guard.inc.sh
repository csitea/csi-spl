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
#   - tmux send-keys of /exit, /exit-clean or /kill-your-self into a pane that
#     holds another agent, by the same rule as a kill of its pid (SPL-5142):
#     the caller's own pane and a pane with no agent pass. A pane the guard
#     cannot resolve (computed, tmux has no answer, over ssh) is refused.
#     The text must be literal: a typed $var is not read, nor send-keys -H.
#     Quoted text is data (a message body), unless a shell, eval, ssh, ... runs it.
# Heredoc bodies are data, unless a shell or eval on the same line reads them.
# A script file that runs kill is not read: an action's own stop code is its
# own, so rotation and close-window, which type /exit in their scripts, pass.
# Fails CLOSED: no python3, a guard error or an untokenizable command
# that runs kill is refused. KILL_GUARD_SELF_PID names the caller agent's pid
# (tests); else it is the nearest agent process above the hook.

kill_target_guard_check() {
  case "${1-}" in *kill*|*send*) ;; *) return 0 ;; esac
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
SEND = {"send-keys", "send"}
EXIT_TEXT = re.compile(r"^\s*/(exit|exit-clean|kill-your-self)(\s|$)")
KEY_NAME = re.compile(r"^(Enter|KPEnter|Escape|Tab|BSpace|[CMS]-.+)$")
OWN_PANE = {"$TMUX_PANE", "${TMUX_PANE}"}
TMUX_ARG = {"-S", "-L", "-f", "-c", "-T"}
EXIT_RULE = "never type an exit command into another agent\x27s pane; ask it through the spool"
REMOTE_EXIT = re.compile(r"\btmux\s.*\bsend(-keys)?\s.*/(exit|exit-clean|kill-your-self)(\s|$|[\"\x27])")
RAW_EXIT = re.compile(r"(^|[\s;&|(`/])tmux\s.*\bsend(-keys)?\s.*/(exit|kill-your-self)")
COMPUTED_PANE = re.compile(r"(^|[\s;&|(`/\"\x27])tmux\s[^;&|\n]*\bsend(-keys)?\s[^;&|\n]*-t\s*(\$\(|`)[^\n]*/(exit|kill-your-self)")
TMUX_WORD = re.compile(r"(^|[\s;&|(`/\"\x27])tmux\s")
RUNNERS = SHELLS | {"eval", "ssh", "screen", "su", "runuser", "env", "flock", "watch"}
RUN_AS = None  # the user a sudo / su around the tmux runs it as
SOCK = []  # the -S / -L of the tmux, kept for the next command of a chain


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


def open_quote(cmd, end):
    """Where the quote holding cmd[end] opens; None if it is live shell text."""
    stack, i = [], 0
    while i < end:
        c = cmd[i]
        top = stack[-1][0] if stack else None
        if top == "\x27":
            if c == top:
                stack.pop()
        elif c == "\\":
            i += 1
        elif c == "$" and cmd[i + 1:i + 2] == "(":
            stack.append(("(", i))
            i += 1
        elif c == ")" and top == "(":
            stack.pop()
        elif c in "\"`" and top == c:
            stack.pop()
        elif c in "\"`\x27":
            stack.append((c, i))
        i += 1
    return stack[-1][1] if stack and stack[-1][0] in "\"\x27" else None


def is_data(cmd, pos):
    """Quoted text is an argument, unless a shell-like runner on its command runs it."""
    q = open_quote(cmd, pos)
    if q is None:
        return False
    words = re.split(r"[;&|(\n]", cmd[:q])[-1].split()
    return not any(w.rsplit("/", 1)[-1] in RUNNERS for w in words)


def check(cmd, depth=0):
    if depth > 8:
        raise Refuse("the command nests too deep to read (fail closed)")
    if "kill" not in cmd and "send" not in cmd:
        return
    if "<<" in cmd:
        cmd = heredocs(cmd, depth)
    try:
        segs = split(cmd)
    except ValueError as e:
        if re.search(r"(^|[\s;&|(`/])(kill|pkill|killall)(\s|$)", cmd):
            raise Refuse("cannot tokenize a command that runs kill (%s); fail closed" % e)
        if RAW_EXIT.search(cmd):
            raise Refuse("cannot tokenize a tmux send-keys of an exit command (%s); fail closed" % e)
        return
    for seg in segs:
        segment(seg, depth)
    # split() cuts $( ) and backticks into their own segments, so a kill fed
    # by one shows up with no target there: read the raw text for it.
    if re.search(r"(^|[\s;&|(`/])(kill|pkill)\s[^;&|\n]*(\$\(|`)", cmd):
        raise Refuse("kill with a computed target list ($( ) or backticks); " + RULE)
    if any(COMPUTED_PANE.match(cmd, m.start()) and not is_data(cmd, m.end() - 1)
           for m in TMUX_WORD.finditer(cmd)):
        raise Refuse("send-keys of an exit command to a computed pane; " + EXIT_RULE)


def skip_wrapper(b, toks, i, depth):
    global RUN_AS
    opts = ARG_OPTS.get(b, set())
    if b == "sudo":
        RUN_AS = "root"
    while i < len(toks) and toks[i].startswith("-") and toks[i] != "-":
        if b == "sudo" and toks[i] == "-u" and i + 1 < len(toks):
            RUN_AS = toks[i + 1]
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
        elif b == "tmux":
            tmux(toks[i + 1:], depth)
            return
        elif b in SEND:
            send_keys(toks[i + 1:])
            return
        elif b == "ssh" and REMOTE_EXIT.search(" ".join(toks[i + 1:])):
            raise Refuse("send-keys of an exit command over ssh cannot be judged here; " + EXIT_RULE)
        elif b == "eval" or b in ("ssh", "screen"):
            check(" ".join(toks[i + 1:]), depth + 1)
            return
        elif b in ("su", "runuser"):
            rest = toks[i + 1:]
            global RUN_AS
            RUN_AS = next((a for j, a in enumerate(rest) if not a.startswith("-")
                           and (j == 0 or rest[j - 1] not in ("-c", "--command"))), "root")
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


def tmux(args, depth):
    global SOCK
    i = 0
    while i < len(args) and args[i].startswith("-"):
        if args[i] in ("-S", "-L") and i + 1 < len(args):
            SOCK = args[i:i + 2]
        i += 2 if args[i] in TMUX_ARG else 1
    if i < len(args) and args[i] in SEND:
        send_keys(args[i + 1:])
    else:
        check(" ".join(args), depth + 1)


def send_keys(args):
    """Judge one send-keys: only an exit command typed at a pane matters."""
    target, keys, i = None, [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            keys.extend(args[i + 1:])
            break
        if a.startswith("-") and len(a) > 1:
            for n, c in enumerate(a[1:]):
                if c == "X":
                    return  # a copy-mode command, nothing is typed
                if c in "ctN":
                    glued = a[n + 2:]
                    value = glued or (args[i + 1] if i + 1 < len(args) else "")
                    i += 0 if glued else 1
                    target = value if c == "t" else target
                    break
            i += 1
            continue
        keys.append(a)
        i += 1
    text = "".join(" " if k == "Space" else k for k in keys if not KEY_NAME.match(k))
    if EXIT_TEXT.match(text):
        pane(target)


def pane(target):
    """The kill rule for every agent process in the target pane."""
    if target in OWN_PANE:
        return
    if target and ("$" in target or "`" in target):
        raise Refuse("send-keys of an exit command to a computed pane %s; %s" % (target, EXIT_RULE))
    cmd = ["sudo", "-n", "-u", RUN_AS] if RUN_AS else []
    cmd += ["tmux"] + SOCK + ["display-message", "-p"] + (["-t", target] if target else []) + ["#{pane_pid}"]
    # a bad target is rc 0 with empty output, so only a pid counts as an answer
    out = subprocess.run(cmd, capture_output=True, text=True, timeout=10, check=False).stdout.strip()
    if not out.isdigit():
        raise Refuse("send-keys of an exit command: tmux cannot resolve pane %s; %s" % (target, EXIT_RULE))
    ps, todo, seen = table(), [int(out)], set()
    while todo:
        p = todo.pop()
        if p in seen:
            continue
        seen.add(p)
        todo.extend(c for c, v in ps.items() if v[0] == p)
        if p in ps and is_agent(ps[p][1]):
            literal(p, "send-keys of an exit command into pane %s" % target, EXIT_RULE)


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


def literal(n, what=None, rule=RULE):
    what = what or "kill %d" % n
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
        raise Refuse("%s targets %s; %s" % (what, first, rule))
    who = is_agent(args)
    if who:
        raise Refuse("%s targets another agent\x27s %s process; %s" % (what, who, rule))


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
