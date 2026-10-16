#!/usr/bin/env bash
# force-push-guard.inc.sh — the ONE decision "is this shell command a forbidden
# push form?", shared by every harness guard (the vibe pre_tool hook, and the
# claude / grok / agy / qwen hooks). Owner order, t1 4e373f5d: nobody
# force-pushes master without the owner's explicit approval.
#
#   force_push_guard_check "<command>"
#       rc 0  allow (prints nothing)
#       rc 2  refuse; one line "force-push-guard: refused: <reason>" on stderr
#   bash force-push-guard.inc.sh --check "<command>"   the same, run directly
#
# Refused anywhere in the command: after ; && || | & newlines, backticks and
# $( ), and inside bash/sh/zsh -c, eval, su -c, ssh, env -S and the wrappers
# env, sudo, command, exec, nohup, timeout, xargs, ... :
#   - git push -f / --force / --force-with-lease / --force-if-includes /
#     --mirror (also inside combined short flags such as -fu)
#   - git push with a +refspec (+HEAD:master, +master)
#   - git push deleting master: :master, :refs/heads/master, or --delete / -d
#     with master as the refspec
#   - git -c remote.<r>.push=+..., remote.<r>.mirror=..., or an alias.<a>=
#     that expands to one of the above
#   - git push --no-verify, and git -c / --config-env core.hooksPath=... or
#     GIT_CONFIG_KEY_<n>=core.hooksPath / GIT_CONFIG_PARAMETERS on a push:
#     each skips the pre-push hook (the gate this guard backs up). A long
#     option is matched by any prefix git accepts (--no-veri, --mirr, --forc).
#     git push -n is --dry-run (git push -h), not a skip, and stays allowed.
#   - SPL_PREPUSH_OVERRIDE assigned anything but empty or 0 (a prefix
#     assignment, env, export / declare / typeset / readonly / local); a
#     command that only NAMES it (a grep pattern, an echo) is not refused
# A plain `git push origin HEAD:master` is allowed. A command that only reaches
# git through a variable or a script file is not read (the pre-push hook and
# the GitHub ruleset are the layers behind this one).
# Heredoc bodies are data and are not read, unless a shell or eval on the
# same line reads them (bash <<EOF, cat <<EOF | sh): then they are checked.
# Fails CLOSED: no python3, a guard error, or an untokenizable command that
# mentions push is refused.

force_push_guard_check() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "force-push-guard: refused: python3 is missing, the guard cannot read the command (fail closed)" >&2
    return 2
  fi
  python3 -c "$_FORCE_PUSH_GUARD_PY" "${1-}"
}

# shellcheck disable=SC2016  # python source, never expanded by bash
_FORCE_PUSH_GUARD_PY='
import re, shlex, sys

OVERRIDE = "SPL_PREPUSH_OVERRIDE"
# The override as an ASSIGNMENT in raw text: only used when the command cannot
# be tokenized. A grep pattern or an echo that names the variable is not one.
OVERRIDE_RAW = re.compile(r"(?:^|[\s;&|(`])(?:export\s+|declare\s+-\w+\s+|env\s+)?SPL_PREPUSH_OVERRIDE=(?![\"\x27]{2}|\s|;|&|\||$|0(?![^\s;&|]))")
DECLARE = {"export", "declare", "typeset", "readonly", "local"}
FORCE_LONG = ("--force", "--force-with-lease", "--force-if-includes", "--mirror")
NO_VERIFY = "--no-verify"
HOOKS = "core.hookspath"
SHELLS = {"bash", "sh", "zsh", "dash", "ksh", "fish", "busybox"}
WRAP = {"env", "command", "exec", "nohup", "time", "nice", "ionice", "setsid",
        "stdbuf", "timeout", "xargs", "builtin", "chronic", "unbuffer", "flock",
        "doas", "sudo", "then", "do", "else", "!", "watch", "parallel", "strace"}
ARG_OPTS = {"sudo": {"-u", "-g", "-C", "-D", "-h", "-p", "-r", "-t", "-U", "-T"},
            "env": {"-u", "--unset", "-C", "--chdir", "-S", "--split-string"},
            "nice": {"-n", "--adjustment"}, "ionice": {"-c", "-n", "-t"},
            "timeout": {"-s", "--signal", "-k", "--kill-after"},
            "xargs": {"-I", "-L", "-n", "-P", "-d", "-E", "-a", "-s"},
            "flock": {"-w", "-E", "-c"}, "watch": {"-n", "-d"},
            "stdbuf": {"-i", "-o", "-e"}}
GIT_ARG_OPTS = {"-C", "--git-dir", "--work-tree", "--namespace", "--exec-path", "--config-env"}
PUSH_ARG_OPTS = {"-o", "--push-option", "--repo", "--receive-pack", "--exec"}
MASTER = {"master", "refs/heads/master"}
APPROVAL = "forbidden without the owner\x27s explicit approval"


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


def check(cmd, depth=0):
    if depth > 8:
        raise Refuse("the command nests too deep to read (fail closed)")
    if "<<" in cmd:
        cmd = heredocs(cmd, depth)
    try:
        segs = split(cmd)
    except ValueError as e:
        # Fail closed only where a push can hide: the override assigned, or
        # git followed by push. A grep pattern that only names push passes.
        if OVERRIDE_RAW.search(cmd):
            raise Refuse("SPL_PREPUSH_OVERRIDE bypasses the pre-push gate; " + APPROVAL)
        if re.search(r"\bgit\b.*\bpush\b", cmd, re.S):
            raise Refuse("cannot tokenize a command with git ... push (%s); fail closed" % e)
        return
    for seg in segs:
        segment(seg, depth)


HEREDOC = re.compile(r"(?<!<)<<(-?)\s*([\"\x27]?)([A-Za-z_][A-Za-z0-9_]*)\2")


def heredocs(cmd, depth):
    """Cut heredoc bodies out of cmd: a body is data (a commit message whose
    prose names git and push, with an apostrophe, is not a command). A body
    that a shell or eval on the same line reads (bash <<EOF, cat <<EOF | sh)
    is checked as a command."""
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


def override(tok):
    """Refuse the override assigned anything but empty or 0."""
    name, eq, val = tok.partition("=")
    if eq and name == OVERRIDE and val not in ("", "0"):
        raise Refuse("SPL_PREPUSH_OVERRIDE bypasses the pre-push gate; " + APPROVAL)


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
    i, hooks = 0, False
    while i < len(toks):
        t = toks[i]
        b = t.rsplit("/", 1)[-1]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            override(t)
            hooks = hooks or hooks_env(t)
            i += 1
        elif b in DECLARE:
            for a in toks[i + 1:]:
                override(a)
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
        else:
            if b == "git":
                git(toks[i + 1:], depth, hooks)
            return


def hooks_env(tok):
    """GIT_CONFIG_KEY_<n>=core.hooksPath or GIT_CONFIG_PARAMETERS naming it."""
    name, _, val = tok.partition("=")
    if re.match(r"^GIT_CONFIG_KEY_[0-9]+$", name):
        return val.strip().lower() == HOOKS
    return name == "GIT_CONFIG_PARAMETERS" and HOOKS in val.lower()


def git(args, depth, hooks=False):
    i = 0
    while i < len(args):
        a = args[i]
        if a == "-c" and i + 1 < len(args):
            gitcfg(args[i + 1], depth)
            hooks = hooks or args[i + 1].lower().startswith(HOOKS + "=")
            i += 2
        elif a.startswith("--config-env"):
            kv = a.split("=", 1)[1] if "=" in a else (args[i + 1] if i + 1 < len(args) else "")
            hooks = hooks or kv.lower().startswith(HOOKS + "=")
            i += 1 if "=" in a else 2
        elif a in GIT_ARG_OPTS:
            i += 2
        elif a.startswith("-"):
            i += 1
        else:
            break
    if i < len(args) and args[i] == "push":
        if hooks:
            raise Refuse("git core.hooksPath on a push skips the pre-push hook; " + APPROVAL)
        push(args[i + 1:])


def gitcfg(kv, depth):
    k, _, v = kv.partition("=")
    k = k.lower()
    if re.match(r"^remote\..+\.push$", k) and v.startswith("+"):
        raise Refuse("git -c %s=+... is a forced push refspec; %s" % (k, APPROVAL))
    if re.match(r"^remote\..+\.mirror$", k):
        raise Refuse("git -c %s turns push into --mirror; %s" % (k, APPROVAL))
    if k.startswith("alias."):
        check(v[1:] if v.startswith("!") else "git " + v, depth + 1)


def push(args):
    pos, delete = [], False
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--":
            pos.extend(args[i + 1:])
            break
        if a.startswith("--"):
            name = a.split("=", 1)[0]
            if len(name) >= 5 and NO_VERIFY.startswith(name):
                raise Refuse("git push %s skips the pre-push hook; %s" % (name, APPROVAL))
            if name in FORCE_LONG or (len(name) >= 5 and any(f.startswith(name) for f in FORCE_LONG)):
                raise Refuse("git push %s rewrites remote history; %s" % (name, APPROVAL))
            if name == "--delete":
                delete = True
            i += 2 if name in PUSH_ARG_OPTS and "=" not in a else 1
            continue
        if a.startswith("-") and len(a) > 1:
            flags = a[1:]
            for n, c in enumerate(flags):
                if c == "f":
                    raise Refuse("git push -f is a force push; " + APPROVAL)
                if c == "d":
                    delete = True
                if c == "o":
                    if n == len(flags) - 1:
                        i += 1  # -o takes the next word
                    break
            i += 1
            continue
        pos.append(a)
        i += 1
    for r in pos:
        if r.startswith("+"):
            raise Refuse("git push %s is a forced refspec (+); %s" % (r, APPROVAL))
        if r.startswith(":") and r[1:] in MASTER:
            raise Refuse("git push %s deletes master; %s" % (r, APPROVAL))
        if delete and r.split(":")[-1] in MASTER:
            raise Refuse("git push --delete %s deletes master; %s" % (r, APPROVAL))


try:
    check(sys.argv[1])
except Refuse as e:
    print("force-push-guard: refused: %s" % e, file=sys.stderr)
    sys.exit(2)
except Exception as e:
    print("force-push-guard: refused: guard error %s (fail closed)" % type(e).__name__, file=sys.stderr)
    sys.exit(2)
'

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  if [ "${1-}" = --check ] && [ $# -eq 2 ]; then
    force_push_guard_check "$2"
    exit $?
  fi
  echo "usage: bash force-push-guard.inc.sh --check \"<command>\"  (rc 0 allow, 2 refuse)" >&2
  exit 64
fi
