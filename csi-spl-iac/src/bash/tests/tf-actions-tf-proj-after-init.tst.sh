#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no tf-*.func.sh action reads $tf_proj before do_tf_init sets it.
#   run.sh runs actions under `set -u`, so an early "${tf_proj}" aborts the
#   action with "tf_proj: unbound variable" before it does anything: measured
#   2026-09-19 on `make do-tf-state-remove`, which pushed a dev 031 `state rm`
#   onto a raw `docker exec` (adhoc-harvest.md row 1).
#   CONTROL: the same scan flags a planted early read.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RUN="$(cd "$TEST_DIR/.." && pwd)/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# early_reads <file> -> "<file>:<line>" for each $tf_proj read before do_tf_init
early_reads() {
  awk -v F="$1" '/^[[:space:]]*#/ { next } /do_tf_init/ { init = 1 }
    !init && /\$\{?tf_proj/ { print F ":" FNR }' "$1"
}

n=0; bad=""
for f in "$RUN"/tf-*.func.sh; do
  grep -q do_tf_init "$f" || continue
  n=$((n + 1)); bad+="$(early_reads "$f")"
done
[[ $n -ge 10 ]] && pass "scanned $n tf-* actions that call do_tf_init" || fail "scanned only $n tf-* actions: the scan is blind"
[[ -z "$bad" ]] && pass "no tf-* action reads \$tf_proj before do_tf_init" || fail "early \$tf_proj read(s): $bad"

printf 'do_x() {\n  do_log "START ${tf_proj}"\n  do_tf_init\n  echo "$tf_proj"\n}\n' >"$T/planted.func.sh"
[[ "$(early_reads "$T/planted.func.sh")" == "$T/planted.func.sh:2" ]] && pass "CONTROL: a planted early read is flagged (and only it)" \
  || fail "CONTROL: planted scan gave '$(early_reads "$T/planted.func.sh")'"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
