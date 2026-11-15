#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-5594 (owner poll answer B on SPL-5514): do_spl_unanswered_sweep
#          lists and escalates an unanswered human post only after the take /
#          ack deferral (cnf env.box.desk_ack_defer_s, ACK_DEFER_S overrides
#          it) plus SWEEP_DEFER_MARGIN (60 s), so the deferred take line lands
#          first. Fixture rows, a scratch spool root, a fake sender; no hub.
#   1. ACK_DEFER_S=300, the cron's SWEEP_MIN_AGE=3 SWEEP_ESCALATE_AGE=5,
#      swept every minute for 10 minutes: NOT listed before minute 6, listed
#      (NEW) at minute 6 and escalated (ESC) at minute 7, each once.
#      RED on origin/master: listed at 3, escalated at 5
#   2. no override: the deferral comes from the cnf key itself
#   3. CONTROL: ACK_DEFER_S=0 keeps the cron's 3 / 5 minutes
#   4. a bad ACK_DEFER_S or SWEEP_DEFER_MARGIN is refused
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
NOW=1790000000
cat >"$T/send.sh" <<'SH'
#!/usr/bin/env bash
to="" body=""
while [ $# -gt 0 ]; do case "$1" in --to) to="$2"; shift 2 ;; --body-file) body="$2"; shift 2 ;; *) shift ;; esac; done
{ echo "TO $to"; cat "$body"; echo; echo "END"; } >>"$SEND_LOG"
SH
chmod +x "$T/send.sh"
P=00000000-0000-4000-8000-0000000005d4
# one human post at minute 0, its own oldest unanswered anchor (15 columns)
printf '%s\t\tdev\t%s\t10000000-0000-4000-8000-0000000005d4\t%s\tHUM-10\tbox-desk\thuman\topen\tlive\t-\tplease look\t%s\t10000000-0000-4000-8000-0000000005d4\n' \
  t1 "$P" "$NOW" "$NOW" >"$T/rows.tsv"

# sweep <spool dir> <minute> [VAR=value ...]: one delivering sweep at <minute>
sweep() {
  local s="$1" m="$2"; shift 2
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPOOL_ROOT="$s" ENV=prd SWEEP_ROWS_FILE="$T/rows.tsv" \
    SWEEP_SEND="$T/send.sh" SEND_LOG="$s/sent" SWEEP_NOW=$(( NOW + m * 60 )) HOME="$T/home" DELIVER=1 \
    SWEEP_MIN_AGE=3 SWEEP_ESCALATE_AGE=5 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$PROJ_PATH/src/bash/run/spl-dispatch-lease.func.sh"
    source "$PROJ_PATH/src/bash/run/spl-unanswered-sweep.func.sh"
    do_spl_unanswered_sweep'
}
# minutes <name> [VAR=value ...]: sweeps minutes 0..10 on a fresh spool root,
# prints "listed=<minutes> escalated=<minutes> notes=<n>"
minutes() {
  local s="$T/$1" m l0 new_lines listed="" escalated=""; shift
  mkdir -p "$s/dispatch"
  echo "c-002 $NOW" >"$s/dispatch/lease"
  printf 'LEASE_MASTER=c-002\nLEASE_FAILOVER=c-003\nLEASE_ORCH=c-001\n' >"$s/dispatch/lease.conf"
  for m in 0 1 2 3 4 5 6 7 8 9 10; do
    l0="$(cat "$s/sent" 2>/dev/null | wc -l)"
    sweep "$s" "$m" "$@" >"$s/o.$m" 2>&1 || { echo "sweep failed at minute $m: $(cat "$s/o.$m")"; return 1; }
    new_lines="$(tail -n +$(( l0 + 1 )) "$s/sent" 2>/dev/null)"
    grep '^| NEW | t1 | #dev | '"$P"' |' <<<"$new_lines" >/dev/null && listed="$listed,$m"
    grep '^| ESC | t1 | #dev | '"$P"' |' <<<"$new_lines" >/dev/null && escalated="$escalated,$m"
  done
  echo "listed=${listed#,} escalated=${escalated#,} notes=$(grep -c '^TO ' "$s/sent" 2>/dev/null || echo 0)"
}

# --- 1. ACK_DEFER_S=300: listed at 6, escalated at 7 ---------------------------------
got="$(minutes a ACK_DEFER_S=300)"
[[ "$got" == "listed=6 escalated=7 notes=2" ]] &&
  pass "1. deferral 300 s + 60 s margin: listed at minute 6, escalated at minute 7, once each" ||
  fail "1. want listed=6 escalated=7 notes=2, got: $got"
grep -q 'older than 6 min' "$T/a/o.6" && pass "1. the report states the 6-minute floor" || fail "1. report floor: $(grep -m1 'older than' "$T/a/o.6")"

# --- 2. the cnf key, no override -------------------------------------------------------
cnf_s="$(yq -r '.env.box.desk_ack_defer_s' "$APP_ROOT/csi-spl-cnf/csi-spl/prd.env.json")"
if [[ "$cnf_s" =~ ^[0-9]+$ ]]; then
  want_l=$(( (cnf_s + 60 + 59) / 60 )); (( want_l < 3 )) && want_l=3
  want_e=$(( want_l + 1 )); (( want_e < 5 )) && want_e=5
  got="$(minutes b)"
  [[ "$got" == "listed=$want_l escalated=$want_e notes=2" ]] &&
    pass "2. cnf env.box.desk_ack_defer_s=$cnf_s: listed at minute $want_l, escalated at $want_e" ||
    fail "2. cnf $cnf_s: want listed=$want_l escalated=$want_e notes=2, got: $got"
else
  fail "2. prd cnf env.box.desk_ack_defer_s is not a number: '$cnf_s'"
fi

# --- 3. CONTROL: no deferral keeps the cron's 3 / 5 ----------------------------------------
got="$(minutes c ACK_DEFER_S=0)"
[[ "$got" == "listed=3 escalated=5 notes=2" ]] &&
  pass "3. CONTROL: ACK_DEFER_S=0 lists at minute 3 and escalates at 5" ||
  fail "3. CONTROL: want listed=3 escalated=5 notes=2, got: $got"

# --- 4. bad input is refused ---------------------------------------------------------------
for bad in ACK_DEFER_S=5m SWEEP_DEFER_MARGIN=-1; do
  mkdir -p "$T/d/dispatch"
  sweep "$T/d" 0 "$bad" >"$T/o4" 2>&1 && fail "4. $bad: ran" ||
    { grep -q FATAL "$T/o4" && pass "4. $bad: refused (FATAL)" || fail "4. $bad: $(cat "$T/o4")"; }
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
