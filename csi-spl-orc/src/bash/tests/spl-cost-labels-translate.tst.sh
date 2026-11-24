#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_cost_labels_translate (spec 123 section 16.6, row L4,
#          SPL-6201): the night run's fill, the unreviewed read, ONE agy
#          review and the write back. The hub and agy are stubbed.
#   1. agy's correction is the one written, an "ok" writes the draft; each PUT
#      carries the read's key and source_sha; agy sees the mask token and
#      never a key or a sha; the fill runs first
#   2. the log has no label: no master text, draft or correction in stdout or
#      stderr
#   3. RED CONTROL: agy answers "refuse" -> zero writes, exit 2
#   4. RED CONTROL: agy answers 101 characters for one locale -> that locale
#      refused, every other locale written
#   5. an off-schema JSON answer (an extra field, a locale not asked, an i out
#      of range) -> zero writes; a fenced answer is still read
#   6. DRY_RUN=1 (default): no fill, no agy call, no write
#   7. agy failing 3 runs in a row -> one note (the key's prefix, no text),
#      none on the 4th; a success clears the count
#   8. agy at its vendor limit -> one note per day
#   9. 409 stale_source drops the text, no failure counted
#  10. TRANSLATE_CMD=measure: n agy calls on the same prompt, no hub call;
#      schema_ok=<k>/<n> n=<n>
#  11. a held lock -> FATAL, no hub call
#  12. SPL-6346: agy not on PATH -> the no_agy FATAL is one line naming the
#      user it ran as and the PATH it searched; control: an agy that fails
#      otherwise carries no such tail
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-cost-labels-translate.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# Two unreviewed texts, synthetic: A carries a mask token, B none.
cat >"$T/unreviewed.json" <<'EOF'
{"items":[
 {"key":"kA0001","source_sha":"shaA0001","masked_text":"Zorblat rent for [WORKSPACE_1]",
  "masked_drafts":{"fi":"FIDRAFTA [WORKSPACE_1]","sv":"SVDRAFTA [WORKSPACE_1]","bg":"BGDRAFTA [WORKSPACE_1]"}},
 {"key":"kB0002","source_sha":"shaB0002","masked_text":"Quibble desk",
  "masked_drafts":{"fi":"FIDRAFTB","sv":"SVDRAFTB"}}]}
EOF
LABELS='Zorblat|Quibble|DRAFTA|DRAFTB|CORRA|CORRB|xxxxxxxxxx'

# The agy stub: records its argv, then answers $AGY_ANSWER (a file), or
# AGY_MODE=okall ("ok" for every draft of the prompt's input), fail, limit.
cat >"$T/agy" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$T/agy.args"
echo x >>"$T/agy.calls"
case "${AGY_MODE:-file}" in
  fail) echo "boom" >&2; exit 1 ;;
  limit) echo "You hit your weekly limit" >&2; exit 1 ;;
  okall) in="${2##*Input:$'\n'}"
         jq -c '{items: [.items[] | {i, labels: (.drafts | map_values("ok"))}]}' <<<"$in" ;;
  *) cat "$AGY_ANSWER" ;;
esac
EOF
chmod +x "$T/agy"
cat >"$T/send.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$T/notes"
EOF

# runa <state> [VAR=val ...]: the action, hub and agy stubbed; the output in
# $T/out, the exit code in $T/rc, the hub calls in $T/calls, the PUT bodies
# in $T/puts
runa() {
  local st="$1"; shift
  : >"$T/calls"; : >"$T/puts"; rm -f "$T/agy.args" "$T/agy.calls"
  # shellcheck disable=SC2016 # the script expands in the child shell
  env -u DRY_RUN -u TRANSLATE_CMD FUNC="$FUNC" T="$T" ST="$T/$st" ENV=dev AGY_BIN="$T/agy" \
    TRANSLATE_SEND="$T/send.sh" TRANSLATE_NOTE_TO=c-999 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; SPL_STATE_DIR="$ST"; mkdir -p "$ST"; }
    spl_hub_operator_url() { SPL_HUB_URL=https://hub.example; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.iam; }
    do_gcp_require_live_account() { return 0; }
    spl_hub_operator_call() {
      echo "$1 $2" >>"$T/calls"
      case "$1" in
        POST) SPL_HUB_OP_STATUS=200; SPL_HUB_OP_BODY="{\"texts\":1,\"written\":18,\"refused\":0,\"failed\":0,\"capped\":0}" ;;
        GET) SPL_HUB_OP_STATUS=200; SPL_HUB_OP_BODY="$(cat "$T/unreviewed.json")" ;;
        PUT) printf "%s\n" "$3" >>"$T/puts"; SPL_HUB_OP_STATUS="${PUT_STATUS:-200}"
             SPL_HUB_OP_BODY="$(jq -c "{written: (.labels | length), refused: {}}" <<<"$3")" ;;
      esac
    }
    source "$FUNC"
    do_spl_cost_labels_translate' >"$T/out" 2>&1
  echo $? >"$T/rc"
}
answer() { printf '%s\n' "$1" >"$T/answer"; }
puts() { [[ -s "$T/puts" ]] && wc -l <"$T/puts" || echo 0; }
put_of() { jq -c --arg k "$1" 'select(.key == $k)' "$T/puts"; }

# 1. correction written, ok writes the draft
answer '{"items":[{"i":0,"labels":{"fi":"FICORRA [WORKSPACE_1]","sv":"ok","bg":"ok"}},{"i":1,"labels":{"fi":"ok","sv":"SVCORRB"}}]}'
runa s1 DRY_RUN=0 AGY_ANSWER="$T/answer"
a="$(put_of kA0001)"; b="$(put_of kB0002)"
if [[ "$(cat "$T/rc")" == 0 && "$(puts)" == 2 ]] &&
  [[ "$(jq -c .labels <<<"$a")" == '{"fi":"FICORRA [WORKSPACE_1]","sv":"SVDRAFTA [WORKSPACE_1]","bg":"BGDRAFTA [WORKSPACE_1]"}' ]] &&
  [[ "$(jq -c .labels <<<"$b")" == '{"fi":"FIDRAFTB","sv":"SVCORRB"}' ]] &&
  [[ "$(jq -r .source_sha <<<"$a") $(jq -r .source_sha <<<"$b")" == "shaA0001 shaB0002" ]]; then
  pass "1. the correction is written, an ok writes the draft, with the read's key and source_sha"
else fail "1. rc=$(cat "$T/rc") puts=$(puts): $(cat "$T/puts") $(cat "$T/out")"; fi
if grep -q '\[WORKSPACE_1\]' "$T/agy.args" && ! grep -qE 'kA0001|shaA0001|kB0002' "$T/agy.args" &&
  grep -q -- '--print-timeout' "$T/agy.args" && ! grep -q -- '--json-schema' "$T/agy.args" &&
  [[ "$(head -1 "$T/calls")" == "POST /v1/operator/cost-labels/fill" ]]; then
  pass "1. agy sees the mask token, no key, no sha, no --json-schema; the fill runs first"
else fail "1. agy args or call order: $(cat "$T/calls")"; fi

# 2. the log has no label
if ! grep -qE "$LABELS" "$T/out" && grep -q 'locales_written=5' "$T/out"; then
  pass "2. the log has counts and no label"
else fail "2. the log: $(cat "$T/out")"; fi

# 3. RED CONTROL: agy answers refuse -> zero writes
answer 'refuse'
runa s3 DRY_RUN=0 AGY_ANSWER="$T/answer"
if [[ "$(cat "$T/rc")" == 2 && "$(puts)" == 0 ]] && grep -q 'off_schema' "$T/out" && ! grep -qE "$LABELS" "$T/out"; then
  pass "3. RED CONTROL: agy answers refuse -> zero writes, exit 2"
else fail "3. rc=$(cat "$T/rc") puts=$(puts) $(cat "$T/out")"; fi

# 4. RED CONTROL: 101 characters -> that locale refused, the others written
long="$(printf 'x%.0s' $(seq 101))"
answer "{\"items\":[{\"i\":0,\"labels\":{\"fi\":\"$long\",\"sv\":\"ok\",\"bg\":\"ok\"}},{\"i\":1,\"labels\":{\"fi\":\"ok\",\"sv\":\"ok\"}}]}"
runa s4 DRY_RUN=0 AGY_ANSWER="$T/answer"
a="$(put_of kA0001)"
if [[ "$(cat "$T/rc")" == 0 && "$(puts)" == 2 && "$(jq -c '.labels | keys' <<<"$a")" == '["bg","sv"]' ]] &&
  [[ "$(jq -c '.labels | keys' <<<"$(put_of kB0002)")" == '["fi","sv"]' ]] && grep -q 'locales_refused=1' "$T/out" &&
  ! grep -qE "$LABELS" "$T/out"; then
  pass "4. RED CONTROL: 101 characters -> that locale refused, the other four written"
else fail "4. rc=$(cat "$T/rc") $(cat "$T/puts") $(cat "$T/out")"; fi

# 5. off-schema JSON -> zero writes; a fenced answer is read
for bad in '{"items":[{"i":0,"labels":{"fi":"ok"},"extra":1}]}' '{"items":[{"i":0,"labels":{"de":"ok"}}]}' \
  '{"items":[{"i":2,"labels":{"fi":"ok"}}]}' '{"items":[{"i":0,"labels":{"fi":1}}]}' '{"answer":[]}' \
  '{"items":[{"i":0,"labels":{"fi":"ok"}},{"i":0,"labels":{"sv":"ok"}}]}'; do
  answer "$bad"
  runa s5 DRY_RUN=0 AGY_ANSWER="$T/answer"
  if [[ "$(cat "$T/rc")" == 2 && "$(puts)" == 0 ]] && grep -q off_schema "$T/out"; then
    pass "5. off schema -> zero writes: $bad"
  else fail "5. $bad: rc=$(cat "$T/rc") puts=$(puts)"; fi
done
# shellcheck disable=SC2016 # a literal code fence
printf 'Here it is:\n```json\n%s\n```\n' '{"items":[{"i":1,"labels":{"fi":"ok"}}]}' >"$T/answer"
runa s5b DRY_RUN=0 AGY_ANSWER="$T/answer"
if [[ "$(cat "$T/rc")" == 0 && "$(puts)" == 1 ]] && grep -q 'unanswered=1' "$T/out"; then
  pass "5. a fenced answer is read; the unanswered text is not written"
else fail "5. fenced: rc=$(cat "$T/rc") $(cat "$T/out")"; fi

# 6. DRY_RUN=1 (default)
answer '{"items":[]}'
runa s6 AGY_ANSWER="$T/answer"
if [[ "$(cat "$T/rc")" == 0 && "$(puts)" == 0 && ! -e "$T/agy.calls" ]] &&
  [[ "$(cat "$T/calls")" == "GET /v1/operator/cost-labels/unreviewed" ]] && grep -q 'texts=2 locales=5 (DRY_RUN=1' "$T/out"; then
  pass "6. DRY_RUN=1: one read, no fill, no agy call, no write"
else fail "6. $(cat "$T/calls") $(cat "$T/out")"; fi

# 7. 3 failing runs -> one note, none on the 4th; a success clears it
: >"$T/notes"
for _ in 1 2 3 4; do runa s7 DRY_RUN=0 AGY_MODE=fail; done
pa="$(printf '%s' kA0001 | sha256sum | cut -c1-12)"
if [[ "$(wc -l <"$T/notes")" == 2 ]] && grep -q "$pa" "$T/notes" && ! grep -qE "$LABELS|kA0001" "$T/notes" &&
  grep -q 'failed its agy review 3 runs' "$T/notes" && grep -q "exit_1" "$T/out"; then
  pass "7. 3 failed runs: one note per text (prefix only), none on the 4th"
else fail "7. notes: $(cat "$T/notes")"; fi
answer '{"items":[{"i":0,"labels":{"fi":"ok"}},{"i":1,"labels":{"fi":"ok"}}]}'
runa s7 DRY_RUN=0 AGY_ANSWER="$T/answer"
if [[ ! -s "$T/s7/cost-labels-translate/fails.tsv" ]]; then pass "7. a success clears the count"
else fail "7. fails.tsv: $(cat "$T/s7/cost-labels-translate/fails.tsv")"; fi

# 12. no agy: the FATAL names the user and the PATH searched, on one line
runa s12 DRY_RUN=0 AGY_BIN=no-such-agy-bin PATH="$T/emptybin:$PATH"
fl="$(grep 'FATAL dev agy review failed' "$T/out")"
if [[ "$(cat "$T/rc")" == 2 && "$(grep -c 'FATAL' "$T/out")" == 1 ]] && [[ "$fl" == *"(no_agy)"* ]] &&
  [[ "$fl" == *"'no-such-agy-bin' not found as user $(id -un) on PATH=$T/emptybin:"* ]]; then
  pass "12. no_agy: one FATAL line naming the user ($(id -un)) and the PATH it searched"
else fail "12. rc=$(cat "$T/rc"): $(cat "$T/out")"; fi
runa s12b DRY_RUN=0 AGY_MODE=fail
if grep -q 'agy review failed (exit_1)' "$T/out" && ! grep -q 'not found as user' "$T/out"; then
  pass "12. control: an agy that exits 1 carries no user/PATH tail"
else fail "12. control: $(cat "$T/out")"; fi

# 8. vendor limit -> one note per day
: >"$T/notes"
runa s8 DRY_RUN=0 AGY_MODE=limit; runa s8 DRY_RUN=0 AGY_MODE=limit
if [[ "$(grep -c 'vendor limit' "$T/notes")" == 1 && "$(puts)" == 0 ]] && grep -q vendor_limit "$T/out"; then
  pass "8. agy at its vendor limit: one note per day, zero writes"
else fail "8. notes: $(cat "$T/notes")"; fi

# 9. 409 stale_source
answer '{"items":[{"i":0,"labels":{"fi":"ok"}}]}'
runa s9 DRY_RUN=0 AGY_ANSWER="$T/answer" PUT_STATUS=409
if [[ "$(cat "$T/rc")" == 0 ]] && grep -q 'stale=1' "$T/out" && [[ ! -s "$T/s9/cost-labels-translate/fails.tsv" ]]; then
  pass "9. 409 stale_source drops the text, no failure counted"
else fail "9. $(cat "$T/out")"; fi

# 10. measure: the same prompt and schema, no hub call
runa s10 TRANSLATE_CMD=measure AGY_MODE=okall
if [[ "$(cat "$T/rc")" == 0 ]] && grep -qx 'schema_ok=20/20 n=20' "$T/out" && [[ ! -s "$T/calls" ]] &&
  [[ "$(wc -l <"$T/agy.calls")" == 20 ]] && grep -q '"sr":"Insurance, professional liability"' "$T/agy.args" &&
  grep -q 'It must follow this JSON schema' "$T/agy.args" && grep -q '"additionalProperties":false' "$T/agy.args"; then
  pass "10. measure: 20 agy calls on the write path's prompt and schema, no hub call, schema_ok=20/20 n=20"
else fail "10. $(cat "$T/out")"; fi
answer 'refuse'
runa s10 TRANSLATE_CMD=measure MEASURE_N=3 AGY_ANSWER="$T/answer"
if grep -qx 'schema_ok=0/3 n=3' "$T/out" && [[ ! -s "$T/calls" ]]; then pass "10. measure counts an off-schema answer as not ok"
else fail "10. refuse: $(cat "$T/out")"; fi

# 11. a held lock
mkdir -p "$T/s11/cost-labels-translate"
exec {held}>>"$T/s11/cost-labels-translate/run.lock"
flock -n "$held"
runa s11 DRY_RUN=0
exec {held}>&-
if [[ "$(cat "$T/rc")" == 1 && ! -s "$T/calls" ]] && grep -q 'holds its lock' "$T/out"; then
  pass "11. a held lock: FATAL, no hub call"
else fail "11. rc=$(cat "$T/rc") $(cat "$T/out")"; fi

echo "---"
if (( fails == 0 )); then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
