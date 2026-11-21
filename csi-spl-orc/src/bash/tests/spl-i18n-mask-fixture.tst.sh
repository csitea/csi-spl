#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the shared fixture of the i18n mask (spec 123 section 16.6.5, row
#          L3). The hub's Go port (csi-spl-api .../internal/i18nmask) must give
#          the same tokens as the bash action do_spl_i18n_mask (spec 115 T9):
#          fixtures/i18n-mask/input.txt masked with terms.txt is masked.txt,
#          with the map map.tsv. This test pins the bash side; the Go side is
#          internal/i18nmask/mask_test.go, on the same files.
#          SPL_I18N_MASK_FIXTURE_WRITE=1 rewrites masked.txt and map.tsv from
#          the bash action instead (then run the Go test).
#          Every value of the fixture is synthetic.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FIX="$TEST_DIR/fixtures/i18n-mask"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
FUNC="$PROJ_ROOT/src/bash/run/spl-i18n-mask.func.sh"

# mask <input> <terms> <out-dir>: the bash action's own matcher (its mask
# mode, the one of do_spl_i18n_mask) on one file: <out-dir>/agy/input.txt and
# <out-dir>/map.tsv. The action's leak check is left out on purpose: the
# fixture plants near misses (XTesti, 12040 123 4567) that must stay as they
# are, and the check would refuse them as an original value left in the copy.
mask() {
  mkdir -p "$3/agy"
  FUNC_FILE="$FUNC" IN="$1" TERMS="$2" OUT="$3" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$FUNC_FILE"
    printf "%s\0%s\0" "$IN" "$OUT/agy/input.txt" | perl -e "$_SPL_I18N_MASK_PL" mask "$TERMS" "$OUT/map.tsv"' >"$T/out" 2>&1 </dev/null
}

for f in input.txt terms.txt; do
  [[ -s "$FIX/$f" ]] || { fail "0. no fixture $FIX/$f"; echo "FAILED: $fails"; exit 1; }
done
mkdir -p "$T/src" "$T/spool"
cp "$FIX/input.txt" "$T/src/input.txt"
mask "$T/src/input.txt" "$FIX/terms.txt" "$T/mask"
rc=$?
[[ $rc == 0 && -f "$T/mask/agy/input.txt" ]] && pass "1. the bash matcher masks the fixture (rc 0)" \
  || { fail "1. mask rc=$rc: $(cat "$T/out")"; echo "FAILED: $fails"; exit 1; }

if [[ "${SPL_I18N_MASK_FIXTURE_WRITE:-0}" == 1 ]]; then
  cp "$T/mask/agy/input.txt" "$FIX/masked.txt"
  cp "$T/mask/map.tsv" "$FIX/map.tsv"
  chmod 0644 "$FIX/map.tsv"
  echo "WROTE: $FIX/masked.txt $FIX/map.tsv (now run the Go test: go test ./internal/i18nmask/)"
  exit 0
fi

cmp -s "$T/mask/agy/input.txt" "$FIX/masked.txt" && pass "2. the bash action's masked text is fixtures/i18n-mask/masked.txt" \
  || fail "2. masked text differs: $(diff "$FIX/masked.txt" "$T/mask/agy/input.txt" | sed -n 1,5p)"
cmp -s "$T/mask/map.tsv" "$FIX/map.tsv" && pass "3. the bash action's map is fixtures/i18n-mask/map.tsv" \
  || fail "3. map differs: $(diff <(cut -f1 "$FIX/map.tsv") <(cut -f1 "$T/mask/map.tsv") | sed -n 1,5p)"
n=$(grep -cE '^\[(EMAIL|PHONE|NAME|WORKSPACE|OTHER)_[0-9]+\]	' "$FIX/map.tsv")
(( n >= 10 )) && pass "4. the fixture exercises $n tokens" || fail "4. only $n tokens: the fixture no longer exercises the rules"

# CONTROL: a changed term list must change the tokens (the compare is live)
grep -v '^name Testi$' "$FIX/terms.txt" >"$T/terms-less.txt"
mask "$T/src/input.txt" "$T/terms-less.txt" "$T/mask2"
! cmp -s "$T/mask2/agy/input.txt" "$FIX/masked.txt" && pass "5. CONTROL: one term less gives another masked text" \
  || fail "5. CONTROL: the masked text did not change without a term"

if (( fails )); then echo "FAILED: $fails"; exit 1; fi
echo "ALL PASS"
