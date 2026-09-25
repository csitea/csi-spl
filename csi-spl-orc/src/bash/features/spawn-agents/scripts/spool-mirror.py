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
(no default: a human id is per env).

Opt out per seat: touch <seat>/spool/<agent>/.no-mirror.

Usage:
  spool-mirror.py hook                     < hook JSON (claude, grok)
  spool-mirror.py hook --agy pre|stop      < agy hook JSON (PreInvocation, Stop)
  spool-mirror.py post --agent ID --event prompt|answer [--session S] < text
  spool-mirror.py topic <seat>/spool/<agent>       -> "<human>\t<task>"
  spool-mirror.py remember <seat>/spool/<agent> <human> <task>
  spool-mirror.py operator <seat>[/spool/<agent>] HUM-n|--clear
                      who types at this desk (or this one seat): its prompts
                      are posted AS that human (typed_by, hub-verified)

Environment (post):
  SPOOL_MIRROR_SEATS  glob of desk dirs, default
                      $HOME/.local/share/csi-spl/cloud/*/desk/*/*
  SPOOL_MIRROR_TO     the human when the desk names none (<desk>/mirror-to);
                      unset + no peer + no desk file = the post is skipped
  SPOOL_MIRROR_SPOOL  the spool binary, default <env dir>/bin/spool
  SPOOL_MIRROR_DRY    1 = print the send argv instead of running it
Environment (hook):
  MCP_BOT_AGENT_ID    the agent id (set by the spawner); SPOOL_AGENT_ID wins.
                      When both are unset, the hook takes the id from the
                      tmux window that owns this process, so a hand-started
                      grok still mirrors. SPOOL_MIRROR_DISCOVER=0 turns that off.
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
# A line another AGENT typed into this pane: the inbox doorbell (bare, or the
# shell-inert `: 'INBOX ...'` form inbox-send.sh types) and the desk's
# `: 'SPOOL ...'` poke line. Mirrored as typed by that agent, never as a human.
MACHINE_LINE = re.compile(r"^(?::\s*')?(?:INBOX|SPOOL) [A-Z]{2,4}-[0-9]+\b")
LINE_SENDER = (re.compile(r"--([A-Z]{2,4}-[0-9]+)--"), re.compile(r"\bfrom ([A-Z]{2,4}-[0-9]+)\b"))


def line_sender(line):
    for pat in LINE_SENDER:
        m = pat.search(line)
        if m:
            return m.group(1)
    return ""
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


def ancestor_pids(start):
    """Pids from start up to, but not including, pid 1."""
    pids, pid, seen = [], start, set()
    while pid and pid not in seen and pid != 1:
        seen.add(pid)
        pids.append(pid)
        try:
            with open("/proc/%d/stat" % pid) as f:
                stat = f.read()
            pid = int(stat[stat.rfind(")") + 2:].split()[1])
        except (OSError, ValueError, IndexError):
            break
    return pids


def agent_from_window_rows(pids, rows):
    """The agent id in the tmux window whose pane pid is one of pids."""
    want = {str(p) for p in pids}
    for row in rows:
        pid, _, name = row.partition(" ")
        if pid not in want or not name:
            continue
        m = re.search(r"[A-Z]{2,4}-[0-9]+", name)
        if m and ID_RE.match(m.group(0)):
            return m.group(0)
    return ""


def tmux_pane_rows():
    """`pane_pid window_name` lines, or [] when tmux cannot be asked."""
    if os.environ.get("SPOOL_MIRROR_DISCOVER", "1") == "0":
        return []
    try:
        owner = pwd.getpwuid(os.stat(os.path.realpath(__file__)).st_uid)
    except OSError:
        return []
    sock = os.environ.get("SPOOL_TMUX_SOCKET") or "/tmp/tmux-%d/default" % owner.pw_uid
    cmd = ["tmux", "-S", sock, "list-panes", "-a", "-F", "#{pane_pid} #{window_name}"]
    if owner.pw_uid != os.getuid():
        cmd = ["sudo", "-n", "-u", owner.pw_name] + cmd
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=3)
    except (OSError, subprocess.TimeoutExpired):
        return []
    return out.stdout.splitlines() if out.returncode == 0 else []


def resolve_agent():
    """The spawner env, else the id painted on this process's tmux window."""
    agent = os.environ.get("SPOOL_AGENT_ID") or os.environ.get("MCP_BOT_AGENT_ID") or ""
    if ID_RE.match(agent):
        return agent
    return agent_from_window_rows(ancestor_pids(os.getppid()), tmux_pane_rows())


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
    last_user = max((i for i, st in enumerate(steps) if st.get("type") == "USER_INPUT"
                     and st.get("source") == "USER_EXPLICIT"), default=-1)
    if last_user < 0:
        return None
    if which == "pre":
        c = str(steps[last_user].get("content") or "")
        m = AGY_REQ.search(c)
        text = (m.group(1) if m else c).strip()
        return ("prompt", text, session) if text else None
    texts = [str(st.get("content") or "").strip() for st in steps[last_user + 1:]
             if st.get("type") == "PLANNER_RESPONSE" and st.get("source") == "MODEL"]
    text = "\n\n".join(t for t in texts if t)
    return ("answer", text, session) if text else None


def hook_main(agy=""):
    try:
        raw = sys.stdin.read()
        if agy:
            # agy blocks its loop on a hook and reads JSON from stdout
            print("{}", flush=True)
        ev = json.loads(raw) if raw.strip() else {}
        got = agy_extract(ev, agy) if agy else hook_extract(ev)
        agent = resolve_agent()
        if not got or not ID_RE.match(agent):
            return 0
        event, text, session = got
        argv = os.environ.get("SPOOL_MIRROR_POST", "").split()
        if not argv:
            owner = box_user(os.path.realpath(__file__))
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


def prompt_keep(agent_dir, text, now, agent_lines=None):
    """Drop the lines that came from the web UI; set aside the lines another
    agent typed (into agent_lines, when given - else they are dropped).
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
            if agent_lines is None:
                dropped += 1
            else:
                agent_lines.append(n)
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
    # No literal id: a human id is per env (the owner is one id on dev and
    # another on prd), so the default is the DESK's (<seat>/mirror-to, beside
    # spool/), else SPOOL_MIRROR_TO, else nobody - the post is skipped.
    # Measured 2026-09-25: a hard-coded dev id sent 177 prd posts to a human
    # that does not exist on prd.
    mine = _read_json(os.path.join(agent_dir, ".mirror", "topic"))
    human = ""
    try:
        human = open(os.path.join(os.path.dirname(os.path.dirname(agent_dir.rstrip("/"))), "mirror-to")).read().strip()
    except OSError:
        pass
    if not HUM_RE.match(human):
        human = os.environ.get("SPOOL_MIRROR_TO", "")
    if not HUM_RE.match(human):
        return "", ""
    if mine.get("to") == human and UUID_RE.match(str(mine.get("task", ""))):
        return human, mine["task"]
    return human, ""


def operator_of(seat, adir):
    """The human at this terminal (FR-012): the seat's .mirror/operator, else
    the desk's <seat>/operator. Explicit only - never guessed, because a
    refused claim on a QUEUED send is dropped by the hub, not re-posted."""
    for p in (os.path.join(adir, ".mirror", "operator"), os.path.join(seat, "operator")):
        try:
            v = open(p).read().strip()
        except OSError:
            continue
        if HUM_RE.match(v):
            return v
    return ""


def set_operator(path, human):
    """operator <seat>|<seat>/spool/<agent> HUM-n|--clear"""
    f = (os.path.join(path, ".mirror", "operator") if os.path.basename(os.path.dirname(path.rstrip("/"))) == "spool"
         else os.path.join(path, "operator"))
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
    return cut + f"\n… [{len(b) - BODY_MAX} more bytes: the full text is in the terminal]"


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
    h = hashlib.sha256("\0".join((session, event, norm(text))).encode()).hexdigest()[:32]
    try:
        os.close(os.open(os.path.join(d, h), os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        return True
    except FileExistsError:
        return False


def post_one(seat, agent, event, text, session):
    adir = os.path.join(seat, "spool", agent)
    now = time.time()
    if event == "prompt":
        agent_lines = []
        text, dropped = prompt_keep(adir, text, now, agent_lines)
        if agent_lines:
            # Typed by another agent: posted from THIS agent's seat, marked
            # with the typing agent, never with a human's typed_by.
            by = line_sender(agent_lines[0]) or "an agent"
            post_one(seat, agent, "agent-typed", f"[typed by {by}] " + "\n".join(agent_lines), session)
        if not text.strip():
            if not agent_lines:
                log(adir, f"skip prompt: every line came from the web UI ({dropped})")
            return "skipped"
        body = text
    elif event == "agent-typed":
        body = text
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
    if session and not first_sighting(adir, session, event, body, now):
        log(adir, f"skip {event}: a second hook fired for the same {event} of this session")
        return "skipped"
    body, counts = redact(body)
    body = clip_body(body)
    human, task = pick_topic(adir)
    if not human:
        log(adir, f"skip {event}: no human to post to on this desk (no DM peer, no {seat}/mirror-to, no SPOOL_MIRROR_TO)")
        return "skipped"
    env = seat_env(seat)
    if "SPOOL_HUB_URL" not in env:
        log(adir, f"FAIL {event}: no live sidecar to read the hub url from")
        return "failed"
    spool = os.environ.get("SPOOL_MIRROR_SPOOL") or os.path.join(
        os.path.dirname(os.path.dirname(os.path.dirname(seat.rstrip("/")))), "bin", "spool")
    # FR-009..FR-012: a prompt the operator typed goes out AS that human
    # (typed_by, hub-verified) with no [terminal] prefix. Refused, or a spool
    # binary that predates the flag: re-post the old way, prefixed.
    op = operator_of(seat, adir) if event == "prompt" else ""

    def argv_for(typed_by):
        b = body if typed_by or event != "prompt" else PROMPT_PREFIX + body
        a = [spool, "send", "--from", agent, "--to", human, "--to-box", "box-wui",
             "--kind", "note", "--body", b]
        if task:
            a += ["--task", task]
        if typed_by:
            a += ["--typed-by", typed_by]
        return a
    argv = argv_for(op)
    if os.environ.get("SPOOL_MIRROR_DRY") == "1":
        # A dry run writes no state: no topic, no watermark, no log line.
        print(json.dumps({"seat": seat, "argv": argv, "env": env, "redactions": counts}, sort_keys=True))
        return "dry"
    r = subprocess.run(argv, env={**os.environ, **env}, capture_output=True, text=True, timeout=60)
    rc, out = r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()
    if rc != 0 and op and ("typed_by_not_bound" in out or "typed-by" in out):
        why = "not bound on the hub" if "typed_by_not_bound" in out else "this spool binary has no --typed-by"
        log(adir, f"typed_by {op} refused ({why}): re-posting as {agent}")
        op = ""
        r = subprocess.run(argv_for(""), env={**os.environ, **env}, capture_output=True, text=True, timeout=60)
        rc, out = r.returncode, ((r.stdout or "") + (r.stderr or "")).strip()
    if rc != 0:
        log(adir, f"FAIL {event} -> {human}: rc {rc}: {out[:300]}")
        return "failed"
    try:
        sent = json.loads(out.splitlines()[-1])
    except (ValueError, IndexError):
        sent = {}
    got_task = str(sent.get("task_id", "")) or task
    os.makedirs(os.path.join(adir, ".mirror"), exist_ok=True)
    remember_topic(adir, human, got_task)
    if event == "answer":
        with open(os.path.join(adir, ".mirror", "last-answer"), "w") as f:
            f.write(h)
    log(adir, f"OK {event} -> {human} task {got_task} msg {sent.get('msg_id', '?')} "
              f"({len(body)} chars, redactions {counts or 'none'}){' typed_by ' + op if op else ''}")
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
    # Every seat (dev, prd, ...) in parallel: one spool send is ~80-100 ms and
    # they were serial (measured 2026-09-25: 2 seats 198-257 ms).
    import concurrent.futures
    ss = seats(agent)
    rc = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, len(ss))) as ex:
        for seat, res in zip(ss, ex.map(lambda st: post_one(st, agent, event, text, session), ss)):
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
