#!/usr/bin/env python3
"""do_spl_local_hub_e2e, the terminal seat: run one command under a fresh
pseudo-terminal (its controlling tty) and type a THROWAWAY secret each time
it asks for one, as an operator would. Owner rule (msg 3cfe43ce): actions read
a passphrase or password only from the terminal, so the e2e cannot pipe it.

Usage: local-hub-e2e-tty.py <secret-file> <cmd> [args...]
A prompt is any output line ending that names a passphrase or password
("type the passphrase here", "Password:", "again"); each one gets the secret
plus Enter, at most LHE2E_TTY_MAX (default 4) times. The child's output is
echoed to stdout; the secret is never echoed (the action reads it without
echo). Exit = the child's exit code; 124 when it outlives LHE2E_TTY_TIMEOUT
(default 900 s).
"""

import os
import pty
import re
import select
import signal
import sys
import time

PROMPT = re.compile(rb"(passphrase|password|again)[^\n]*$", re.I)


def main():
    if len(sys.argv) < 3:
        sys.exit("usage: local-hub-e2e-tty.py <secret-file> <cmd> [args...]")
    with open(sys.argv[1], "rb") as fh:
        secret = fh.read().strip()
    left = int(os.environ.get("LHE2E_TTY_MAX", "4"))
    end = time.time() + int(os.environ.get("LHE2E_TTY_TIMEOUT", "900"))
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(sys.argv[2], sys.argv[2:])
    tail = b""
    while True:
        if time.time() > end:
            os.kill(pid, signal.SIGKILL)
            os.waitpid(pid, 0)
            return 124
        r, _, _ = select.select([fd], [], [], 0.2)
        if not r:
            continue
        try:
            chunk = os.read(fd, 4096)
        except OSError:  # EIO: the child closed the tty
            break
        if not chunk:
            break
        sys.stdout.buffer.write(chunk.replace(secret, b"***"))
        sys.stdout.flush()
        tail = (tail + chunk).split(b"\n")[-1][-200:]
        if left > 0 and PROMPT.search(tail):
            os.write(fd, secret + b"\n")
            left -= 1
            tail = b""
    _, status = os.waitpid(pid, 0)
    return os.waitstatus_to_exitcode(status)


if __name__ == "__main__":
    sys.exit(main())
