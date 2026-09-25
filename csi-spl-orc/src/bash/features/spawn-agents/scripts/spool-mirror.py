#!/usr/bin/env python3
"""spool-mirror.py - the terminal -> web UI leg of a seated agent
(specs/036-spool-terminal-mirror).

A desk agent already RECEIVES its human's web UI DMs in its terminal (the desk
sidecar types them into the prompt, specs/028). This is the other direction:
every prompt typed in the agent's terminal and every final answer the agent
gives is posted into the agent's DM with that human, so the conversation reads
the same in both places.

Two halves, because the two sides run as two users:

  hook   runs as the AGENT user, from the CLI's own hooks (Claude Code and
         grok both read UserPromptSubmit / Stop from ~/.claude/settings.json).
         It parses the hook JSON on stdin, takes the prompt or the final
         answer, and hands it to `post` as the BOX user, detached, so the
         agent's turn never waits on the network. It ALWAYS exits 0: a mirror
         that fails must never block a prompt or keep an agent working.
  post   runs as the BOX user (the owner of the desk state). For every desk
         seat of the agent it drops what came FROM the web UI, redacts, picks
         the DM topic and runs `spool send`; the seat's hub-run sidecar
         flushes it to the hub.

Nothing is posted twice:
  - a line the desk TYPED into the prompt (a human's web UI message) was
    recorded by the notifier in <seat>/spool/<agent>/.mirror/typed/; the
    prompt hook drops every line that matches one, so it never echoes back
  - a `: 'SPOOL ...'` poke line and an `INBOX <ID>:` doorbell are machine
    text, not the human's words, and are dropped too
  - the mirror post goes FROM the agent TO the human on box-wui: the hub never
    dispatches it back to the desk, so the agent is not poked by its own post
  - the same answer text twice in a row for one session is posted once

The topic: the DM topic the human last wrote to this agent in
(<seat>/spool/<agent>/.mirror/peer, written by the notifier); else the topic
this mirror used before (.mirror/topic); else a new topic is minted on the
first post and remembered. The human: that peer; else SPOOL_MIRROR_TO
(default HUM-9).

Opt out per seat: touch <seat>/spool/<agent>/.no-mirror.

Usage:
  spool-mirror.py hook                     < hook JSON
  spool-mirror.py post --agent ID --event prompt|answer [--session S] < text

Environment (post):
  SPOOL_MIRROR_SEATS  glob of desk dirs, default
                      $HOME/.local/share/csi-spl/cloud/*/desk/*/*
  SPOOL_MIRROR_TO     default human id, default HUM-9
  SPOOL_MIRROR_SPOOL  the spool binary, default <env dir>/bin/spool
  SPOOL_MIRROR_DRY    1 = print the send argv instead of running it
Environment (hook):
  MCP_BOT_AGENT_ID    the agent id (set by the spawner); SPOOL_AGENT_ID wins
  SPOOL_MIRROR_POST   the argv prefix that runs `post` as the box user,
                      default: sudo -n -u <owner of this script> <this script>
  SPOOL_MIRROR_SYNC   1 = run post in the foreground (tests)
"""
import glob
import hashlib
import json
import os
import pwd
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.realpath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "lib"))
from spool_redact import redact  # noqa: E402

ID_RE = re.compile(r"^[A-Z]{2,4}-[0-9]+$")
HUM_RE = re.compile(r"^HUM-[A-Za-z0-9_-]{1,64}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
MACHINE_LINE = re.compile(r"^(: 'SPOOL |INBOX [A-Z]{2,4}-[0-9]+:)")
BODY_MAX = 60000          # the hub's MaxBodyBytes is 64 KiB
TYPED_TTL = 3600          # a typed marker older than this no longer matches
PROMPT_PREFIX = "[terminal] "


def norm(s):
    return " ".join(str(s or "").split())


def log(seat_agent_dir, line):
    try:
        os.makedirs(os.path.join(seat_agent_dir, ".mirror"), exist_ok=True)
        with open(os.path.join(seat_agent_dir, ".mirror", "mirror.log"), "a") as f:
            f.write(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + " " + line + "\n")
    except OSError:
        pass


# ── hook half (agent user) ──────────────────────────────────────────────────
def hook_extract(ev):
    """hook JSON -> (event, text, session) or None when nothing is mirrored."""
    if not isinstance(ev, dict):
        return None
    if ev.get("subagentType") or ev.get("agent_type"):
        return None  # a subagent's turn is not the conversation
    name = ev.get("hook_event_name") or ev.get("hookEventName") or ""
    session = str(ev.get("session_id") or ev.get("sessionId") or "")
    if name in ("UserPromptSubmit", "user_prompt_submit"):
        text = ev.get("prompt")
        if text is None:
            text = ev.get("userPrompt") or ev.get("message") or ""
        return ("prompt", str(text), session) if str(text).strip() else None
    if name in ("Stop", "stop"):
        if ev.get("reason") not in (None, "", "end_turn"):
            return None  # grok's session-end Stop carries no new answer
        text = ev.get("last_assistant_message")
        if text is None:
            text = ev.get("lastAssistantMessage") or ""
        return ("answer", str(text), session) if str(text).strip() else None
    return None


def hook_main():
    try:
        raw = sys.stdin.read()
        got = hook_extract(json.loads(raw) if raw.strip() else {})
        agent = os.environ.get("SPOOL_AGENT_ID") or os.environ.get("MCP_BOT_AGENT_ID") or ""
        if not got or not ID_RE.match(agent):
            return 0
        event, text, session = got
        argv = os.environ.get("SPOOL_MIRROR_POST", "").split()
        if not argv:
            owner = pwd.getpwuid(os.stat(os.path.realpath(__file__)).st_uid).pw_name
            me = pwd.getpwuid(os.getuid()).pw_name
            argv = [sys.executable, os.path.realpath(__file__)]
            if owner != me:
                argv = ["sudo", "-n", "-u", owner] + argv
        argv += ["post", "--agent", agent, "--event", event, "--session", session]
        if os.environ.get("SPOOL_MIRROR_SYNC") == "1":
            subprocess.run(argv, input=text.encode(), stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=60)
            return 0
        # Detached: the CLI's turn does not wait for the send, and nothing of
        # ours holds the hook's pipes open.
        p = subprocess.Popen(argv, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        p.stdin.write(text.encode())
        p.stdin.close()
    except Exception:  # noqa: BLE001 - a mirror must never break the CLI
        pass
    return 0


# ── post half (box user) ────────────────────────────────────────────────────
def seats(agent):
    pat = os.environ.get("SPOOL_MIRROR_SEATS") or os.path.expanduser("~/.local/share/csi-spl/cloud/*/desk/*/*")
    out = []
    for d in sorted(glob.glob(pat)):
        a = os.path.join(d, "spool", agent)
        if os.path.isdir(a) and not os.path.exists(os.path.join(a, ".no-mirror")):
            out.append(d)
    return out


def typed_lines(agent_dir, now):
    """The lines the desk typed into this prompt lately: {normalised: path}."""
    out = {}
    for p in glob.glob(os.path.join(agent_dir, ".mirror", "typed", "*")):
        try:
            if now - os.path.getmtime(p) > TYPED_TTL:
                os.unlink(p)
                continue
            with open(p, errors="replace") as f:
                out.setdefault(norm(f.read()), p)
        except OSError:
            pass
    return out


def prompt_keep(agent_dir, text, now):
    """Drop the lines that came from the web UI or are machine doorbells.
    -> (kept text, dropped count). A consumed typed marker is removed, so the
    SAME words typed by the human in the terminal later are mirrored."""
    typed = typed_lines(agent_dir, now)
    whole = norm(text)
    if whole in typed:
        _unlink(typed[whole])
        return "", 1
    kept, dropped = [], 0
    for line in text.split("\n"):
        n = norm(line)
        if n and n in typed:
            _unlink(typed.pop(n))
            dropped += 1
        elif n and MACHINE_LINE.match(n):
            dropped += 1
        else:
            kept.append(line)
    return "\n".join(kept).strip("\n"), dropped


def _unlink(p):
    try:
        os.unlink(p)
    except OSError:
        pass


def _read_json(p):
    try:
        with open(p) as f:
            v = json.load(f)
        return v if isinstance(v, dict) else {}
    except (OSError, ValueError):
        return {}


def pick_topic(agent_dir):
    """-> (human, task or '') - see the module doc."""
    peer = _read_json(os.path.join(agent_dir, ".mirror", "peer"))
    human, task = str(peer.get("to", "")), str(peer.get("task", ""))
    if HUM_RE.match(human) and UUID_RE.match(task):
        return human, task
    mine = _read_json(os.path.join(agent_dir, ".mirror", "topic"))
    human = os.environ.get("SPOOL_MIRROR_TO") or "HUM-9"
    if not HUM_RE.match(human):
        human = "HUM-9"
    if mine.get("to") == human and UUID_RE.match(str(mine.get("task", ""))):
        return human, mine["task"]
    return human, ""


def seat_env(seat):
    """The spool env of a desk seat: from its live sidecar when there is one
    (the values it actually runs under), else from the path."""
    env = {}
    try:
        with open(os.path.join(seat, "spool", ".hub", "hub-run.pid")) as f:
            pid = f.read().strip()
        with open(f"/proc/{pid}/environ", "rb") as f:
            for kv in f.read().split(b"\0"):
                k, _, v = kv.decode(errors="replace").partition("=")
                if k in ("SPOOL_HUB_URL", "SPOOL_TENANT", "SPOOL_BOX_ID"):
                    env[k] = v
    except (OSError, ValueError):
        pass
    parts = seat.rstrip("/").split("/")
    env.setdefault("SPOOL_BOX_ID", parts[-1])
    env.setdefault("SPOOL_TENANT", parts[-2])
    env["SPOOL_ROOT"] = os.path.join(seat, "spool")
    env["SPOOL_KEYS_DIR"] = os.path.join(seat, "keys")
    return env


def clip_body(s):
    b = s.encode()
    if len(b) <= BODY_MAX:
        return s
    cut = b[:BODY_MAX].decode(errors="ignore")
    return cut + f"\n… [{len(b) - BODY_MAX} more bytes: the full text is in the terminal]"


def post_one(seat, agent, event, text, session):
    adir = os.path.join(seat, "spool", agent)
    now = time.time()
    if event == "prompt":
        text, dropped = prompt_keep(adir, text, now)
        if not text.strip():
            log(adir, f"skip prompt: every line came from the web UI or is a doorbell ({dropped})")
            return "skipped"
        body = PROMPT_PREFIX + text
    else:
        h = hashlib.sha256((session + "\0" + norm(text)).encode()).hexdigest()
        last = os.path.join(adir, ".mirror", "last-answer")
        try:
            if open(last).read().strip() == h:
                log(adir, "skip answer: the same answer was already posted for this session")
                return "skipped"
        except OSError:
            pass
        body = text
    body, counts = redact(body)
    body = clip_body(body)
    human, task = pick_topic(adir)
    env = seat_env(seat)
    if "SPOOL_HUB_URL" not in env:
        log(adir, f"FAIL {event}: no live sidecar to read the hub url from")
        return "failed"
    spool = os.environ.get("SPOOL_MIRROR_SPOOL") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(seat.rstrip("/")))), "bin", "spool")
    argv = [spool, "send", "--from", agent, "--to", human, "--to-box", "box-wui",
            "--kind", "note", "--body", body]
    if task:
        argv += ["--task", task]
    if os.environ.get("SPOOL_MIRROR_DRY") == "1":
        # A dry run writes no state: no topic, no watermark, no log line.
        print(json.dumps({"seat": seat, "argv": argv, "env": env, "redactions": counts}, sort_keys=True))
        return "dry"
    r = subprocess.run(argv, env={**os.environ, **env}, capture_output=True, text=True, timeout=60)
    rc, out = r.returncode, (r.stdout or r.stderr).strip()
    if rc != 0:
        log(adir, f"FAIL {event} -> {human}: rc {rc}: {out[:300]}")
        return "failed"
    try:
        sent = json.loads(out.splitlines()[-1])
    except (ValueError, IndexError):
        sent = {}
    got_task = str(sent.get("task_id", "")) or task
    os.makedirs(os.path.join(adir, ".mirror"), exist_ok=True)
    if UUID_RE.match(got_task):
        with open(os.path.join(adir, ".mirror", "topic"), "w") as f:
            json.dump({"to": human, "task": got_task}, f)
    if event == "answer":
        with open(os.path.join(adir, ".mirror", "last-answer"), "w") as f:
            f.write(h)
    log(adir, f"OK {event} -> {human} task {got_task} msg {sent.get('msg_id', '?')} "
              f"({len(body)} chars, redactions {counts or 'none'})")
    return "posted"


def post_main(args):
    agent, event, session = "", "", ""
    i = 0
    while i < len(args):
        if args[i] in ("--agent", "--event", "--session") and i + 1 < len(args):
            v = args[i + 1]
            if args[i] == "--agent":
                agent = v
            elif args[i] == "--event":
                event = v
            else:
                session = v
            i += 2
        else:
            print(f"unknown argument {args[i]}", file=sys.stderr)
            return 64
    if not ID_RE.match(agent) or event not in ("prompt", "answer"):
        print("usage: post --agent ID --event prompt|answer [--session S] < text", file=sys.stderr)
        return 64
    text = sys.stdin.read()
    if not text.strip():
        return 0
    rc = 0
    for seat in seats(agent):
        res = post_one(seat, agent, event, text, session)
        print(f"{res} {seat}")
        rc = rc or (1 if res == "failed" else 0)
    return rc


def main(argv):
    if len(argv) >= 2 and argv[1] == "hook":
        return hook_main()
    if len(argv) >= 2 and argv[1] == "post":
        return post_main(argv[2:])
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
