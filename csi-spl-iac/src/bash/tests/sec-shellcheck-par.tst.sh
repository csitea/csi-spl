#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_sec_shellcheck's one parallel -S warning pass (perf round 4, C4)
#          sees every file across its batches, keeps a tool error (exit >= 2)
#          apart from findings (exit 1), and with the REAL shellcheck derives
#          the same error lines a separate -S error pass prints.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/sec-shellcheck.func.sh"

fails=0

require_action "$FUNC"

do_log() { printf '%s\n' "$*"; }
# shellcheck source=../run/sec-shellcheck.func.sh
source "$FUNC"

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

# 95 files: 3 batches of 40, run 2 at a time.
ROOT="$T/root"; R="$ROOT/csi-spl-iac/src/bash/run"
mkdir -p "$R"
for i in $(seq -w 1 95); do printf '#!/usr/bin/env bash\ntrue\n' >"$R/f$i.func.sh"; done
printf '# empty\n' >"$ROOT/.shellcheck-warning-baseline.txt"
export SEC_SHELLCHECK_JOBS=2

# --- every file is scanned once, in one warn-phase pass ----------------------
stub shellcheck 'if [[ "${SEC_SHELLCHECK_PHASE:-}" == control ]]; then echo "c.sh:1:1: error: g [SC2144]"; exit 1; fi
echo "$SEC_SHELLCHECK_PHASE $*" >>"'"$T"'/calls"; for f in "$@"; do [[ "$f" == *.sh ]] && echo "$f" >>"'"$T"'/seen"; done; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -eq 0 ]] && pass "95 clean files pass" || { fail "clean tree failed (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }
n=$(sort -u "$T/seen" | wc -l); dup=$(wc -l <"$T/seen")
[[ "$n" -eq 95 && "$dup" -eq 95 ]] && pass "every file scanned exactly once across batches" || fail "seen $n unique of $dup scans, want 95/95"
[[ "$(wc -l <"$T/calls")" -eq 3 ]] && ! grep -qv '^warn -S warning ' "$T/calls" \
  && pass "one -S warning pass, 3 batches, no separate error pass" || { fail "calls:"; sed 's/^/    | /' "$T/calls"; }

# --- an error line in ONE batch fails the error gate, not the ratchet --------
stub shellcheck 'if [[ "${SEC_SHELLCHECK_PHASE:-}" == control ]]; then echo "c.sh:1:1: error: g [SC2144]"; exit 1; fi
for f in "$@"; do [[ "$f" == */f77.func.sh ]] && { echo "$f:2:1: error: x [SC2148]"; echo "$f:2:1: warning: w [SC2034]"; exit 1; }; done; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'FATAL shellcheck: error-level findings' <<<"$out" && grep -q 'f77.func.sh:2:1: error: x' <<<"$out" \
  && ! grep -q 'warning: w' <<<"$out" && ! grep -q 'NEW ' <<<"$out" \
  && pass "an error in one batch fails the error gate and prints only error lines" || { fail "error in a batch (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- a tool error (exit 2) fails even with no output -------------------------
stub shellcheck 'if [[ "${SEC_SHELLCHECK_PHASE:-}" == control ]]; then echo "c.sh:1:1: error: g [SC2144]"; exit 1; fi
for f in "$@"; do [[ "$f" == */f10.func.sh ]] && exit 2; done; exit 0'
set +e
out=$(PATH="$T/bin:$PATH" SEC_SHELLCHECK_ROOT="$ROOT" do_sec_shellcheck 2>&1); rc=$?
set -e
[[ "$rc" -ne 0 ]] && grep -q 'tool error: exit 2' <<<"$out" \
  && pass "CONTROL: a silent exit 2 in one batch is a tool error, not a pass" || { fail "tool error accepted (rc=$rc)"; sed 's/^/    | /' <<<"$out"; }

# --- real shellcheck: error lines of the warning pass == a -S error pass -----
REAL_SC="$(command -v shellcheck 2>/dev/null || true)"
if [[ -n "$REAL_SC" ]]; then
  P="$T/plant"; mkdir -p "$P"
  printf '#!/bin/bash\nif [ -f *.log ]; then echo y; fi\nx=1\n' >"$P/bad.sh"
  printf '#!/bin/bash\necho $1\n' >"$P/warn.sh"
  set +e
  "$REAL_SC" -S error -f gcc "$P/bad.sh" "$P/warn.sh" | sort >"$T/err.ref"
  _sec_shellcheck_par "$REAL_SC" warning warn "$T/w.log" "$P/bad.sh" "$P/warn.sh"; prc=$?
  grep ': error: ' "$T/w.log" | sort >"$T/err.new"
  set -e
  [[ "$prc" -eq 0 && -s "$T/err.ref" ]] && cmp -s "$T/err.ref" "$T/err.new" && grep -q 'SC2034' "$T/w.log" \
    && pass "real shellcheck: planted SC2144 found, error lines identical to a -S error pass" \
    || { fail "real shellcheck parity (rc=$prc)"; diff "$T/err.ref" "$T/err.new" | sed 's/^/    | /'; }
else
  pass "(no shellcheck on this host; real-tool parity leg not applicable)"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all sec-shellcheck-par.tst.sh assertions"
exit "$fails"
