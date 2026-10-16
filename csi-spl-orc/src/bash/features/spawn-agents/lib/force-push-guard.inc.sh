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
# Also refused, by the same reading (SPL-2187: a doc seat apt-installed
# systemd-resolved as root and took a box off DNS for 22 min; agents never
# change a box's system, the owner does), a SYSTEM CHANGE:
#   - packages: apt / apt-get / aptitude with a changing verb (install,
#     remove, purge, update, upgrade, ...; -s / --simulate passes), dpkg with
#     an action that is not a query (-i, -r, -P, --configure, ...), apt-mark
#     hold/unhold/auto/manual, snap install/remove/refresh, add-apt-repository,
#     apt-key, dpkg-reconfigure, debconf-set-selections, do-release-upgrade,
#     unattended-upgrade(s), update-alternatives with a changing action
#   - services: systemctl with a changing verb (start, stop, restart, enable,
#     mask, daemon-reload, ...; status / show / is-* / list-* and --user
#     pass), service <unit> <verb> but status, /etc/init.d/<x> <verb> but
#     status, update-rc.d, invoke-rc.d, resolvectl / hostnamectl /
#     timedatectl / localectl set-* (and resolvectl dns|domain <link> <value>),
#     reboot / shutdown / poweroff / halt / telinit
#   - /etc writes: a redirection (> or >>) to /etc/..., tee / rm / chmod /
#     chown / chgrp / setfacl / touch / truncate / mkdir / rmdir / unlink on
#     /etc/..., cp / mv / install / ln / rsync INTO /etc (the last word, or
#     -t), sed -i / perl -i on /etc/..., dd of=/etc/...
# Commands inside a container (docker run ... apt-get) are not the box's and
# are not read. A ban list cannot prove absence: a script file, a variable, a
# binary under another name or a container with / mounted is not read here.
# The restricted agent sudoers (csi-spl-iac do_spl_agent_sudoers) is the
# layer behind this one for root; neither stops a hop through the owner user.
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
SSH_ARG_OPTS = {"-b", "-c", "-D", "-E", "-e", "-F", "-I", "-i", "-J", "-L", "-l", "-m",
                "-O", "-o", "-p", "-Q", "-R", "-S", "-W", "-w"}
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
    segs, cur, redir = [], [], False
    for t in lx:
        if t and all(c in ";&|()<>" for c in t):
            if cur:
                segs.append(cur)
            cur = []
            redir = ">" in t and "<" not in t
            continue
        if redir:
            etc_write(t, "a redirection to " + t)
            redir = False
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
        elif t.startswith("/etc/init.d/"):
            system(t, b, toks[i + 1:])
            return
        elif b == "ssh":
            # the remote command, after the options and the host
            rest = toks[i + 1:]
            j = 0
            while j < len(rest) and rest[j].startswith("-"):
                j += 2 if rest[j] in SSH_ARG_OPTS else 1
            check(" ".join(rest), depth + 1)
            check(" ".join(rest[j + 1:]), depth + 1)
            return
        elif b == "eval" or b in ("tmux", "screen"):
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
            else:
                system(t, b, toks[i + 1:])
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


# SPL-2187: a system change (packages, services, /etc) belongs to the owner.
SYSTEM = "agents never change a box\x27s system (SPL-2187); send the exact command to the orchestrator for the owner\x27s go"
APT_READ = {"list", "search", "show", "showsrc", "showpkg", "policy", "depends", "rdepends",
            "madison", "changelog", "download", "source", "help", "moo", "stats", "dump",
            "pkgnames", "why", "why-not", "versions"}
APT_SIM = {"-s", "--simulate", "--just-print", "--dry-run", "--recon", "--no-act",
           "-h", "--help", "-v", "--version"}
APT_ARG_OPTS = {"-o", "--option", "-c", "--config-file", "-t", "--target-release",
                "-a", "--host-architecture"}
DPKG_READ = {"-l", "--list", "-L", "--listfiles", "-s", "--status", "-S", "--search",
             "-p", "--print-avail", "-c", "--contents", "-I", "--info", "-C", "--audit",
             "--get-selections", "--compare-versions", "--print-architecture",
             "--print-foreign-architectures", "--help", "--version", "-W", "--show",
             "-f", "--field", "-V", "--verify", "--no-act", "--dry-run", "--simulate",
             "--admindir", "--showformat"}
SYSTEMCTL_READ = {"status", "show", "cat", "help", "is-active", "is-enabled", "is-failed",
                  "is-system-running", "get-default", "show-environment", "list-units",
                  "list-unit-files", "list-sockets", "list-timers", "list-jobs",
                  "list-dependencies", "list-machines", "list-automounts", "list-paths"}
SYSTEMCTL_ARG_OPTS = {"-t", "--type", "-p", "--property", "-n", "--lines", "-o", "--output",
                      "-H", "--host", "-M", "--machine", "-s", "--signal", "--state", "--root"}
SNAP_READ = {"list", "find", "info", "version", "help", "changes", "services", "connections", "warnings"}
CTL_SET = {"resolvectl", "hostnamectl", "timedatectl", "localectl"}
CTL_ACT = {"revert", "flush-caches", "reset-statistics", "reset-server-features"}
CTL_LINK = {"dns", "domain", "default-route", "llmnr", "mdns", "dnssec", "dnsovertls", "nta"}
ALWAYS = {"add-apt-repository", "apt-key", "dpkg-reconfigure", "debconf-set-selections",
          "do-release-upgrade", "unattended-upgrade", "unattended-upgrades", "update-rc.d",
          "invoke-rc.d", "reboot", "shutdown", "poweroff", "halt", "telinit"}
ETC_ANY = {"tee", "rm", "chmod", "chown", "chgrp", "setfacl", "touch", "truncate",
           "mkdir", "rmdir", "unlink", "shred"}
ETC_DEST = {"cp", "mv", "install", "ln", "rsync"}
ETC_DEST_ARG_OPTS = {"-t", "--target-directory", "-S", "--suffix", "-m", "--mode",
                     "-o", "--owner", "-g", "--group"}


def etc_write(path, what):
    if path == "/etc" or path.startswith("/etc/"):
        raise Refuse("system change: %s writes the box\x27s /etc; %s" % (what, SYSTEM))


def positional(args, opts=()):
    out, i = [], 0
    while i < len(args):
        a = args[i]
        if a == "--":
            out.extend(args[i + 1:])
            break
        if a.startswith("-") and a != "-":
            i += 2 if a in opts else 1
            continue
        out.append(a)
        i += 1
    return out


def first(args, opts=()):
    pos = positional(args, opts)
    return pos[0] if pos else ""


def system(t, b, args):
    """Refuse a package, service or /etc change (SPL-2187)."""
    if b in ALWAYS:
        raise Refuse("system change: %s; %s" % (b, SYSTEM))
    if b in ("apt", "apt-get", "aptitude"):
        verb = first(args, APT_ARG_OPTS)
        if verb and verb not in APT_READ and not any(a in APT_SIM for a in args):
            raise Refuse("system change: %s %s changes the box\x27s packages; %s" % (b, verb, SYSTEM))
    elif b == "dpkg":
        acts = [a for a in args if a.startswith("-") and a.split("=", 1)[0] not in DPKG_READ]
        if acts:
            raise Refuse("system change: dpkg %s changes the box\x27s packages; %s" % (acts[0], SYSTEM))
    elif b == "apt-mark":
        if first(args) in ("hold", "unhold", "auto", "manual", "minimize-manual"):
            raise Refuse("system change: apt-mark %s; %s" % (first(args), SYSTEM))
    elif b == "snap":
        if first(args) not in SNAP_READ | {""}:
            raise Refuse("system change: snap %s; %s" % (first(args), SYSTEM))
    elif b == "update-alternatives":
        if not any(a in ("--display", "--query", "--list", "--get-selections", "--help", "--version") for a in args):
            raise Refuse("system change: update-alternatives; %s" % SYSTEM)
    elif b == "systemctl":
        verb = first(args, SYSTEMCTL_ARG_OPTS)
        if "--user" not in args and verb and verb not in SYSTEMCTL_READ:
            raise Refuse("system change: systemctl %s changes the box\x27s services; %s" % (verb, SYSTEM))
    elif b == "service" or t.startswith("/etc/init.d/"):
        pos = positional(args)
        verb = (pos[0] if pos else "") if t.startswith("/etc/init.d/") else (pos[1] if len(pos) > 1 else "")
        if verb and verb != "status":
            raise Refuse("system change: %s %s changes the box\x27s services; %s" % (b, verb, SYSTEM))
    elif b in CTL_SET:
        pos = positional(args)
        verb = pos[0] if pos else ""
        if verb.startswith("set-") or verb in CTL_ACT or (verb in CTL_LINK and len(pos) > 2):
            raise Refuse("system change: %s %s; %s" % (b, verb, SYSTEM))
    elif b == "init":
        if first(args) in ("0", "1", "6", "s", "S"):
            raise Refuse("system change: init %s; %s" % (first(args), SYSTEM))
    elif b in ETC_ANY:
        for a in positional(args):
            etc_write(a, b + " " + a)
    elif b in ETC_DEST:
        for j, a in enumerate(args):
            if a in ("-t", "--target-directory") and j + 1 < len(args):
                etc_write(args[j + 1], b + " -t " + args[j + 1])
            elif a.startswith("--target-directory="):
                etc_write(a.split("=", 1)[1], b + " " + a)
        pos = positional(args, ETC_DEST_ARG_OPTS)
        if b == "install" and any(re.match(r"^-[A-Za-z]*d", a) or a == "--directory" for a in args):
            for a in pos:
                etc_write(a, "install -d " + a)
        elif len(pos) >= 2:
            etc_write(pos[-1], "%s into %s" % (b, pos[-1]))
    elif b in ("sed", "perl"):
        if any(re.match(r"^-(?![MmIx])[A-Za-z]*i", a) or a.startswith("--in-place") for a in args):
            for a in positional(args, {"-e", "-f", "--expression", "--file"}):
                etc_write(a, b + " -i " + a)
    elif b == "dd":
        for a in args:
            if a.startswith("of="):
                etc_write(a[3:], "dd " + a)


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
