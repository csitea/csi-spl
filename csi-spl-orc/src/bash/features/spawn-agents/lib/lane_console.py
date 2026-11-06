"""lane_console.py - a lane's live console on the box side (spec 153 section
3.20, SPL-4810), run by the box file follower (file-stream-follow.py) on
each tick.

Every FILE_STREAMS_CONSOLE_S the follower pulls the agents of THIS box whose
console a reader watches now (lane op file_streams_console_demands, through
the same push command and session as the file streams). For each one it
finds the tmux window whose name is the agent id (an optional `<tag>: `
prefix, then the id, an optional `@<tag>`, then the title; the hub demands the
bare id, and any `@<tag>` counts: this tmux server holds only this box's
windows and the hub already scoped the demand to this box), captures its screen plus
FILE_STREAMS_CONSOLE_LINES lines of scrollback as plain text, masks EVERY
line (the follower's mask: spool_redact.redact() plus the PEM state, from
the first captured line on), masks whole the lines a secret hard-wrapped by
the agent's TUI spans (up to WRAP_SPAN lines joined) and pushes it (file_streams_console_push). An
unmasked line never leaves this module. Nothing is captured while nobody
watches: no demand, no tmux call.

A screen that did not change is re-sent only every FILE_STREAMS_CONSOLE_KEEP_S,
so the reader's "captured" age stays fresh without a write a tick.

A demanded agent with no screen (no such window, or the capture failed) is
counted in `missing`, and the follower's tick line shows it (consoles_missing=N).

Env (set by do_spl_file_stream_follow):
  FILE_STREAMS_CONSOLE_TMUX   JSON argv that runs tmux on the agents' server,
                              e.g. ["sudo","-n","-u","<box user>","tmux","-S","<sock>"];
                              default ["tmux"]
  FILE_STREAMS_CONSOLE_S      seconds between two demand pulls (5)
  FILE_STREAMS_CONSOLE_LINES  scrollback lines above the screen (200)
  FILE_STREAMS_CONSOLE_KEEP_S re-send an unchanged screen after this (10)
"""

import hashlib
import json
import os
import re
import subprocess

AGENT_RE = re.compile(r"^[A-Za-z][A-Za-z0-9-]{0,31}$")
# a window name: an optional box tag "<tag>: ", then the agent id, which stops
# at the "@<tag>" of spec 061 ("c-036@abc title") or a space
WINDOW_RE = re.compile(r"^(?:[A-Za-z0-9][A-Za-z0-9._-]*: )?([^\s@]+)")
SCREEN_MAX_BYTES = 120 << 10  # under the hub's 128 KiB cap
DEMANDS_OP = "file_streams_console_demands"
PUSH_OP = "file_streams_console_push"
# a line a hard-wrapped secret spans (LaneConsole.wrapped)
WRAPPED_KIND = "wrapped-secret"
WRAPPED_MASK = f"<redacted:{WRAPPED_KIND}>"
PEM_MASK = "<redacted:private-key>"  # a PEM line, masked whole by the follower
WRAP_SPAN = 4  # lines a hard-wrapped secret may span: a 40-char token at 12 cols
BORDER = "│┃|⎿"  # the box edges and gutters a TUI draws around a wrapped line


def unbox(text):
    """-> text without its end spaces and every layer of BORDER glyphs a
    TUI draws around it ("│ │ x │ │" -> "x"; R7 c-164 r3 N1)."""
    prev = None
    while prev != text:  # ctl:console-unbox
        prev, text = text, text.strip().strip(BORDER).strip()
    return text


def span(text, masked):
    """-> [lo, hi) of `text` that the mask changed, or (None, None)."""
    if masked is None or masked == text:
        return None, None
    lo = 0
    while lo < min(len(text), len(masked)) and text[lo] == masked[lo]:
        lo += 1
    hi = 0
    while hi < min(len(text), len(masked)) - lo and text[-1 - hi] == masked[-1 - hi]:
        hi += 1
    return lo, len(text) - hi


def env_int(name, default):
    try:
        return int(os.environ.get(name) or default)
    except ValueError:
        return default


class LaneConsole:
    """The console half of the follower. send_ack(frame) -> the hub's ack
    or None; mask(state, text) -> [(text, marker, {kind: n})], the
    follower's line mask with its PEM state in `state`."""

    def __init__(self, send_ack, mask, line_bytes, say=print):
        self.send_ack, self.mask, self.say = send_ack, mask, say
        self.line_bytes = line_bytes
        try:
            self.tmux = json.loads(
                os.environ.get("FILE_STREAMS_CONSOLE_TMUX") or '["tmux"]'
            )
        except ValueError:
            self.tmux = ["tmux"]
        if not (
            isinstance(self.tmux, list)
            and self.tmux
            and all(isinstance(a, str) for a in self.tmux)
        ):
            self.tmux = ["tmux"]
        self.every_s = env_int("FILE_STREAMS_CONSOLE_S", 5)
        self.scroll = env_int("FILE_STREAMS_CONSOLE_LINES", 200)
        self.keep_s = env_int("FILE_STREAMS_CONSOLE_KEEP_S", 10)
        self.next_pull = 0.0
        self.agents = []
        self.missing = 0  # demanded agents the last tick got no screen of
        self.sent = {}  # agent -> (sha256 of the masked screen, when sent)

    def pull(self, now):
        if now < self.next_pull:
            return
        self.next_pull = now + self.every_s
        ack = self.send_ack({"type": "lane", "lane_op": DEMANDS_OP})
        got = ack.get("agents") if ack else None
        if not isinstance(got, list):
            self.agents = []  # fail closed: no answer, no capture
            return
        self.agents = [a for a in got if isinstance(a, str) and AGENT_RE.match(a)][:16]
        self.sent = {a: s for a, s in self.sent.items() if a in self.agents}

    def windows(self):
        """-> {agent id: window id} of the tmux server."""
        try:
            p = subprocess.run(
                self.tmux
                + ["list-windows", "-a", "-F", "#{window_id}\t#{window_name}"],
                capture_output=True,
                text=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            return {}
        out = {}
        for ln in p.stdout.splitlines() if p.returncode == 0 else []:
            wid, _, name = ln.partition("\t")
            m = WINDOW_RE.match(name)
            if m and wid.startswith("@") and m.group(1) not in out:
                out[m.group(1)] = wid
        return out

    def capture(self, wid):
        """-> the window's screen plus scrollback as raw text, or None."""
        try:
            p = subprocess.run(
                self.tmux
                + ["capture-pane", "-p", "-J", "-S", f"-{self.scroll}", "-t", wid],
                capture_output=True,
                timeout=5,
            )
        except (OSError, subprocess.TimeoutExpired):
            return None
        if p.returncode != 0:
            return None
        return p.stdout.decode("utf-8", "replace")

    def masked(self, raw):
        """-> (masked text, lines, {kind: n}): every line through the mask,
        in order, one PEM state for the whole capture; then the lines a
        hard-wrapped secret spans (wrapped()) masked whole; then each line
        cut to line_bytes, after the mask, so a cut never shortens a secret
        below its pattern."""
        st, out, red, src = {}, [], {}, []
        for ln in raw.rstrip("\n").split("\n"):
            ln = ln.rstrip()
            res = self.mask(st, ln)
            for text, _marker, counts in res:  # ctl:console-mask
                out.append(text)
                # the join reads the raw line: a masked head line hides
                # the secret a wrapped tail line still carries (R7 c-164 r3
                # W1); a line masked whole (a PEM body) stays masked
                # (a secret at column 0 has lo 0: test None, not falsy,
                # R7 c-164 r4)
                raw = (
                    len(res) == 1
                    and span(ln, text)[0] is not None
                    and PEM_MASK not in text
                )
                src.append(ln if raw else text)  # ctl:console-raw
                for k, n in counts.items():
                    red[k] = red.get(k, 0) + n
        for i in self.wrapped(src):
            out[i] = WRAPPED_MASK
            red[WRAPPED_KIND] = red.get(WRAPPED_KIND, 0) + 1
        out = [self.cut(x) for x in out]
        while out and sum(len(x.encode("utf-8")) + 1 for x in out) > SCREEN_MAX_BYTES:
            out.pop(0)
        return "\n".join(out), len(out), red

    def cut(self, text):
        b = text.encode("utf-8", "replace")
        if len(b) <= self.line_bytes:
            return text
        return b[: self.line_bytes].decode("utf-8", "ignore")

    def remask(self, text):
        """-> (masked text, secrets found) for one line on its own."""
        res = self.mask({}, text)
        n = sum(v for _t, _m, c in res for v in c.values())
        return (res[0][0] if len(res) == 1 else None), n

    def whole(self, text):
        """-> True when the value the mask hides in `text` is a secret on
        its own (a complete token after GH_TOKEN=), so a join with the next
        line is not a wrap of it; a cut value (a password's first half)
        is not."""
        masked, _n = self.remask(text)
        lo, hi = span(text, masked)
        return lo is not None and self.remask(text[lo:hi])[1] > 0  # ctl:console-whole

    def at_end(self, text):
        """-> True when the value the mask hides in `text` runs to the end
        of the line: a token the TUI cut at the pane width still matches
        its pattern on the head line alone, so whole() cannot tell it from
        a complete one and its tail line would leak (R7 c-164 r4)."""
        _lo, hi = span(text, self.remask(text)[0])
        return hi == len(text)

    def wrapped(self, lines):
        """-> the indexes of the masked lines a secret spans that no line
        shows alone. capture-pane -J joins only the rows tmux wrapped; an
        agent's TUI hard-wraps at the pane width with real newlines, so a
        token can arrive in pieces. From each line, WRAP_SPAN lines are
        joined at the wrap (end spaces, indents and a TUI box's BORDER
        glyphs dropped, R7 c-164 W); when the join
        finds more than its lines alone, every line the masked span of the
        join touches is marked (the whole run when the span is unclear).
        The join drops the newline, so a word that starts the line after a
        token may be masked with it: more is masked, never less."""
        parts = [unbox(x) for x in lines]  # ctl:console-border
        one = [self.remask(x)[1] for x in parts]
        out = set()
        for i in range(len(parts) - 1):
            run = parts[i : i + WRAP_SPAN]
            joined = "".join(run)
            masked, n = self.remask(joined)
            lo, hi = span(joined, masked)
            # a head line that holds the secret's start counts once alone
            # and once joined: a masked span across the wrap still marks,
            # unless the head line's own masked value is a whole secret
            over = lo is not None and lo < len(run[0]) < hi
            crosses = over and (self.at_end(run[0]) or not self.whole(run[0]))
            if n <= sum(one[i : i + len(run)]) and not crosses:  # ctl:console-wrap
                continue
            at = 0
            for j, x in enumerate(run):
                if lo is None or (at < hi and at + len(x) > lo):
                    out.add(i + j)
                at += len(x)
        return sorted(out)

    def tick(self, now):
        """Pull when due, then capture and push each watched agent."""
        self.missing = 0  # ctl:console-missing-reset
        self.pull(now)
        if not self.agents:
            return 0
        wins, pushed = self.windows(), 0
        for agent in self.agents:
            wid = wins.get(agent)
            raw = self.capture(wid) if wid else None
            if raw is None:
                self.missing += 1  # ctl:console-missing
                continue
            text, n, red = self.masked(raw)
            sha = hashlib.sha256(text.encode("utf-8")).hexdigest()
            last = self.sent.get(agent)
            if last and last[0] == sha and now - last[1] < self.keep_s:
                continue
            ack = self.send_ack(
                {
                    "type": "lane",
                    "lane_op": PUSH_OP,
                    "agent_id": agent,
                    "screen": text,
                    "lines_n": n,
                    "redactions": red,
                }
            )
            if ack is not None:
                self.sent[agent] = (sha, now)
                pushed += 1
        return pushed
