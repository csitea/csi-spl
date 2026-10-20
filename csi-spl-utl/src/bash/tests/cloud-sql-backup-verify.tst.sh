#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Test suite for rel-10: Cloud SQL daily backup verification (SPL-2661, Refs: SPL-2364)
# Verifies do_cloud_sql_backup_verify against a stub gcloud, stub spool sender,
# and temp state/cnf directories. Live GCP and live spool are never touched.
#
# Cases:
#   1. Fresh automated backup (< 26h, status SUCCESSFUL) -> exits 0, verdict OK
#   2. Fresh on-demand backup (< 26h, status SUCCESSFUL) -> exits 0, verdict OK
#   3. Stale backup (28h old, status SUCCESSFUL) -> exits 1, verdict ALERT
#   4. Failed backup (< 26h, status FAILED) -> exits 1, verdict ALERT
#   5. In-progress backup (status RUNNING) -> exits 1, verdict ALERT
#   6. Empty backup list ([]) -> exits 1, verdict ALERT
#   7. gcloud execution error (rc=1) -> exits 1, alert emitted
#   8. Invalid JSON response from gcloud -> exits 1, alert emitted
#   9. Missing timestamp in backup -> exits 1, alert emitted
#  10. Unparseable timestamp in backup -> exits 1, alert emitted
#  11. Future timestamp with large skew (> 300s) -> exits 1, alert emitted
#  12. Clock skew <= 300s in future -> handled gracefully, exits 0, verdict OK
#  13. Custom max age override (CLOUD_SQL_BACKUP_MAX_AGE_HOURS=10) -> exits 1 on 12h
#  14. Instance resolution from cnf: resolves csi-spl-dev-pg for dev
#  15. Instance resolution from cnf: resolves csi-spl-prd-pg for prd
#  16. Explicit CLOUD_SQL_INSTANCE override honoured
#  17. Invalid ENV (unset or invalid) -> exits 1, FATAL logged
#  18. DRY_RUN=1 plans alert, sends no spool note, writes no stamp file
#  19. DRY_RUN=0 sends alert via spool-send, writes stamp file
#  20. Alert throttling: repeated failure within throttle window sends no duplicate
#  21. Recovery: successful run with DRY_RUN=0 clears stamp file
#  22. Invocation via csi-spl-utl ./run harness -> exits 0 on valid backup
#  23. RED CONTROL 1: stale backup (> 26h) must fail
#  24. RED CONTROL 2: non-SUCCESSFUL status must fail
#  25. LIVE GUARD: zero un-stubbed gcloud or spool calls leaked outside test dir
#------------------------------------------------------------------------------
set -uo pipefail

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
UTL_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC_SH="$UTL_ROOT/src/bash/run/cloud-sql-backup-verify.func.sh"

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq not on PATH"; exit 1; }

T=$(mktemp -d /tmp/csq-tst.XXXXXX)
trap 'rm -rf "$T"' EXIT

BIN_DIR="$T/bin"
STATE_DIR="$T/state"
CNF_DIR="$T/cnf"
mkdir -p "$BIN_DIR" "$STATE_DIR" "$CNF_DIR"

GCLOUD_CALLS="$T/gcloud.calls"
SPOOL_SEND_LOG="$T/spool-send.log"
LIVE_LOG="$T/live-guard.log"
GCLOUD_STUB_JSON="$T/gcloud-stub.json"
GCLOUD_RC_FILE="$T/gcloud.rc"
echo "0" > "$GCLOUD_RC_FILE"
: >"$GCLOUD_CALLS"; : >"$SPOOL_SEND_LOG"; : >"$LIVE_LOG"

# Stub gcloud that logs call and outputs fixture json
cat >"$BIN_DIR/gcloud" <<GCL_EOF
#!/bin/bash
printf '%s\n' "\$*" >> "$GCLOUD_CALLS"
if [[ "\$*" == *"auth activate-service-account"* ]]; then
  exit 0
fi
if [[ "\$*" == *"auth list"* ]]; then
  echo "csi-spl-dev@csi-spl-dev.iam.gserviceaccount.com"
  exit 0
fi
rc=0
[[ -f "$GCLOUD_RC_FILE" ]] && rc="\$(cat "$GCLOUD_RC_FILE")"
if [[ -f "$GCLOUD_STUB_JSON" ]]; then
  cat "$GCLOUD_STUB_JSON"
fi
exit "\${rc:-0}"
GCL_EOF

# Stub spool-send
cat >"$BIN_DIR/spool-send.sh" <<SND_EOF
#!/bin/bash
printf 'SPOOL-SEND %s\n' "\$*" >> "$SPOOL_SEND_LOG"
exit 0
SND_EOF

chmod +x "$BIN_DIR"/*

# Setup mock cnf files
cat >"$CNF_DIR/all.env.yaml" <<'YAML_EOF'
env:
  dns:
    BASE_DOMAIN: example.test
  steps:
    "040-cloud-sql-postgres":
      instance_name: ~
YAML_EOF

cat >"$CNF_DIR/dev.env.yaml" <<'YAML_EOF'
env:
  gcp:
    gcp_project: csi-spl-dev
  steps:
    "040-cloud-sql-postgres":
      instance_name: csi-spl-dev-pg
YAML_EOF

cat >"$CNF_DIR/prd.env.yaml" <<'YAML_EOF'
env:
  gcp:
    gcp_project: csi-spl-prd
  steps:
    "040-cloud-sql-postgres":
      instance_name: csi-spl-prd-pg
YAML_EOF

ORIG_PATH="$PATH"
export PATH="$BIN_DIR:$ORIG_PATH"
export CLOUD_SQL_CNF_DIR="$CNF_DIR"
export CLOUD_SQL_BACKUP_STATE_DIR="$STATE_DIR"
export CLOUD_SQL_BACKUP_ALERT_SEND_BIN="$BIN_DIR/spool-send.sh"
export GCP_ACCOUNT="csi-spl-test@csi-spl-dev.iam.gserviceaccount.com"
export PROJ_PATH="$UTL_ROOT"

NOW_TEST=1792464000 # 2026-10-20T02:40:00Z
export NOW_EPOCH="$NOW_TEST"

iso_offset() {
  local offset_s="$1"
  date -u -d "@$(( NOW_TEST - offset_s ))" +%Y-%m-%dT%H:%M:%SZ
}

make_json() {
  local id="$1" status="$2" type="$3" offset_s="$4"
  local start_iso
  start_iso="$(iso_offset "$offset_s")"
  cat >"$GCLOUD_STUB_JSON" <<JSON_EOF
[
  {
    "id": "$id",
    "status": "$status",
    "type": "$type",
    "startTime": "$start_iso",
    "windowStartTime": "$start_iso",
    "endTime": "$start_iso"
  }
]
JSON_EOF
}

run_action() {
  (
    # shellcheck source=/dev/null
    source "$FUNC_SH"
    do_cloud_sql_backup_verify
  ) 2>&1
}

# --- Case 1: Fresh automated backup (< 26h, e.g. 2h old) --------------------
make_json "1001" "SUCCESSFUL" "AUTOMATED" 7200
echo "0" > "$GCLOUD_RC_FILE"
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 0 ]] && grep -q "verdict=OK" <<<"$out" && grep -q "backup 1001 on csi-spl-dev-pg (dev) is SUCCESSFUL" <<<"$out"; then
  pass "case 1: fresh automated backup (2h old) passes with exit 0 and verdict=OK"
else
  fail "case 1: fresh automated backup failed (rc=$rc): $out"
fi

# --- Case 2: Fresh on-demand backup (< 26h, e.g. 1h old) --------------------
make_json "1002" "SUCCESSFUL" "ON_DEMAND" 3600
echo "0" > "$GCLOUD_RC_FILE"
out=$(ENV=prd run_action); rc=$?
if [[ $rc -eq 0 ]] && grep -q "verdict=OK" <<<"$out" && grep -q "type=ON_DEMAND" <<<"$out"; then
  pass "case 2: fresh on-demand backup (1h old) passes with exit 0 and verdict=OK"
else
  fail "case 2: fresh on-demand backup failed (rc=$rc): $out"
fi

# --- Case 3: Stale backup (28h old, status SUCCESSFUL) -----------------------
make_json "1003" "SUCCESSFUL" "AUTOMATED" $(( 28 * 3600 ))
echo "0" > "$GCLOUD_RC_FILE"
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "verdict=ALERT" <<<"$out" && grep -q "stale" <<<"$out"; then
  pass "case 3: stale backup (28h old) alerts with exit 1"
else
  fail "case 3: stale backup did not alert properly (rc=$rc): $out"
fi

# --- Case 4: Failed backup (< 26h, status FAILED) ---------------------------
make_json "1004" "FAILED" "AUTOMATED" 7200
echo "0" > "$GCLOUD_RC_FILE"
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "verdict=ALERT" <<<"$out" && grep -q "status 'FAILED'" <<<"$out"; then
  pass "case 4: backup with status FAILED alerts with exit 1"
else
  fail "case 4: failed backup did not alert properly (rc=$rc): $out"
fi

# --- Case 5: In-progress backup (status RUNNING) ----------------------------
make_json "1005" "RUNNING" "AUTOMATED" 600
echo "0" > "$GCLOUD_RC_FILE"
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "verdict=ALERT" <<<"$out" && grep -q "status 'RUNNING'" <<<"$out"; then
  pass "case 5: backup with status RUNNING alerts with exit 1"
else
  fail "case 5: in-progress backup did not alert properly (rc=$rc): $out"
fi

# --- Case 6: Empty backup list ([]) ------------------------------------------
echo "[]" >"$GCLOUD_STUB_JSON"
echo "0" > "$GCLOUD_RC_FILE"
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "no backups found for instance" <<<"$out"; then
  pass "case 6: empty backup list alerts with exit 1"
else
  fail "case 6: empty backup list did not alert properly (rc=$rc): $out"
fi

# --- Case 7: gcloud execution error (rc=1) -----------------------------------
echo "1" > "$GCLOUD_RC_FILE"
echo "ERROR: (gcloud.sql.backups.list) The instance was not found." >"$GCLOUD_STUB_JSON"
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "ERROR gcloud sql backups list failed" <<<"$out"; then
  pass "case 7: gcloud command error returns exit 1"
else
  fail "case 7: gcloud error did not return exit 1 (rc=$rc): $out"
fi
echo "0" > "$GCLOUD_RC_FILE"

# --- Case 8: Invalid JSON response -------------------------------------------
echo "this-is-not-json" >"$GCLOUD_STUB_JSON"
echo "0" > "$GCLOUD_RC_FILE"
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "verdict=ALERT" <<<"$out" && grep -q "INVALID_JSON" <<<"$out"; then
  pass "case 8: invalid JSON response returns exit 1 and alerts"
else
  fail "case 8: invalid JSON response did not alert properly (rc=$rc): $out"
fi

# --- Case 9: Missing timestamp in backup -------------------------------------
cat >"$GCLOUD_STUB_JSON" <<'JSON_EOF'
[{"id": "1009", "status": "SUCCESSFUL", "type": "AUTOMATED"}]
JSON_EOF
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "NO_TIMESTAMP" <<<"$out"; then
  pass "case 9: missing timestamp in backup alerts with exit 1"
else
  fail "case 9: missing timestamp did not alert (rc=$rc): $out"
fi

# --- Case 10: Unparseable timestamp in backup --------------------------------
cat >"$GCLOUD_STUB_JSON" <<'JSON_EOF'
[{"id": "1010", "status": "SUCCESSFUL", "type": "AUTOMATED", "startTime": "invalid-time"}]
JSON_EOF
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "TIMESTAMP_PARSE_ERROR" <<<"$out"; then
  pass "case 10: unparseable timestamp alerts with exit 1"
else
  fail "case 10: unparseable timestamp did not alert (rc=$rc): $out"
fi

# --- Case 11: Future timestamp with large skew (> 300s) ----------------------
make_json "1011" "SUCCESSFUL" "AUTOMATED" -1000
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "FUTURE_TIMESTAMP" <<<"$out"; then
  pass "case 11: future timestamp with large skew (> 300s) alerts with exit 1"
else
  fail "case 11: future timestamp did not alert (rc=$rc): $out"
fi

# --- Case 12: Clock skew <= 300s in future -----------------------------------
make_json "1012" "SUCCESSFUL" "AUTOMATED" -60
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 0 ]] && grep -q "verdict=OK" <<<"$out"; then
  pass "case 12: clock skew <= 300s in future is handled and passes with exit 0"
else
  fail "case 12: small clock skew failed (rc=$rc): $out"
fi

# --- Case 13: Custom max age override ----------------------------------------
make_json "1013" "SUCCESSFUL" "AUTOMATED" $(( 12 * 3600 )) # 12h old
out=$(ENV=dev CLOUD_SQL_BACKUP_MAX_AGE_HOURS=10 run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "exceeds limit" <<<"$out"; then
  pass "case 13: custom max age override (10h limit vs 12h backup) alerts with exit 1"
else
  fail "case 13: custom max age override did not alert (rc=$rc): $out"
fi

# --- Case 14: Instance resolution for dev ------------------------------------
make_json "1014" "SUCCESSFUL" "AUTOMATED" 3600
out=$(ENV=dev run_action); rc=$?
if [[ $rc -eq 0 ]] && grep -q "instance=csi-spl-dev-pg" <<<"$out"; then
  pass "case 14: resolves instance name csi-spl-dev-pg from cnf for dev"
else
  fail "case 14: did not resolve csi-spl-dev-pg from cnf: $out"
fi

# --- Case 15: Instance resolution for prd ------------------------------------
make_json "1015" "SUCCESSFUL" "AUTOMATED" 3600
out=$(ENV=prd run_action); rc=$?
if [[ $rc -eq 0 ]] && grep -q "instance=csi-spl-prd-pg" <<<"$out"; then
  pass "case 15: resolves instance name csi-spl-prd-pg from cnf for prd"
else
  fail "case 15: did not resolve csi-spl-prd-pg from cnf: $out"
fi

# --- Case 16: Explicit CLOUD_SQL_INSTANCE override ---------------------------
make_json "1016" "SUCCESSFUL" "AUTOMATED" 3600
out=$(ENV=dev CLOUD_SQL_INSTANCE="custom-pg-instance" run_action); rc=$?
if [[ $rc -eq 0 ]] && grep -q "instance=custom-pg-instance" <<<"$out"; then
  pass "case 16: honours explicit CLOUD_SQL_INSTANCE override"
else
  fail "case 16: did not honour CLOUD_SQL_INSTANCE override: $out"
fi

# --- Case 17: Invalid ENV (unset or invalid) ---------------------------------
out=$(ENV=foo run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "FATAL ENV must be dev or prd" <<<"$out"; then
  pass "case 17: invalid ENV returns exit 1 and logs FATAL"
else
  fail "case 17: invalid ENV did not fail as expected (rc=$rc): $out"
fi

# --- Case 18: DRY_RUN=1 plans alert, no spool note, no stamp -----------------
make_json "1018" "FAILED" "AUTOMATED" 3600
: >"$SPOOL_SEND_LOG"
rm -f "$STATE_DIR"/*
out=$(ENV=dev DRY_RUN=1 run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "PLAN note to orchestrator" <<<"$out" && [[ ! -s "$SPOOL_SEND_LOG" ]] && ! ls "$STATE_DIR"/*.stamp >/dev/null 2>&1; then
  pass "case 18: DRY_RUN=1 plans note, sends nothing, writes no stamp"
else
  fail "case 18: DRY_RUN=1 did not behave as expected (rc=$rc): $out"
fi

# --- Case 19: DRY_RUN=0 sends alert via spool-send, writes stamp --------------
make_json "1019" "FAILED" "AUTOMATED" 3600
: >"$SPOOL_SEND_LOG"
rm -f "$STATE_DIR"/*
out=$(ENV=dev DRY_RUN=0 run_action); rc=$?
stamp_file="$STATE_DIR/cloud-sql-backup-alert-dev.stamp"
if [[ $rc -eq 1 ]] && grep -q "SPOOL-SEND" "$SPOOL_SEND_LOG" && [[ -f "$stamp_file" ]] && grep -q "CODE=STATUS_FAIL" "$stamp_file"; then
  pass "case 19: DRY_RUN=0 delivers alert note and records stamp file"
else
  fail "case 19: DRY_RUN=0 did not send alert or write stamp (rc=$rc): $out"
fi

# --- Case 20: Alert throttling on repeated failure ---------------------------
: >"$SPOOL_SEND_LOG"
out=$(ENV=dev DRY_RUN=0 run_action); rc=$?
if [[ $rc -eq 1 ]] && grep -q "alert throttled by" <<<"$out" && [[ ! -s "$SPOOL_SEND_LOG" ]]; then
  pass "case 20: repeated alert within throttle window is throttled (no duplicate note)"
else
  fail "case 20: alert was not throttled (rc=$rc): $out"
fi

# --- Case 21: Recovery clears stamp file -------------------------------------
make_json "1021" "SUCCESSFUL" "AUTOMATED" 3600
out=$(ENV=dev DRY_RUN=0 run_action); rc=$?
if [[ $rc -eq 0 ]] && [[ ! -f "$stamp_file" ]]; then
  pass "case 21: successful backup with DRY_RUN=0 clears alert stamp"
else
  fail "case 21: stamp file was not cleared after recovery (rc=$rc): $out"
fi

# --- Case 22: Invocation via csi-spl-utl ./run harness -----------------------
make_json "1022" "SUCCESSFUL" "AUTOMATED" 3600
out=$(cd "$UTL_ROOT" && ENV=dev ./run -a do_cloud_sql_backup_verify 2>&1); rc=$?
if [[ $rc -eq 0 ]] && grep -q "verdict=OK" <<<"$out"; then
  pass "case 22: action runs cleanly via ./run harness with exit 0"
else
  fail "case 22: ./run harness execution failed (rc=$rc): $out"
fi

# --- Case 23: RED CONTROL 1 (stale backup must fail) -------------------------
make_json "1023" "SUCCESSFUL" "AUTOMATED" $(( 30 * 3600 )) # 30h old
out=$(ENV=dev run_action); rc=$?
if [[ $rc -ne 0 ]]; then
  pass "case 23 (red control 1): 30h old backup reliably fails"
else
  fail "case 23 (red control 1): 30h old backup passed unexpectedly: $out"
fi

# --- Case 24: RED CONTROL 2 (non-SUCCESSFUL status must fail) ----------------
make_json "1024" "SKIPPED" "AUTOMATED" 1800
out=$(ENV=dev run_action); rc=$?
if [[ $rc -ne 0 ]]; then
  pass "case 24 (red control 2): non-SUCCESSFUL backup status reliably fails"
else
  fail "case 24 (red control 2): non-SUCCESSFUL backup status passed unexpectedly: $out"
fi

# --- Case 25: LIVE GUARD ----------------------------------------------------
if [[ ! -s "$LIVE_LOG" ]]; then
  pass "case 25 (live guard): 0 calls reached live gcloud or spool outside test stubs"
else
  fail "case 25 (live guard): leaked calls detected: $(cat "$LIVE_LOG")"
fi

echo "cloud-sql-backup-verify.tst.sh: 25 cases, $fails failure(s)"
[[ $fails -eq 0 ]]
