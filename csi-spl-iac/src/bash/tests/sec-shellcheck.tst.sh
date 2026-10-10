#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_shellcheck fails closed, and its negative control can fail.
#          The tool here is a stub. A green stub that reports nothing on a
#          broken script must NOT let the action pass: that is the control. The
#          real scanner runs from .github/workflows/67_shellcheck.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/sec-shellcheck.func.sh"
WF="$APP_ROOT/.github/workflows/67_shellcheck.yml"

fails=0

require_action "$FUNC"

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-shellcheck.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# A fake repo root with one bash file to scan.
ROOT="$T/root"
mkdir -p "$ROOT/csi-spl-iac/src/bash/run"
printf '#!/usr/bin/env bash\ntrue\n' >"$ROOT/csi-spl-iac/src/bash/run/ok.func.sh"
printf '# empty\n' >"$ROOT/.shellcheck-warning-baseline.txt"


# --- missing binary fails closed --------------------------------------------
set +e
out=$(SEC_SHELLCHECK_ROOT="$ROOT" SEC_SHELLCHECK_BIN=not-a-shellcheck do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing shellcheck fails closed" || fail "missing shellcheck not closed (rc=$rc)"

# --- CONTROL: a stub that finds nothing on the broken script fails -----------
stub shellcheck 'exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent shellcheck fails the action" || fail "CONTROL: silent shellcheck accepted (rc=$rc)"

# --- control fires, scan clean -> passes ------------------------------------
stub shellcheck 'if [[ "${SEC_SHELLCHECK_PHASE:-}" == control ]]; then echo "bad.sh:2: error: SC2144"; exit 1; fi; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no error-level findings' <<<"$out" \
  && pass "control then a clean tree passes" || { fail "clean scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a real error-level finding fails ---------------------------------------
stub shellcheck 'if [[ "${SEC_SHELLCHECK_PHASE:-}" == control ]]; then echo "c.sh:1: error: SC2144"; exit 1; fi; echo "x.func.sh:3: error: SC2148"; exit 1'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'error-level findings' <<<"$out" \
  && pass "a real error finding fails the gate" || fail "real finding did not fail (rc=$rc)"

# --- the warning ratchet (CLE-77915) ----------------------------------------
# The stub answers per phase: control finds SC2144, the error scan is clean,
# the warning scan prints $WARN_OUT.
stub shellcheck 'if [[ "${SEC_SHELLCHECK_PHASE:-}" == control ]]; then echo "c.sh:1: error: SC2144"; exit 1; fi; [[ "${SEC_SHELLCHECK_PHASE:-}" == warn ]] && printf "%b" "${WARN_OUT:-}"; exit 0'
W1="$ROOT/csi-spl-iac/src/bash/run/ok.func.sh:2:1: warning: x appears unused. [SC2034]\n"
ratchet() { set +e; out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" WARN_OUT="$1" do_sec_shellcheck 2>&1); rc=$?; set -e; }
ratchet "$W1"
[[ "$rc" -ne 0 ]] && grep -q 'NEW SC2034 csi-spl-iac/src/bash/run/ok.func.sh: 1 found, 0 baselined' <<<"$out" \
  && pass "a NEW warning (not in the baseline) fails, named by code and file" || { fail "new warning not caught (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }
echo 'SC2034|csi-spl-iac/src/bash/run/ok.func.sh|1' >>"$ROOT/.shellcheck-warning-baseline.txt"
ratchet "$W1"
[[ "$rc" -eq 0 ]] && grep -q 'baseline holds' <<<"$out" && pass "a baselined warning passes" || fail "baselined warning failed (rc=$rc): $out"
ratchet "$W1$W1"
[[ "$rc" -ne 0 ]] && grep -q '2 found, 1 baselined' <<<"$out" && pass "a count above its baseline fails" || fail "count growth not caught (rc=$rc): $out"
ratchet ""
[[ "$rc" -ne 0 ]] && grep -q 'lower this line' <<<"$out" && grep -q 'LOWER SC2034 csi-spl-iac/src/bash/run/ok.func.sh: 1 baselined, 0 found' <<<"$out" \
  && pass "RED CONTROL: a fixed warning fails until its baseline line is lowered (r5-05)" || fail "fixed warning: rc=$rc $out"
echo 'SC2154|csi-spl-iac/src/bash/run/gone.func.sh|1' >>"$ROOT/.shellcheck-warning-baseline.txt"
ratchet "$W1"
[[ "$rc" -ne 0 ]] && grep -q 'LOWER SC2154 csi-spl-iac/src/bash/run/gone.func.sh: 1 baselined, 0 found' <<<"$out" \
  && pass "a line for a deleted file fails a whole-tree scan" || fail "deleted file's line held: rc=$rc $out"
set +e; out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" SEC_SHELLCHECK_FILES=csi-spl-iac/src/bash/run/ok.func.sh WARN_OUT="$W1" do_sec_shellcheck 2>&1); rc=$?; set -e
[[ "$rc" -eq 0 ]] && pass "a touched-files scan holds only the touched files' lines" || fail "touched-files scan held other lines: rc=$rc $out"
printf '# empty\nSC2034|csi-spl-iac/src/bash/run/ok.func.sh|1\n' >"$ROOT/.shellcheck-warning-baseline.txt"
mv "$ROOT/.shellcheck-warning-baseline.txt" "$T/bl.saved"
ratchet ""
[[ "$rc" -ne 0 ]] && grep -q 'nothing to hold' <<<"$out" && pass "CONTROL: no baseline file fails closed" || fail "missing baseline accepted (rc=$rc)"
mv "$T/bl.saved" "$ROOT/.shellcheck-warning-baseline.txt"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'do_sec_shellcheck' 'koalaman/shellcheck' "$_SEC_SHELLCHECK_VER"; do
    grep -qF "$needle" "$WF" || { fail "workflow missing $needle"; miss=1; }
  done
  (( miss )) || pass "67_shellcheck.yml installs the pinned shellcheck and runs the action"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-shellcheck.tst.sh assertions"
exit "$fails"
