#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_review_line_check (refactor round 11 row 06) on fixture
# journals in a temp dir, never a real one.
#   1. red control: a journal holding only `git diff --stat` (the r10-09
#      shape; its OUTPUT lists the test file) -> MISSING, exit 3; one holding
#      the run -> OK 1 of 1, exit 0
#   2. a log on another box is refused (exit 2, names the box), never read
#   3. the three journal shapes: claude tool_use input, a vibe journal dir with
#      the command in a JSON-encoded arguments string, grok arguments;
#      go test <pkg> and pnpm run <script> are names too
#   4. a name is matched whole: `xgit-prune-...` is not `git-prune-...`
#   5. refusals: no line, no log:, a ran: naming no test, an unreadable log
#   6. a vibe store compacted after the line was written (journal file gone,
#      the run only in chunks/*.json, whole-file JSON): the session dir and the
#      gone journal file both read the store -> OK; control: chunks holding the
#      test only in tool output -> MISSING; a gone file outside a vibe store
#      is still refused
#   7. agy transcripts: `args.CommandLine` of a `run_command` tool call, JSON-
#      quoted in transcript.jsonl, plain in transcript_full.jsonl -> OK;
#      control: the test only in tool output, or another tool -> MISSING
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

chk() { SNIPPET='do_spl_review_line_check' in_orc REVIEW_LINE_BOX=box-a "$@" 2>&1; }
SHA=0123456789abcdef0123456789abcdef01234567
line() { echo "review: m-159@box-a mistral PASS $SHA ran: $1 | read: 9 PASS | log: m-159@${3:-box-a}:$2"; }
TST=csi-spl-orc/src/bash/tests/git-prune-round-branches.tst.sh

# 1. red control ---------------------------------------------------------------
J="$T/stat.jsonl"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff --stat origin/master"}}]}}' \
  '{"type":"user","message":{"content":[{"type":"tool_result","content":" '"$TST"' | 40 +++\n 1 file changed"}]}}' >"$J"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$J")")"; rc=$?
[[ $rc -eq 3 && "$out" == *"MISSING git-prune-round-branches.tst.sh"* ]] \
  && pass "1. a journal with only git diff --stat -> MISSING, exit 3" || fail "1. diff-stat journal (rc $rc: $out)"
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"cd /x && bash '"$TST"'"}}]}}' >>"$J"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$J")")"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK 1 of 1"* ]] && pass "1. the same journal holding the run -> OK 1 of 1, exit 0" || fail "1. run journal (rc $rc: $out)"
out="$(chk REVIEW_LINE="Some subject body
$(line "bash $TST" "$J")")"; rc=$?
[[ $rc -eq 0 ]] && pass "1. the line is found inside a whole commit body" || fail "1. body (rc $rc: $out)"

# 2. another box ---------------------------------------------------------------
out="$(chk REVIEW_LINE="$(line "bash $TST" "/nonexistent/j.jsonl" box-b)")"; rc=$?
[[ $rc -eq 2 && "$out" == *"'box-b'"* && "$out" == *"'box-a'"* ]] && pass "2. a log on box-b is refused on box-a, exit 2" || fail "2. other box (rc $rc: $out)"
out="$(SNIPPET='do_spl_review_line_check' in_orc REVIEW_LINE_BOX= SPOOL_BOX_TAG=box-b REVIEW_LINE="$(line "bash $TST" "$J")" 2>&1)"; rc=$?
[[ $rc -eq 2 ]] && pass "2. this box defaults to SPOOL_BOX_TAG" || fail "2. SPOOL_BOX_TAG (rc $rc: $out)"

# 3. vibe dir, grok, go test, pnpm run -----------------------------------------
V="$T/vibe/journal"; mkdir -p "$V"
printf '%s\n' '{"parts":[{"arguments_json":"{\"command\": \"cd api && go test -count=1 ./cmd/spool/\"}","name":"bash"}]}' >"$V/0001.jsonl"
printf '%s\n' '{"call":{"arguments":{"command":"pnpm --dir csi-spl-wui run typecheck && node --test tests/unit/cleancode.test.mjs"}}}' >"$V/0002.jsonl"
out="$(chk REVIEW_LINE="$(line "go test -count=1 ./cmd/spool/; pnpm run typecheck; node --test tests/unit/cleancode.test.mjs" "$V")")"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK 3 of 3"* ]] && pass "3. a vibe journal dir: go test, pnpm run, *.test.mjs -> OK 3 of 3" || fail "3. vibe (rc $rc: $out)"
out="$(chk REVIEW_LINE="$(line "go test ./internal/store/; pnpm run lint" "$V")")"; rc=$?
[[ $rc -eq 3 && "$out" == *"MISSING go test ./internal/store/"* && "$out" == *"MISSING pnpm run lint"* ]] \
  && pass "3. a package or script not run is MISSING" || fail "3. vibe missing (rc $rc: $out)"
G="$T/chat_history.jsonl"
printf '%s\n' '{"role":"assistant","tool_calls":[{"function":{"name":"run_terminal_command","arguments":"{\"command\":\"go test ./cmd/spool/ -run TestRepoEdit; cd api && go vet ./... && true\"}"}}]}' >"$G"
printf '%s\n' '{"role":"tool","content":"ok hub_repo_edit_test.go"}' >>"$G"
out="$(chk REVIEW_LINE="$(line "go test ./cmd/spool/ hub_repo_edit_test.go" "$G")")"; rc=$?
[[ $rc -eq 3 && "$out" == *"MISSING hub_repo_edit_test.go"* && "$out" == *"1 of 2"* ]] \
  && pass "3. grok arguments: go test found, a *_test.go only in tool output MISSING" || fail "3. grok (rc $rc: $out)"

# 4. whole names ---------------------------------------------------------------
X="$T/x.jsonl"
printf '%s\n' '{"input":{"command":"bash xgit-prune-round-branches.tst.sh"}}' >"$X"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$X")")"; rc=$?
[[ $rc -eq 3 ]] && pass "4. xgit-prune-... is not git-prune-..." || fail "4. whole name (rc $rc: $out)"

# 5. refusals -----------------------------------------------------------------
out="$(chk REVIEW_LINE=)"; rc=$?
[[ $rc -eq 1 && "$out" == *FATAL* ]] && pass "5. no REVIEW_LINE -> exit 1" || fail "5. empty (rc $rc: $out)"
out="$(chk REVIEW_LINE="review: m-159@box-a mistral PASS $SHA ran: bash $TST | read: ok")"; rc=$?
[[ $rc -eq 1 && "$out" == *"log:"* ]] && pass "5. no log: -> exit 1" || fail "5. no log (rc $rc: $out)"
out="$(chk REVIEW_LINE="$(line "git diff --stat" "$J")")"; rc=$?
[[ $rc -eq 3 && "$out" == *"names no test"* ]] && pass "5. a ran: naming no test -> exit 3" || fail "5. no test (rc $rc: $out)"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$T/none.jsonl")")"; rc=$?
[[ $rc -eq 1 && "$out" == *"not readable"* ]] && pass "5. a missing log -> exit 1" || fail "5. missing log (rc $rc: $out)"

# 6. a compacted vibe store ---------------------------------------------------
C="$T/unified/bb00"; mkdir -p "$C/journal" "$C/chunks" "$C/generations/0926"
echo '{"generation":"0926","store_format":"mistral.vibe.unified-session-store/v1"}' >"$C/CURRENT"
printf '%s\n' '{"input":{"command":"spool recv --as m-183"}}' >"$C/journal/0892.jsonl"
printf '%s' '[{"role":"user","content":[{"text":"review '"$TST"'"}]},' \
  '{"display":{"verb":"Running"},"input":{"command":"cd /x && bash '"$TST"'"},"kind":"tool"}]' >"$C/chunks/a814.json"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$C")")"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK 1 of 1"* ]] && pass "6. log: names the session dir -> the run in chunks/ counts, OK 1 of 1" || fail "6. session dir (rc $rc: $out)"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$C/journal/0001.jsonl")")"; rc=$?
[[ $rc -eq 0 && "$out" == *"NOTE"*"compacted"* && "$out" == *"OK 1 of 1"* ]] \
  && pass "6. log: names the journal file vibe deleted -> NOTE, the session dir is read, OK" || fail "6. gone journal file (rc $rc: $out)"
printf '%s' '[{"role":"tool","content":" '"$TST"' | 40 +++"},{"input":{"command":"git diff --stat"}}]' >"$C/chunks/a814.json"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$C/journal/0001.jsonl")")"; rc=$?
[[ $rc -eq 3 && "$out" == *"MISSING git-prune-round-branches.tst.sh"* ]] \
  && pass "6. control: chunks holding the test only in tool output -> MISSING, exit 3" || fail "6. control (rc $rc: $out)"
mkdir -p "$T/plain/journal"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$T/plain/journal/0001.jsonl")")"; rc=$?
[[ $rc -eq 1 && "$out" == *"not readable"* ]] && pass "6. a gone journal file outside a vibe store -> exit 1" || fail "6. plain gone (rc $rc: $out)"

# 7. agy transcripts ----------------------------------------------------------
A="$T/agy/logs"; mkdir -p "$A"
printf '%s\n' '{"step_index":3,"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"git diff --stat origin/master\"","Cwd":"\"/x\""}}]}' \
  '{"step_index":4,"source":"SYSTEM","type":"RUN_COMMAND","content":" '"$TST"' | 40 +++"}' >"$A/transcript.jsonl"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$A/transcript.jsonl")")"; rc=$?
[[ $rc -eq 3 && "$out" == *"MISSING git-prune-round-branches.tst.sh"* ]] \
  && pass "7. control: an agy transcript holding the test only in tool output -> MISSING, exit 3" || fail "7. agy control (rc $rc: $out)"
printf '%s\n' '{"step_index":9,"source":"MODEL","type":"PLANNER_RESPONSE","tool_calls":[{"name":"run_command","args":{"CommandLine":"\"cd /x && bash '"$TST"'\"","Cwd":"\"/x\""}}]}' >>"$A/transcript.jsonl"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$A/transcript.jsonl")")"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK 1 of 1"* ]] && pass "7. agy transcript.jsonl: a JSON-quoted run_command CommandLine -> OK 1 of 1" || fail "7. agy transcript (rc $rc: $out)"
printf '%s\n' '{"step_index":9,"tool_calls":[{"name":"run_command","args":{"CommandLine":"go test -count=1 ./cmd/spool/","Cwd":"/x","WaitMsBeforeAsync":2000}}]}' >"$A/transcript_full.jsonl"
rm "$A/transcript.jsonl"
out="$(chk REVIEW_LINE="$(line "go test ./cmd/spool/" "$A/transcript_full.jsonl")")"; rc=$?
[[ $rc -eq 0 && "$out" == *"OK 1 of 1"* ]] && pass "7. agy transcript_full.jsonl: a plain CommandLine -> OK 1 of 1" || fail "7. agy full (rc $rc: $out)"
printf '%s\n' '{"tool_calls":[{"name":"view_file","args":{"CommandLine":"\"bash '"$TST"'\""}}]}' >"$A/transcript_full.jsonl"
out="$(chk REVIEW_LINE="$(line "bash $TST" "$A/transcript_full.jsonl")")"; rc=$?
[[ $rc -eq 3 ]] && pass "7. a CommandLine outside a run_command call does not count" || fail "7. agy other tool (rc $rc: $out)"

echo "spl-review-line-check: ${fails} failure(s)"
[ "$fails" -eq 0 ]
