#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_pdf (spec 183 row P3, spec 182 row L6's names) runs
# `spool topic-pdf` with TOPIC_ID, ENV and OUT: the verb's argv, its stdout
# passed through, its exit code returned (3 = the hub's 404); a bad ENV or no
# TOPIC_ID is refused before the verb runs. RED CONTROL: drop the OUT line of
# the action and the first case fails (no --out in the argv).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

A=0f8fad5b-d9cb-469f-a165-70867728950e
# The stub verb: its argv and SPOOL_AGENT_ID to $T/argv, a JSON line, exit $STUB_RC.
printf '#!/bin/bash\n{ printf "%%s|" "$@"; echo; echo "agent=${SPOOL_AGENT_ID:-}"; } >"%s/argv"\necho "{\\"task_id\\":\\"%s\\"}"\nexit "${STUB_RC:-0}"\n' \
  "$T" "$A" >"$T/spool"
chmod +x "$T/spool"
run() {
  rm -f "$T/argv"
  SNIPPET='do_spl_topic_pdf' IN_ORC_RUN=spl-topic-pdf in_orc SPOOL_TEST=1 SPOOL_DESK_BOX=box-t \
    TOPIC_PDF_SPOOL_CMD="$T/spool" TOPIC_PDF_DESKS="$T/desk" AGENT_ID=c-007 "$@" >"$T/o" 2>&1
  RC=$?
}

run TOPIC_ID="$A" OUT="$T/x.pdf"
want="topic-pdf|--task|$A|--desks|$T/desk|--desk-box|box-t|--out|$T/x.pdf|"
[[ $RC -eq 0 && "$(head -1 "$T/argv")" == "$want" ]] && grep -qx "{\"task_id\":\"$A\"}" "$T/o" &&
  pass "TOPIC_ID, ENV, OUT run spool topic-pdf --task --desks --desk-box --out; its JSON is printed" ||
  fail "argv (rc=$RC): $(cat "$T/argv" 2>/dev/null) / $(cat "$T/o"), want $want"
grep -qx "agent=c-007" "$T/argv" && pass "AGENT_ID names the exporting agent (SPOOL_AGENT_ID)" || fail "agent: $(cat "$T/argv")"

run TOPIC_ID="https://t1.example.com/t/$A" TYPED_BY=HUM-12 ENV=prd
want="topic-pdf|--task|https://t1.example.com/t/$A|--desks|$T/desk|--desk-box|box-t|--typed-by|HUM-12|"
[[ $RC -eq 0 && "$(head -1 "$T/argv")" == "$want" ]] && pass "a link, TYPED_BY and ENV=prd; no OUT = no --out" ||
  fail "argv (rc=$RC): $(cat "$T/argv" 2>/dev/null), want $want"

run TOPIC_ID="$A" STUB_RC=3
[[ $RC -eq 3 ]] && pass "the verb's exit 3 (the hub's 404) is the action's" || fail "rc $RC, want 3: $(cat "$T/o")"

for bad in "ENV=prod" "ENV=" "TOPIC_ID="; do
  run TOPIC_ID="$A" "$bad"
  [[ $RC -eq 1 && ! -e "$T/argv" ]] && grep -q FATAL "$T/o" && pass "$bad: refused before the verb" ||
    fail "$bad (rc=$RC): $(cat "$T/o") / $(cat "$T/argv" 2>/dev/null)"
done

echo "spl-topic-pdf: $fails failure(s)"
[[ $fails -eq 0 ]]
