#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tf_state_remove backs the state up before it removes anything,
#          keeps the state lock, and is a dry run unless told otherwise.
#   1. default: a 0600 backup under a 0700 dir holds the pulled state, the
#      targets are only listed, nothing is removed
#   2. DRY_RUN=0: every comma separated target is removed, AFTER the pull,
#      with the lock (no -lock=false)
#   3. DRY_RUN=0 FORCE=1: -lock=false
#   4. CONTROL: a failing pull, and an empty pull, abort before any state rm
#      and leave no backup file behind
# terraform is a stub on PATH; do_tf_init is stubbed. No network, no GCP.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
ACTION="$PROJ_ROOT/src/bash/run/tf-state-remove.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

mkdir -p "$T/bin"
cat >"$T/bin/terraform" <<'EOF'
#!/usr/bin/env bash
shift
echo "$*" >>"$TF_CALLS"
case "$1 $2" in
  "state pull")
    case "${STUB_PULL:-ok}" in
      ok) printf '{"version":4,"serial":7,"lineage":"x"}\n' ;;
      empty) : ;;
      fail) exit 1 ;;
    esac ;;
  "state list") echo "$3" ;;
esac
exit 0
EOF
chmod +x "$T/bin/terraform"

# run_action <env assignments...> -> rc; calls in $T/calls.log, output in $T/out.log
run_action() {
  : >"$T/calls.log"
  env PATH="$T/bin:$PATH" TF_CALLS="$T/calls.log" ACTION="$ACTION" \
    ORG=o APP=a ENV=dev STEP=s1 APP_PATH="$T/app" PROJ_PATH="$T/proj" \
    TF_STATE_BACKUP_DIR="$T/bk" TARGET="x.a,x.b" "$@" \
    bash -c 'do_log(){ echo "$*"; }; do_simple_log(){ echo "$*"; }
      do_tf_init(){ tf_proj="$STEP"; tf_run_path="$PROJ_PATH/bin/$ENV/$tf_proj"; mkdir -p "$tf_run_path"; }
      source "$ACTION"; do_tf_state_remove' >"$T/out.log" 2>&1
}

# --- 1. default = dry run, with a backup --------------------------------------------
rm -rf "$T/bk"; run_action; rc=$?
bk=$(ls "$T"/bk/o-a-dev-s1-*.tfstate 2>/dev/null | head -1)
[[ $rc -eq 0 && -n "$bk" ]] && pass "default: a backup file o-a-dev-s1-<ts>.tfstate is written" || fail "default: rc=$rc backup='$bk' $(cat "$T/out.log")"
[[ -n "$bk" && "$(stat -c %a "$bk")" == 600 && "$(stat -c %a "$T/bk")" == 700 ]] \
  && pass "default: the backup is 0600 in a 0700 dir" || fail "modes: file=$(stat -c %a "$bk" 2>/dev/null) dir=$(stat -c %a "$T/bk")"
grep -q '"serial":7' "$bk" 2>/dev/null && pass "default: the backup holds the pulled state" || fail "backup content"
! grep -q '^state rm' "$T/calls.log" && grep -c '^state list' "$T/calls.log" | grep -qx 2 \
  && pass "default: both targets listed, nothing removed" || fail "default calls: $(tr '\n' '|' <"$T/calls.log")"

# --- 2. DRY_RUN=0 keeps the lock and removes after the backup -----------------------
rm -rf "$T/bk"; run_action DRY_RUN=0; rc=$?
rms=$(grep '^state rm' "$T/calls.log")
[[ $rc -eq 0 && "$rms" == $'state rm x.a\nstate rm x.b' ]] \
  && pass "DRY_RUN=0: each target removed, with the lock (no -lock=false)" || fail "DRY_RUN=0: rc=$rc rm='$rms'"
pull_at=$(grep -n '^state pull' "$T/calls.log" | cut -d: -f1); rm_at=$(grep -n '^state rm' "$T/calls.log" | head -1 | cut -d: -f1)
[[ -n "$pull_at" && -n "$rm_at" && "$pull_at" -lt "$rm_at" ]] && pass "DRY_RUN=0: the pull precedes the first state rm" || fail "order: pull=$pull_at rm=$rm_at"

# --- 3. FORCE=1 drops the lock ------------------------------------------------------
run_action DRY_RUN=0 FORCE=1
[[ "$(grep -c '^state rm -lock=false' "$T/calls.log")" == 2 ]] && pass "FORCE=1: -lock=false on each state rm" || fail "FORCE: $(tr '\n' '|' <"$T/calls.log")"

# --- 4. CONTROL: no backup, no state rm ---------------------------------------------
for mode in fail empty; do
  rm -rf "$T/bk"; run_action DRY_RUN=0 STUB_PULL=$mode; rc=$?
  left=$(ls "$T/bk" 2>/dev/null | wc -l)
  [[ $rc -ne 0 ]] && ! grep -q '^state rm' "$T/calls.log" && [[ "$left" -eq 0 ]] \
    && pass "CONTROL: a $mode pull aborts before any state rm and leaves no file" \
    || fail "CONTROL $mode: rc=$rc left=$left calls=$(tr '\n' '|' <"$T/calls.log")"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
