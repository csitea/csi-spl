#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the bash clean-code gate (CLE-77915, refactor item 5) - the limit the
#          hub's Go gate holds (csi-spl-api internal/cleancode), over every
#          top-level function in the product bash trees (tests aside): ROOTS,
#          iac + orc + cnf + utl, and the .sh files of csi-spl-api/src and
#          csi-spl-wui/src (r24-02). csi-spl-doc/.specify is not walked: it is
#          the vendored spec-kit scaffold, upstream code.
#          A function longer than MAX_LINES fails unless LONG lists it. LONG is
#          what was over the limit when the gate landed and may only shrink:
#          split a function and delete its line; a NEW long function fails.
#          Each LONG entry carries a ceiling (r5-06): a listed function that
#          grows past it fails too. Lower a ceiling when the function shrinks.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
APP_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
MAX_LINES=80

# <file> <function> <ceiling>: the ceiling is its length on 2026-10-10 (r5-06).
LONG="
  csi-spl-iac/src/bash/run/gcp-002-delete-project-service-account.func.sh do_gcp_002_delete_project_service_account 132
  csi-spl-iac/src/bash/run/provision-firebase-dns.func.sh do_provision_firebase_dns 169
"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# measure <file>... -> "<lines> <file> <function>" per top-level function. A
# one-line function (`f() { ...; }`) closes on its own line, length 1 (r8-04):
# left open, it swallowed every function up to the next `^}`. A column-1 header
# closes the function still open (length = header line - start), and `^) }`
# closes like `^}` (r9-05): a body closed inline (`' "$1"; }`) or a subshell
# body (`f() { (` ... `) }`) hid every function after it.
measure() {
  local f
  for f in "$@"; do
    awk -v f="${f#$APP_ROOT/}" '
      /^[A-Za-z_][A-Za-z0-9_:.-]*\(\)[[:space:]]*\{/ { if (n) print NR - s, f, n
        n = $1; sub(/\(\).*/, "", n); s = NR
        if ($0 ~ /\}[[:space:]]*(#.*)?$/) { print 1, f, n; n = "" } }
      /^(\)[[:space:]]*)?\}/ { if (n) { print NR - s + 1, f, n; n = "" } }' "$f"
  done
}

# check_long <measured> <long-list>: a function over MAX_LINES fails unless the
# list carries it, and fails above its ceiling; a NOTE names a ceiling to lower
# or a line to delete.
check_long() {
  local all=$1 list=$2 lines file fn cap new=0 long=""
  local -A ceil=()
  while read -r file fn cap; do
    [[ -n "$cap" ]] && ceil["$file $fn"]=$cap
  done < <(sed -E 's/[[:space:]]*#.*//' <<<"$list")
  while read -r lines file fn; do
    (( lines > MAX_LINES )) || continue
    long+="$file $fn $lines"$'\n'
    cap=${ceil["$file $fn"]:-}
    if [[ -z "$cap" ]]; then
      fail "$file $fn is $lines lines (> $MAX_LINES): split it into named steps (or add it to LONG with a reason in the commit)"; new=$((new + 1))
    elif (( lines > cap )); then
      fail "$file $fn is $lines lines, over its LONG ceiling $cap: split it into named steps, never raise the ceiling"; new=$((new + 1))
    fi
  done <<<"$all"
  (( new == 0 )) && pass "no function over $MAX_LINES lines outside LONG or over its ceiling ($(grep -c . <<<"$long") listed)"
  while read -r file fn cap; do
    [[ -n "$cap" ]] || continue
    lines=$(awk -v k="$file $fn" '$1" "$2 == k { print $3 }' <<<"$long")
    if [[ -z "$lines" ]]; then
      echo "NOTE LONG: '$file $fn' is no longer over $MAX_LINES lines (or is gone) - delete its line"
    elif (( lines < cap )); then
      echo "NOTE LONG: '$file $fn' is $lines lines, under its ceiling $cap - lower the ceiling to $lines"
    fi
  done < <(sed -E 's/[[:space:]]*#.*//' <<<"$list")
}

ROOTS="csi-spl-iac/src/bash csi-spl-iac/lib/bash csi-spl-orc/src/bash csi-spl-orc/lib/bash csi-spl-cnf/src/bash
  csi-spl-utl/src/bash csi-spl-api/src csi-spl-wui/src"
# shellcheck disable=SC2086 # ROOTS is a word list
mapfile -t files < <(cd "$APP_ROOT" && find $ROOTS \
  -type f -name '*.sh' ! -path '*/tests/*' ! -path '*/node_modules/*' 2>/dev/null | sort | sed "s#^#$APP_ROOT/#")
all=$(measure "${files[@]}")
n=$(grep -c . <<<"$all")
[[ $n -ge 500 ]] && pass "the walk measured $n functions in ${#files[@]} files" || fail "measured only $n functions: the walk is broken, not the code"
check_long "$all" "$LONG"

# Control (r24-02): every root is walked. A root dropped from ROOTS passes
# vacuously, so one known file of each newly walked tree must be in the list.
for want in csi-spl-utl/src/bash/run/reboot-required-check.func.sh csi-spl-api/src/bash/build.sh csi-spl-wui/src/docker/wui-config.sh; do
  [[ " ${files[*]} " == *" $APP_ROOT/$want "* ]] && pass "CONTROL: the walk lists $want" || fail "CONTROL: the walk does not list $want: a root was dropped"
done

# Control: the measure counts a known function right.
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
printf 'a() {\n  echo 1\n  echo 2\n}\nb() { :; }\n' >"$T/x.sh"
got=$(APP_ROOT="$T" measure "$T/x.sh" | sed -n 1p)
[[ "$got" == "4 $T/x.sh a" || "$got" == "4 x.sh a" ]] && pass "CONTROL: a 4-line function measures 4" || fail "CONTROL: measured '$got'"

# Red control (r8-04): a one-liner followed by a 100-line function. The old awk
# left the one-liner open, so the 100-line function was never listed.
{ echo 'one() { :; }'; echo 'big() {'; for ((i = 0; i < 98; i++)); do echo '  :'; done; echo '}'; } >"$T/o.sh"
got=$(APP_ROOT="$T" measure "$T/o.sh")
[[ "$got" == $'1 o.sh one\n100 o.sh big' ]] && pass "CONTROL: a one-liner measures 1 and the 100-line function after it measures 100" || fail "CONTROL: one-liner then 100 lines measured '$got'"

# Red control (r9-05): a body closed inline (`' "$1"; }`) and a subshell body
# (`f() { (` ... `) }`), each followed by a 100-line function. The old awk left
# both open, so the 100-line function after them was never listed.
big100() { echo 'big() {'; for ((i = 0; i < 98; i++)); do echo '  :'; done; echo '}'; }
{ printf '%s\n' 'q() { python3 -c '"'" 'print(1)' "'"' "$1"; }'; big100; } >"$T/q.sh"
got=$(APP_ROOT="$T" measure "$T/q.sh")
[[ "$got" == $'3 q.sh q\n100 q.sh big' ]] && pass "CONTROL: a body closed inline measures 3 and the 100-line function after it measures 100" || fail "CONTROL: inline close then 100 lines measured '$got'"
{ printf '%s\n' 'p() { (' '  :' ') }'; big100; } >"$T/p.sh"
got=$(APP_ROOT="$T" measure "$T/p.sh")
[[ "$got" == $'3 p.sh p\n100 p.sh big' ]] && pass "CONTROL: a subshell body measures 3 and the 100-line function after it measures 100" || fail "CONTROL: subshell body then 100 lines measured '$got'"

# Red control (r5-06): a listed function one line over its ceiling fails, at the
# ceiling passes, one line under prints the NOTE to lower it.
grown() { { echo 'g() {'; for ((i = 0; i < $1 - 2; i++)); do echo '  :'; done; echo '}'; } >"$T/g.sh"; APP_ROOT="$T" measure "$T/g.sh"; }
out=$(check_long "$(grown 91)" "g.sh g 90")
[[ "$out" == *"FAIL: g.sh g is 91 lines, over its LONG ceiling 90"* ]] && pass "CONTROL: a listed function grown 1 line past its ceiling fails" || fail "CONTROL: ceiling+1 did not fail: $out"
out=$(check_long "$(grown 90)" "g.sh g 90")
[[ "$out" != *FAIL* && "$out" != *NOTE* ]] && pass "CONTROL: a listed function at its ceiling passes" || fail "CONTROL: at the ceiling: $out"
out=$(check_long "$(grown 89)" "g.sh g 90")
[[ "$out" != *FAIL* && "$out" == *"lower the ceiling to 89"* ]] && pass "CONTROL: a listed function under its ceiling prints the NOTE" || fail "CONTROL: under the ceiling: $out"

[[ "$fails" -eq 0 ]] && echo "PASS: all $(basename "$0") assertions"
exit "$fails"
