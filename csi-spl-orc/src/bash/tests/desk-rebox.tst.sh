#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_rebox (specs/058 M5 / 6.5, CLE-77924): a machine's desk
#          moves from the old hub box (box-desk) to its own box id, step by
#          step, with every cloud call stubbed (pin, sidecar, hub-sync, SQL).
#   1. DRY_RUN (the default) touches nothing; TO_BOX = box-desk / = FROM_BOX /
#      an unknown step / no FROM_BOX are refused
#   2. pin: do_spl_desk_pin self mode for TO_BOX with the newest saved root key
#   3. copy: one transaction copies box_operators + channel_subscriptions to
#      TO_BOX with backfilled_at set (no back-fill burst); values are psql
#      variables, app.tenant_id is set
#   4. drain: the cron pause is written, the old sidecar is stopped for ALL,
#      the seated agents are recorded and parked, and ONE hub-sync as the old
#      box (empty roster, fleet root + notify set) pulls a still-queued
#      message, which is counted and parked too; a re-run keeps the record
#   5. seat: refused before pin/drain; then the recorded agents get dirs on
#      TO_BOX (a muted seat stays muted) and do_spl_desk_up_all seats them
#      seated-only
#   6. resume removes the pause; retire drains again, deletes the old box's
#      rows and revokes its pin
#   7. copy also carries the legacy-id aliases and moves the LIVE lane rows
#      (never a done one, never over an existing TO_BOX row)
#   8. verify is read-only, runs under the DRY_RUN default, and fails while a
#      drained FROM_BOX still has an unacked delivery
#   9. TENANT_ID=all runs the step for every tenant pinned on FROM_BOX, in
#      order, and stops at the first failure
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

S="$T/spool"; ST="$T/state/dev"; F="$ST/desk/t1/box-desk"
mkdir -p "$S" "$T/keys" "$T/bin" "$F/spool/.hub" "$F/spool/CLE-10/inbox" "$F/spool/CLE-002/inbox" "$F/spool/files"
: >"$F/spool/CLE-002/.no-poke"
( umask 077; echo '{"root_private_key":"x"}' >"$T/keys/t1.20260101T000000Z.json"; echo '{"root_private_key":"y"}' >"$T/keys/t1.20261001T000000Z.json" )
cat >"$T/bin/fakespool" <<'EOF'
#!/bin/sh
echo "spool $* box=$SPOOL_BOX_ID root=$SPOOL_ROOT fleet=$SPOOL_FLEET_ROOT notify=$SPOOL_NOTIFY_CMD roster=$(ls "$SPOOL_ROOT" | grep -c '^[A-Z]')" >>"$STUB_LOG"
mkdir -p "$SPOOL_ROOT/CLE-10/inbox" && echo '{}' >"$SPOOL_ROOT/CLE-10/inbox/queued.json"
EOF
chmod +x "$T/bin/fakespool"
STUBS='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.example.com; SPL_ORG_APP=csi-spl; SPL_CNF=/dev/null; }
do_spl_desk_pin() { echo "CALL pin $TENANT_ID $DESK_BOX revoke=$PIN_REVOKE key=$ROOT_KEY_JSON" >>"$STUB_LOG"; [ "$PIN_REVOKE" = 0 ] && mkdir -p "$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX" && echo PUB >"$SPL_STATE_DIR/desk/$TENANT_ID/$DESK_BOX/pinned"; return 0; }
do_spl_desk_down() { echo "CALL down $TENANT_ID $DESK_BOX all=$DESK_ALL" >>"$STUB_LOG"; }
do_spl_desk_up_all() { echo "CALL upall $TENANT_ID $DESK_BOX only=$DESK_SEATED_ONLY retire=$DESK_RETIRE" >>"$STUB_LOG"; }
spl_host_spool() { SPL_SPOOL="$FAKESPOOL"; }
do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
do_gcp_require_live_account() { :; }
spl_via_proxy() { SPL_PROXY_DSN=x "$@"; }
spl_pg_env() { shift; { echo "PSQL PGOPTIONS=${PGOPTIONS:-} $*"; cat; } >>"$SQL_LOG"; printf "%b\n" "${PG_OUT:-rows 1}"; }'
rb() { # STEP [VAR=value]...
  local step="$1"; shift
  SNIPPET="$STUBS; do_spl_desk_rebox" in_orc SPL_STATE_DIR="$ST" SPOOL_ROOT="$S" SPOOL_FLEET_ROOT="$S" FAKESPOOL="$T/bin/fakespool" \
    SQL_LOG="$T/sql.log" SPL_TENANTS_DIR="$T/keys" DESK_NOTIFY_CMD=off TENANT_ID=t1 FROM_BOX=box-desk TO_BOX=hom REBOX_STEP="$step" "$@"
}
snap() { (cd "$T" && find state spool -printf '%p %y\n' | sort); }

# 1 --------------------------------------------------------------------------
s0="$(snap)"; : >"$T/calls.log"
out="$(rb drain 2>&1)"
[[ "$(snap)" == "$s0" && ! -s "$T/calls.log" ]] && grep -q 'DRY_RUN would run step drain' <<<"$out" &&
  pass "1 dry run touches nothing and calls nothing" || fail "1 dry run: $out"
rb pin TO_BOX=box-desk DRY_RUN=0 >/dev/null 2>&1 && fail "1 TO_BOX=box-desk accepted" || pass "1 TO_BOX=box-desk refused"
rb pin TO_BOX=hom FROM_BOX=hom DRY_RUN=0 >/dev/null 2>&1 && fail "1 TO=FROM accepted" || pass "1 TO_BOX = FROM_BOX refused"
rb nonsense DRY_RUN=0 >/dev/null 2>&1 && fail "1 unknown step accepted" || pass "1 an unknown step refused"
rb pin FROM_BOX= DRY_RUN=0 >/dev/null 2>&1 && fail "1 empty FROM_BOX accepted" || pass "1 FROM_BOX is required (no box-desk default)"

# 2 --------------------------------------------------------------------------
: >"$T/calls.log"
rb pin DRY_RUN=0 >/dev/null 2>&1
grep -q "CALL pin t1 hom revoke=0 key=$T/keys/t1.20261001T000000Z.json" "$T/calls.log" && [[ -s "$ST/desk/t1/hom/pinned" ]] &&
  pass "2 pin: TO_BOX pinned with the newest saved root key" || fail "2 pin: $(cat "$T/calls.log")"
grep -q 'CALL down' "$T/calls.log" && fail "2 pin stopped a sidecar" || pass "2 pin leaves the old desk running"

# 3 --------------------------------------------------------------------------
: >"$T/sql.log"
out="$(rb copy DRY_RUN=0 2>&1)"
grep -q -- "-v tenant=t1 -v from=box-desk -v to=hom" "$T/sql.log" && grep -q "SET LOCAL app.tenant_id = :'tenant'" "$T/sql.log" &&
  grep -q "INSERT INTO box_operators" "$T/sql.log" && grep -q "COALESCE(backfilled_at, now())" "$T/sql.log" &&
  grep -q "ON CONFLICT (tenant_id, channel_id, agent_id, box_id) DO NOTHING" "$T/sql.log" &&
  pass "3 copy: operators + channel seats copied in one tx, backfilled, idempotent, values as psql variables" || fail "3 copy: $out $(cat "$T/sql.log")"
! grep -qE "'(t1|box-desk|hom)'" "$T/sql.log" && pass "3 no value spliced into the SQL" || fail "3 spliced value"

# 4 --------------------------------------------------------------------------
: >"$T/calls.log"
out="$(rb drain DRY_RUN=0 2>&1)"; rc=$?
[[ $rc -eq 0 && -s "$S/.desk-reconcile.dev.pause" ]] && pass "4 drain writes the desk cron pause" || fail "4 pause: rc=$rc $out"
grep -q "CALL down t1 box-desk all=1" "$T/calls.log" && pass "4 the old sidecar is stopped for every seat" || fail "4 down: $(cat "$T/calls.log")"
[[ "$(sort "$F/rebox-seated.txt" | tr '\n' ' ')" == "CLE-002 CLE-10 " ]] && pass "4 the seated agents are recorded" || fail "4 seated: $(cat "$F/rebox-seated.txt")"
grep -q "spool hub-sync box=box-desk root=$F/spool fleet=$S notify=off roster=0" "$T/calls.log" &&
  pass "4 ONE hub-sync as box-desk with an EMPTY root (empty roster), fleet copy on" || fail "4 hub-sync: $(cat "$T/calls.log")"
[[ -z "$(find "$F/spool" -mindepth 1 -maxdepth 1 -name '[A-Z]*')" && -d "$F/spool/files" && -d "$F/spool/.hub" ]] &&
  pass "4 the desk root holds no agent after the drain (.hub and files kept)" || fail "4 root: $(ls -a "$F/spool")"
grep -q "drained 1 message" <<<"$out" && [[ -n "$(find "$F/rebox-retired" -name queued.json)" ]] &&
  pass "4 the still-queued delivery was pulled, counted and kept" || fail "4 drained: $out"
rb drain DRY_RUN=0 >/dev/null 2>&1
[[ "$(sort "$F/rebox-seated.txt" | tr '\n' ' ')" == "CLE-002 CLE-10 " ]] && pass "4 a re-run keeps the record (no duplicate, nothing lost)" || fail "4 rerun record: $(cat "$F/rebox-seated.txt")"

# 5 --------------------------------------------------------------------------
mv "$ST/desk/t1/hom/pinned" "$T/pinned.bak"
rb seat DRY_RUN=0 >/dev/null 2>&1 && fail "5 seat without a pin accepted" || pass "5 seat refuses before pin"
mv "$T/pinned.bak" "$ST/desk/t1/hom/pinned"
: >"$T/calls.log"
rb seat DRY_RUN=0 >/dev/null 2>&1
[[ -d "$ST/desk/t1/hom/spool/CLE-10/inbox" && -d "$ST/desk/t1/hom/spool/CLE-002/inbox" ]] && pass "5 the recorded agents get their dirs on the new box" || fail "5 dirs"
[[ -e "$ST/desk/t1/hom/spool/CLE-002/.no-poke" && ! -e "$ST/desk/t1/hom/spool/CLE-10/.no-poke" ]] && pass "5 a muted seat stays muted, the others do not" || fail "5 mute"
grep -q "CALL upall t1 hom only=1 retire=0" "$T/calls.log" && pass "5 do_spl_desk_up_all seats them seated-only on the new box" || fail "5 upall: $(cat "$T/calls.log")"

# 6 --------------------------------------------------------------------------
rb resume DRY_RUN=0 >/dev/null 2>&1
[[ ! -e "$S/.desk-reconcile.dev.pause" ]] && pass "6 resume removes the pause" || fail "6 resume"
: >"$T/calls.log"; : >"$T/sql.log"
out="$(rb retire DRY_RUN=0 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "spool hub-sync box=box-desk" "$T/calls.log" && grep -q "DELETE FROM channel_subscriptions" "$T/sql.log" &&
  grep -q "DELETE FROM box_operators" "$T/sql.log" && grep -q "CALL pin t1 box-desk revoke=1" "$T/calls.log" &&
  pass "6 retire: drains again, deletes the old box's rows, revokes its pin" || fail "6 retire rc=$rc: $out $(cat "$T/calls.log")"

# 7 --------------------------------------------------------------------------
: >"$T/sql.log"
rb copy DRY_RUN=0 >/dev/null 2>&1
grep -q "INSERT INTO agent_id_aliases" "$T/sql.log" && grep -q "ON CONFLICT (tenant_id, old_id, box_id) DO NOTHING" "$T/sql.log" &&
  pass "7 copy carries the legacy-id aliases to TO_BOX, idempotent" || fail "7 aliases: $(cat "$T/sql.log")"
grep -q "UPDATE fleet_lanes f SET agent_box = :'to'" "$T/sql.log" && grep -q "f.state = 'live'" "$T/sql.log" &&
  grep -q "NOT EXISTS (SELECT 1 FROM fleet_lanes g" "$T/sql.log" &&
  pass "7 copy moves only LIVE lane rows, never over an existing TO_BOX row" || fail "7 lanes: $(cat "$T/sql.log")"
[[ "$(grep -c '^BEGIN;' "$T/sql.log")" == 1 && "$(grep -c '^COMMIT;' "$T/sql.log")" == 1 ]] &&
  pass "7 the copy is still ONE transaction" || fail "7 tx: $(grep -cE '^(BEGIN|COMMIT);' "$T/sql.log")"

# 8 --------------------------------------------------------------------------
: >"$T/sql.log"
out="$(rb verify PG_OUT='box-desk 1 0 0 0\nhom 1 2 5 0' 2>&1)"; rc=$?
[[ $rc -eq 0 ]] && grep -q "PGOPTIONS=-c default_transaction_read_only=on" "$T/sql.log" && grep -q "BEGIN TRANSACTION READ ONLY" "$T/sql.log" &&
  ! grep -qiE "INSERT|UPDATE|DELETE" "$T/sql.log" && grep -q "hom 1 2 5 0" <<<"$out" &&
  pass "8 verify runs read-only under the DRY_RUN default and prints both boxes" || fail "8 verify rc=$rc: $out"
rb verify PG_OUT='box-desk 1 0 0 3\nhom 1 2 5 0' >/dev/null 2>&1 && fail "8 unacked after drain accepted" ||
  pass "8 verify fails while the drained box still has unacked deliveries"
rb verify PG_OUT='' >/dev/null 2>&1 && fail "8 empty read accepted" || pass "8 verify fails on an empty read"

# 9 --------------------------------------------------------------------------
mkdir -p "$ST/desk/a1/box-desk" "$ST/desk/b2/box-desk" "$ST/desk/c3/box-desk"
echo PUB >"$ST/desk/a1/box-desk/pinned"; echo PUB >"$ST/desk/c3/box-desk/pinned"; echo PUB >"$ST/desk/t1/box-desk/pinned"
( umask 077; for t in a1 c3; do echo '{}' >"$T/keys/$t.20261001T000000Z.json"; done )
: >"$T/calls.log"
out="$(rb pin TENANT_ID=all DRY_RUN=0 2>&1)"; rc=$?
[[ $rc -eq 0 && "$(grep -o 'CALL pin [a-z0-9]*' "$T/calls.log" | tr '\n' ' ')" == "CALL pin a1 CALL pin c3 CALL pin t1 " ]] &&
  pass "9 TENANT_ID=all: every pinned FROM_BOX desk, in order, b2 (not pinned) skipped" || fail "9 all rc=$rc: $(cat "$T/calls.log") $out"
s0="$(snap)"; : >"$T/calls.log"
rb pin TENANT_ID=all >/dev/null 2>&1
[[ "$(snap)" == "$s0" && ! -s "$T/calls.log" ]] && pass "9 TENANT_ID=all keeps the DRY_RUN default" || fail "9 all dry: $(cat "$T/calls.log")"
rm -f "$T/keys/c3."*; : >"$T/calls.log"
rb pin TENANT_ID=all DRY_RUN=0 >/dev/null 2>&1 && fail "9 a failing tenant passed" ||
  { grep -q 'CALL pin a1' "$T/calls.log" && ! grep -q 'CALL pin t1' "$T/calls.log" && pass "9 TENANT_ID=all stops at the first failure" || fail "9 stop: $(cat "$T/calls.log")"; }
rb pin TENANT_ID=all FROM_BOX=nobox DRY_RUN=0 >/dev/null 2>&1 && fail "9 no desk accepted" || pass "9 TENANT_ID=all with no pinned desk fails"

[[ $fails -eq 0 ]] && echo "desk-rebox.tst.sh: all passed" || echo "desk-rebox.tst.sh: $fails failed"
exit $((fails > 0))
