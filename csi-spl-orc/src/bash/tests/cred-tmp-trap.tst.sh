#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the throwaway CLOUDSDK_CONFIG of five actions (refactor r4-09) holds
#          an activated SA credential, so no exit path may leave it in TMPDIR:
#          do_spl_db_rls_check, do_spl_lb_absent_check,
#          do_spl_wait_for_mapping_cert, do_spl_domain_verify,
#          do_spl_wait_for_firebase_domain.
#   1. gcloud fails (exit 130): the same exit code as before the trap, and
#      TMPDIR is empty afterwards
#   2. an interrupt (gcloud sends INT to its process group, as Ctrl-C does):
#      bash kills itself and no function returns, yet TMPDIR is empty
#   CONTROL: the stub log shows activate-service-account was reached, so the
#   temp dir existed before it was removed.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub" "$T/key"
cat >"$T/stub/gcloud" <<'STUB'
#!/usr/bin/env bash
echo "gcloud $*" >>"$STUB_LOG"
[[ "${STUB_INT:-0}" == 1 ]] && kill -INT 0
exit 130
STUB
chmod +x "$T/stub/gcloud"
echo '{}' >"$T/key/sa.json"
export -f in_orc
export T PROJ_ROOT APP_ROOT

# run_action <action> <want rc> <interrupt 0|1>: the action in its own
# process group (setsid), so the INT reaches it and not this test.
run_action() {
  local act="$1" want="$2" int="$3" rc
  rm -rf "$T/tmpd"; mkdir -p "$T/tmpd"; : >"$T/calls.log"
  SNIPPET="$act" setsid --wait bash -c 'in_orc "$@"' _ \
    SPL_SA_KEY="$T/key/sa.json" TMPDIR="$T/tmpd" DOMAIN=t1.dev.example.test STUB_INT="$int" \
    >"$T/out" 2>&1
  rc=$?
  grep -q "^gcloud auth activate-service-account" "$T/calls.log" \
    && pass "CONTROL $act int=$int: activate reached" \
    || fail "CONTROL $act int=$int: activate not reached: $(head -c 300 "$T/out")"
  if [[ "$int" == 0 ]]; then
    [[ "$rc" == "$want" ]] && pass "$act: a failing gcloud exits $want" || fail "$act: rc=$rc, want $want"
  fi
  [[ -z "$(ls -A "$T/tmpd")" ]] && pass "$act int=$int: TMPDIR left empty" \
    || fail "$act int=$int: left $(ls -A "$T/tmpd" | tr '\n' ' ')"
}

for spec in do_spl_db_rls_check:1 do_spl_lb_absent_check:2 do_spl_wait_for_mapping_cert:1 \
  do_spl_domain_verify:1 do_spl_wait_for_firebase_domain:1; do
  run_action "${spec%%:*}" "${spec##*:}" 0
  run_action "${spec%%:*}" "${spec##*:}" 1
done

(( fails == 0 )) && echo "OK cred-tmp-trap: all checks passed" || { echo "FAIL cred-tmp-trap: $fails check(s)"; exit 1; }
