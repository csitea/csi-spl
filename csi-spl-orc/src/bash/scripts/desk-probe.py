"""desk-probe.py - the round trip of a desk agent (do_spl_desk_up), end to end.

A signed-in member DMs the desk agent from a scripted WUI session; the message
has to reach the agent's inbox AND its terminal pane (specs/028); the documented
reply action has to put the answer back in the browser's topic.

Run it through `./run -a do_spl_desk_probe`, which sets the environment. The WUI
session, the login and the viewer API come from m3-e2e.py - one renderer of the
WS protocol on this box, not two.

Env (all set by the action):
  M3_HUB_URL M3_AUTH_URL M3_TENANT M3_STATE M3_SPOOL M3_HUMAN_EMAIL   as m3-e2e.py
  DESK_AGENT      the agent id the desk seats
  DESK_BOX        the desk box id
  DESK_ROOT       the desk's SPOOL_ROOT
  DESK_REPLY_CMD  argv (JSON list) of the reply leg, run with DESK_BODY in env
  DESK_TMUX_SOCK  the box user's tmux socket (default /tmp/tmux-<uid>/default)
  DESK_NOTIFY_CMD the box's terminal-leg renderer, asked for its verdict when
                  the pane shows nothing (its exit code is poke-line.md §3)
  DESK_OUT        where to write results.json
"""
import importlib.util
import json
import os
import subprocess
import sys
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
_spec = importlib.util.spec_from_file_location("m3_e2e", os.path.join(HERE, "m3-e2e.py"))
m3 = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(m3)

AGENT = os.environ.get("DESK_AGENT", "")
BOX = os.environ.get("DESK_BOX", "")
ROOT = os.environ.get("DESK_ROOT", "")
REPLY_CMD = json.loads(os.environ.get("DESK_REPLY_CMD", "[]"))
TMUX_SOCK = os.environ.get("DESK_TMUX_SOCK", "/tmp/tmux-%d/default" % os.getuid())
OUT = os.environ.get("DESK_OUT", "")
NOTIFY_CMD = os.environ.get("DESK_NOTIFY_CMD", "")
WUI_BOX = "box-wui"

RESULTS = []


def record(step, ok, evidence):
    RESULTS.append({"step": step, "result": "PASS" if ok else "FAIL", "evidence": evidence})
    print("%-4s %s %s" % ("PASS" if ok else "FAIL", step, json.dumps(evidence, sort_keys=True)[:600]), flush=True)
    return ok


def inbox_msgs():
    d = os.path.join(ROOT, AGENT, "inbox")
    out = []
    for name in sorted(os.listdir(d)) if os.path.isdir(d) else []:
        if not name.endswith(".json"):
            continue
        try:
            with open(os.path.join(d, name)) as f:
                out.append(json.load(f))
        except (OSError, ValueError):
            continue
    return out


def wait_inbox(msg_id, timeout=30):
    end = time.time() + timeout
    while time.time() < end:
        for m in inbox_msgs():
            if m.get("msg_id") == msg_id:
                return m
        time.sleep(0.5)
    return None


def pane_of(agent):
    """The live pane whose window name carries AGENT - the rule
    lib/spool-env.inc.sh spool_id_of_window uses, so the probe looks where the
    notifier looked."""
    try:
        out = subprocess.run(["tmux", "-u", "-S", TMUX_SOCK, "list-panes", "-a", "-F", "%s\t%s" % ("#{pane_id}", "#{window_name}")],
                             capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.splitlines():
        if "\t" not in line:
            continue
        pane, name = line.split("\t", 1)
        n = name.split(": ", 1)[-1] if ": " in name else name
        if n.split(" ")[0] == agent:
            return pane
    return ""


def notice_pane_of(agent):
    """The notice pane spool_poke_show splits into the agent's window, marked
    with the pane option @spool_notices. On a pane that paints a TUI this is
    where the body is VISIBLE, since the prompt may legitimately refuse it."""
    try:
        out = subprocess.run(["tmux", "-u", "-S", TMUX_SOCK, "list-panes", "-a", "-F",
                              "#{pane_id}\t#{@spool_notices}"],
                             capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""
    for line in out.splitlines():
        if "\t" not in line:
            continue
        pane, mark = line.split("\t", 1)
        if mark.strip() == agent:
            return pane
    return ""


def pane_text(pane):
    """The visible pane AND its recent scrollback: a busy agent's pane scrolls
    a poke off the screen in seconds, and a plain capture would then report a
    delivered message as missing."""
    try:
        return subprocess.run(["tmux", "-u", "-S", TMUX_SOCK, "capture-pane", "-p", "-S", "-500", "-t", pane],
                              capture_output=True, text=True, timeout=15).stdout
    except (OSError, subprocess.SubprocessError):
        return ""


def wait_pane(panes, needle, timeout=30):
    """Seconds until `needle` is visible in ANY of `panes`, else None.

    capture-pane hard-wraps, and can split a word across lines, so the raw
    substring is not a reliable assert: compare on the whitespace-free text."""
    flat = "".join(needle.split())
    end = time.time() + timeout
    while time.time() < end:
        for pane in panes:
            if pane and flat in "".join(pane_text(pane).split()):
                return pane
        time.sleep(0.5)
    return None


POKE_RC = {0: "typed into the pane", 5: "no live window carries the id",
           6: "REFUSED: the pane holds unsent text", 7: "the pane runs only shells"}


def observe(step, evidence):
    RESULTS.append({"step": step, "result": "OBSERVED", "evidence": evidence})
    print("OBS  %s %s" % (step, json.dumps(evidence, sort_keys=True)[:600]), flush=True)


def notifier_verdict(frm, msg_id, task, body):
    """Run the box's own renderer for this message and return (exit, output).
    Its exit code is the authority on what happened to the pane
    (specs/028 contracts/poke-line.md §3); re-running it is safe - it sends
    nothing and writes nothing, the message is already in the inbox."""
    if not NOTIFY_CMD:
        return -1, "no DESK_NOTIFY_CMD"
    argv = NOTIFY_CMD.split() + ["--to", AGENT, "--from", frm, "--kind", "note",
                                 "--task", task, "--msg-id", msg_id, "--body-stdin"]
    try:
        r = subprocess.run(argv, input=body, capture_output=True, text=True, timeout=60,
                           env=dict(os.environ, SPOOL_ROOT=ROOT))
    except (OSError, subprocess.SubprocessError) as e:
        return -1, str(e)[:200]
    return r.returncode, (r.stdout + r.stderr).strip()[:300]


def main():
    for name, v in (("DESK_AGENT", AGENT), ("DESK_BOX", BOX), ("DESK_ROOT", ROOT)):
        if not v:
            sys.exit("%s is required" % name)
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    ask = "desk-probe kysymys %s" % stamp          # Finnish in, Finnish out
    answer = "desk-probe vastaus %s" % stamp

    st, body, cookie = m3.native_login(m3.HUMAN, m3.TENANT, "human")
    if st != 200 or not cookie:
        record("p-member-session", False, {"login_status": st, "body": body})
        return finish(1)
    m3.write_secret("cookie-human", cookie)
    st, _, sess = m3.http("GET", m3.AUTH + "/api/v1/auth/session", headers={"Cookie": cookie})
    hum = (sess or {}).get("hum", "") if st == 200 else ""
    ok = record("p-member-session", st == 200 and hum.startswith("HUM-") and (sess or {}).get("t") == m3.TENANT,
                {"session_status": st, "hum": hum, "t": (sess or {}).get("t")})
    if not ok:
        return finish(1)

    pane = pane_of(AGENT)
    record("p-agent-pane", bool(pane), {"pane": pane, "tmux_socket": TMUX_SOCK, "agent": AGENT})

    ws = m3.WS(m3.ws_url("/v1/wui/ws"), cookie)
    rc = 1
    try:
        ws.send({"type": "hello", "as": "desk-probe"})
        wel = ws.wait(lambda f: f.get("type") in ("welcome", "error"))
        if not record("p-welcome", bool(wel) and wel.get("as") == hum, {"welcome": wel}):
            return finish(1)
        peer = "%s@%s" % (AGENT, BOX)
        online = ws.any_seen(lambda f: f.get("type") == "presence" and f.get("peer") == peer
                             and f.get("status") == "online")
        roster = m3.view("/v1/view/roster")
        seat = next((b for b in (roster or {}).get("boxes", [])
                     if b.get("box_id") == BOX and AGENT in (b.get("agents") or [])), None)
        record("p-roster-seat", seat is not None and bool(seat.get("online")) and not seat.get("revoked"),
               {"peer": peer, "roster_row": seat, "presence_frame_seen": bool(online)})

        task = str(uuid.uuid4())
        ws.send({"type": "subscribe", "task_id": task})
        ws.wait(lambda f: f.get("type") == "subscribed" and f.get("task_id") == task)
        mid = str(uuid.uuid4())
        ws.send({"type": "send", "task_id": task, "kind": "note", "to": AGENT, "body": ask, "msg_id": mid})
        ack = ws.wait(lambda f: f.get("msg_id") == mid and f.get("type") in ("ack", "error"), 25)
        if not record("p-dm-accepted", bool(ack) and ack.get("type") == "ack" and ack.get("to_box") == BOX,
                      {"ack": ack, "task_id": task}):
            return finish(1)

        got = wait_inbox(mid)
        if not record("p-dm-in-inbox", got is not None and got.get("from") == hum and got.get("body") == ask,
                      {"inbox_msg": got, "inbox": os.path.join(ROOT, AGENT, "inbox")}):
            return finish(1)

        if pane:
            notice = notice_pane_of(AGENT)
            shown = wait_pane([pane, notice], ask)
            if shown is not None:
                record("p-dm-in-pane", True,
                       {"pane": shown, "agent_pane": pane, "notice_pane": notice, "needle": ask,
                        "via": "notice pane" if shown == notice else "agent pane"})
            else:
                # Not shown is not the same as not delivered. poke-line.md §3
                # gives the notifier four outcomes and three of them leave the
                # pane alone on purpose, so ask the notifier - its exit code is
                # the contract - instead of re-deciding the rule here.
                rc, line = notifier_verdict(hum, mid, task, ask)
                if rc == 0:
                    record("p-dm-in-pane", True, {"pane": pane, "needle": ask,
                                                  "via": "notifier re-poke", "notify": line})
                elif rc in (5, 6, 7):
                    observe("p-dm-in-pane", {"pane": pane, "notify_exit": rc, "notify": line,
                                             "means": POKE_RC.get(rc, ""),
                                             "note": "delivered; the pane was left alone on purpose"})
                else:
                    record("p-dm-in-pane", False, {"pane": pane, "notice_pane": notice, "needle": ask,
                                                   "notify_exit": rc, "notify": line,
                                                   "tail": pane_text(pane).splitlines()[-3:]})
        else:
            observe("p-dm-in-pane", {"note": "no live window carries %s; the message waits in its inbox" % AGENT})

        if REPLY_CMD:
            env = dict(os.environ, DESK_BODY=answer, DESK_TASK=task, DESK_TO=hum)
            r = subprocess.run(REPLY_CMD, capture_output=True, text=True, timeout=300, env=env,
                               cwd=os.environ.get("DESK_REPLY_CWD") or None)
            if not record("p-reply-sent", r.returncode == 0,
                          {"cmd": REPLY_CMD, "exit": r.returncode, "tail": (r.stdout or r.stderr)[-400:]}):
                return finish(1)
            back = ws.wait(lambda f: f.get("type") == "message" and f.get("task_id") == task
                           and (f.get("envelope") or {}).get("from") == AGENT, 30)
            kinds = [m["env"]["msg"]["kind"] for m in m3.topic(task)]
            bodies = [m["env"]["msg"]["body"] for m in m3.topic(task)]
            record("p-reply-in-wui-topic", back is not None and answer in bodies,
                   {"wui_frame_msg_id": (back or {}).get("envelope", {}).get("msg_id"),
                    "topic_kinds": kinds, "topic_bodies": bodies})
        rc = 0 if all(r["result"] != "FAIL" for r in RESULTS) else 1
    finally:
        ws.close()
    return finish(rc)


def finish(rc):
    if OUT:
        try:
            with open(OUT, "w") as f:
                json.dump({"results": RESULTS, "agent": AGENT, "box": BOX,
                           "at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())}, f, indent=1, sort_keys=True)
        except OSError:
            pass
    bad = [r["step"] for r in RESULTS if r["result"] == "FAIL"]
    print(("FAIL desk probe: " + ", ".join(bad)) if bad else "OK desk probe: every step PASS", flush=True)
    return 1 if bad else rc


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(main())
