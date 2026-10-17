#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-06: orphaned process & detached worker advisory (SPL-2445)
# Tests do_fleet_orphan_process_reap against simulated /proc and temp dirs;
# the live box is untouched.
#   1. Clean system (0 orphans) -> exits 0, OK log, no note sent, no stamp
#   2. Planted orphan with retired AGENT_ID in environ, DRY_RUN=1 -> exits 1,
#      PLAN note only, no note sent, no stamp written
#   3. Planted orphan with deleted worktree cwd ((deleted)), DRY_RUN=1 -> exits 1,
#      flagged by provenance deleted-worktree:...
#   4. Planted orphan with BOTH retired AGENT_ID and deleted cwd -> exits 1,
#      both provenances recorded
#   5. Active agent process (AGENT_ID not in retired registry, cwd not deleted) ->
#      exits 0, 0 false alerts, live agent preserved
#   6. Live daemon on never-list: tmux server and clients -> exits 0, ignored
#   7. Live daemon on never-list: systemd and (sd-pam) -> exits 0, ignored
#   8. Live daemon on never-list: do_spl_watchdog -> exits 0, ignored
#   9. Live daemon on never-list: runner listeners (Runner.Listener, Runner.Worker, runsvc.sh) ->
#      exits 0, ignored
#  10. Planted orphan with DRY_RUN=0 -> exits 1, sends structured spool note,
#      creates stamp file
#  11. Throttling by stamp file -> exits 1, duplicate note suppressed within throttle window
#  12. Throttling expired -> exits 1, alert fires again once throttle duration has expired
#  13. Alert unthrottled when orphan count changes -> exits 1, note sent immediately
#  14. System recovery in DRY_RUN=0 -> exits 0, clears existing stamp file
#  15. Failed send does not write stamp file -> exits 1, logs failure, no stamp
#  16. Machine-readable --json output -> parses valid JSON array with quoted arguments
#  17. Both action names (do_fleet_orphan_process_reap and do_orphan_process_reap)
#      work end-to-end through csi-spl-utl ./run
#  18. Default sender resolution -> repo-relative spool-send.sh used from orphan-process-advisory@<box>
#  19. Agent ID reuse guard: id in both registry.retired.tsv and active registry.tsv ->
#      exits 0, 0 false alerts, live lane preserved
#  20. Deleted cwds outside worktree root (/tmp/...) -> exits 0, not falsely flagged
#  21. LIVE GUARD -> every probe used temp proc dir and temp registry; zero host calls leaked
#  22. Red controls -> simulated regressions turn gates red: retired gate flags active lane,
#      dropped never-list flags tmux, external sender triggers LIVE GUARD intercept,
#      and never-list substring argument (tmux-health-guard.tst.sh) does not false-spare.
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/orphan-process-reap.func.sh"

T=$(mktemp -d /tmp/opr.XXXXXX)
chmod 777 "$T"
BIN="$T/bin" STATE="$T/state" PROC="$T/proc" CNF="$T/cnf" LOGS="$T/log"
SENT="$T/sent.log" LIVE_LOG="$T/live-calls.log" SENTINEL_LOG="$T/sentinel.log"
RETIRED_TSV="$CNF/registry.retired.tsv"
ACTIVE_TSV="$CNF/registry.tsv"
STAMP="$STATE/alert.stamp"

mkdir -p "$BIN" "$STATE" "$PROC" "$CNF" "$LOGS"
chmod -R 777 "$T"
: >"$SENT"; : >"$LIVE_LOG"; : >"$SENTINEL_LOG"

cleanup() {
  if [[ -n "${T:-}" && -d "$T" ]]; then
    rm -rf "$T"
  fi
}
trap cleanup EXIT

# Export T and LIVE_LOG so all subprocesses and stubs inherit them
export T LIVE_LOG

# Stub binaries
cat >"$BIN/send-stub" <<'SEOF'
#!/bin/bash
printf 'SEND %s\n' "$*" >>"${SENT_LOG_FILE:-/dev/null}"
exit 0
SEOF

cat >"$BIN/send-fail" <<'SEOF'
#!/bin/bash
exit 1
SEOF

cat >"$BIN/bash" <<BEOF
#!/bin/bash
for a in "\$@"; do
  if [[ "\$a" == */spool-send.sh && "\$a" != "$T"/* ]]; then
    printf 'bash %s\n' "\$*" >>"$LIVE_LOG"; exit 97
  fi
done
exec /bin/bash "\$@"
BEOF

cat >"$BIN/spool" <<BEOF
#!/bin/bash
printf 'spool %s\n' "\$*" >>"$LIVE_LOG"; exit 97
BEOF

chmod +x "$BIN"/*

export PATH="$BIN:$PATH"
export SENT_LOG_FILE="$SENT"
export SENTINEL_LOG="$SENTINEL_LOG"
export ORPHAN_PROC_DIR="$PROC"
export ORPHAN_ACTIVE_REGISTRY="$ACTIVE_TSV"
export ORPHAN_RETIRED_REGISTRY="$RETIRED_TSV"
export ORPHAN_WT_ROOT="/opt/csi/csi-spl-wt"
export ORPHAN_PROCESS_STATE_DIR="$STATE"
export ORPHAN_PROCESS_SEND_CMD="$BIN/send-stub"
export PROJ_PATH="$UTL_ROOT"
export DEV_BOX="PC"
unset SPOOL_AGENT_ID ORPHAN_PROCESS_ALERT_FROM

# Helper to plant a mock process in $PROC
plant_proc() {
  local pid="$1" comm="$2" cmdline="$3" agent="$4" cwd="$5" ppid="${6:-1}"
  local pdir="$PROC/$pid"
  mkdir -p "$pdir"
  echo "$comm" > "$pdir/comm"
  printf '%s\0' "$cmdline" > "$pdir/cmdline"
  echo "$pid ($comm) S $ppid 0 0 0 0" > "$pdir/stat"
  if [[ -n "$agent" ]]; then
    printf 'AGENT_ID=%s\0PATH=/bin\0' "$agent" > "$pdir/environ"
  else
    printf 'PATH=/bin\0USER=test\0' > "$pdir/environ"
  fi
  if [[ -n "$cwd" ]]; then
    ln -s "$cwd" "$pdir/cwd"
  fi
  chmod -R 777 "$pdir"
}

clear_procs() {
  find "$PROC" -mindepth 1 -delete 2>/dev/null || true
}

# Helper to execute check
run_check() {
  local dry="${1:-1}"
  shift || true
  # shellcheck disable=SC1090
  (
    source "$FUNC_SH"
    DRY_RUN="$dry" do_fleet_orphan_process_reap "$@"
  )
}

# Seed retired and active registry TSVs
cat >"$RETIRED_TSV" <<'REOF'
# retired agent registry
c-004	claude	%5	/opt/csi/csi-spl-wt/c-004	20261002T080000Z	20261002T120000Z
a-100@sat	agy	%2	/opt/csi/csi-spl-wt/a-100	20261010T080000Z	20261010T120000Z
m-200	mistral	%3	/opt/csi/csi-spl-wt/m-200	20261012T080000Z	20261012T120000Z
REOF

cat >"$ACTIVE_TSV" <<'AEOF'
# active agent registry
a-779	agy	%1	/opt/csi/csi-spl-wt/a-779	20261018T000000Z
c-500	claude	%4	/opt/csi/csi-spl-wt/c-500	20261018T000000Z
AEOF

chmod -R 777 "$T"

# ---- 1. Clean system (0 orphans) --------------------------------------------
clear_procs
plant_proc 101 "bash" "bash ./run" "test-lane-999" "/opt/csi/csi-spl-wt/a-779" 1
plant_proc 102 "node" "node server.js" "" "/var/tmp/project" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 1 2>&1); rc=$?
if ((rc == 0)) && [[ "$out" == *"orphan-process OK: 0 orphan processes found"* ]] && [[ ! -f "$STAMP" && ! -s "$SENT" ]]; then
  pass "1. Clean system: exits 0, OK log, no alert, no stamp"
else
  fail "1. Clean system (rc=$rc out=$out)"
fi

# ---- 2. Planted orphan with retired AGENT_ID in environ (DRY_RUN=1) ----------
clear_procs
plant_proc 201 "node" "node serve-generated.mjs" "c-004" "/tmp/scratch" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 1 2>&1); rc=$?
if ((rc == 1)) && [[ "$out" == *"orphan-process ADVISORY: 1 orphan process(es) detected"* ]] \
   && [[ "$out" == *"orphan pid=201"*"provenance=retired-agent:c-004"* ]] \
   && [[ "$out" == *"PLAN note to orchestrator on task orphan-process:"* ]] \
   && [[ ! -f "$STAMP" && ! -s "$SENT" ]]; then
  pass "2. Planted orphan with retired AGENT_ID: DRY_RUN=1 exits 1, PLAN note only, no note sent, no stamp"
else
  fail "2. Retired AGENT_ID dry run (rc=$rc out=$out)"
fi

# ---- 3. Planted orphan with deleted worktree cwd ((deleted)) -----------------
clear_procs
plant_proc 202 "python3" "python3 worker.py" "" "/opt/csi/csi-spl-wt/old-lane (deleted)" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 1 2>&1); rc=$?
if ((rc == 1)) && [[ "$out" == *"orphan-process ADVISORY: 1 orphan process(es) detected"* ]] \
   && [[ "$out" == *"orphan pid=202"*"provenance=deleted-worktree:/opt/csi/csi-spl-wt/old-lane (deleted)"* ]]; then
  pass "3. Planted orphan with deleted worktree cwd: flagged by provenance deleted-worktree"
else
  fail "3. Deleted worktree cwd (rc=$rc out=$out)"
fi

# ---- 4. Planted orphan with BOTH retired AGENT_ID and deleted cwd -----------
clear_procs
plant_proc 203 "tee" "tee pre-push.log" "m-200" "/opt/csi/csi-spl-wt/m-200 (deleted)" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 1 2>&1); rc=$?
if ((rc == 1)) && [[ "$out" == *"orphan pid=203"* ]] \
   && [[ "$out" == *"retired-agent:m-200"* && "$out" == *"deleted-worktree:"* ]]; then
  pass "4. Planted orphan with BOTH retired AGENT_ID and deleted cwd: both provenances recorded"
else
  fail "4. Dual provenance (rc=$rc out=$out)"
fi

# ---- 5. Active agent process preserved ---------------------------------------
clear_procs
plant_proc 204 "bash" "bash ./run -a do_work" "test-lane-999" "/opt/csi/csi-spl-wt/a-779" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 1 2>&1); rc=$?
if ((rc == 0)) && [[ "$out" == *"orphan-process OK: 0 orphan processes found"* ]]; then
  pass "5. Active agent process (not in retired registry, cwd intact): exits 0, 0 false alerts"
else
  fail "5. Active agent preserved (rc=$rc out=$out)"
fi

# ---- 6. Live daemon on never-list: tmux --------------------------------------
clear_procs
plant_proc 301 "tmux: server" "tmux -S /tmp/tmux-1000/default" "c-004" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
plant_proc 302 "tmux" "tmux list-sessions" "c-004" "/tmp (deleted)" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 1 2>&1); rc=$?
if ((rc == 0)) && [[ "$out" == *"orphan-process OK: 0 orphan processes found"* ]]; then
  pass "6. Live daemon on never-list (tmux server & client): preserved with 0 false alerts"
else
  fail "6. Tmux never-list (rc=$rc out=$out)"
fi

# ---- 7. Live daemon on never-list: systemd and (sd-pam) ---------------------
clear_procs
plant_proc 303 "systemd" "/usr/lib/systemd/systemd --user" "c-004" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
plant_proc 304 "systemd-timesyn" "/usr/lib/systemd/systemd-timesyncd" "" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
plant_proc 305 "(sd-pam)" "(sd-pam)" "" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 1 2>&1); rc=$?
if ((rc == 0)) && [[ "$out" == *"orphan-process OK: 0 orphan processes found"* ]]; then
  pass "7. Live daemon on never-list (systemd, timesyncd, sd-pam): preserved with 0 false alerts"
else
  fail "7. Systemd never-list (rc=$rc out=$out)"
fi

# ---- 8. Live daemon on never-list: do_spl_watchdog ---------------------------
clear_procs
plant_proc 306 "spl-watchdog" "bash /opt/csi/csi-spl/run -a do_spl_watchdog" "c-004" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 1 2>&1); rc=$?
if ((rc == 0)) && [[ "$out" == *"orphan-process OK: 0 orphan processes found"* ]]; then
  pass "8. Live daemon on never-list (do_spl_watchdog): preserved with 0 false alerts"
else
  fail "8. Watchdog never-list (rc=$rc out=$out)"
fi

# ---- 9. Live daemon on never-list: runner listeners --------------------------
clear_procs
plant_proc 307 "Runner.Listener" "./bin/Runner.Listener run" "c-004" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
plant_proc 308 "Runner.Worker" "./bin/Runner.Worker spawnJob" "c-004" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
plant_proc 309 "bash" "bash runsvc.sh" "c-004" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 1 2>&1); rc=$?
if ((rc == 0)) && [[ "$out" == *"orphan-process OK: 0 orphan processes found"* ]]; then
  pass "9. Live daemon on never-list (Runner.Listener, Worker, runsvc.sh): preserved with 0 false alerts"
else
  fail "9. Runner listeners never-list (rc=$rc out=$out)"
fi

# ---- 10. Planted orphan with DRY_RUN=0 ---------------------------------------
clear_procs
plant_proc 201 "node" "node serve-generated.mjs" "c-004" "/tmp/test" 1
rm -f "$STAMP" "$SENT"

out=$(run_check 0 2>&1); rc=$?
if ((rc == 1)) && [[ -f "$STAMP" ]] && [[ -s "$SENT" ]] \
   && grep -q -- "--to orchestrator --kind note --task orphan-process --no-poke" "$SENT" \
   && grep -q "orphan-process ADVISORY on PC: 1 orphaned runner process(es) detected" "$SENT" \
   && read -r s_count _ <"$STAMP" && [[ "$s_count" == 1 ]]; then
  pass "10. Planted orphan in DRY_RUN=0: exits 1, sends structured note, creates stamp file"
else
  fail "10. Real alert run (rc=$rc sent=$(cat "$SENT" 2>/dev/null) out=$out)"
fi

# ---- 11. Throttling by stamp file --------------------------------------------
: >"$SENT"
out=$(run_check 0 2>&1); rc=$?
if ((rc == 1)) && [[ ! -s "$SENT" ]] && [[ "$out" == *"orphan-process advisory throttled by"* ]]; then
  pass "11. Throttling: duplicate alert suppressed within throttle window"
else
  fail "11. Throttling (rc=$rc sent=$(cat "$SENT" 2>/dev/null) out=$out)"
fi

# ---- 12. Throttling expired --------------------------------------------------
: >"$SENT"
past_time=$(( $(date +%s) - 2500 ))
echo "1 $past_time" > "$STAMP"

out=$(run_check 0 2>&1); rc=$?
if ((rc == 1)) && [[ -s "$SENT" ]] && grep -q "orphan-process ADVISORY" "$SENT"; then
  pass "12. Throttling expired: alert sent again after throttle duration"
else
  fail "12. Throttling expired (rc=$rc sent=$(cat "$SENT" 2>/dev/null) out=$out)"
fi

# ---- 13. Alert unthrottled when orphan count changes -------------------------
: >"$SENT"
echo "1 $(date +%s)" > "$STAMP"
# Add a second orphan
plant_proc 202 "tail" "tail -f log" "a-100@sat" "/tmp/scratch" 1

out=$(run_check 0 2>&1); rc=$?
if ((rc == 1)) && [[ -s "$SENT" ]] && grep -q "2 orphaned runner process(es) detected" "$SENT" \
   && read -r s_count _ <"$STAMP" && [[ "$s_count" == 2 ]]; then
  pass "13. Count change: alert fires immediately when new orphan is detected"
else
  fail "13. Count change (rc=$rc sent=$(cat "$SENT" 2>/dev/null) out=$out)"
fi

# ---- 14. System recovery in DRY_RUN=0 ----------------------------------------
clear_procs
plant_proc 101 "bash" "bash ./run" "test-lane-999" "/opt/csi/csi-spl-wt/a-779" 1
out=$(run_check 0 2>&1); rc=$?
if ((rc == 0)) && [[ ! -f "$STAMP" ]] && [[ "$out" == *"orphan-process OK: 0 orphan processes found"* ]]; then
  pass "14. System recovery in DRY_RUN=0: exits 0 and removes stamp file"
else
  fail "14. System recovery (rc=$rc stamp_exists=$(test -f "$STAMP" && echo 1 || echo 0) out=$out)"
fi

# ---- 15. Failed send does not write stamp file -------------------------------
clear_procs
plant_proc 201 "node" "node serve.js" "c-004" "/tmp/test" 1
rm -f "$STAMP" "$SENT"

out=$(ORPHAN_PROCESS_SEND_CMD="$BIN/send-fail" run_check 0 2>&1); rc=$?
if ((rc == 1)) && [[ ! -f "$STAMP" ]] && [[ "$out" == *"the note to orchestrator failed"* ]]; then
  pass "15. Failed send: logs failure and does not write stamp file"
else
  fail "15. Failed send stamp prevention (rc=$rc out=$out)"
fi

# ---- 16. Machine-readable --json output with quoted and escaped arguments ----
clear_procs
plant_proc 201 "node" "node -e 'console.log(\"hello world\")'" "c-004" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
json_out=$(run_check 1 --json); rc=$?
json_valid=$(python3 -c "import json, sys; d=json.loads(sys.stdin.read()); print(len(d) == 1 and d[0]['pid'] == 201 and d[0]['agent_id'] == 'c-004' and 'hello world' in d[0]['cmdline'])" <<<"$json_out" 2>/dev/null || echo "False")

if ((rc == 1)) && [[ "$json_valid" == "True" ]]; then
  pass "16. Machine-readable --json outputs strictly valid JSON containing escaped quotes and correct types"
else
  fail "16. JSON output (rc=$rc valid=$json_valid out=$json_out)"
fi

# ---- 17. Both action names work via ./run ------------------------------------
clear_procs
plant_proc 101 "bash" "bash ./run" "test-lane-999" "/opt/csi/csi-spl-wt/a-779" 1
chmod -R 777 "$T"
o1=$(cd "$UTL_ROOT" && DRY_RUN=1 ORPHAN_PROC_DIR="$PROC" ORPHAN_ACTIVE_REGISTRY="$ACTIVE_TSV" ORPHAN_RETIRED_REGISTRY="$RETIRED_TSV" ORPHAN_PROCESS_STATE_DIR="$STATE" ./run -a do_fleet_orphan_process_reap 2>&1); r1=$?
o2=$(cd "$UTL_ROOT" && DRY_RUN=1 ORPHAN_PROC_DIR="$PROC" ORPHAN_ACTIVE_REGISTRY="$ACTIVE_TSV" ORPHAN_RETIRED_REGISTRY="$RETIRED_TSV" ORPHAN_PROCESS_STATE_DIR="$STATE" ./run -a do_orphan_process_reap 2>&1); r2=$?
if ((r1 == 0 && r2 == 0)) && [[ "$o1" == *"orphan-process OK: 0 orphan processes found"* ]] \
   && [[ "$o2" == *"orphan-process OK: 0 orphan processes found"* ]]; then
  pass "17. Both do_fleet_orphan_process_reap and do_orphan_process_reap succeed via ./run"
else
  fail "17. Action names via ./run (r1=$r1 r2=$r2 o1=$o1 o2=$o2)"
fi

# ---- 18. Default sender resolution -------------------------------------------
FAKE="$T/fake-repo/csi-spl-utl"
mkdir -p "$FAKE" "$T/fake-repo/csi-spl-orc/src/bash/features/spawn-agents/scripts"
cat >"$T/fake-repo/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" <<'FEOF'
#!/bin/bash
printf 'SENTINEL %s\n' "$*" >>"${SENTINEL_LOG}"
exit 0
FEOF
chmod +x "$T/fake-repo/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
chmod -R 777 "$T"

clear_procs
plant_proc 201 "node" "node serve.js" "c-004" "/tmp/test" 1
rm -f "$STAMP"
: >"$SENTINEL_LOG"

out=$(PROJ_PATH="$FAKE" ORPHAN_PROCESS_SEND_CMD="" run_check 0 2>&1); rc=$?
if ((rc == 1)) && grep -q -- "--from orphan-process-advisory@PC --to orchestrator --kind note --task orphan-process --no-poke" "$SENTINEL_LOG"; then
  pass "18. Default sender: repo-relative spool-send.sh used from orphan-process-advisory@<box>"
else
  fail "18. Default sender (rc=$rc sentinel=$(cat "$SENTINEL_LOG" 2>/dev/null) out=$out)"
fi

# ---- 19. Agent ID reuse guard: id in both registry.retired.tsv and registry.tsv
clear_procs
# Seed c-385 in both retired and active registry (simulating past retirement and current live reuse)
echo -e "c-385\tclaude\t%4\t/opt/csi/csi-spl-wt/c-385\t20261006T080000Z\t20261006T120000Z" >> "$RETIRED_TSV"
echo -e "c-385\tclaude\t%4\t/opt/csi/csi-spl-wt/c-385\t20261017T080000Z" >> "$ACTIVE_TSV"
# Plant running process tree of active c-385
plant_proc 401 "tee" "tee pre-push.log" "c-385" "/opt/csi/csi-spl-wt/c-385" 100
plant_proc 402 "bash" "bash ./run -a do_check_pre_push" "c-385" "/opt/csi/csi-spl-wt/c-385" 401

out=$(run_check 1 2>&1); rc=$?
# Clean up c-385 from registries
sed -i '/^c-385/d' "$RETIRED_TSV"
sed -i '/^c-385/d' "$ACTIVE_TSV"

if ((rc == 0)) && [[ "$out" == *"orphan-process OK: 0 orphan processes found"* ]]; then
  pass "19. Agent ID reuse guard: reused ID present in both retired and active registry is not flagged"
else
  fail "19. Agent ID reuse guard (rc=$rc out=$out)"
fi

# ---- 20. Deleted cwds outside worktree root (/tmp/...) ----------------------
clear_procs
# Process running in a deleted temporary test directory outside worktree
plant_proc 501 "python3" "python3 test.py" "test-lane-999" "/tmp/csi-spl-pre-push-base.123 (deleted)" 1
plant_proc 502 "cat" "cat scratch.txt" "" "/tmp/scratch (deleted)" 1

out=$(run_check 1 2>&1); rc=$?
if ((rc == 0)) && [[ "$out" == *"orphan-process OK: 0 orphan processes found"* ]]; then
  pass "20. Deleted non-worktree cwds (/tmp/* (deleted)): preserved with 0 false alerts"
else
  fail "20. Deleted non-worktree cwd (rc=$rc out=$out)"
fi

# ---- 21. LIVE GUARD ----------------------------------------------------------
bad_calls=$(cat "$LIVE_LOG")
if [[ -z "$bad_calls" ]]; then
  pass "21. LIVE GUARD: zero live host calls reached outside temp dir"
else
  fail "21. LIVE GUARD: detected live host calls: $bad_calls"
fi

# ---- 22. Red controls (simulated regressions) --------------------------------
# 22a: Seeding active lane in retired registry (and NOT active) turns case 5 red
echo -e "test-lane-999\tagy\t%1\t/opt/csi/csi-spl-wt/a-779\t20261018T000000Z\t20261018T010000Z" >> "$RETIRED_TSV"
sed -i '/^a-779/d' "$ACTIVE_TSV"
clear_procs
plant_proc 204 "bash" "bash ./run" "test-lane-999" "/tmp/test" 1
out_red_ret=$(run_check 1 2>&1); rc_red_ret=$?; [[ -n "$out_red_ret" ]] || true
# Restore clean registries
sed -i "/^test-lane-999/d" "$RETIRED_TSV"
echo -e "test-lane-999\tagy\t%1\t/opt/csi/csi-spl-wt/a-779\t20261018T000000Z" >> "$ACTIVE_TSV"

# 22b: Dropping never-list flags tmux (turns case 6 red)
# shellcheck disable=SC2034
red_tmux_out=$(
  # shellcheck disable=SC1090
  source "$FUNC_SH"
  # shellcheck disable=SC2317
  orphan_process_is_never_listed() { return 1; }
  clear_procs
  plant_proc 301 "tmux: server" "tmux -S /tmp/tmux-1000/default" "c-004" "/opt/csi/csi-spl-wt/c-004 (deleted)" 1
  do_fleet_orphan_process_reap
)
rc_red_tmux=$?

# 22c: LIVE GUARD red control: external spool-send outside $T triggers exit 97 in $BIN/bash stub
EXT_DIR=$(mktemp -d /tmp/opr-ext.XXXXXX)
mkdir -p "$EXT_DIR/csi-spl-utl" "$EXT_DIR/csi-spl-orc/src/bash/features/spawn-agents/scripts"
cat >"$EXT_DIR/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh" <<'XEOF'
#!/bin/bash
printf 'EXT-UNGUARDED\n' >>"$LIVE_LOG"
exit 0
XEOF
chmod +x "$EXT_DIR/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh"
chmod -R 777 "$EXT_DIR"

clear_procs
plant_proc 201 "node" "node serve.js" "c-004" "/tmp/test" 1
rm -f "$STAMP"
: >"$LIVE_LOG"
# shellcheck disable=SC2034
red_guard_out=$(PROJ_PATH="$EXT_DIR/csi-spl-utl" ORPHAN_PROCESS_SEND_CMD="" run_check 0 2>&1); rc_red_guard=$?
guard_intercepted=0
if [[ "$rc_red_guard" -ne 0 ]] && grep -q "bash .*spool-send.sh" "$LIVE_LOG" && ! grep -q "EXT-UNGUARDED" "$LIVE_LOG"; then
  guard_intercepted=1
fi
rm -rf "$EXT_DIR"
: >"$LIVE_LOG"

# 22d: Never-list substring guard: process running test mentioning *tmux* in arguments is NOT spared
clear_procs
plant_proc 205 "bash" "bash /opt/csi/csi-spl-utl/src/bash/tests/tmux-health-guard.tst.sh" "c-004" "/tmp/test" 1
out_sub=$(run_check 1 2>&1); rc_sub=$?; [[ -n "$out_sub" ]] || true

if ((rc_red_ret == 1 && rc_red_tmux == 1 && guard_intercepted == 1 && rc_sub == 1)); then
  pass "22. Red controls: retired gate flags active lane (exit 1), dropped never-list flags tmux (exit 1), external sender triggers LIVE GUARD intercept (exit 97), and never-list substring in arguments does not spare orphan (exit 1)"
else
  fail "22. Red controls failed (rc_red_ret=$rc_red_ret rc_red_tmux=$rc_red_tmux guard_intercepted=$guard_intercepted rc_sub=$rc_sub)"
fi

echo "=========================================="
echo "orphan-process-reap: $fails failure(s)"
echo "=========================================="
[[ "$fails" -eq 0 ]]
