#!/usr/bin/env python3
"""The generated differential corpora of spl-cmd-guard (SPL-5392).

  corpus-gen.py soup   <seed> <n>          NUL-terminated commands on stdout:
                                           random words, quotes, separators,
                                           heredoc marks and Unicode blanks
  corpus-gen.py struct <seed> <n>          NUL-terminated commands: assignments,
                                           wrappers, git options, a verb and its
                                           arguments, nested in bash -c / eval /
                                           $( ) / heredocs, sometimes cut short
  corpus-gen.py payload <seed> <n> <dir>   n hook payload files in <dir>: every
                                           harness shape, wrong types, broken
                                           JSON, lone surrogates, NUL escapes

The same seed gives the same corpus, so a mismatch replays.
"""

import json
import os
import random
import shlex
import sys

SOUP = [
    "git",
    "push",
    "-f",
    "--force",
    "--forc",
    "--no-veri",
    "--no-verify",
    "--mirror",
    "-fu",
    "-uf",
    "-d",
    "--delete",
    "-o",
    "x",
    "origin",
    "HEAD:master",
    "+HEAD:master",
    ":master",
    ":refs/heads/master",
    "master",
    "main",
    "+main",
    "--",
    "-n",
    "sudo",
    "-u",
    "agentusr",
    "env",
    "-S",
    "-i",
    "bash",
    "-c",
    "-lc",
    "sh",
    "eval",
    "ssh",
    "box",
    "su",
    "--command=git push -f",
    "timeout",
    "60",
    "nohup",
    "flock",
    "/tmp/l",
    "xargs",
    "-I",
    "{}",
    "command",
    "exec",
    "!",
    "if",
    "then",
    "fi",
    "SPL_PREPUSH_OVERRIDE=1",
    "SPL_PREPUSH_OVERRIDE=0",
    "SPL_PREPUSH_OVERRIDE=",
    "export",
    "declare",
    "-x",
    "local",
    "GIT_ASKPASS=/bin/echo",
    "GIT_ASKPASS=",
    "SSH_ASKPASS=x",
    "GIT_CONFIG_KEY_0=core.hooksPath",
    "GIT_CONFIG_KEY_1=Credential.Helper",
    "GIT_CONFIG_PARAMETERS='core.hooksPath=/x'",
    "-C",
    "/opt/x",
    "core.hooksPath=/dev/null",
    "alias.p=push --force",
    "alias.q=!git push -f",
    "remote.origin.push=+HEAD:master",
    "remote.o.mirror=true",
    "credential.helper=store",
    "--config-env",
    "--config-env=core.hooksPath=X",
    "config",
    "--global",
    "credential.helper",
    "store",
    "--get",
    "set",
    "credential",
    "fill",
    "credential-store",
    "remote",
    "set-url",
    "add",
    "https://u:p@h.example.com/r.git",
    "HTTPS://tok@h/x",
    "https://h/x",
    "cat",
    "~/.git-credentials",
    "/x/.git-credentials",
    "grep",
    "find",
    "-exec",
    "rm",
    "echo",
    "printf",
    "tee",
    "cp",
    "ls",
    "&&",
    "||",
    ";",
    "|",
    "&",
    ">",
    ">>",
    "2>",
    "2>&1",
    "<",
    "$(",
    ")",
    "`",
    "\n",
    "'",
    '"',
    "\\",
    "\\\\",
    '"git push -f"',
    "'git push --force origin master'",
    "<<EOF",
    "<<-'EOF'",
    '<<"X"',
    "EOF",
    "\tEOF",
    "X",
    "cat <<EOF | sh",
    "\u00e9",
    "\ufb00",
    "\u00a0",
    "\u2028",
    "\x1c",
    "\u0130",
    "\u00df",
    "#",
    "~",
    "*",
    "?",
    "=",
    "0",
    "1",
    "push\u00a0-f",
]
ASSIGN = [
    "",
    "",
    "SPL_PREPUSH_OVERRIDE=1 ",
    "SPL_PREPUSH_OVERRIDE=0 ",
    "GIT_CONFIG_KEY_0=core.hooksPath ",
    "GIT_TRACE=1 ",
    "GIT_CONFIG_PARAMETERS=\"'core.hooksPath=/x'\" ",
    "GIT_ASKPASS= ",
]
WRAP = [
    "",
    "",
    "sudo -u agentusr ",
    "env ",
    "env -i PATH=/usr/bin ",
    "timeout 60 ",
    "nohup ",
    "command ",
    "exec ",
    "nice -n 5 ",
    "xargs -I {} ",
    "flock /tmp/l ",
    "stdbuf -o0 ",
    "if ",
    "! ",
    "time ",
    "/usr/bin/env ",
]
GITOPT = [
    "",
    "",
    "-C /opt/x ",
    "-c user.name=x ",
    "-c core.hooksPath=/dev/null ",
    "-c CORE.HOOKSPATH= ",
    "--config-env=core.hooksPath=N ",
    "--config-env core.hooksPath=N ",
    "-c remote.origin.push=+HEAD:master ",
    "-c remote.o.mirror=1 ",
    "-c alias.p=push ",
    "--git-dir /x/.git ",
    "-c credential.helper=store ",
    "-c credential.helper= ",
    "-p ",
]
VERB = [
    "push",
    "push",
    "push",
    "push",
    "p",
    "fetch",
    "config",
    "remote set-url origin",
    "remote add x",
    "credential",
    "log",
    "commit -m",
]
PUSHARG = [
    "origin",
    "HEAD:master",
    "+HEAD:master",
    "+master",
    ":master",
    ":refs/heads/master",
    ":c-1",
    "master",
    "c-1-branch",
    "-f",
    "--force",
    "--forc",
    "--force-with-lease=master:abc",
    "--force-if-includes",
    "--mirror",
    "--mirr",
    "--no-verify",
    "--no-veri",
    "--no-v",
    "--verify",
    "-u",
    "-fu",
    "-uf",
    "-ud",
    "-d",
    "--delete",
    "-n",
    "--dry-run",
    "-o",
    "ci.skip",
    "-of",
    "--push-option",
    "x",
    "--push-option=x",
    "--repo",
    "r",
    "--",
    "https://u:p@h.example.com/r.git",
    "https://h/r.git",
    "--no-force-with-lease",
    "--force-wit",
    "refs/heads/master",
    "v1.2.3",
    "--delete=x",
    "-q",
    "--quiet",
    "-4",
]
CFGARG = [
    "--global",
    "credential.helper",
    "store",
    "--get",
    "set",
    "core.askPass",
    "/bin/echo",
    '""',
    "--file",
    "/x",
    "user.name",
    "--unset",
    "credential.https://h.helper",
    "get",
    "--add",
    "-l",
]


def soup(r):
    seps = [" ", " ", " ", "", "\t", "\n", " ; "]
    return "".join(r.choice(SOUP) + r.choice(seps) for _ in range(r.randint(1, 14)))


def inner(r):
    v = r.choice(VERB)
    args = [
        r.choice(CFGARG if v == "config" else PUSHARG) for _ in range(r.randint(0, 5))
    ]
    return (
        r.choice(ASSIGN)
        + r.choice(WRAP)
        + "git "
        + r.choice(GITOPT)
        + v
        + (" " + " ".join(args) if args else "")
    )


def nest(r, c, d=0):
    k = r.randint(0, 9)
    if d > 2 or k < 4:
        return c
    if k == 4:
        return "bash -c " + shlex.quote(nest(r, c, d + 1))
    if k == 5:
        return "sudo -u agentusr sh -lc " + shlex.quote(nest(r, c, d + 1))
    if k == 6:
        return "eval " + shlex.quote(nest(r, c, d + 1))
    if k == 7:
        return "echo $(" + nest(r, c, d + 1) + ")"
    if k == 8:
        head = r.choice(["bash <<'EOF'\n", "cat <<EOF\n", "cat <<-EOF | sh\n\t"])
        return head + nest(r, c, d + 1) + r.choice(["\nEOF", "\n\tEOF", ""])
    return "su agentusr -c " + shlex.quote(nest(r, c, d + 1))


def struct(r):
    c = r.choice([" && ", "; ", " || ", "\n", " | ", " & "]).join(
        nest(r, inner(r)) for _ in range(r.randint(1, 3))
    )
    return c[: r.randint(0, len(c))] if r.random() < 0.05 else c


CMDS = [
    "git status",
    "git push -f",
    "",
    "a\u0000b",
    "x\n\n",
    "\u00e9 \u2028",
    "\U0001f600 ok",
    "git push origin +HEAD:master",
]
NAMES = [
    "Bash",
    "bash",
    "BASH",
    "run_command",
    "Read",
    "shellTool",
    "",
    None,
    0,
    1,
    True,
    [],
    ["bash"],
    {},
    "run_shell_command",
]
BROKEN = [
    "[]",
    "",
    "null",
    "\ufeff{}",
    '{"tool_name":"Bash","tool_input":{"command":"\\ud800"}}',
    '{"a":NaN,"tool_input":{"command":"ls"}}',
    '{"tool_input":{"command":"x"},"tool_input":{"cmd":"y"}}',
]


def args(r):
    k, c = r.randint(0, 6), r.choice(CMDS)
    if k == 0:
        return {r.choice(["command", "CommandLine", "commandLine", "cmd", "other"]): c}
    if k == 1:
        return json.dumps({r.choice(["command", "cmd"]): c})
    if k == 2:
        return c
    if k == 3:
        return r.choice(["5", "[1]", '"x"', "null", "{", '{"command": 5}', "NaN"])
    if k == 4:
        return {"command": r.choice([5, None, ["x"], {"a": 1}])}
    if k == 5:
        return r.choice([None, 0, [], "", 7])
    return {"command": c, "cmd": "other"}


def payload(r):
    d = {}
    for k in r.sample(
        ["tool_name", "toolName", "tool_input", "toolInput", "toolCall", "x"],
        r.randint(0, 4),
    ):
        if k in ("tool_name", "toolName"):
            d[k] = r.choice(NAMES)
        elif k == "toolCall":
            d[k] = r.choice(
                [
                    {},
                    "x",
                    None,
                    {
                        r.choice(["name", "toolName"]): r.choice(NAMES),
                        r.choice(["args", "arguments", "input"]): args(r),
                    },
                ]
            )
        else:
            d[k] = args(r)
    s = json.dumps(d, ensure_ascii=r.random() < 0.5)
    m = r.randint(0, 12)
    if m == 0:
        s += "\n\n"
    elif m == 1:
        s = s[: r.randint(0, len(s))]
    elif m == 2:
        s = r.choice(BROKEN)
    elif m == 3:
        s = s.replace(" ", "\t\r\n ")
    return s


def main():
    mode, seed, n = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    r = random.Random(seed)
    if mode == "payload":
        for i in range(n):
            with open(
                os.path.join(sys.argv[4], "%05d.json" % i),
                "w",
                encoding="utf-8",
                errors="surrogatepass",
            ) as f:
                f.write(payload(r))
        return
    gen = {"soup": soup, "struct": struct}[mode]
    out = sys.stdout.buffer
    for _ in range(n):
        out.write(gen(r).encode("utf-8", "surrogatepass") + b"\0")


if __name__ == "__main__":
    main()
