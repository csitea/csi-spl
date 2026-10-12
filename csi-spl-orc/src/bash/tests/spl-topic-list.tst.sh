#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_list (t1 1457bb6f), a desk agent's read of one
#          channel's topics through `spool topics`. No cloud call, no spool
#          binary: spool is a fake that logs its argv and prints pages.
#   1. it refuses a bad CHANNEL / TOPIC_LIMIT / TOPIC_ALL / DESK_AGENT before
#      it reads anything. CONTROL: no refused run reached spool
#   2. the dry run says what it would read and reads nothing
#   3. DRY_RUN=0 reads one page as `spool topics --as --channel --limit
#      --json` (the # stripped) and prints one document of task id, subject
#      and last_ts per topic
#   4. TOPIC_ALL=1 follows "next" (--before) to the last page, one document
#   5. a hub refusal is a FATAL carrying the hub's token
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux

cat >"$T/fakespool" <<'FAKE'
#!/bin/sh
printf '%s|' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
[ -n "${FAKE_REFUSE:-}" ] && { echo 'spool: hub refused: from_not_announced (c-227 is not an agent announced by box-desk)' >&2; exit 78; }
case "$*" in
  *"--before CUR1"*) echo '{"channel":"refactoring","topics":[{"task_id":"t-3","subject":"third","last_ts":"2026-10-12T01:00:00Z"}],"next":null}' ;;
  *) echo '{"channel":"refactoring","topics":[{"task_id":"t-1","subject":"first","last_ts":"2026-10-12T03:00:00Z"},{"task_id":"t-2","subject":"second","last_ts":"2026-10-12T02:00:00Z"}],"next":"CUR1"}' ;;
esac
FAKE
chmod +x "$T/fakespool"; : >"$T/topics.log"
TL='spl_host_spool() { SPL_SPOOL="$FAKE"; }; do_spl_topic_list'
mkdir -p "$T/state/dev/desk/t1/box-desk/spool/c-227"
run_tl() { SNIPPET="$TL" in_orc FAKE="$T/fakespool" FAKE_LOG="$T/topics.log" TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=c-227 CHANNEL=refactoring "$@"; }

# --- 1. refusals ----------------------------------------------------------------
for bad in "CHANNEL=" "CHANNEL=Refactoring" "CHANNEL=a b" "CHANNEL=#" "TOPIC_LIMIT=0" "TOPIC_LIMIT=101" "TOPIC_LIMIT=x" \
           "TOPIC_ALL=2" "DESK_AGENT=box-desk" "DESK_AGENT=" "TENANT_ID=T1"; do
  if run_tl DRY_RUN=0 "$bad" >"$T/o" 2>&1; then
    fail "refuses $bad: $(cat "$T/o")"
  else
    grep -q FATAL "$T/o" && pass "refuses $bad" || fail "refuses $bad without saying why: $(cat "$T/o")"
  fi
done
[[ ! -s "$T/topics.log" ]] && pass "CONTROL no refused run reached spool" || fail "a refused run ran spool: $(cat "$T/topics.log")"

# --- 2. the dry run -------------------------------------------------------------
out=$(run_tl 2>&1); rc=$?
[[ $rc -eq 0 && "$out" == *"DRY_RUN would: spool topics --as c-227 --channel refactoring --limit 50"* && ! -s "$T/topics.log" ]] &&
  pass "the dry run says what it would read and reads nothing" || fail "dry run (rc=$rc): $out / $(cat "$T/topics.log")"

# --- 3. one page ----------------------------------------------------------------
out=$(run_tl CHANNEL='#refactoring' DRY_RUN=0 2>&1); rc=$?
[[ $rc -eq 0 ]] && tail -1 "$T/topics.log" | grep -x 'topics|--as|c-227|--channel|refactoring|--limit|50|--json|' >/dev/null &&
  pass "DRY_RUN=0 reads one page as spool topics --as --channel --limit --json" || fail "one page (rc=$rc): $out / $(cat "$T/topics.log")"
doc=$(printf '%s\n' "$out" | tail -1)
python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert d["channel"] == "refactoring" and d["agent"] == "c-227" and d["tenant"] == "t1" and d["box"] == "box-desk", d
assert [t["task_id"] for t in d["topics"]] == ["t-1", "t-2"] and d["next"] == "CUR1", d
assert all(sorted(t) == ["last_ts", "subject", "task_id"] for t in d["topics"]), d
' "$doc" 2>"$T/py" && pass "…printed as one document of task_id, subject, last_ts and next" || fail "one-page doc: $doc / $(cat "$T/py")"

# --- 4. every page --------------------------------------------------------------
: >"$T/topics.log"
out=$(run_tl TOPIC_ALL=1 TOPIC_LIMIT=2 DRY_RUN=0 2>&1); rc=$?
doc=$(printf '%s\n' "$out" | tail -1)
[[ $rc -eq 0 && $(wc -l <"$T/topics.log") -eq 2 ]] && [[ "$(sed -n 2p "$T/topics.log")" == *'|--limit|2|--json|--before|CUR1|'* ]] &&
  python3 -c '
import json, sys
d = json.loads(sys.argv[1])
assert [t["task_id"] for t in d["topics"]] == ["t-1", "t-2", "t-3"] and d["next"] is None, d
' "$doc" 2>"$T/py" && pass "TOPIC_ALL=1 follows next to the last page, one document" ||
  fail "all pages (rc=$rc): $out / $(cat "$T/topics.log") / $(cat "$T/py")"

# --- 5. a refusal ---------------------------------------------------------------
out=$(run_tl FAKE_REFUSE=1 DRY_RUN=0 2>&1); rc=$?
[[ $rc -ne 0 && "$out" == *FATAL*from_not_announced* ]] && pass "a hub refusal is a FATAL with the hub's token" || fail "refusal (rc=$rc): $out"

echo "=== $([[ $fails -eq 0 ]] && echo 'all spl-topic-list.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]
