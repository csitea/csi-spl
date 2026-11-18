#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 180 FR-10 (T5), do_spl_calendar_outlook_tick with a stub box
# link checkout (its ./run queues nothing, it writes a result dir) and the
# import stubbed (the import itself: spl-calendar-import-outlook.tst.sh).
# Synthetic export only.
#   1. no box-local file = no-op, exit 0, nothing queued
#   2. a bad value in the file fails fast, nothing queued
#   3. the window: Mon-Fri 06:30..20:30 Europe/Helsinki, both ends in
#   4. DRY_RUN (the default) queues nothing
#   5. DRY_RUN=0 queues the committed script, imports the result's stdout
#      (CR stripped) for the file's target, deletes the export
#   6. a failed export or no result imports nothing and fails
#   7. a second tick while one holds the lock runs nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

LINK="$T/link" RES="$T/results" CF="$T/outlook-import.env"
mkdir -p "$LINK" "$RES"
# The stub link: records CMD, prints a run id, and writes the result dir
# as the box would (STUB_EXIT, STUB_NORESULT).
cat >"$LINK/run" <<'STUB_RUN'
#!/usr/bin/env bash
printf '%s' "$CMD" >"$CALLS.cmd"; echo "queue $2 $LABEL $CWD $TIMEOUT" >>"$CALLS"
id=0123456789ab
[[ "${STUB_NORESULT:-0}" == 1 ]] || {
  mkdir -p "$RES/$id"; printf '{"format":"spool-hub-outlook-export/1","events":[]}\r\n' >"$RES/$id/stdout.txt"
  printf '{"id":"%s","exit":%s}' "$id" "${STUB_EXIT:-0}" >"$RES/$id/result.json"; }
echo "OK queued cmd-$id.zip"
STUB_RUN
chmod +x "$LINK/run"
printf '%s\n' "OUTLOOK_IMPORT_LINK_HOME=$LINK" OUTLOOK_IMPORT_LINK_ACTION=run-on-box "OUTLOOK_IMPORT_LINK_RESULTS=$RES" \
  OUTLOOK_IMPORT_TARGET_ENV=prd OUTLOOK_IMPORT_TENANT=csitea OUTLOOK_IMPORT_OWNER=HUM-10 >"$CF"
MON0630=$(date -d '2027-02-01T04:30:00Z' +%s)   # Monday 06:30 Europe/Helsinki

run() {
  : >"$T/calls"; rm -f "$T/calls.cmd" "$T/calls.file"
  env PROJ_PATH="$PROJ_ROOT" CALLS="$T/calls" RES="$RES" OUTLOOK_IMPORT_STATE="$T/state" OUTLOOK_IMPORT_POLL_S=1 \
    OUTLOOK_IMPORT_NOW="$MON0630" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_calendar_import_outlook() {
      echo "import $ENV $TENANT_ID $EVENT_OWNER dry=$DRY_RUN" >>"$CALLS"; cp "$IMPORT_FILE" "$CALLS.file"; echo "$IMPORT_FILE" >"$CALLS.tmp"
      echo "created=0 updated=15 unchanged=0 deleted=0"; }
    do_spl_calendar_outlook_tick' >"$T/o" 2>&1
}

# --- 1. no file ---------------------------------------------------------------
run OUTLOOK_IMPORT_ENV="$T/none.env" DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'OK no box link configured' "$T/o" \
  && pass "1. no box-local file: no-op, exit 0, nothing queued" || fail "1. no file: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 2. fail fast ---------------------------------------------------------------
for bad in OUTLOOK_IMPORT_TARGET_ENV=stg OUTLOOK_IMPORT_TENANT=W_1 OUTLOOK_IMPORT_OWNER=c-042 "OUTLOOK_IMPORT_LINK_ACTION=a;b" \
           OUTLOOK_IMPORT_LINK_HOME="$T/nolink" OUTLOOK_IMPORT_DAYS=x DRY_RUN=yes; do
  run OUTLOOK_IMPORT_ENV="$CF" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q FATAL "$T/o" && pass "2. ${bad%%=*} bad: fails fast, nothing queued" || fail "2. $bad: rc=$rc $(cat "$T/calls" "$T/o")"
done

# --- 3. the window --------------------------------------------------------------
for c in "0:in Mon 06:30" "-60:out Mon 06:29" "50400:in Mon 20:30" "50460:out Mon 20:31" \
         "345600:in Fri 06:30" "432000:out Sat 06:30" "518400:out Sun 06:30"; do
  off="${c%%:*}" want="${c#*:}"; want="${want%% *}"
  run OUTLOOK_IMPORT_ENV="$CF" OUTLOOK_IMPORT_NOW=$((MON0630 + off)); rc=$?
  if [[ "$want" == in ]]; then grep -q 'OK DRY_RUN would queue' "$T/o"; else grep -q 'OK outside the sync window' "$T/o"; fi \
    && [[ $rc -eq 0 ]] && pass "3. ${c#*:} Helsinki: $want" || fail "3. $c: rc=$rc $(cat "$T/o")"
done
run OUTLOOK_IMPORT_ENV="$CF" OUTLOOK_IMPORT_NOW=$((MON0630 + 432000)) OUTLOOK_IMPORT_ANYTIME=1; rc=$?
[[ $rc -eq 0 ]] && grep -q 'OK DRY_RUN would queue' "$T/o" && pass "3. OUTLOOK_IMPORT_ANYTIME=1 runs outside the window" || fail "3. anytime: $(cat "$T/o")"

# --- 4. dry run -----------------------------------------------------------------
run OUTLOOK_IMPORT_ENV="$CF"; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'OK DRY_RUN would queue the export (.* bytes, -Days 14) through the box link, then import it into csitea (prd) for HUM-10; queued nothing' "$T/o" \
  && pass "4. DRY_RUN (default) queues nothing" || fail "4. dry: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 5. the tick ----------------------------------------------------------------
run OUTLOOK_IMPORT_ENV="$CF" DRY_RUN=0; rc=$?
ps1="$PROJ_ROOT/src/powershell/outlook-calendar-export.ps1"
[[ $rc -eq 0 ]] && grep -qx 'queue run-on-box spl-outlook-export /tmp 300' "$T/calls" && grep -qx 'import prd csitea HUM-10 dry=0' "$T/calls" \
  && [[ "$(cat "$T/calls.file")" == '{"format":"spool-hub-outlook-export/1","events":[]}' ]] \
  && [[ ! -e "$RES/0123456789ab/stdout.txt" && ! -e "$(cat "$T/calls.tmp")" ]] \
  && grep -q 'OK Outlook sync tick: run 0123456789ab imported, export deleted' "$T/o" \
  && pass "5. DRY_RUN=0 queues, imports the CR-stripped stdout for prd/csitea/HUM-10, deletes the export" || fail "5. tick: rc=$rc $(cat "$T/calls" "$T/o")"
body="$(sed -n "/<<'SPL_PS1_EOF'\$/,/^SPL_PS1_EOF\$/p" "$T/calls.cmd" | sed '1d;$d')"
[[ "$body" == "$(cat "$ps1")" ]] && grep -q -- '-File "${WT}spl-outlook-export.ps1" -Days 14 -OutFile STDOUT$' "$T/calls.cmd" && bash -n "$T/calls.cmd" \
  && pass "5. the remote shell carries the committed script verbatim, runs it -Days 14 -OutFile STDOUT, parses" || fail "5. cmd: $(head -c 400 "$T/calls.cmd")"
run OUTLOOK_IMPORT_ENV="$CF" DRY_RUN=0 OUTLOOK_IMPORT_DRY=1; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'import prd csitea HUM-10 dry=1' "$T/calls" && pass "5. OUTLOOK_IMPORT_DRY=1 imports with DRY_RUN=1" || fail "5. dry import: $(cat "$T/calls")"

# --- 6. failures ----------------------------------------------------------------
rm -rf "${RES:?}"/*
run OUTLOOK_IMPORT_ENV="$CF" DRY_RUN=0 STUB_EXIT=1; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^import' "$T/calls" && [[ ! -e "$RES/0123456789ab/stdout.txt" ]] && grep -q 'FATAL the export on the Outlook box failed (run 0123456789ab, exit 1)' "$T/o" \
  && pass "6. a failed export imports nothing, its stdout deleted" || fail "6. exit 1: rc=$rc $(cat "$T/calls" "$T/o")"
rm -rf "${RES:?}"/*
run OUTLOOK_IMPORT_ENV="$CF" DRY_RUN=0 STUB_NORESULT=1 OUTLOOK_IMPORT_WAIT_S=1; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^import' "$T/calls" && grep -q 'FATAL no result for run 0123456789ab after 1s' "$T/o" \
  && pass "6. no result in time imports nothing" || fail "6. no result: rc=$rc $(cat "$T/calls" "$T/o")"

# --- 7. the lock ----------------------------------------------------------------
mkdir -p "$T/state"; exec 9>"$T/state/outlook-import.lock"; flock -n 9
run OUTLOOK_IMPORT_ENV="$CF" DRY_RUN=0; rc=$?
exec 9>&-
[[ $rc -eq 0 && ! -s "$T/calls" ]] && grep -q 'another Outlook sync tick holds the lock' "$T/o" \
  && pass "7. a held lock: the tick runs nothing" || fail "7. lock: rc=$rc $(cat "$T/calls" "$T/o")"

(( fails == 0 )) && echo "ALL PASS: spl-calendar-outlook-tick" || { echo "FAILED: $fails"; exit 1; }
