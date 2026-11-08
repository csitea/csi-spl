#!/usr/bin/env bash
# Purpose: old-stores-prune.sh on fixture grok and retired trees in a mktemp
# dir: the refusals, the dry run, and DRY_RUN=0 removing only the old dead dirs
# while every guard keeps its own.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/old-stores-prune.sh"
T="$(mktemp -d)"
trap 'kill "${cmd_pid:-}" 2>/dev/null; rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; fails=$((fails + 1)); }
uuid() { cat /proc/sys/kernel/random/uuid; }
run() { env SPOOL_TEST=1 SPOOL_ROOT="$T/spool" GROK_SESSIONS="$T/grok/sessions" OLD_PROJECTS="$T/claude/projects" OLD_SESSIONS="$T/claude/sessions" "$@" bash "$SCRIPT" 2>&1; }

mkdir -p "$T/spool/agents" "$T/spool/.retired" "$T/grok/sessions"
W=$(printf '%%2Fopt%%2Fx-wt%%2F')
wt() { printf '%s' "$W$1"; }
mk() { mkdir -p "$1"; echo x >"$1/f"; }
u_dead=$(uuid) u_rest=$(uuid) u_act=$(uuid) u_cmd=$(uuid) u_new=$(uuid) u_open=$(uuid) u_alive=$(uuid) u_role=$(uuid) u_human=$(uuid)
G="$T/grok/sessions"
mk "$G/$(wt c-500)/$u_dead"; mk "$G/$(wt c-500)/$u_rest"; mk "$G/$(wt c-500)/$u_act"
mk "$G/$(wt c-500)/$u_cmd"; mk "$G/$(wt c-500)/$u_new"; mk "$G/$(wt c-500)/$u_open"
mk "$G/$(wt c-501)/$u_alive"; mk "$G/$(wt c-002)/$u_role"; mk "$G/%2Fopt/$u_human"
echo x >"$G/$(wt c-500)/prompt_history.jsonl"
R="$T/spool/.retired"
mk "$R/c-510.20261001T000000Z/inbox"; mv "$R/c-510.20261001T000000Z/inbox/f" "$R/c-510.20261001T000000Z/inbox/m.json"
mk "$R/c-511.20261001T000000Z"; mk "$R/c-512.20261001T000000Z"; mk "$R/c-513.20261001T000000Z"
mk "$R/c-002.20261001T000000Z"; mk "$R/notaretired"
P="$T/claude/projects"; H="$P/-opt"; S="$P/-opt-x-wt-c-002"; A="$P/-opt-x-wt-c-500"
mkdir -p "$H" "$S" "$A" "$P/-opt/memory" "$T/claude/sessions"; echo x >"$P/-opt/memory/note.md"
t_h=$(uuid) t_r=$(uuid) t_a=$(uuid) t_rest=$(uuid) t_live=$(uuid) t_new=$(uuid) t_open=$(uuid) t_rr=$(uuid)
for f in "$H/$t_h" "$S/$t_r" "$A/$t_a" "$H/$t_rest" "$H/$t_live" "$H/$u_cmd" "$H/$t_new" "$H/$t_open" "$S/$t_rr"; do echo x >"$f.jsonl"; done
mk "$H/$t_h"; mk "$H/$t_new"
find "$G" "$R" "$P" -exec touch -h -d '10 days ago' {} +
touch "$H/$t_new/f"
touch "$G/$(wt c-500)/$u_new/f" "$R/c-511.20261001T000000Z/f"
echo '{"session_id":"'"$u_rest"'"}' >"$T/spool/agents/c-500.json"
echo '{"alive":true}' >"$T/spool/agents/c-501.json"
echo '{"alive":true,"session_id":"'"$t_rr"'"}' >"$T/spool/agents/c-002.json"
echo '{"session_id":"'"$t_rest"'"}' >"$T/spool/agents/c-502.json"
echo '{"pid":'$$',"sessionId":"'"$t_live"'"}' >"$T/claude/sessions/1.json"
echo '[{"session_id":"'"$u_act"'"}]' >"$T/grok/active_sessions.json"
printf 'c-512@box\tclaude\n' >"$T/spool/registry.tsv"
exec 7<"$H/$t_open.jsonl" 8<"$G/$(wt c-500)/$u_open/f" 9<"$R/c-513.20261001T000000Z/f"
python3 -c 'import time; time.sleep(300)' "$u_cmd" >/dev/null 2>&1 &
cmd_pid=$!

for bad in 'DRY_RUN=2 OLD_STORE_TARGET=grok' 'AGE_DAYS=0 OLD_STORE_TARGET=grok' 'OLD_STORE_TARGET=' 'OLD_STORE_TARGET=all'; do
  # shellcheck disable=SC2086 # the pairs are separate env words
  o="$(run $bad)"; rc=$?
  [[ $rc == 2 && "$o" == *REFUSE* ]] && pass "1. refused: $bad" || fail "1. refused: $bad ($rc $o)"
done
mv "$T/spool/registry.tsv" "$T/r"; o="$(run OLD_STORE_TARGET=retired)"; rc=$?; mv "$T/r" "$T/spool/registry.tsv"
[[ $rc == 2 ]] && pass "1. refused: no registry" || fail "1. refused: no registry ($rc)"

o="$(run OLD_STORE_TARGET=grok)"
[[ "$(grep -c ' PLAN ' <<<"$o")" == 1 && "$o" == *"PLAN remove"*"$u_dead"* && -d "$G/$(wt c-500)/$u_dead" ]] \
  && pass "2. grok dry run plans one, removes none" || fail "2. grok dry run ($o)"
o="$(run OLD_STORE_TARGET=retired)"
[[ "$(grep -c ' PLAN ' <<<"$o")" == 1 && "$o" == *"unread=1"*c-510* && -d "$R/c-510.20261001T000000Z" ]] \
  && pass "3. retired dry run plans one with its unread count" || fail "3. retired dry run ($o)"

o="$(run OLD_STORE_TARGET=grok DRY_RUN=0)"
[[ ! -e "$G/$(wt c-500)/$u_dead" ]] && pass "4. old dead grok session removed" || fail "4. old dead grok session ($o)"
chk() { grep -q "KEEP $1 .*$2" <<<"$o" && [[ -d "$3" ]] && pass "$4 keeps $1" || fail "$4 keeps $1 ($o)"; }
chk restorable "$u_rest" "$G/$(wt c-500)/$u_rest" 4.
chk live "$u_act" "$G/$(wt c-500)/$u_act" 4.
chk live "$u_cmd" "$G/$(wt c-500)/$u_cmd" 4.
chk recent "$u_new" "$G/$(wt c-500)/$u_new" 4.
chk open "$u_open" "$G/$(wt c-500)/$u_open" 4.
chk alive "$u_alive" "$G/$(wt c-501)/$u_alive" 4.
chk role-seat "$u_role" "$G/$(wt c-002)/$u_role" 4.
chk human "$u_human" "$G/%2Fopt/$u_human" 4.
[[ -f "$G/$(wt c-500)/prompt_history.jsonl" ]] && pass "4. non-session file stays" || fail "4. non-session file"

o="$(run OLD_STORE_TARGET=retired DRY_RUN=0)"
[[ ! -e "$R/c-510.20261001T000000Z" && "$o" == *"unread_mail=1"* ]] && pass "5. old retired dir removed, mail counted" || fail "5. retired removed ($o)"
chk recent c-511 "$R/c-511.20261001T000000Z" 5.
chk reused c-512 "$R/c-512.20261001T000000Z" 5.
chk open c-513 "$R/c-513.20261001T000000Z" 5.
chk role-seat c-002 "$R/c-002.20261001T000000Z" 5.
chk name notaretired "$R/notaretired" 5.

for bad in 'OLD_STORE_TARGET=transcripts' 'OLD_STORE_TARGET=transcripts OLD_TRANSCRIPT_SET=agent' 'OLD_STORE_TARGET=transcripts OLD_TRANSCRIPT_SET=all'; do
  # shellcheck disable=SC2086 # the pairs are separate env words
  o="$(run $bad)"; rc=$?
  [[ $rc == 2 && "$o" == *REFUSE* ]] && pass "6. refused: $bad" || fail "6. refused: $bad ($rc $o)"
done
o="$(run OLD_STORE_TARGET=transcripts OLD_TRANSCRIPT_SET=human)"
[[ "$(grep -c ' PLAN ' <<<"$o")" == 1 && "$o" == *"PLAN remove"*"$t_h"* && -f "$H/$t_h.jsonl" && -d "$H/$t_h" ]] \
  && pass "7. human dry run plans one, removes none" || fail "7. human dry run ($o)"
o="$(run OLD_STORE_TARGET=transcripts OLD_TRANSCRIPT_SET=human DRY_RUN=0)"
[[ ! -e "$H/$t_h.jsonl" && ! -e "$H/$t_h" ]] && pass "8. human session and its dir removed" || fail "8. human removed ($o)"
fchk() { grep -q "KEEP $1 .*$2" <<<"$o" && [[ -e "$3" ]] && pass "$4 keeps $1" || fail "$4 keeps $1 ($o)"; }
fchk restorable "$t_rest" "$H/$t_rest.jsonl" 8.
fchk live "$t_live" "$H/$t_live.jsonl" 8.
fchk live "$u_cmd" "$H/$u_cmd.jsonl" 8.
fchk recent "$t_new" "$H/$t_new.jsonl" 8.
fchk open "$t_open" "$H/$t_open.jsonl" 8.
fchk set-role-seat "$t_r" "$S/$t_r.jsonl" 8.
fchk set-agent "$t_a" "$A/$t_a.jsonl" 8.
[[ -f "$P/-opt/memory/note.md" ]] && pass "8. memory stays" || fail "8. memory"
o="$(run OLD_STORE_TARGET=transcripts OLD_TRANSCRIPT_SET=role-seat DRY_RUN=0)"
[[ ! -e "$S/$t_r.jsonl" ]] && pass "9. role seat's earlier rotation removed though its record says alive" || fail "9. role removed ($o)"
fchk restorable "$t_rr" "$S/$t_rr.jsonl" 9.
fchk set-human "$t_rest" "$H/$t_rest.jsonl" 9.
fchk set-agent "$t_a" "$A/$t_a.jsonl" 9.

echo "old-stores-prune: ${fails} failure(s)"
[[ "$fails" -eq 0 ]]
