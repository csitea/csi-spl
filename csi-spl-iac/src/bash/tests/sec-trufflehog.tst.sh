#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_trufflehog fails closed, its negative control can fail, and a
#          VERIFIED secret reddens the gate. TruffleHog here is a stub emitting
#          JSON. The real tool runs from .github/workflows/64_trufflehog.yml.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/sec-trufflehog.func.sh"
WF="$APP_ROOT/.github/workflows/64_trufflehog.yml"

fails=0

require_action "$FUNC"
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required"; exit 1; }

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-trufflehog.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
ROOT="$T/root"; mkdir -p "$ROOT"
# The control's kept verdicts go to this run's own cache, never the user's.
export XDG_CACHE_HOME="$T/cache"


# --- missing binary fails closed --------------------------------------------
set +e
out=$(SEC_TRUFFLEHOG_ROOT="$ROOT" SEC_TRUFFLEHOG_BIN=not-a-th do_sec_trufflehog 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'not on PATH' <<<"$out" \
  && pass "a missing trufflehog fails closed" || fail "missing trufflehog not closed (rc=$rc)"

# --- CONTROL: a stub that detects nothing in control phase fails -------------
stub trufflehog 'exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_TRUFFLEHOG_ROOT="$ROOT" do_sec_trufflehog 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'control:' <<<"$out" \
  && pass "CONTROL: a silent trufflehog fails the action" || fail "CONTROL: silent trufflehog accepted (rc=$rc)"

# --- control detects, scan finds no verified -> passes ----------------------
stub trufflehog 'if [[ "${SEC_TRUFFLEHOG_PHASE:-}" == control ]]; then echo "{\"DetectorName\":\"AWS\"}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_TRUFFLEHOG_ROOT="$ROOT" do_sec_trufflehog 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && grep -q 'no verified' <<<"$out" \
  && pass "control then a clean tree passes" || { fail "clean scan did not pass (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a verified secret fails ------------------------------------------------
stub trufflehog 'if [[ "${SEC_TRUFFLEHOG_PHASE:-}" == control ]]; then echo "{\"DetectorName\":\"AWS\"}"; else echo "{\"DetectorName\":\"AWS\",\"SourceMetadata\":{\"Data\":{\"Filesystem\":{\"file\":\"x/leak.env\"}}}}"; fi'
set +e
out=$(PATH="$T/bin:$PATH" SEC_TRUFFLEHOG_ROOT="$ROOT" do_sec_trufflehog 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'VERIFIED' <<<"$out" \
  && pass "a verified secret fails the gate" || fail "verified secret did not fail (rc=$rc)"

# --- the control's verdict is kept per (binary, func file, version) ----------
# The stub logs each call's phase; count the control calls of a run sequence.
CALLS="$T/calls"
log_stub() {
  mkdir -p "$T/bin"
  {
    printf '#!/bin/bash\n# %s\n' "$1"
    printf 'echo "${SEC_TRUFFLEHOG_PHASE:-}" >>"%s"\n' "$CALLS"
    printf '%s\n' '[[ "${SEC_TRUFFLEHOG_PHASE:-}" == control ]] && echo "{\"DetectorName\":\"AWS\"}"' 'exit 0'
  } >"$T/bin/trufflehog"
  chmod +x "$T/bin/trufflehog"
}
ctl_calls() { grep -cx control "$CALLS" 2>/dev/null || true; }
th() { PATH="$T/bin:$PATH" SEC_TRUFFLEHOG_ROOT="$ROOT" do_sec_trufflehog >"$T/th.out" 2>&1; }
export XDG_CACHE_HOME="$T/cache-keep"; : >"$CALLS"
log_stub v1
th && th
c=$(ctl_calls)
[[ "$c" -eq 1 ]] && grep -q 'control: kept for' "$T/th.out" \
  && pass "two runs, one binary: 1 control call" || fail "two runs, one binary: $c control calls (want 1)"
log_stub v2
th; c=$(ctl_calls)
[[ "$c" -eq 2 ]] && pass "a changed binary (new sha256) runs the control again" || fail "changed binary: $c control calls (want 2)"
SEC_TRUFFLEHOG_BIN="$T/bin/trufflehog" th; c=$(ctl_calls)
[[ "$c" -eq 2 ]] && pass "bare name on PATH and full path are one key" || fail "full path: $c control calls (want 2)"
cp "$FUNC" "$T/func-copy.sh"; printf '# one byte\n' >>"$T/func-copy.sh"
c=$( (source "$T/func-copy.sh"; th; th) ; ctl_calls)
[[ "$c" -eq 3 ]] && pass "a changed func file runs the control again (once)" || fail "changed func file: $c control calls (want 3)"
stub trufflehog 'exit 0'
set +e
th; rc1=$?; th; rc2=$?
set -e
[[ "$rc1" -ne 0 && "$rc2" -ne 0 ]] && grep -q 'control:' "$T/th.out" \
  && pass "CONTROL: a silent trufflehog still fails on its second run" || fail "CONTROL: silent second run rc=$rc1/$rc2"
: >"$T/not-a-dir"; export XDG_CACHE_HOME="$T/not-a-dir"; : >"$CALLS"
log_stub v3
set +e
th && th; rc=$?
set -e
c=$(ctl_calls)
[[ "$rc" -eq 0 && "$c" -eq 2 ]] && pass "an unwritable cache only costs the control run" || fail "unwritable cache: rc=$rc, $c control calls (want 0, 2)"
export XDG_CACHE_HOME="$T/cache"

# --- the workflow actually invokes the action -------------------------------
if [[ -f "$WF" ]]; then
  miss=0
  for needle in 'do_sec_trufflehog' 'trufflesecurity/trufflehog' "$_SEC_TRUFFLEHOG_VER"; do
    grep -qF "$needle" "$WF" || { fail "workflow missing $needle"; miss=1; }
  done
  (( miss )) || pass "64_trufflehog.yml installs the pinned trufflehog and runs the action"
else
  fail "no workflow at $WF"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-trufflehog.tst.sh assertions"
exit "$fails"
