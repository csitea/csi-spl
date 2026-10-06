#!/usr/bin/env bash
# test-agent-identity.sh — the identity map, step (a): record + check.
#
# A fake /proc (AI_PROC_ROOT) holds the agent processes and the tmux pane
# shells above them; AI_PANES_FILE stands in for tmux. Nothing live is read.
# The actions run through their run/*.func.sh, as ./run -a would.
#
#   1. facts come from the PROCESS: the id from SPOOL_AGENT_ID, the session
#      from its sessions/<pid>.json (beating a stale --resume), its cwd, and
#      the pane whose process tree holds it - a window NAMED for another
#      agent changes none of it
#   2. record: the dry run plans and writes nothing; DRY_RUN=0 writes one
#      record per agent and index.json; a second run changes nothing (same
#      updated_at, same hash) - idempotent
#   3. the hash changes exactly when a record changes: a process gone ->
#      alive:false and a new hash; the same facts again -> the same hash
#   4. an id two live processes carry is a CONFLICT, never recorded; a
#      process with no id in its environment is skipped with the reason;
#      adopt records the one pid a rotation names (spec 060 FR-006)
#   5. check: consistent -> exit 0; two windows whose names are swapped ->
#      exit 1 naming both; a record that says alive with no process ->
#      drift; a record edited by hand -> the index hash drifts
#   6. ai_alive: the pid for the live agent; no once the pid is reused
#      (another start time), is not the agent's CLI (a shell with the env id),
#      or carries another id
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
P="$T_TMP/proc"; H="$T_TMP/home"; W="$T_TMP/wt"
export AI_PROC_ROOT="$P" AI_PANES_FILE="$T_TMP/panes.tsv"
mkdir -p "$P" "$H/.claude/sessions" "$W"
. "$T_FEAT/lib/agent-identity.inc.sh"
MAP="$SPOOL_ROOT/agents"

proc() {  # PID PPID START ARGV0 CWD ENV-ID [ARGS...]
  local pid="$1" ppid="$2" start="$3" a0="$4" cwd="$5" id="$6"; shift 6
  mkdir -p "$P/$pid" "$cwd"
  printf '%s\0' "$a0" "$@" > "$P/$pid/cmdline"
  { [ -n "$id" ] && printf 'SPOOL_AGENT_ID=%s\0' "$id"; printf 'HOME=%s\0' "$H"; } > "$P/$pid/environ"
  ln -sfn "$cwd" "$P/$pid/cwd"
  printf '%s (%s) S %s 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 %s 0\n' "$pid" "${a0##*/}" "$ppid" "$start" > "$P/$pid/stat"
  printf 'Uid:\t%s\t%s\t%s\t%s\n' "$(id -u)" "$(id -u)" "$(id -u)" "$(id -u)" > "$P/$pid/status"
}
sess() { printf '{"pid":%s,"sessionId":"%s","cwd":"%s","procStart":"%s"}\n' "$1" "$2" "$3" "$4" > "$H/.claude/sessions/$1.json"; }
act() {  # ACTION [ENV=VAL...] — through the run action, as ./run -a would
  local a="$1"; shift
  env PROJ_PATH="$T_REPO/csi-spl-orc" "$@" bash -c '
    set -uo pipefail; do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/src/bash/run/spl-agent-identity-*.func.sh; do source "$f"; done
    "$0"' "$a"
}
rec() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]))' "$MAP/$1.json" "$2" 2>/dev/null; }

# Two lanes, each a pane shell (pid x0) with a claude under a wrapper (x1 -> x2).
# CLE-1's claude was launched with a stale --resume; its sessions json is the truth.
proc 100 1 500 /bin/bash "$T_TMP" ""
proc 101 100 501 /bin/bash "$W/CLE-1" ""
proc 102 101 502 /usr/bin/claude "$W/CLE-1" CLE-1 --resume stale-sid --dangerously-skip-permissions --model opus-x
sess 102 s-1 "$W/CLE-1" 502
proc 200 1 600 /bin/bash "$T_TMP" ""
proc 202 200 602 /usr/bin/claude "$W/CLE-2" CLE-2 --session-id s-2
printf 't\t@1\t%%1\t100\tbx: CLE-1 > lane one\nt\t@2\t%%2\t200\tbx: CLE-2\nt\t@3\t%%3\t300\tnotes\n' > "$AI_PANES_FILE"

# --- 1 --------------------------------------------------------------------------
f="$(ai_panes | ai_py facts)"
f1="$(printf '%s\n' "$f" | grep '"CLE-1"')"
has "1. CLE-1's session is its sessions json, not the stale --resume" '"session_id": "s-1"' "$f1"
has "1. ... its pane is the one whose tree holds it (two levels up)" '"pane_id": "%1"' "$f1"
has "1. ... model and permission mode from its argv" '"permission_mode": "auto"' "$f1"
has "1. CLE-2: --session-id when there is no sessions json" '"session_id": "s-2"' "$(printf '%s\n' "$f" | grep '"CLE-2"')"
eq "1. one fact per agent process, the wrapper and pane shells are not agents" 2 "$(printf '%s\n' "$f" | grep -c .)"

# --- 2 --------------------------------------------------------------------------
out="$(act do_spl_agent_identity_record)"
has "2. dry run plans CLE-1" "PLAN CLE-1" "$out"
check "2. ... and writes nothing" test ! -e "$MAP"
out="$(act do_spl_agent_identity_record DRY_RUN=0)"
has "2. DRY_RUN=0 writes CLE-1" "WRITE CLE-1" "$out"
eq "2. two records + the index" "CLE-1.json CLE-2.json index.json" "$(ls "$MAP" | tr '\n' ' ' | sed 's/ $//')"
eq "2. the record carries the process's facts" "s-1|%1|@1|True|lane one" "$(rec CLE-1 session_id)|$(rec CLE-1 pane_id)|$(rec CLE-1 window_id)|$(rec CLE-1 alive)|$(rec CLE-1 title)"
h1="$(ai_hash)"; u1="$(rec CLE-1 updated_at)"
eq "2. index.json holds that hash" "$h1" "$(python3 -c 'import json; print(json.load(open("'"$MAP"'/index.json"))["hash"])')"
sleep 1.1
out="$(act do_spl_agent_identity_record DRY_RUN=0)"
has "2. a second run changes nothing" "0 change(s)" "$out"
eq "2. ... updated_at untouched" "$u1" "$(rec CLE-1 updated_at)"
eq "2. ... hash untouched" "$h1" "$(ai_hash)"

# --- 3 --------------------------------------------------------------------------
mv "$P/202" "$T_TMP/202.gone"
act do_spl_agent_identity_record DRY_RUN=0 >/dev/null
eq "3. CLE-2's process gone -> alive False, session kept" "False|s-2" "$(rec CLE-2 alive)|$(rec CLE-2 session_id)"
h2="$(ai_hash)"
check "3. ... and the hash changed" test "$h1" != "$h2"
act do_spl_agent_identity_record DRY_RUN=0 >/dev/null
eq "3. the same facts again -> the same hash" "$h2" "$(ai_hash)"
mv "$T_TMP/202.gone" "$P/202"
act do_spl_agent_identity_record DRY_RUN=0 >/dev/null
eq "3. back alive -> the first hash again (content, not time)" "$h1" "$(ai_hash)"

# --- 4 --------------------------------------------------------------------------
proc 400 1 700 /bin/bash "$T_TMP" ""
proc 402 400 702 /usr/bin/claude "$W/CLE-1b" CLE-1 --session-id s-impostor
proc 502 1 802 /usr/bin/claude "$W/x" "" --session-id s-anon
out="$(act do_spl_agent_identity_record)"
has "4. an id two live processes carry is a conflict" "CONFLICT CLE-1: carried by 2 live processes (pids 102 402)" "$out"
hasnt "4. ... and is not planned" "PLAN CLE-1" "$out"
has "4. a process with no agent id is skipped, with the reason" "SKIP pid 502 (claude): its environment carries no agent id" "$out"
# adopt (spec 060 FR-006): the rotation names which of the two is the agent now
cp "$AI_PANES_FILE" "$T_TMP/panes.keep"; printf 't\t@4\t%%4\t400\tCLE-1-0405Z-retiring\n' >> "$AI_PANES_FILE"
out="$(ai_adopt CLE-1 402)"
has "4. adopt records the named pid despite the conflict" "adopt: CLE-1 -> pid 402 pane %4" "$out"
eq "4. ... so the map routes CLE-1 to its pane" "%4" "$(ai_pane_of CLE-1 "$(cut -f3 "$AI_PANES_FILE")")"
out="$(act do_spl_agent_identity_record DRY_RUN=0)"
eq "4. ... and a record pass during the overlap keeps it" "402" "$(rec CLE-1 pid)"
has "4. adopt refuses a pid that does not carry the id" "is not a live agent carrying CLE-1" "$(ai_adopt CLE-1 502)"
out="$(ai_adopt CLE-1 102)"; eq "4. adopt back: the old pid again" "%1" "$(ai_pane_of CLE-1 "$(cut -f3 "$AI_PANES_FILE")")"
cp "$T_TMP/panes.keep" "$AI_PANES_FILE"
rm -rf "$P/400" "$P/402" "$P/502"

# --- 5 --------------------------------------------------------------------------
out="$(act do_spl_agent_identity_check)"; rc=$?
eq "5. consistent map -> exit 0" 0 "$rc"
has "5. ... 0 drifts" "2 agent(s), 0 drift(s)" "$out"
printf 't\t@1\t%%1\t100\tbx: CLE-2 > lane one\nt\t@2\t%%2\t200\tbx: CLE-1\n' > "$AI_PANES_FILE"
out="$(act do_spl_agent_identity_check)"; rc=$?
eq "5. two windows with swapped names -> exit 1" 1 "$rc"
has "5. ... CLE-1's window is named CLE-2" "window named CLE-2" "$(printf '%s\n' "$out" | grep '^CLE-1 ')"
has "5. ... CLE-2's window is named CLE-1" "window named CLE-1" "$(printf '%s\n' "$out" | grep '^CLE-2 ')"
printf 't\t@1\t%%1\t100\tbx: CLE-1 > lane one\nt\t@2\t%%2\t200\tbx: CLE-2\n' > "$AI_PANES_FILE"
mv "$P/202" "$T_TMP/202.gone"
out="$(act do_spl_agent_identity_check)"; rc=$?
eq "5. a record that says alive, no process -> exit 1" 1 "$rc"
has "5. ... says so" "map says alive, no live process" "$out"
mv "$T_TMP/202.gone" "$P/202"
python3 - "$MAP/CLE-2.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1])); d["title"] = "edited by hand"; json.dump(d, open(sys.argv[1], "w"))
PY
out="$(act do_spl_agent_identity_check)"; rc=$?
eq "5. a record edited outside record -> exit 1" 1 "$rc"
has "5. ... the index hash drifts" "index.json hash" "$out"

# --- 6 --------------------------------------------------------------------------
act do_spl_agent_identity_record DRY_RUN=0 >/dev/null
eq "6. ai_alive CLE-1: the live agent, its pid printed" 102 "$(ai_alive CLE-1)"
cp "$P/102/cmdline" "$T_TMP/102.argv"; printf '/bin/bash\0' > "$P/102/cmdline"
if ai_alive CLE-1 >/dev/null; then nok "6. ai_alive CLE-1: no, when the pid is a shell carrying the id"; else ok "6. ai_alive CLE-1: no, when the pid is a shell carrying the id"; fi
cp "$T_TMP/102.argv" "$P/102/cmdline"
sed -i 's/ 502 0$/ 999 0/' "$P/102/stat"
if ai_alive CLE-1 >/dev/null; then nok "6. ai_alive CLE-1: no, once the pid is reused (another start time)"; else ok "6. ai_alive CLE-1: no, once the pid is reused (another start time)"; fi
sed -i 's/ 999 0$/ 502 0/' "$P/102/stat"
printf 'SPOOL_AGENT_ID=CLE-9\0' > "$P/102/environ"
if ai_alive CLE-1 >/dev/null; then nok "6. ai_alive CLE-1: no, when the pid carries another id"; else ok "6. ai_alive CLE-1: no, when the pid carries another id"; fi
if ai_alive CLE-404 >/dev/null; then nok "6. ai_alive of an unknown id is no"; else ok "6. ai_alive of an unknown id is no"; fi

t_done
