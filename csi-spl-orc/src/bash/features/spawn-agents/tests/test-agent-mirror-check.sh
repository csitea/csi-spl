#!/usr/bin/env bash
# test-agent-mirror-check.sh — agent-mirror-check.py (do_spl_agent_mirror_check):
# per live agent, mirrored yes/no from a fake /proc, fake homes and fake seats.
#
#   1. claude with --settings <file naming spool-mirror.py>, its env id, a seat: yes
#   2. claude with no --settings and no hook in ~/.claude/settings.json: no, relaunch
#   3. CONTROL: the user's ~/.claude/settings.json hook counts
#   4. a hook naming a missing script: no, relaunch
#   5. a process whose env names no / another id: no (never a window name)
#   6. no desk seat, or a .no-mirror seat: no
#   7. $SPOOL_ROOT/.mirror-off: no for everyone; exit 1 when any is no, 0 when all yes
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
PY="$T_SCRIPTS/agent-mirror-check.py"
P="$T_TMP/proc"; H="$T_TMP/homes"; S="$T_TMP/cloud/dev/desk/t1/box-desk"
export AMC_PROC_ROOT="$P" AMC_HOME_OF="$H" AMC_SEATS="$T_TMP/cloud/*/desk/*/*" SPOOL_ROOT="$T_TMP/root"
mkdir -p "$SPOOL_ROOT" "$H/u1/.claude" "$H/u2/.claude"
MIR="$T_TMP/spool-mirror.py"; : >"$MIR"
printf '{"hooks":{"Stop":[{"hooks":[{"command":"[ -r %s ] && exec python3 %s hook"}]}]}}' "$MIR" "$MIR" >"$T_TMP/hooks.json"
proc() {  # PID ENV-ID ARGV...
  local pid="$1" id="$2"; shift 2
  mkdir -p "$P/$pid"
  { [ -n "$id" ] && printf 'SPOOL_AGENT_ID=%s\0' "$id"; printf 'HOME=/x\0'; } >"$P/$pid/environ"
  printf '%s\0' "$@" >"$P/$pid/cmdline"
}
seat() { mkdir -p "$S/spool/$1"; }
fact() { printf '{"id":"%s","kind":"%s","pid":%s,"user":"%s"}\n' "$@"; }
row() { python3 -c 'import json,sys
for l in sys.stdin:
    r=json.loads(l)
    if r.get("agent")==sys.argv[1]: print(r["mirrored"], r["relaunch"], r["why"])' "$1"; }

proc 11 CLE-1 claude --settings "$T_TMP/hooks.json" --resume s; seat CLE-1
proc 12 CLE-2 claude --resume s; seat CLE-2
proc 13 CLE-3 claude; seat CLE-3
printf '{"hooks":{"Stop":[{"hooks":[{"command":"python3 /gone/spool-mirror.py hook"}]}]}}' >"$T_TMP/gone.json"
proc 14 CLE-4 claude --settings "$T_TMP/gone.json"; seat CLE-4
proc 15 "" claude --settings "$T_TMP/hooks.json"; seat CLE-5
proc 16 CLE-9 claude --settings "$T_TMP/hooks.json"; seat CLE-6
proc 17 CLE-7 claude --settings "$T_TMP/hooks.json"
proc 18 CLE-8 claude --settings "$T_TMP/hooks.json"; seat CLE-8; : >"$S/spool/CLE-8/.no-mirror"
cp "$T_TMP/hooks.json" "$H/u2/.claude/settings.json"
facts="$(fact CLE-1 claude 11 u1; fact CLE-2 claude 12 u1; fact CLE-3 claude 13 u2; fact CLE-4 claude 14 u1
         fact CLE-5 claude 15 u1; fact CLE-6 claude 16 u1; fact CLE-7 claude 17 u1; fact CLE-8 claude 18 u1)"
out="$(printf '%s\n' "$facts" | python3 "$PY" --json)"; rc=$?
has "1. --settings + env id + seat -> yes" "yes False" "$(row CLE-1 <<<"$out")"
has "2. no hook anywhere -> no, needs a relaunch" "no True no mirror hook loaded" "$(row CLE-2 <<<"$out")"
has "3. CONTROL: the user's settings.json hook counts" "yes False" "$(row CLE-3 <<<"$out")"
has "4. a hook naming a missing script -> no, relaunch" "no True the hook names a missing /gone/spool-mirror.py" "$(row CLE-4 <<<"$out")"
has "5. no id in the process env -> no" "process env names no agent id" "$(row CLE-5 <<<"$out")"
has "5. another id in the process env -> no" "process env names CLE-9" "$(row CLE-6 <<<"$out")"
has "6. no desk seat -> no" "no desk seat" "$(row CLE-7 <<<"$out")"
has "6. a .no-mirror seat -> no" "no desk seat" "$(row CLE-8 <<<"$out")"
eq "7. exit 1 when one is not mirrored" 1 "$rc"
has "7. the summary names who needs a relaunch" '"need_relaunch": ["CLE-2", "CLE-4"]' "$(tail -1 <<<"$out")"
printf '%s\n' "$(fact CLE-1 claude 11 u1)" | python3 "$PY" >"$T_TMP/one"; eq "7. exit 0 when every agent is mirrored" 0 "$?"
has "7. ...the table says yes" "CLE-1       claude u1       yes" "$(cat "$T_TMP/one")"
: >"$SPOOL_ROOT/.mirror-off"
out="$(printf '%s\n' "$(fact CLE-1 claude 11 u1)" | python3 "$PY" --json)"
has "7. the kill switch makes every agent no" "no False box kill switch .mirror-off" "$(row CLE-1 <<<"$out")"
python3 "$PY" --bogus </dev/null >/dev/null 2>&1; eq "usage -> 2" 2 "$?"

t_done
