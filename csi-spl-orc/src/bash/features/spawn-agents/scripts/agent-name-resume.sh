#!/usr/bin/env bash
# agent-name-resume.sh — every live claude on THIS machine carries the ONE name
# (spec 061, owner 07af027a): `--name` = the first token of its tmux window =
# spool_decorate <id> = "c-NNN@<tag>", and its environment says
# SPOOL_AGENT_ID=<id>. An agent that does not is resumed in its own pane, same
# session (--resume), through restore-claude-plain.sh, so the spool harness
# exports SPOOL_AGENT_ID again and the CLI runs as the agent user. This is the
# in-repo replacement of the one-off /var/tmp/claude/agent-id-restart.sh step 3,
# which resumed with a bare `sudo su - <agent user> -c claude ...`: that dropped
# SPOOL_AGENT_ID (the identity record then SKIPs the agent and the lease reads
# it as dead) and kept the "<tag>: <id>" name.
#
# The id of a process: its env SPOOL_AGENT_ID, else the id in its --name; a
# legacy id that agent-id-rename.sh has renamed (<root>/<old> is a link to the
# table's <new>) becomes <new>. The orchestrator id (SPOOL_ORCHESTRATOR_ID's
# old "xxx-00" form) and the caller's own claude are never touched.
#
# Usage: agent-name-resume.sh [--apply] [--only ID[,ID...]]
#   --only   resume only these ids (old or new form); roles go one at a time
# Without --apply it prints the plan: one line per live claude,
#   OK   <pid> <id> '<name>'
#   PLAN <pid> <id> pane=<pane> sid=<session> name '<have>' -> '<want>' env <have> -> <id>
# Env: SPOOL_ROOT, SPOOL_BOX_TAG (else box.env), SPOOL_TMUX_SOCKET, RESUME_PROC_ROOT
# (/proc), RESUME_SESSIONS_DIR (<agent home>/.claude/sessions), RESUME_RESTORE
# (restore-claude-plain.sh), RESUME_TERM_WAIT (20 s).
# Exit 0 nothing failed, 1 one resume failed, 2 usage.
set -uo pipefail
_here="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=../lib/spool-env.inc.sh
. "$_here/../lib/spool-env.inc.sh"
spool_env_resolve
# shellcheck source=/dev/null
. "$_here/../../../../../lib/bash/funcs/spl-desk-box.func.sh"

APPLY=0; ONLY=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply) APPLY=1; shift ;;
    --only) [ "$#" -ge 2 ] || exit 2; ONLY="$2"; shift 2 ;;
    -h|--help) sed -n '/^# Usage:/,/^# Exit/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) echo "agent-name-resume: unknown argument: $1" >&2; exit 2 ;;
  esac
done
spool_tmux_argv
home="$(_spool_home_of "$SPOOL_AGENT_USER")"
tagged="$(spool_decorate x)"

"${SPOOL_TM[@]}" list-panes -a -F '#{pane_pid}	#{pane_id}	#{window_name}' 2>/dev/null |
  APPLY="$APPLY" ONLY="$ONLY" TAG="$([ "$tagged" = x ] || printf '%s' "${tagged#x@}")" \
  ROOT="$SPOOL_ROOT" BOX="$(spl_desk_box_default)" ORCH0="$SPOOL_ORCHESTRATOR_ID" \
  PROC="${RESUME_PROC_ROOT:-/proc}" SESS="${RESUME_SESSIONS_DIR:-$home/.claude/sessions}" \
  RESTORE="${RESUME_RESTORE:-$_here/restore-claude-plain.sh}" WAIT="${RESUME_TERM_WAIT:-20}" \
  SELF="$$" python3 -c "$(cat <<'EOF'
import glob, json, os, re, shlex, signal, subprocess, sys, time
E = os.environ
apply, proc, root, tag = E["APPLY"] == "1", E["PROC"], E["ROOT"], E["TAG"]
only = set(x for x in E["ONLY"].split(",") if x)
tm = sys.argv[1:]
ID = r"(?:[acgq]-[0-9]{3}|(?:CLE|GRK|AGY|QWN)-[0-9]+)"

def name_of(d): return d + "@" + tag if tag else d
def read(p, mode="r"):
    try:
        with open(p, mode) as f: return f.read()
    except OSError: return None
def ppid(p):
    s = read("%s/%d/stat" % (proc, p))
    try: return int(s.rsplit(")", 1)[1].split()[1])
    except Exception: return 0

panes = {}
for l in sys.stdin.read().splitlines():
    f = l.split("\t", 2)
    if len(f) == 3 and f[0].isdigit(): panes[int(f[0])] = (f[1], f[2])
def pane_of(p):
    while p > 1:
        if p in panes: return panes[p]
        p = ppid(p)
    return None
mine = set()
p = int(E["SELF"])
while p > 1: mine.add(p); p = ppid(p)

alias = {}
for l in (read(os.path.join(root, "agent-id-aliases.tsv")) or "").splitlines():
    f = l.split("\t")
    if len(f) >= 4 and f[3] == E["BOX"] and os.path.islink(os.path.join(root, f[0])) \
            and os.readlink(os.path.join(root, f[0])) == f[1]:
        alias[f[0]] = f[1]

rc = 0
for sf in sorted(glob.glob(os.path.join(E["SESS"], "*.json"))):
    try: s = json.load(open(sf))
    except Exception: continue
    pid = s.get("pid")
    argv = (read("%s/%s/cmdline" % (proc, pid)) or "").split("\0")
    if not pid or not argv[0] or not re.search(r"(^|/)claude$", argv[0]): continue
    if pid in mine: continue
    env = dict(x.split("=", 1) for x in (read("%s/%s/environ" % (proc, pid)) or "").split("\0") if "=" in x)
    have = argv[argv.index("--name") + 1] if "--name" in argv[:-1] else ""
    m = re.search(r"(?:^|: )(" + ID + r")(?:@|$| )", have)
    eid = env.get("SPOOL_AGENT_ID", "")
    aid = eid or (m.group(1) if m else "")
    if not aid or aid == E["ORCH0"]: continue
    aid = alias.get(aid, aid)
    if only and not ({aid, eid, m.group(1) if m else ""} & only): continue
    want = name_of(aid)
    if have == want and eid == aid:
        print("OK   %s %s '%s'" % (pid, aid, have)); continue
    pw = pane_of(pid)
    sid, cwd = s.get("sessionId", ""), s.get("cwd", "")
    print("%s %s %s pane=%s sid=%s name '%s' -> '%s' env %s -> %s" % (
        "DO  " if apply else "PLAN", pid, aid, pw[0] if pw else "-", sid, have, want, eid or "-", aid))
    if not apply: continue
    if not pw or not sid or not cwd:
        print("FAIL %s %s: no pane, session or cwd" % (pid, aid)); rc = 1; continue
    try: os.kill(pid, signal.SIGTERM)
    except OSError: pass
    for _ in range(int(E["WAIT"])):
        if not os.path.isdir("%s/%s" % (proc, pid)): break
        time.sleep(1)
    kick = ("Your agent id is now %s and this session's name is %s (spec 061: one id everywhere: "
            "--name, the tmux window, the web app). You were resumed in the same session under it; "
            "use --from %s from now on and continue what you were doing." % (aid, want, aid))
    cmd = " ".join(shlex.quote(x) for x in ["env", "SPOOL_ROOT=" + root] + (["SPOOL_BOX_TAG=" + tag] if tag else []) +
                   ["bash", E["RESTORE"], aid, cwd, sid, kick])
    r = subprocess.run(tm + ["respawn-pane", "-k", "-t", pw[0], cmd], capture_output=True, text=True)
    if r.returncode: print("FAIL %s %s: respawn-pane %s: %s" % (pid, aid, pw[0], r.stderr.strip())); rc = 1
sys.exit(rc)
EOF
)" "${SPOOL_TM[@]}"
