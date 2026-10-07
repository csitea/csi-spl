#!/bin/bash
#------------------------------------------------------------------------------
# @description Compose one agent's handoff file (spec 102 5.1, 5.2):
# @description <spool root>/<id>/handoff.md, the 9 sections of 5.2 (header,
# @description brief, done, in flight, next step, open questions, owned topics,
# @description notes, lessons), about 250 lines at most. The ONLY writer of
# @description handoff.md: under lifetime/handoff.lock (flock -x, 10 s, busy =
# @description exit 4), written to handoff.md.tmp.<pid>, the old file renamed
# @description to handoff.prev.md, then the tmp renamed in. A kill while
# @description composing leaves the previous complete file. It reads the
# @description agent's own handoff.d/{next,notes,lessons}.md, never writes them.
# @description The terminal lines go through spool_redact.py first. The brief
# @description is filled once: later composes carry it from the previous file.
# @description Callers: the PostToolUse hook (detached, at most every 60 s), the
# @description watchdog and the restart. No network: git reads local refs only.
# @param ID (optional) - the agent id, default $SPOOL_AGENT_ID
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param HANDOFF_WORKDIR (optional) - the agent's worktree, default its registry row, else $PWD
# @param HANDOFF_BRIEF (optional) - the brief path, default lifetime/session.json .brief
# @param HANDOFF_HARD_KILLED (optional) - 1 sets hard_killed: true in the header (the restart)
# @param HANDOFF_CAPTURE_CMD (optional) - seam: prints the pane's lines (default tmux capture-pane -J)
# @param HANDOFF_LOCK (optional, SPOOL_TEST=1 only) - 0 composes without the lock (the test control)
# @param HANDOFF_PAUSE_FILE (optional, SPOOL_TEST=1 only) - wait for this file between the renames
# @param HANDOFF_KILL_AT (optional, SPOOL_TEST=1 only) - SIGKILL the compose after section <n>
# @example ./run -a do_spl_agent_handoff
# @example ID=c-123 ./run -a do_spl_agent_handoff
#------------------------------------------------------------------------------

_spl_handoff_lib() {
  local here
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  printf '%s' "$here/../features/spawn-agents/lib"
}

do_spl_agent_handoff() {
  local id="${ID:-${SPOOL_AGENT_ID:-}}" root="${SPOOL_ROOT:-/var/spool-hub}"
  local live="${SPOOL_LIVE_ROOT:-/var/spool-hub}" d tmp f pid fd="" rc=0 i
  [[ "$id" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]] || { echo "handoff FAIL: ID (or SPOOL_AGENT_ID) required, got '$id'" >&2; return 2; }
  if [[ "${SPOOL_TEST:-}" == 1 && "$(realpath -m "$root")" == "$(realpath -m "$live")" ]]; then
    echo "handoff REFUSED: SPOOL_TEST=1 on the live spool root $root" >&2; return 97
  fi
  d="$root/$id"
  [[ -d "$d" ]] || { echo "handoff FAIL: no agent dir $d" >&2; return 2; }
  umask 027
  mkdir -p "$d/lifetime" || return 1
  if [[ "${SPOOL_TEST:-}" != 1 || "${HANDOFF_LOCK:-1}" != 0 ]]; then
    exec {fd}>>"$d/lifetime/handoff.lock" || return 1
    if ! flock -x -w "${HANDOFF_LOCK_WAIT:-10}" "$fd"; then
      exec {fd}>&-
      echo "handoff BUSY: $d/lifetime/handoff.lock is held" >&2; return 4
    fi
  fi
  # A tmp whose writer is gone is a killed compose: never renamed in, removed.
  for f in "$d"/handoff.md.tmp.*; do
    [[ -e "$f" ]] || continue
    pid="${f##*.}"
    [[ "$pid" =~ ^[0-9]+$ && -d "/proc/$pid" ]] || rm -f "$f"
  done
  tmp="$d/handoff.md.tmp.$BASHPID"
  if HANDOFF_ID="$id" HANDOFF_DIR="$d" HANDOFF_ROOT="$root" \
      PYTHONPATH="$(_spl_handoff_lib)" python3 -c "$_SPL_HANDOFF_PY" >"$tmp"; then
    [[ -f "$d/handoff.md" ]] && mv -f "$d/handoff.md" "$d/handoff.prev.md"
    if [[ "${SPOOL_TEST:-}" == 1 && -n "${HANDOFF_PAUSE_FILE:-}" ]]; then
      for ((i = 0; i < 100; i++)); do [[ -e "$HANDOFF_PAUSE_FILE" ]] && break; sleep 0.1; done
    fi
    mv -f "$tmp" "$d/handoff.md" || rc=1
  else
    rm -f "$tmp"; rc=1
  fi
  [[ -n "$fd" ]] && exec {fd}>&-
  (( rc == 0 )) || { echo "handoff FAIL: compose of $d/handoff.md" >&2; return 1; }
  echo "OK handoff $d/handoff.md lines=$(wc -l <"$d/handoff.md")"
}

read -r -d '' _SPL_HANDOFF_PY <<'EOF_PY' || true
import calendar, json, os, signal, subprocess, sys, time

aid, d, root = os.environ["HANDOFF_ID"], os.environ["HANDOFF_DIR"], os.environ["HANDOFF_ROOT"]
now = time.time()
kill_at = os.environ.get("HANDOFF_KILL_AT") if os.environ.get("SPOOL_TEST") == "1" else None
CAP = {"brief": 60, "done": 20, "dirty": 30, "term": 30, "next": 20,
       "open": 15, "topics": 15, "notes": 40, "lessons": 20}
SCAN = 300

def iso(t):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))

def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            return f.read()
    except OSError:
        return None

def readj(path):
    try:
        v = json.loads(read(path) or "")
        return v if isinstance(v, dict) else {}
    except ValueError:
        return {}

def cap(lines, n, where):
    if len(lines) <= n:
        return lines
    return lines[-n:] + ["[cut: %d earlier lines, see %s]" % (len(lines) - n, where)]

def run(cmd, cwd=None):
    try:
        p = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, timeout=20)
        return p.stdout if p.returncode == 0 else None
    except (OSError, subprocess.SubprocessError):
        return None

def parse_utc(s):
    for fmt in ("%Y-%m-%dT%H:%M:%SZ", "%Y%m%dT%H%M%SZ"):
        try:
            return calendar.timegm(time.strptime(s, fmt))
        except (TypeError, ValueError):
            pass
    return None

def registry():
    row = []
    for line in (read(os.path.join(root, "registry.tsv")) or "").splitlines():
        cols = line.split("\t")
        if cols and cols[0] == aid:
            row = cols
    return row + [""] * (6 - len(row))

def prev_section(name):
    text = read(os.path.join(d, "handoff.md")) or ""
    head = "\n## %s\n" % name
    i = text.find(head)
    if i < 0:
        return None
    body = text[i + len(head):]
    j = body.find("\n## ")
    return (body[:j] if j >= 0 else body).strip("\n")

out = ["# handoff %s\n" % aid]
def section(n, name, body):
    out.append("## %d. %s\n\n%s" % (n, name, body.rstrip("\n") + "\n" if body.strip() else "(none)\n"))
    if kill_at == str(n):
        sys.stdout.write("\n".join(out))
        sys.stdout.flush()
        os.kill(os.getppid(), signal.SIGKILL)
        os.kill(os.getpid(), signal.SIGKILL)

reg = registry()
sess = readj(os.path.join(d, "lifetime", "session.json"))
hb = readj(os.path.join(d, "heartbeat.json"))
wd = os.environ.get("HANDOFF_WORKDIR") or reg[3] or os.getcwd()
started = parse_utc(sess.get("started")) or parse_utc(reg[4])
# The agent user may not own its worktree: trust it for these reads only.
GIT = ["git", "-c", "safe.directory=%s" % os.path.abspath(wd)]

# 1 header
try:
    mt = os.stat(os.path.join(d, "lifetime", "rebirth")).st_mtime
    fresh = "fresh" if now - mt < 300 else "stale since %s" % iso(mt)
except OSError:
    fresh = "-"
section(1, "header", "\n".join([
    "- id: %s" % aid,
    "- box: %s" % (os.environ.get("SPOOL_BOX_ID") or os.uname().nodename.split(".")[0]),
    "- harness: %s" % (hb.get("harness") or reg[1] or "-"),
    "- session: #%s started %s" % (sess.get("n", "-"), iso(started) if started else "-"),
    "- age_min: %s" % (int((now - started) // 60) if started else "-"),
    "- rebirths: %s, restarts: %s" % (sess.get("rebirths", 0), sess.get("restarts", 0)),
    "- freshness: %s" % fresh,
    "- hard_killed: %s" % ("true" if os.environ.get("HANDOFF_HARD_KILLED") == "1" else "false"),
    "- composed: %s" % iso(now),
]))

# 2 the brief: filled once, then carried from the previous file
brief = prev_section("2. brief")
if not brief or brief == "(none)":
    path = os.environ.get("HANDOFF_BRIEF") or sess.get("brief") or ""
    text = read(path) if path else None
    brief = "" if text is None else "brief: %s\n\n%s" % (
        path, "\n".join(cap(text.splitlines()[:CAP["brief"] + 1], CAP["brief"], path)))
section(2, "brief", brief)

# 3 done: commits of this session, pushed (on a remote ref) or not
since = ["--since=%s" % iso(started)] if started else []
log = run(GIT + ["log", "--format=%H %s", "-n", str(CAP["done"])] + since + ["HEAD"], cwd=wd)
done = ["(no git worktree at %s)" % wd] if log is None else []
for line in (log or "").splitlines():
    sha, _, subj = line.partition(" ")
    pushed = (run(GIT + ["branch", "-r", "--contains", sha], cwd=wd) or "").strip()
    done.append("- %s %s (%s)" % (sha[:10], subj, "pushed" if pushed else "NOT pushed"))
section(3, "done", "\n".join(done))

# 4 in flight
dirty = (run(GIT + ["status", "--porcelain"], cwd=wd) or "").splitlines()
fl = ["dirty files: %d" % len(dirty)] + ["    " + l for l in cap(dirty, CAP["dirty"], "git status")]
fl.append("state: %s, tool: %s since %s, progress_ts: %s" % (
    hb.get("state", "-"), hb.get("tool") or "-", hb.get("tool_since") or "-", hb.get("progress_ts") or "-"))
cmd = os.environ.get("HANDOFF_CAPTURE_CMD")
if cmd:
    term = run(["bash", "-c", cmd])
elif reg[2]:
    sock = os.environ.get("SPOOL_TMUX_SOCKET")
    term = run(["tmux"] + (["-S", sock] if sock else []) +
               ["capture-pane", "-p", "-J", "-t", reg[2], "-S", "-%d" % CAP["term"]])
else:
    term = None
if term is None:
    fl.append("terminal: (unavailable)")
else:
    try:
        from spool_redact import redact
        term = redact(term)[0]
    except Exception:
        term = "[terminal dropped: the redaction pass failed]"
    tl = term.rstrip("\n").splitlines()[-CAP["term"]:]
    fl += ["terminal (last %d lines, scrubbed):" % len(tl), "```text"]
    fl += [l.replace("```", "'''") for l in tl] + ["```"]
section(4, "in flight", "\n".join(fl))

# 5 next step: the agent's file
hd = os.path.join(d, "handoff.d")
nxt = read(os.path.join(hd, "next.md")) or ""
section(5, "next step", "\n".join(cap(nxt.splitlines(), CAP["next"], "handoff.d/next.md")))

# 6 open questions, 7 owned topics: the newest outbox messages
def msgs(sub):
    try:
        names = sorted(n for n in os.listdir(os.path.join(d, sub)) if n.endswith(".json"))[-SCAN:]
    except OSError:
        return []
    return [m for m in (readj(os.path.join(d, sub, n)) for n in names) if m]

sent = msgs("outbox")
heard = {}
for m in msgs("inbox") + msgs("archive"):
    k = (m.get("task_id"), m.get("from"))
    heard[k] = max(heard.get(k, ""), str(m.get("ts") or ""))
openq = []
for m in reversed(sent):
    if m.get("kind") in ("blocker", "msg") and heard.get((m.get("task_id"), m.get("to")), "") <= str(m.get("ts") or ""):
        body = m.get("body") if isinstance(m.get("body"), str) else json.dumps(m.get("body"))
        first = (body or "").strip().splitlines()[:1]
        openq.append("- %s %s to %s, task %s: %s" % (m.get("ts"), m.get("kind"), m.get("to"),
                                                     m.get("task_id"), first[0][:120] if first else ""))
section(6, "open questions", "\n".join(openq[:CAP["open"]] + (["(the agent's notes: section 8)"] if openq else [])))

topics, seen = [], set()
for m in reversed(sent):
    t = m.get("task_id")
    if t and t not in seen:
        seen.add(t)
        topics.append("- %s (last: %s %s to %s)" % (t, m.get("ts"), m.get("kind"), m.get("to")))
held = [l.split()[0] for l in (read(os.path.join(root, "peer", aid, "held")) or "").splitlines() if l.strip()]
section(7, "owned topics", "\n".join(topics[:CAP["topics"]] + ["- held job %s" % h for h in held]))

# 8 notes, 9 lessons: the agent's files, verbatim
notes = read(os.path.join(hd, "notes.md")) or ""
section(8, "notes", "\n".join(cap(notes.splitlines(), CAP["notes"], "handoff.d/notes.md")))
les = read(os.path.join(hd, "lessons.md")) or ""
section(9, "lessons", "\n".join(cap(les.splitlines(), CAP["lessons"], "handoff.d/lessons.md")))

sys.stdout.write("\n".join(out))
EOF_PY
