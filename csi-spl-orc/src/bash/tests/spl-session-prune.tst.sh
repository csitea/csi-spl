#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_session_prune on a fixture projects tree, sessions dir and
# agent records in a mktemp dir.
#   1. refusals: DRY_RUN=2, AGE_DAYS=0, an unreadable agents or sessions dir,
#      and SPOOL_TEST=1 with no tree named each remove nothing (exit 2)
#   2. the dry run (default) plans exactly the two old dead sessions and
#      removes nothing
#   3. DRY_RUN=0 removes ONLY the old dead session (.jsonl + its dir) and an
#      old dead orphan dir; it keeps a session an agent record names, a live
#      one (registry pid, or the uuid on a running command line), one whose
#      .jsonl or whose dir changed inside AGE_DAYS, a symlink (and its
#      target), and every non-session file or dir (memory/)
#   4. a HUMAN tree (SESSION_PRUNE_AGENT_ONLY=1, every user by default):
#      only old dead sessions of an agent worktree slug (-wt-c-123,
#      -wt4-CLE-31) go; the owner's own sessions (-opt, a project dir) are
#      KEEP human however old; =2 is refused; a role seat's worktree
#      (-wt-c-002) and an agent whose record says alive keep theirs
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/projects" S="$T/sessions" A="$T/spool/agents" OUT="$T/outside"
u_old=11111111-1111-4111-8111-111111111111 u_rest=22222222-2222-4222-8222-222222222222
u_live=33333333-3333-4333-8333-333333333333 u_cmd=44444444-4444-4444-8444-444444444444
u_new=55555555-5555-4555-8555-555555555555 u_dirnew=66666666-6666-4666-8666-666666666666
u_orph=77777777-7777-4777-8777-777777777777 u_link=88888888-8888-4888-8888-888888888888
P="$R/-opt-a"
mkdir -p "$S" "$A" "$OUT" "$P/memory" "$P/$u_old/subagents" "$P/$u_dirnew/tool-results" "$P/$u_orph" "$R/-opt-b"
for u in "$u_old" "$u_rest" "$u_live" "$u_cmd" "$u_new" "$u_dirnew"; do echo '{}' >"$P/$u.jsonl"; done
echo x >"$P/$u_old/subagents/a.jsonl"; echo x >"$P/$u_orph/f"; echo x >"$P/memory/MEMORY.md"; echo x >"$P/notes.txt"
echo x >"$P/$u_dirnew/tool-results/r"; echo '{}' >"$OUT/$u_link.jsonl"; ln -s "$OUT/$u_link.jsonl" "$R/-opt-b/$u_link.jsonl"
find "$R" "$OUT" -exec touch -h -d '5 days ago' {} +
touch "$P/$u_new.jsonl" "$P/$u_dirnew/tool-results/r"
printf '{"id":"c-901","alive":false,"session_id":"%s"}\n' "$u_rest" >"$A/c-901.json"
printf '{"pid":%s,"sessionId":"%s"}\n' "$$" "$u_live" >"$S/$$.json"
printf 'not json' >"$S/bad.json"
bash -c 'sleep 30; :' "$u_cmd" & cmd_pid=$!

prune() { SNIPPET='do_spl_session_prune' in_orc SESSION_PRUNE_ROOT="$R" SESSION_PRUNE_SESSIONS="$S" SPOOL_ROOT="$T/spool" "$@" 2>&1; }
n_files() { find "$R" "$OUT" | wc -l; }
n0="$(n_files)"

out="$(prune DRY_RUN=2)"; rc=$?
[ "$rc" = 2 ] && grep -q 'DRY_RUN must be 0 or 1' <<<"$out" && pass "1. DRY_RUN is checked" || fail "1. DRY_RUN=2 (rc $rc: $out)"
out="$(prune AGE_DAYS=0 DRY_RUN=0)"; rc=$?
[ "$rc" = 2 ] && grep -q 'AGE_DAYS must be' <<<"$out" && pass "1. AGE_DAYS is checked" || fail "1. AGE_DAYS=0 (rc $rc: $out)"
out="$(prune SPOOL_ROOT="$T/nope" DRY_RUN=0)"; rc=$?
[ "$rc" = 2 ] && grep -q 'REFUSE cannot read the agent records' <<<"$out" && pass "1. unreadable agent records decide nothing" || fail "1. agents (rc $rc: $out)"
out="$(prune SESSION_PRUNE_SESSIONS="$T/nope" DRY_RUN=0)"; rc=$?
[ "$rc" = 2 ] && grep -q 'REFUSE cannot read the live sessions' <<<"$out" && pass "1. an unreadable sessions dir decides nothing" || fail "1. sessions (rc $rc: $out)"
out="$(SNIPPET='do_spl_session_prune' in_orc DRY_RUN=0 2>&1)"; rc=$?
[ "$rc" = 2 ] && grep -q 'a test names its tree' <<<"$out" && pass "1. SPOOL_TEST=1 never reaches the live users" || fail "1. live users (rc $rc: $out)"
[ "$(n_files)" = "$n0" ] && pass "1. ...and no refusal removed anything" || fail "1. a refusal removed files"

out="$(prune)"; rc=$?
[ "$rc" = 0 ] && grep -q "PLAN remove [0-9]*KB $P/$u_old\$" <<<"$out" && grep -q "PLAN remove [0-9]*KB $P/$u_orph\$" <<<"$out" \
  && [ "$(grep -c 'PLAN remove' <<<"$out")" = 2 ] && pass "2. the dry run plans exactly the two old dead sessions" || fail "2. dry run (rc $rc: $out)"
[ "$(n_files)" = "$n0" ] && pass "2. ...and removes nothing" || fail "2. the dry run removed files"

out="$(prune DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$P/$u_old.jsonl" ] && [ ! -e "$P/$u_old" ] && [ ! -e "$P/$u_orph" ] \
  && grep -q "REMOVE [0-9]*KB $P/$u_old\$" <<<"$out" && pass "3. DRY_RUN=0 removes the old dead .jsonl, its dir and the orphan dir" || fail "3. live run (rc $rc: $out)"
! grep -q "KEEP [a-z-]* $P/$u_old\$" <<<"$out" && [ "$(grep -c "$P/$u_old\$" <<<"$out")" = 1 ] \
  && pass "3. a removed session is one line, never also a KEEP for its dir" || fail "3. double visit ($out)"
grep -q "KEEP restorable $P/$u_rest\$" <<<"$out" && [ -f "$P/$u_rest.jsonl" ] && pass "3. a session an agent record names is kept" || fail "3. restorable ($out)"
grep -q "KEEP live $P/$u_live\$" <<<"$out" && [ -f "$P/$u_live.jsonl" ] && pass "3. a registry-live session is kept" || fail "3. live ($out)"
grep -q "KEEP live $P/$u_cmd\$" <<<"$out" && [ -f "$P/$u_cmd.jsonl" ] && pass "3. a session named on a running command line is kept" || fail "3. resumed ($out)"
grep -q "KEEP recent $P/$u_new\$" <<<"$out" && grep -q "KEEP recent $P/$u_dirnew\$" <<<"$out" && [ -f "$P/$u_dirnew.jsonl" ] \
  && pass "3. a session whose .jsonl or dir changed inside AGE_DAYS is kept" || fail "3. recent ($out)"
grep -q "KEEP symlink $R/-opt-b/$u_link\$" <<<"$out" && [ -L "$R/-opt-b/$u_link.jsonl" ] && [ -f "$OUT/$u_link.jsonl" ] \
  && pass "3. a symlink and its target are kept" || fail "3. symlink ($out)"
[ -f "$P/memory/MEMORY.md" ] && [ -f "$P/notes.txt" ] && pass "3. non-session files and dirs are untouched" || fail "3. touched memory/ or notes"

H="$T/human"; u_h1=aaaaaaaa-1111-4111-8111-111111111111 u_h2=aaaaaaaa-2222-4222-8222-222222222222
u_a1=aaaaaaaa-3333-4333-8333-333333333333 u_a2=aaaaaaaa-4444-4444-8444-444444444444
u_seat=aaaaaaaa-5555-4555-8555-555555555555 u_alive=aaaaaaaa-6666-4666-8666-666666666666
mkdir -p "$H/-opt" "$H/-var-opt-x-doc" "$H/-opt-x-x-spl-wt-c-123" "$H/-tmp-tmp-Ab-wt4-CLE-31" "$H/-opt-x-wt-notes" \
  "$H/-opt-x-x-spl-wt-c-002" "$H/-opt-x-x-spl-wt-c-777"
echo '{}' >"$H/-opt-x-x-spl-wt-c-002/$u_seat.jsonl"; echo '{}' >"$H/-opt-x-x-spl-wt-c-777/$u_alive.jsonl"
printf '{"id":"c-777","alive":true}\n' >"$A/c-777.json"
echo '{}' >"$H/-opt/$u_h1.jsonl"; echo '{}' >"$H/-var-opt-x-doc/$u_h2.jsonl"; echo '{}' >"$H/-opt-x-wt-notes/$u_h2.jsonl"
echo '{}' >"$H/-opt-x-x-spl-wt-c-123/$u_a1.jsonl"; echo '{}' >"$H/-tmp-tmp-Ab-wt4-CLE-31/$u_a2.jsonl"
find "$H" -exec touch -h -d '9 days ago' {} +
hprune() { SNIPPET='do_spl_session_prune' in_orc SESSION_PRUNE_ROOT="$H" SESSION_PRUNE_SESSIONS="$S" SPOOL_ROOT="$T/spool" "$@" 2>&1; }
out="$(hprune SESSION_PRUNE_AGENT_ONLY=2 DRY_RUN=0)"; rc=$?
[ "$rc" = 2 ] && grep -q 'SESSION_PRUNE_AGENT_ONLY must be 0 or 1' <<<"$out" && pass "4. SESSION_PRUNE_AGENT_ONLY is checked" || fail "4. AGENT_ONLY=2 (rc $rc: $out)"
out="$(hprune SESSION_PRUNE_AGENT_ONLY=1 DRY_RUN=0)"; rc=$?
[ "$rc" = 0 ] && [ ! -e "$H/-opt-x-x-spl-wt-c-123/$u_a1.jsonl" ] && [ ! -e "$H/-tmp-tmp-Ab-wt4-CLE-31/$u_a2.jsonl" ] \
  && [ "$(grep -c 'REMOVE' <<<"$out")" = 2 ] && pass "4. a human tree loses only the agent worktree sessions" || fail "4. agent slugs (rc $rc: $out)"
grep -q "KEEP human $H/-opt/$u_h1\$" <<<"$out" && grep -q "KEEP human $H/-var-opt-x-doc/$u_h2\$" <<<"$out" \
  && grep -q "KEEP human $H/-opt-x-wt-notes/$u_h2\$" <<<"$out" && [ -f "$H/-opt/$u_h1.jsonl" ] && [ -f "$H/-var-opt-x-doc/$u_h2.jsonl" ] \
  && pass "4. the owner's own sessions are KEEP human, however old" || fail "4. human sessions ($out)"
grep -q "KEEP role-seat $H/-opt-x-x-spl-wt-c-002/$u_seat\$" <<<"$out" && grep -q "KEEP alive $H/-opt-x-x-spl-wt-c-777/$u_alive\$" <<<"$out" \
  && [ -f "$H/-opt-x-x-spl-wt-c-002/$u_seat.jsonl" ] && [ -f "$H/-opt-x-x-spl-wt-c-777/$u_alive.jsonl" ] \
  && pass "4. a role seat's and an alive agent's worktree sessions are kept" || fail "4. seat/alive ($out)"
kill "$cmd_pid" 2>/dev/null; wait "$cmd_pid" 2>/dev/null

echo "spl-session-prune: ${fails} failure(s)"
[ "$fails" -eq 0 ]
