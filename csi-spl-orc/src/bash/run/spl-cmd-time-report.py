#!/usr/bin/env python3
"""Wait time per Bash ACTION from Claude Code transcripts (spl-cmd-time-report).

  scan   SINCE UNTIL ROLEMAP DIR...   -> one TSV row per finished Bash call:
                                         <action>\t<role>\t<seconds>
  report SINCE UNTIL TOP ROLE         -> reads scan rows on stdin, prints the
                                         markdown table ranked by total wait

Only the normalised ACTION name ever leaves `scan`: the `./run -a do_X` name,
a script's basename, or the first program (plus the verb of a few CLIs). No
argument, no output, no path. A name that is not a plain word is "<other>".
ROLEMAP is "<rundir basename>=<role>,..." (orch, dispatcher); any other
csi-spl-wt/<dir> cwd is a lane, any other cwd is "other".
"""
import datetime
import glob
import json
import os
import re
import shlex
import statistics
import sys

NAME_RX = re.compile(r"^[A-Za-z0-9._+-]{1,60}$")
VERB_RX = re.compile(r"^[a-z][a-z0-9-]{0,30}$")
RUN_RX = re.compile(r"(?:^|[\s;&|('\"])(?:\S*/)?run\s+-a\s+(do_[A-Za-z0-9_]+)")
VERB_CLIS = {"git", "gh", "spool", "go", "pnpm", "npm", "docker", "gcloud",
             "terraform", "tmux", "systemctl", "kubectl", "make"}
SHELLS = {"bash", "sh", "zsh"}
INTERPRETERS = {"python", "python3", "node", "perl"}
PREFIXES = {"time", "nice", "nohup", "exec", "command", "stdbuf", "builtin"}
SOFT = {"cd", "pushd", "popd", "export", "set", "unset", "local", ":", "true",
        "false", "echo", "printf", "date", "source", ".", "trap", "shopt",
        "umask", "declare", "readonly", "sleep", "test", "break", "continue",
        "exit", "return", "wait"}
PUNCT = set("();<>|&")
KEYWORDS = {"do", "then", "else", "elif", "if", "!", "time"}
LOOPS = {"while", "until"}
SKIP_SEGS = {"for", "done", "fi", "esac", "case", "select", "function"}
VAR_RX = re.compile(r"^\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?$")
ASSIGN_RX = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)=(.*)$", re.S)


def clean(name):
    name = os.path.basename(name)
    return name if NAME_RX.match(name) else "<other>"


def segments(cmd):
    try:
        lex = shlex.shlex(cmd.replace("\n", " ; "), posix=True, punctuation_chars=True)
        lex.whitespace_split = True
        toks = list(lex)
    except ValueError:
        toks = cmd.split()
    seg, depth, prev, redirect = [], 0, "", False
    for t in toks:
        if set(t) <= PUNCT:
            # $( ... ) and $(( ... )) are an argument's value, not a command.
            if depth or (t.startswith("(") and prev.endswith("$")):
                depth = max(0, depth + t.count("(") - t.count(")"))
                t = t.lstrip("()") if not depth else ""
            prev = t
            if not t:
                continue
            if set(t) <= set("<>"):
                redirect = True
                continue
            if seg:
                yield seg
            seg = []
        elif depth:
            prev = t
        elif redirect:
            redirect = False
        else:
            prev = t
            seg.append(t)
    if seg:
        yield seg


def strip_wrappers(seg):
    """Drop env assignments and the sudo / env / su / timeout style prefixes."""
    i = 0
    while i < len(seg):
        t = seg[i]
        if re.match(r"^[A-Za-z_][A-Za-z0-9_]*=", t):
            i += 1
        elif t == "env":
            i += 1
            while i < len(seg) and (seg[i].startswith("-") or "=" in seg[i]):
                i += 2 if seg[i] in ("-u", "-C") else 1
        elif t == "sudo":
            i += 1
            while i < len(seg) and seg[i].startswith("-"):
                i += 2 if seg[i] in ("-u", "-g", "-C", "-D", "-h", "-p") else 1
        elif t == "su":
            rest = seg[i + 1:]
            if "-c" in rest and rest.index("-c") + 1 < len(rest):
                return ["bash", "-c", rest[rest.index("-c") + 1]]
            return []
        elif t == "timeout":
            i += 1
            while i < len(seg) and seg[i].startswith("-"):
                i += 1
            i += 1
        elif t in PREFIXES:
            i += 1
        else:
            break
    return seg[i:]


def expand(seg, env):
    """A command named through a variable (S=...; $S args) is its value."""
    m = VAR_RX.match(seg[0]) if seg else None
    if not m or m.group(1) not in env:
        return seg[:1] + [subst(t, env) for t in seg[1:]]
    try:
        head = shlex.split(env[m.group(1)])
    except ValueError:
        head = env[m.group(1)].split()
    return head + [subst(t, env) for t in seg[1:]]


def subst(tok, env):
    m = VAR_RX.match(tok)
    return env[m.group(1)] if m and m.group(1) in env else tok


def seg_action(seg, depth, env):
    while seg and seg[0] in KEYWORDS:
        seg = seg[1:]
    if not seg or seg[0] in SKIP_SEGS or seg[0] in ("{", "}"):
        return None
    if all(ASSIGN_RX.match(t) for t in seg):
        for t in seg:
            k, v = ASSIGN_RX.match(t).groups()
            env[k] = v
        return None
    seg = strip_wrappers(expand(strip_wrappers(seg), env))
    if not seg:
        return None
    prog = os.path.basename(seg[0])
    if prog in ("[", "[[", "test"):
        return "test"
    if prog in SHELLS:
        rest = seg[1:]
        flags = [t for t in rest if re.match(r"^-[a-zA-Z]*c[a-zA-Z]*$", t)]
        if flags and rest.index(flags[0]) + 1 < len(rest):
            return action(rest[rest.index(flags[0]) + 1], depth + 1)
        rest = [t for t in rest if not t.startswith("-")]
        return clean(rest[0]) if rest else prog
    if prog in INTERPRETERS:
        rest = [t for t in seg[1:] if not t.startswith("-")]
        if "-c" in seg[1:] or "-" in seg[1:] or not rest:
            return prog
        return clean(rest[0])
    if prog in VERB_CLIS:
        return verb_action(prog, seg[1:])
    return clean(prog)


def verb_action(prog, args):
    """git -C <dir> log -> "git log"; the verb(s) only, never what follows."""
    i = 0
    while i < len(args) and args[i].startswith("-"):
        i += 2 if args[i] in ("-C", "-c", "-R", "-f", "--repo", "--git-dir", "--work-tree") else 1
    verb = args[i] if i < len(args) else ""
    if not VERB_RX.match(verb):
        return prog
    sub = args[i + 1] if prog == "gh" and i + 1 < len(args) else ""
    # gh has two verbs: "gh run watch" waits on CI, "gh run list" does not.
    return f"{prog} {verb} {sub}" if VERB_RX.match(sub) else f"{prog} {verb}"


def action(cmd, depth=0):
    """The ACTION a command spends its time in; never an argument."""
    m = RUN_RX.search(cmd)
    if m:
        return m.group(1)
    if depth > 3:
        return "<other>"
    env, acts, loop, in_for = {}, [], False, False
    for seg in segments(cmd):
        if seg[0] == "for":
            in_for = True
        if in_for and seg[0] != "do":
            continue
        in_for = False
        if seg[0] in LOOPS:
            loop, seg = True, seg[1:]
        a = seg_action(seg, depth, env)
        if a == "sleep":
            loop = loop or seg_has_loop(cmd)
        if a is not None:
            acts.append(a)
    hard = [a for a in acts if a.split(" ")[0] not in SOFT]
    best = (hard or acts or ["<other>"])[0]
    return f"poll-loop {best}" if loop else best


def seg_has_loop(cmd):
    return bool(re.search(r"(^|[;&|\s])(for|while|until)\s", cmd))


def ts(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def role_of(cwd, rolemap):
    m = re.search(r"/csi-spl-wt/([^/]+)", cwd or "")
    if not m:
        return "other"
    return rolemap.get(m.group(1), "lane")


def scan_file(path, since, until, rolemap, out):
    calls = {}
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except OSError:
        print(f"unreadable transcript skipped: {os.path.basename(path)}", file=sys.stderr)
        return
    with fh:
        for line in fh:
            if '"tool_' not in line:
                continue
            try:
                rec = json.loads(line)
                content = (rec.get("message") or {}).get("content")
                when = ts(rec["timestamp"])
            except (ValueError, KeyError, TypeError, AttributeError):
                continue
            if not isinstance(content, list):
                continue
            for b in content:
                if not isinstance(b, dict):
                    continue
                if b.get("type") == "tool_use" and b.get("name") == "Bash":
                    inp = b.get("input") or {}
                    if inp.get("run_in_background") or not since <= when < until:
                        continue
                    calls[b.get("id")] = (when, inp.get("command") or "", rec.get("cwd"))
                elif b.get("type") == "tool_result" and b.get("tool_use_id") in calls:
                    start, cmd, cwd = calls.pop(b["tool_use_id"])
                    secs = max(0.0, when - start)
                    out.write(f"{action(cmd)}\t{role_of(cwd, rolemap)}\t{secs:.3f}\n")


def scan(argv):
    """argv: SINCE UNTIL ROLEMAP DIR...; DIR is a ~/.claude/projects dir."""
    since, until = ts(argv[0]), ts(argv[1])
    rolemap = dict(p.split("=", 1) for p in argv[2].split(",") if "=" in p)
    for d in argv[3:]:
        for path in sorted(glob.glob(os.path.join(d, "*", "*.jsonl"))):
            try:
                if os.path.getmtime(path) < since:
                    continue
            except OSError:
                continue
            scan_file(path, since, until, rolemap, sys.stdout)


def p90(xs):
    xs = sorted(xs)
    return xs[min(len(xs) - 1, int(round(0.9 * (len(xs) - 1))))]


def report(argv):
    since, until, top, want = argv[0], argv[1], int(argv[2]), argv[3]
    acts = {}
    for line in sys.stdin:
        parts = line.rstrip("\n").split("\t")
        if len(parts) != 3:
            continue
        act, role, secs = parts[0], parts[1], float(parts[2])
        if want and role != want:
            continue
        a = acts.setdefault(act, {"d": [], "r": {}})
        a["d"].append(secs)
        a["r"][role] = a["r"].get(role, 0.0) + secs
    total = sum(sum(a["d"]) for a in acts.values())
    ncalls = sum(len(a["d"]) for a in acts.values())
    print(f"Bash wait by action, {since} .. {until}"
          f"{', role ' + want if want else ''}: {ncalls} calls, {total:.0f} s total\n")
    print("| # | action | calls | total s | share % | median s | p90 s | max s | paid by (share of its wait) |")
    print("|---|---|---|---|---|---|---|---|---|")
    ranked = sorted(acts.items(), key=lambda kv: (-sum(kv[1]["d"]), kv[0]))
    for n, (act, a) in enumerate(ranked[:top], 1):
        s = sum(a["d"])
        roles = sorted(a["r"].items(), key=lambda kv: (-kv[1], kv[0]))
        paid = ", ".join(f"{r} {100 * v / s:.0f}%" if s else r for r, v in roles)
        share = 100 * s / total if total else 0.0
        print(f"| {n} | `{act}` | {len(a['d'])} | {s:.0f} | {share:.1f}"
              f" | {statistics.median(a['d']):.1f} | {p90(a['d']):.1f} | {max(a['d']):.1f} | {paid} |")
    rest = ranked[top:]
    if rest:
        s = sum(sum(a["d"]) for _, a in rest)
        c = sum(len(a["d"]) for _, a in rest)
        share = 100 * s / total if total else 0.0
        print(f"| - | ({len(rest)} more actions) | {c} | {s:.0f} | {share:.1f} | | | | |")


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("scan", "report"):
        sys.exit("usage: spl-cmd-time-report.py scan SINCE UNTIL ROLEMAP DIR... | report SINCE UNTIL TOP ROLE")
    (scan if sys.argv[1] == "scan" else report)(sys.argv[2:])
