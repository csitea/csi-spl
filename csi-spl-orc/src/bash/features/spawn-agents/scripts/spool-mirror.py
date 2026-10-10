#!/usr/bin/env python3
"""spool-mirror.py - the terminal -> web UI leg of a seated agent
(specs/036-spool-terminal-mirror).

A desk agent already RECEIVES its human's web UI DMs in its terminal (the desk
sidecar types them into the prompt, specs/028). This is the other direction:
the agent's answer to a human's DM is posted back into THAT DM, so the
conversation reads the same in both places.

Only a DM-triggered turn is answered (specs/067 L2, rule 1). The notifier
records why it typed each line (<seat>/spool/<agent>/.mirror/trigger/: dm,
channel or task); the prompt hook looks its line up and remembers the turn's
trigger (.mirror/turn); the answer hook posts only when that trigger is a DM,
into that DM's topic, and consumes it. A turn started by a channel post, a peer
agent's poke, a task notification or the terminal posts nothing: the agent's
real reply reaches the channel by do_spl_desk_reply / spool send. Prompts
themselves are never posted (the echo kinds A-D of spec 067 section 2.1).

Two halves, because the two sides run as two users:

  hook   runs as the AGENT user, from the CLI's own hooks (Claude Code and
         grok both read UserPromptSubmit / Stop from ~/.claude/settings.json).
         It parses the hook JSON on stdin, takes the prompt or the final
         answer, and hands it to `post` as the BOX user, detached, so the
         agent's turn never waits on the network. It ALWAYS exits 0: a mirror
         that fails must never block a prompt or keep an agent working.
  post   runs as the BOX user (the owner of the desk state). For every desk
         seat of the agent: a prompt records the turn's trigger; an answer to
         a DM-triggered turn is redacted and sent with `spool send` into that
         DM; the seat's hub-run sidecar flushes it to the hub.

Nothing is posted twice:
  - the mirror post goes FROM the agent TO the human on box-wui: the hub never
    dispatches it back to the desk, so the agent is not poked by its own post
  - one DM trigger answers one turn: the answer consumes it
  - the same answer text twice in a row for one session is posted once

The human and the topic: the DM's sender and topic, from the trigger. No
literal and no fallback: a turn with no DM trigger posts nothing.

Opt out per seat: touch <seat>/spool/<agent>/.no-mirror.

Usage:
  spool-mirror.py hook                     < hook JSON (claude, grok)
  spool-mirror.py hook --agy pre|stop      < agy hook JSON (PreInvocation, Stop)
  spool-mirror.py hook --vibe              < mistral vibe post_agent hook JSON
  spool-mirror.py post --agent ID --event prompt|answer [--session S] < text
  spool-mirror.py topic <seat>/spool/<agent>       -> "<human>\t<task>"
  spool-mirror.py remember <seat>/spool/<agent> <human> <task>
  spool-mirror.py operator <seat>[/spool/<agent>] HUM-n|--clear
                      who types at this desk (or this one seat); the notifier
                      counts that human as a desk owner

Environment (post):
  SPOOL_MIRROR_SEATS  glob of desk dirs, default
                      $HOME/.local/share/csi-spl/cloud/*/desk/*/*
  SPOOL_MIRROR_SPOOL  the spool binary, default <env dir>/bin/spool
  SPOOL_MIRROR_DRY    1 = print the send argv instead of running it
Environment (hook):
  SPOOL_AGENT_ID      the agent id, from the PROCESS env (spool-harness.sh
                      exports it), else MCP_BOT_AGENT_ID. Never a tmux window
                      name: names drift (2026-10-01, CLE-77825), and a wrong id
                      posts one agent's words into another's DM. No id = no post.
  SPOOL_ROOT          $SPOOL_ROOT/.mirror-off (default /var/spool-hub) switches
                      the mirror off for every session on the box, live ones too
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

# A participant id, as lib/spool-env.inc.sh SPOOL_ID_RE (specs/061): c-004, and
# the legacy CLE-07 that readers keep accepting.
PID = r"(?:[acgmq]-[0-9]{3}|[A-Z]{2,4}-[0-9]+)"
ID_RE = re.compile(r"^" + PID + r"$")
HUM_RE = re.compile(r"^HUM-[A-Za-z0-9_-]{1,64}$")
UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
# A line another AGENT typed into this pane: the inbox doorbell (bare, or the
# shell-inert `: 'INBOX ...'` form inbox-send.sh types) and the desk's
# `: 'SPOOL ...'` poke line. A turn it starts is an agent's, never a DM's.
MACHINE_LINE = re.compile(r"^(?::\s*')?(?:INBOX|SPOOL) " + PID + r"\b")
BODY_MAX = 60000  # the hub's MaxBodyBytes is 64 KiB
TYPED_TTL = 3600  # a typed marker / trigger older than this no longer matches


def norm(s):
    return " ".join(str(s or "").split())


def log(seat_agent_dir, line):
    try:
        os.makedirs(os.path.join(seat_agent_dir, ".mirror"), exist_ok=True)
        with open(os.path.join(seat_agent_dir, ".mirror", "mirror.log"), "a") as f:
            f.write(
                time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()) + " " + line + "\n"
            )
    except OSError:
        pass


# ── hook half (agent user) ──────────────────────────────────────────────────
# What the CLI INJECTS into a user turn is not what a person typed, and it
# must never be posted as the human (FR-001 is "every prompt the human types").
# Measured 2026-09-25 19:15Z (CLE-100): 160 of 391 typed_by rows on dev, and
# 18 (agent, human) pairs on prd, carried <system-reminder> memory/tool lists
# and <task-notification> results as if the owner had typed them.
INJECTED_BLOCKS = re.compile(
    r"<(system-reminder|task-notification|local-command-[a-z-]+|command-[a-z-]+|"
    r"user-prompt-submit-hook|bash-(?:input|stdout|stderr))\b[^>]*>.*?(?:</\1>|\Z)",
    re.S,
)
INJECTED_LINES = re.compile(
    r"^(?:CLI RESTARTED IN PLACE\b|\[SYSTEM NOTIFICATION\b|Caveat: The messages below were generated\b)"
)


# An answer that only reports the agent's own machinery is no answer to a
# person (owner no-filler rule, HUM-10, 2026-10-03: such a message "does not
# bring any additional value to the human reader"). Traced to this mirror: prd
# msg b3a233f9, 13:47:21Z, "I restarted the watcher on my inbox and the dispatch
# lease ... I still hold the lease ... my inbox is empty. Waiting on c-001 ...".
# STATUS_OPENER: an answer whose first line is a watcher, lease, poll, inbox or
# waiting report is dropped whole. PROGRESS_LINE: a spinner or tool-progress
# line inside a real answer is cut; the answer text around it goes out.
STATUS_OPENER = re.compile(
    r"^\W*(?:"
    r"(?:i(?:'ve|\s+have)?\s+)?(?:re-?)?(?:start|restart|arm|renew|resume|check)(?:ed)?\b[^.\n]*"
    r"\b(?:watcher|lease|poll(?:er|ing)?|monitor|inbox)\b"
    r"|(?:i\s+)?(?:still\s+)?hold\s+(?:the\s+)?(?:dispatch\s+)?lease\b"
    r"|(?:my\s+)?inbox\s+is\s+(?:still\s+)?empty\b"
    r"|no\s+new\s+(?:messages?|mail|tasks?)\b"
    r"|(?:still\s+)?(?:waiting|polling|watching)\b"
    r"|(?:standing\s+by|on\s+standby|idle)\b"
    r"|(?:watcher|lease|poll(?:er)?)\s*(?::|is\b|held\b|renewed\b|armed\b|expired\b)"
    r")",
    re.I,
)
PROGRESS_LINE = re.compile(
    r"^\s*(?:[\u2800-\u28ff\u273b\u2722\u2736\u2733\u23bf]|\u25cf\s+\w+\()"
)


def answer_text(text):
    """The part of an answer a person reads: spinner / tool-progress lines cut;
    '' when what is left is only a status report."""
    t = "\n".join(
        ln for ln in str(text or "").split("\n") if not PROGRESS_LINE.match(ln)
    ).strip()
    first = next((ln for ln in t.split("\n") if ln.strip()), "")
    return "" if not t or STATUS_OPENER.match(first) else t


def human_text(text):
    """The part of a prompt a person typed: every injected block removed
    (closed or cut off), then nothing at all if what is left is only an
    injected line. '' = nothing to mirror."""
    t = INJECTED_BLOCKS.sub("", str(text or ""))
    t = t.strip()
    if not t or INJECTED_LINES.match(t):
        return ""
    return t


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
        if not str(text or "").strip():
            return None
        # An injection-only prompt (a task notification) still starts a turn:
        # it is passed on EMPTY, so the turn is recorded as no DM's.
        return ("prompt", human_text(text), session)
    if name in ("Stop", "stop"):
        if ev.get("reason") not in (None, "", "end_turn"):
            return None  # grok's session-end Stop carries no new answer
        text = ev.get("last_assistant_message")
        if text is None:
            text = ev.get("lastAssistantMessage") or ""
        return ("answer", str(text), session) if str(text).strip() else None
    return None


def resolve_agent():
    """The agent id from this process's env: SPOOL_AGENT_ID, else
    MCP_BOT_AGENT_ID; '' when neither is an agent id."""
    for k in ("SPOOL_AGENT_ID", "MCP_BOT_AGENT_ID"):
        v = os.environ.get(k) or ""
        if ID_RE.match(v):
            return v
    return ""


def mirror_off():
    """The box-wide kill switch: $SPOOL_ROOT/.mirror-off."""
    return os.path.exists(
        os.path.join(os.environ.get("SPOOL_ROOT") or "/var/spool-hub", ".mirror-off")
    )


def box_user(script):
    """The box user, who owns the desk state the post writes: SPOOL_BOX_USER,
    else the owner of the git checkout root this script lives in, else the
    script's own owner. NOT the file owner first: an agent-side git operation
    rewrites a tracked file as the agent user, and then the hook took itself
    for the box user, skipped the sudo hop, found no desk (0700) and posted
    nothing, silently - measured 2026-09-25 16:43Z, every seat of the box."""
    u = os.environ.get("SPOOL_BOX_USER", "")
    if u:
        return u
    d = os.path.dirname(script)
    while d and d != os.path.dirname(d):
        if os.path.exists(os.path.join(d, ".git")):
            try:
                return pwd.getpwuid(os.stat(d).st_uid).pw_name
            except (OSError, KeyError):
                break
        d = os.path.dirname(d)
    return pwd.getpwuid(os.stat(script).st_uid).pw_name


AGY_REQ = re.compile(r"<USER_REQUEST>\s*(.*?)\s*</USER_REQUEST>", re.S)


def agy_extract(ev, which):
    """agy (antigravity) hooks carry no text, only transcriptPath (measured,
    agy 1.2.11): the prompt is the newest USER_INPUT step (its <USER_REQUEST>
    block) at the FIRST PreInvocation of a turn (invocationNum 0); the answer
    is the PLANNER_RESPONSE text after that USER_INPUT, at Stop."""
    if not isinstance(ev, dict):
        return None
    path, session = ev.get("transcriptPath") or "", str(ev.get("conversationId") or "")
    if which == "pre" and int(ev.get("invocationNum") or 0) != 0:
        return None
    if which == "stop" and (ev.get("error") or "").strip():
        return None
    steps = []
    try:
        with open(path, errors="replace") as f:
            for line in f:
                try:
                    steps.append(json.loads(line))
                except ValueError:
                    pass
    except OSError:
        return None
    last_user = max(
        (
            i
            for i, st in enumerate(steps)
            if st.get("type") == "USER_INPUT" and st.get("source") == "USER_EXPLICIT"
        ),
        default=-1,
    )
    if last_user < 0:
        return None
    if which == "pre":
        c = str(steps[last_user].get("content") or "")
        m = AGY_REQ.search(c)
        text = (m.group(1) if m else c).strip()
        return ("prompt", text, session) if text else None
    texts = [
        str(st.get("content") or "").strip()
        for st in steps[last_user + 1 :]
        if st.get("type") == "PLANNER_RESPONSE" and st.get("source") == "MODEL"
    ]
    text = "\n\n".join(t for t in texts if t)
    return ("answer", text, session) if text else None


def vibe_text(content):
    """A Vibe message's content: a string, or a list of {type: text, text} parts."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(
            str(c.get("text") or "")
            for c in content
            if isinstance(c, dict) and c.get("type", "text") == "text"
        ).strip()
    return ""


def vibe_files(path, session):
    """The session files to read: transcript_path when it is a file; else the
    journal of the session dir it names, or of session_id under $VIBE_HOME."""
    if path and os.path.isfile(path):
        return [path]
    d = path if path and os.path.isdir(path) else ""
    if not d and re.match(r"^[0-9A-Za-z-]{8,64}$", session or ""):
        home = os.environ.get("VIBE_HOME") or os.path.join(
            os.path.expanduser("~"), ".vibe"
        )
        d = os.path.join(home, "logs", "session", "unified", session)
    if not d:
        return []
    legacy = os.path.join(d, "messages.jsonl")
    return sorted(glob.glob(os.path.join(d, "journal", "*.jsonl"))) or (
        [legacy] if os.path.isfile(legacy) else []
    )


def vibe_messages(path, session):
    """The [role, text, injected] list of a Vibe session (specs/110 3.4), oldest
    first. Two stores (mistral-vibe 2.26.0, read from its source):
      legacy   <session dir>/messages.jsonl, one LLMMessage per line
               ({role, content, injected}): the hook's transcript_path
      unified  the default harness: <VIBE_HOME>/logs/session/unified/<id>/
               journal/*.jsonl, whose projection_delta records carry
               {op, entry: {id, role, content, type: message}}; the newest
               entry per id wins
    transcript_path may name either; an empty or missing one falls back to the
    unified dir of session_id under $VIBE_HOME (default ~/.vibe)."""
    order, by_id, n = [], {}, 0

    def add(key, role, content, injected):
        if role not in ("user", "assistant"):
            return
        if key not in by_id:
            order.append(key)
        by_id[key] = [role, vibe_text(content), bool(injected)]

    for fp in vibe_files(path, session):
        try:
            with open(fp, errors="replace") as f:
                lines = f.readlines()
        except OSError:
            continue
        for line in lines:
            try:
                d = json.loads(line)
            except ValueError:
                continue
            if not isinstance(d, dict):
                continue
            n += 1
            if "role" in d:  # legacy LLMMessage
                add("legacy-%d" % n, d.get("role"), d.get("content"), d.get("injected"))
            elif d.get("type") == "projection_delta":
                for op in (d.get("payload") or {}).get("delta") or []:
                    e = op.get("entry") if isinstance(op, dict) else None
                    if isinstance(e, dict) and e.get("type") == "message":
                        add(
                            str(e.get("id") or "anon-%d" % n),
                            e.get("role"),
                            e.get("content"),
                            e.get("injected"),
                        )
    return [by_id[k] for k in order]


def vibe_extract(ev):
    """Mistral Vibe has no prompt hook: its one turn hook is post_agent (once
    per turn, after the answer). Both halves of the turn come from the
    session: the prompt is the newest user message that was not injected, the
    answer the assistant text after it.
    -> [(event, text, session), ...] in post order, or None."""
    if not isinstance(ev, dict) or ev.get("parent_session_id"):
        return None  # a subagent's turn is not the conversation
    if (ev.get("hook_event_name") or "post_agent") != "post_agent":
        return None
    session = str(ev.get("session_id") or "")
    msgs = vibe_messages(str(ev.get("transcript_path") or ""), session)
    last_user = max(
        (i for i, m in enumerate(msgs) if m[0] == "user" and not m[2] and m[1].strip()),
        default=-1,
    )
    if last_user < 0:
        return None
    out = [("prompt", human_text(msgs[last_user][1]), session)]
    text = "\n\n".join(
        m[1].strip()
        for m in msgs[last_user + 1 :]
        if m[0] == "assistant" and m[1].strip()
    )
    if text:
        out.append(("answer", text, session))
    return out


def post_detached(posts):
    """Run each (argv, text) post as the box user, in order, without the CLI's
    turn waiting: one post is one detached process; a prompt + answer pair is
    one detached child that runs them in sequence (the answer consumes the
    trigger the prompt records)."""
    if len(posts) == 1:
        # nothing of ours holds the hook's pipes open
        argv, text = posts[0]
        p = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            close_fds=True,
        )
        p.stdin.write(text.encode())
        p.stdin.close()
        return
    if os.fork() != 0:
        return
    try:
        os.setsid()
        devnull = os.open(os.devnull, os.O_RDWR)
        for fd in (0, 1, 2):
            os.dup2(devnull, fd)
        for argv, text in posts:
            subprocess.run(
                argv,
                input=text.encode(),
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=60,
            )
    finally:
        os._exit(0)


def hook_main(agy="", vibe=False):
    try:
        raw = sys.stdin.read()
        if agy:
            # agy blocks its loop on a hook and reads JSON from stdout
            print("{}", flush=True)
        if mirror_off():
            return 0
        ev = json.loads(raw) if raw.strip() else {}
        if vibe:
            got = vibe_extract(ev)
        else:
            one = agy_extract(ev, agy) if agy else hook_extract(ev)
            got = [one] if one else None
        agent = resolve_agent()
        if not got or not ID_RE.match(agent):
            return 0
        base = os.environ.get("SPOOL_MIRROR_POST", "").split()
        if not base:
            owner = box_user(os.path.realpath(__file__))
            me = pwd.getpwuid(os.getuid()).pw_name
            base = [sys.executable, os.path.realpath(__file__)]
            if owner != me:
                base = ["sudo", "-n", "-u", owner] + base
        posts = [
            (
                base
                + ["post", "--agent", agent, "--event", event, "--session", session],
                text,
            )
            for event, text, session in got
        ]
        if os.environ.get("SPOOL_MIRROR_SYNC") == "1":
            for argv, text in posts:
                subprocess.run(
                    argv,
                    input=text.encode(),
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=60,
                )
            return 0
        post_detached(posts)
    except Exception:  # noqa: BLE001 - a mirror must never break the CLI
        pass
    return 0


# ── post half (box user) ────────────────────────────────────────────────────
def seats(agent):
    pat = os.environ.get("SPOOL_MIRROR_SEATS") or os.path.expanduser(
        "~/.local/share/csi-spl/cloud/*/desk/*/*"
    )
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


def triggers(agent_dir, now):
    """Why the notifier typed each recent line: {normalised line: (path, record)}."""
    out = {}
    for p in sorted(glob.glob(os.path.join(agent_dir, ".mirror", "trigger", "*"))):
        try:
            if now - os.path.getmtime(p) > TYPED_TTL:
                os.unlink(p)
                continue
        except OSError:
            continue
        rec = _read_json(p)
        if rec.get("line"):
            out[norm(rec["line"])] = (p, rec)  # the newest record of a line wins
    return out


def turn_trigger(agent_dir, text, now):
    """The trigger of the turn this prompt starts (spec 067 L2):
    {"kind": "dm", "to": HUM, "task": T} when a line of it is a human's DM the
    desk typed, else {"kind": channel|task|agent|terminal|cli}. The matched
    trigger and typed records are consumed; old ones expire."""
    typed = typed_lines(agent_dir, now)
    trig = triggers(agent_dir, now)
    kinds, dm = [], None
    for line in [text] + text.split("\n"):
        n = norm(line)
        if not n:
            continue
        if n in typed:
            _unlink(typed.pop(n))
        if n in trig:
            p, rec = trig.pop(n)
            _unlink(p)
            if (
                rec.get("kind") == "dm"
                and HUM_RE.match(str(rec.get("from", "")))
                and UUID_RE.match(str(rec.get("task", "")))
            ):
                dm = dm or {"kind": "dm", "to": rec["from"], "task": rec["task"]}
            else:
                # a dm record naming no human or no topic is no DM to answer
                kinds.append(
                    "task"
                    if rec.get("kind") == "dm"
                    else str(rec.get("kind") or "task")
                )
    if dm:
        return dm
    if kinds:
        return {"kind": kinds[0]}
    if any(MACHINE_LINE.match(norm(ln)) for ln in text.split("\n")):
        return {"kind": "agent"}
    return {"kind": "terminal" if text.strip() else "cli"}


def take_turn(agent_dir):
    """Read and consume the current turn's trigger: one DM answers one turn."""
    p = os.path.join(agent_dir, ".mirror", "turn")
    t = _read_json(p)
    _unlink(p)
    return t


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
    """-> (human, task or ''): the DM topic the human last wrote in (.mirror/peer),
    else the one a post last landed in (.mirror/topic). For the `topic`
    subcommand; a post takes its DM from the turn's trigger, never from here."""
    peer = _read_json(os.path.join(agent_dir, ".mirror", "peer"))
    human, task = str(peer.get("to", "")), str(peer.get("task", ""))
    if HUM_RE.match(human) and UUID_RE.match(task):
        return human, task
    # No literal id: a human id is per env (the owner is one id on dev and
    # another on prd), so the default is the DESK's (<seat>/mirror-to, beside
    # spool/), else SPOOL_MIRROR_TO, else nobody - the post is skipped.
    # Measured 2026-09-25: a hard-coded dev id sent 177 prd posts to a human
    # that does not exist on prd.
    mine = _read_json(os.path.join(agent_dir, ".mirror", "topic"))
    human = ""
    try:
        human = (
            open(
                os.path.join(
                    os.path.dirname(os.path.dirname(agent_dir.rstrip("/"))), "mirror-to"
                )
            )
            .read()
            .strip()
        )
    except OSError:
        pass
    if not HUM_RE.match(human):
        human = os.environ.get("SPOOL_MIRROR_TO", "")
    if not HUM_RE.match(human):
        return "", ""
    if mine.get("to") == human and UUID_RE.match(str(mine.get("task", ""))):
        return human, mine["task"]
    return human, ""


def set_operator(path, human):
    """operator <seat>|<seat>/spool/<agent> HUM-n|--clear"""
    f = (
        os.path.join(path, ".mirror", "operator")
        if os.path.basename(os.path.dirname(path.rstrip("/"))) == "spool"
        else os.path.join(path, "operator")
    )
    if human == "--clear":
        try:
            os.unlink(f)
        except OSError:
            pass
        return 0
    if not HUM_RE.match(human):
        print(f"not a human id: {human!r}", file=sys.stderr)
        return 64
    os.makedirs(os.path.dirname(f), exist_ok=True)
    with open(f, "w") as fh:
        fh.write(human + "\n")
    print(f)
    return 0


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
    return (
        cut + f"\n… [{len(b) - BODY_MAX} more bytes: the full text is in the terminal]"
    )


SEEN_TTL = 60  # seconds a (session, event, text) post is remembered


def first_sighting(adir, session, event, text, now):
    """True once per (session, event, text) within SEEN_TTL. Two hook configs
    that both reach one session (the shared ~/.claude/settings.json and a
    wrapper's --settings, at different script paths) fire twice for one
    prompt; the O_EXCL create lets exactly one of them post."""
    d = os.path.join(adir, ".mirror", "seen")
    os.makedirs(d, exist_ok=True)
    for p in glob.glob(os.path.join(d, "*")):
        try:
            if now - os.path.getmtime(p) > SEEN_TTL:
                os.unlink(p)
        except OSError:
            pass
    h = hashlib.sha256("\0".join((session, event, norm(text))).encode()).hexdigest()[
        :32
    ]
    try:
        os.close(
            os.open(os.path.join(d, h), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        )
        return True
    except FileExistsError:
        return False


def post_one(seat, agent, event, text, session):
    adir = os.path.join(seat, "spool", agent)
    now = time.time()
    if event == "prompt":
        # Never posted (spec 067: the echo kinds A-D). It only says what
        # started the turn, so the answer knows whether it answers a DM.
        text = human_text(text)
        if session and not first_sighting(adir, session, event, text, now):
            log(
                adir,
                "skip prompt: a second hook fired for the same prompt of this session",
            )
            return "skipped"
        turn = turn_trigger(adir, text, now)
        os.makedirs(os.path.join(adir, ".mirror"), exist_ok=True)
        with open(os.path.join(adir, ".mirror", "turn.tmp"), "w") as f:
            json.dump(turn, f)
        os.replace(
            os.path.join(adir, ".mirror", "turn.tmp"),
            os.path.join(adir, ".mirror", "turn"),
        )
        log(
            adir,
            "turn: "
            + (
                f"dm from {turn['to']} task {turn['task']}"
                if turn["kind"] == "dm"
                else f"{turn['kind']} - its answer is not posted"
            ),
        )
        return "recorded"
    if session and not first_sighting(adir, session, event, text, now):
        log(
            adir, "skip answer: a second hook fired for the same answer of this session"
        )
        return "skipped"
    turn = take_turn(adir)
    if (
        turn.get("kind") != "dm"
        or not HUM_RE.match(str(turn.get("to", "")))
        or not UUID_RE.match(str(turn.get("task", "")))
    ):
        log(
            adir,
            f"skip answer: the turn was not started by a DM ({turn.get('kind') or 'no prompt recorded'})",
        )
        return "skipped"
    h = hashlib.sha256((session + "\0" + norm(text)).encode()).hexdigest()
    last = os.path.join(adir, ".mirror", "last-answer")
    try:
        if open(last).read().strip() == h:
            log(
                adir, "skip answer: the same answer was already posted for this session"
            )
            return "skipped"
    except OSError:
        pass
    human, task = turn["to"], turn["task"]
    text = answer_text(text)
    if not text:
        log(
            adir,
            "skip answer: status only (watcher, lease, poll, spinner or tool progress), no answer for a person",
        )
        return "skipped"
    body, counts = redact(text)
    body = clip_body(body)
    env = seat_env(seat)
    if "SPOOL_HUB_URL" not in env:
        log(adir, f"FAIL {event}: no live sidecar to read the hub url from")
        return "failed"
    spool = os.environ.get("SPOOL_MIRROR_SPOOL") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(seat.rstrip("/")))),
        "bin",
        "spool",
    )
    argv = [
        spool,
        "send",
        "--from",
        agent,
        "--to",
        human,
        "--to-box",
        "box-wui",
        "--kind",
        "note",
        "--task",
        task,
        "--body",
        body,
    ]
    if os.environ.get("SPOOL_MIRROR_DRY") == "1":
        # A dry run writes no state: no topic, no watermark, no log line.
        print(
            json.dumps(
                {"seat": seat, "argv": argv, "env": env, "redactions": counts},
                sort_keys=True,
            )
        )
        return "dry"
    r = subprocess.run(
        argv, env={**os.environ, **env}, capture_output=True, text=True, timeout=60
    )
    rc, out = r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()
    if rc != 0:
        log(adir, f"FAIL {event} -> {human}: rc {rc}: {out[:300]}")
        return "failed"
    try:
        sent = json.loads(out.splitlines()[-1])
    except (ValueError, IndexError):
        sent = {}
    remember_topic(adir, human, task)
    with open(last, "w") as f:
        f.write(h)
    log(
        adir,
        f"OK {event} -> {human} task {task} msg {sent.get('msg_id', '?')} "
        f"({len(body)} chars, redactions {counts or 'none'})",
    )
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
        print(
            "usage: post --agent ID --event prompt|answer [--session S] < text",
            file=sys.stderr,
        )
        return 64
    text = sys.stdin.read()
    if not text.strip() and event == "answer":
        return 0
    # Every seat (dev, prd, ...) in parallel: one spool send is ~80-100 ms and
    # they were serial (measured 2026-09-25: 2 seats 198-257 ms).
    import concurrent.futures

    ss = seats(agent)
    rc = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(ss))) as ex:
        for seat, res in zip(
            ss, ex.map(lambda st: post_one(st, agent, event, text, session), ss)
        ):
            print(f"{res} {seat}")
            rc = rc or (1 if res == "failed" else 0)
    return rc


def remember_topic(agent_dir, human, task):
    """Record the topic a post (or the backfill) landed in, when it is new."""
    if not (HUM_RE.match(human) and UUID_RE.match(task)):
        return
    os.makedirs(os.path.join(agent_dir, ".mirror"), exist_ok=True)
    with open(os.path.join(agent_dir, ".mirror", "topic"), "w") as f:
        json.dump({"to": human, "task": task}, f)


def main(argv):
    if len(argv) >= 2 and argv[1] == "hook":
        # `hook --agy pre|stop`: agy's payloads name no event, so the config does
        if len(argv) >= 3 and argv[2] == "--vibe":
            return hook_main(vibe=True)
        return hook_main(argv[3] if len(argv) >= 4 and argv[2] == "--agy" else "")
    if len(argv) == 3 and argv[1] == "topic":
        # The DM a post from this agent dir would land in: "<human>\t<task>".
        print("\t".join(pick_topic(argv[2])))
        return 0
    if len(argv) == 4 and argv[1] == "operator":
        return set_operator(argv[2], argv[3])
    if len(argv) == 5 and argv[1] == "remember":
        remember_topic(argv[2], argv[3], argv[4])
        return 0
    if len(argv) >= 2 and argv[1] == "post":
        return post_main(argv[2:])
    print(__doc__, file=sys.stderr)
    return 64


if __name__ == "__main__":
    sys.exit(main(sys.argv))
