#!/usr/bin/env python3
"""The Python side of the spl-cmd-guard differential (SPL-5392), in one
process, so a corpus of 10^5 commands takes seconds, not hours.

  py-batch.py verdicts <force-push-guard.inc.sh>       NUL-separated commands
      on stdin; one line each, as `spl-cmd-guard batch` prints it: "0", or
      "2<TAB><reason>". The matcher source is the library's own
      _FORCE_PUSH_GUARD_PY, loaded the way spool-agent-hook.sh loads it.
  py-batch.py payloads <force-push-guard-hook.sh> <file>...
      "<file>|<answer>" per payload file: the hook's own extractor, with the
      hook's bash around it ($(cat) and $( ) drop NULs and trailing newlines):
      NONE, CMD:<command>, or unreadable. Newlines in an answer print as \\n.
"""

import contextlib
import io
import subprocess
import sys


def verdicts(lib):
    src = subprocess.run(
        ["bash", "-c", '. "$1"; printf %s "$_FORCE_PUSH_GUARD_PY"', "_", lib],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    g = {"__name__": "spl-cmd-guard-parity"}
    exec(compile(src, lib, "exec"), g)  # noqa: S102 -- the guard library itself, from the tree
    data = sys.stdin.buffer.read().decode("utf-8", "replace")
    cmds = data.split("\0")
    if cmds and cmds[-1] == "":
        cmds.pop()
    out = sys.stdout
    for cmd in cmds:
        try:
            g["check"](cmd)
            out.write("0\n")
        except g["Refuse"] as e:
            out.write("2\t%s\n" % str(e).replace("\n", "\\n"))
        except Exception as e:  # the library's main() answers the same
            out.write("2\tguard error %s (fail closed)\n" % type(e).__name__)


def extractor(hook):
    text = open(hook, encoding="utf-8").read()
    code = (
        text.split("py_extract() {", 1)[1]
        .split("python3 -c '", 1)[1]
        .split("' 2>/dev/null", 1)[0]
    )
    if "SHELL = {" not in code:
        raise SystemExit("py-batch: the extractor was not found in " + hook)
    return compile(code, hook, "exec")


def payloads(hook, files):
    code = extractor(hook)
    for f in files:
        with open(f, "rb") as fh:
            raw = fh.read().replace(b"\0", b"").rstrip(b"\n")
        out = io.StringIO()
        try:
            sys.stdin = io.TextIOWrapper(
                io.BytesIO(raw), encoding="utf-8", errors="strict"
            )
            with contextlib.redirect_stdout(out):
                exec(code, {"__name__": "__main__"})  # noqa: S102 -- the hook's own extractor
            res = out.getvalue()
        except SystemExit as e:
            res = out.getvalue() if e.code in (None, 0) else None
        except Exception:
            res = None
        if res is not None:
            try:
                res = (
                    res.encode("utf-8", "strict")
                    .replace(b"\0", b"")
                    .rstrip(b"\n")
                    .decode("utf-8")
                )
            except UnicodeEncodeError:
                res = None
        sys.stdout.write(
            "%s|%s\n" % (f, "unreadable" if res is None else res.replace("\n", "\\n"))
        )


def main():
    if sys.argv[1] == "verdicts":
        verdicts(sys.argv[2])
    else:
        payloads(sys.argv[2], sys.argv[3:])


if __name__ == "__main__":
    main()
