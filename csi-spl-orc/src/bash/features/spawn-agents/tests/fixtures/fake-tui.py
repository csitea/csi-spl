#!/usr/bin/env python3
"""A stand-in agent CLI for test-poke-by-pane.sh (27f01e16 item 3).

On the alternate screen, it draws one composer row the way the Claude CLI
does: the marker, the typed text, then a reverse-video cursor cell. An empty
composer shows a DIM autosuggest instead (the ghost text the poke path must
never mistake for typed input). Enter appends the composer to LOG and clears
it; C-u clears it; C-e is accepted (end of line). MODE "multi" draws a second
draft row under the prompt row, the shape of a multi-line draft; "nocursor"
draws no cursor cell (an unfocused Claude pane); "mid" puts the cursor ON the
last typed character, the shape of a cursor in mid-text.

Usage: fake-tui.py LOG [single|multi|nocursor|mid]
"""
import os
import sys
import tty

log = sys.argv[1]
mode = sys.argv[2] if len(sys.argv) > 2 else "single"
multi = mode == "multi"
buf = ""


def draw():
    out = "\x1b[H\x1b[2Jfake tui\r\n"
    if buf:
        if mode == "nocursor":
            out += "\u276f " + buf
        elif mode == "mid":
            out += "\u276f " + buf[:-1] + "\x1b[7m" + buf[-1] + "\x1b[0m"
        else:
            out += "\u276f " + buf + "\x1b[7m \x1b[0m"
    else:
        out += "\u276f\u00a0\x1b[7mh\x1b[0;2mint ghost\x1b[0m"
    out += "\r\n"
    if multi:
        out += "  second draft row\r\n"
    out += "─" * 20 + "\r\n"
    os.write(1, out.encode())


tty.setraw(0)
os.write(1, b"\x1b[?1049h")
draw()
while True:
    data = os.read(0, 4096)
    if not data:
        break
    for ch in data.decode(errors="replace"):
        if ch in "\r\n":
            with open(log, "a", encoding="utf-8") as f:
                f.write(buf + "\n")
            buf = ""
        elif ch == "\x15":
            buf = ""
        elif ch == "\x7f":
            buf = buf[:-1]
        elif ch >= " ":
            buf += ch
    draw()
