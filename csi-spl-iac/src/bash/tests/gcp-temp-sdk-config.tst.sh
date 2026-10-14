#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_gcp_temp_sdk_config / _restore (refactor round 9 row 10), the one
#          throwaway CLOUDSDK_CONFIG block, with the RETURN trap in the caller.
#   1. A caller whose CLOUDSDK_CONFIG is set: inside it the private dir exists
#      and is exported; after its return the dir is gone, the caller's value is
#      back, the caller's own dir survives, no RETURN trap and no
#      _spl_sdk_* variable is left, and the caller's return code is kept.
#   2. A caller with CLOUDSDK_CONFIG unset gets it unset back.
#   3. CONTROL: a planted helper that sets the RETURN trap itself (D7 says it
#      must not) fails check 1: its trap drops the dir before the caller runs.
#   4. Static: the 3 converted callers hold the one-line trap, source the
#      helper when loaded alone, and carry no copied 4-line block.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
HELPER="$PROJ_ROOT/lib/bash/funcs/gcp-temp-sdk-config.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

fails=0

# probe <helper file> <caller CLOUDSDK_CONFIG or "-" for unset> -> four lines:
#   inside=<CLOUDSDK_CONFIG in the caller> dir=<exists|gone>
#   after=<CLOUDSDK_CONFIG|<unset>> priv=<exists|gone> trap=<n> rc=<n>
#   leak=<_spl_sdk_dir|<none>>
probe() {
  env -u CLOUDSDK_CONFIG H="$1" CALLER_CFG="$2" OUT="$T/inside" bash -c '
    source "$H"
    [[ "$CALLER_CFG" == - ]] || export CLOUDSDK_CONFIG="$CALLER_CFG"
    caller() {
      local _spl_sdk_saved _spl_sdk_dir
      spl_gcp_temp_sdk_config || return 1
      trap '"'"'spl_gcp_temp_sdk_config_restore; trap - RETURN'"'"' RETURN
      local d="${CLOUDSDK_CONFIG-}"
      [[ -n "$d" && -d "$d" ]] && st=exists || st=gone
      echo "$d" >"$OUT"
      echo "inside=$d dir=$st"
      return 7
    }
    caller; rc=$?
    priv=$(cat "$OUT")
    [[ -n "$priv" && -e "$priv" ]] && pst=exists || pst=gone
    echo "after=${CLOUDSDK_CONFIG-<unset>} priv=$pst trap=$(trap -p RETURN | wc -l) rc=$rc"
    echo "leak=${_spl_sdk_dir-<none>}"
  ' 2>&1
}

# check <label> <probe output> <caller value expected after> -> fail count of this case
check() {
  local label="$1" out="$2" want="$3" inside before="$fails"
  inside=$(sed -n 's/^inside=\([^ ]*\) .*/\1/p' <<<"$out")
  if [[ -n "$inside" && "$inside" != "$want" && "$out" == *"inside=$inside dir=exists"* ]]; then
    pass "$label: inside the caller CLOUDSDK_CONFIG is a private dir that exists"
  else fail "$label: inside the caller: $(sed -n 1p <<<"$out")"; fi
  grep -qx "after=$want priv=gone trap=0 rc=7" <<<"$out" \
    && pass "$label: after the return the dir is gone, CLOUDSDK_CONFIG is $want, no RETURN trap, rc kept" \
    || fail "$label: after the return: $(grep '^after=' <<<"$out")"
  grep -qx 'leak=<none>' <<<"$out" && pass "$label: no _spl_sdk_* variable leaks out of the caller" \
    || fail "$label: $(grep '^leak=' <<<"$out")"
  return $((fails - before))
}

# --- 1. caller with CLOUDSDK_CONFIG set ------------------------------------------
mkdir -p "$T/mine"; echo secret >"$T/mine/credentials.db"
check "1. set" "$(probe "$HELPER" "$T/mine")" "$T/mine"
[[ -f "$T/mine/credentials.db" ]] && pass "1. set: the caller's own config dir survives" \
  || fail "1. set: the caller's config dir was deleted"

# --- 2. caller with CLOUDSDK_CONFIG unset -----------------------------------------
check "2. unset" "$(probe "$HELPER" -)" "<unset>"

# --- 3. CONTROL: the trap inside the helper fails check 1 -------------------------
sed 's/^  export CLOUDSDK_CONFIG="\$_spl_sdk_dir"$/&\n  trap '"'"'spl_gcp_temp_sdk_config_restore; trap - RETURN'"'"' RETURN/' \
  "$HELPER" >"$T/planted.func.sh"
if ! grep -q 'trap .* RETURN' "$T/planted.func.sh"; then
  fail "3. CONTROL: the plant did not apply -- the control proves nothing"
else
  saved=$fails
  check "3. CONTROL (planted)" "$(probe "$T/planted.func.sh" "$T/mine")" "$T/mine" >"$T/control.out"
  planted_fails=$((fails - saved)); fails=$saved
  (( planted_fails > 0 )) && pass "3. CONTROL: a helper that sets the RETURN trap itself fails the check ($planted_fails failed: $(grep -m1 '^FAIL' "$T/control.out"))" \
    || fail "3. CONTROL: the trap-in-helper variant passed the check -- the test is blind"
fi

# --- 4. static: the 3 converted callers -------------------------------------------
for f in "$PROJ_ROOT/lib/bash/funcs/gcp-each-env-sa.func.sh" "$PROJ_ROOT/lib/bash/funcs/gcp-project-apis.func.sh" \
         "$PROJ_ROOT/src/bash/run/spl-kms-check.func.sh"; do
  b=$(basename "$f")
  grep -qxF "  trap 'spl_gcp_temp_sdk_config_restore; trap - RETURN' RETURN" "$f" \
    && ! grep -q 'export CLOUDSDK_CONFIG="\$_spl_sdk_dir"' "$f" \
    && pass "4. $b holds the one-line caller trap, no copied block" || fail "4. $b is not converted"
  # shellcheck source=/dev/null  # the caller under test, by path
  ( unset -f spl_gcp_temp_sdk_config spl_gcp_temp_sdk_config_restore; source "$f"; declare -F spl_gcp_temp_sdk_config_restore >/dev/null ) \
    && pass "4. $b sourced alone brings the helper with it" || fail "4. $b sourced alone lacks the helper"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
