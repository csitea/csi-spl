#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_parse_metadata / do_validate_params trim in bash, not with a
#          `sed`/`awk`/`grep` fork per line. They run on EVERY ./run, and the
#          forks were ~0.5 s of a desk reply (2026-09-25). The output must not
#          move by one byte:
#   1. every *.func.sh in the repo parses to the SAME bytes as the reference
#      (the previous sed-based trim, kept below as the control)
#   2. whitespace edge cases: tabs, trailing blanks, continuation lines
#   3. do_validate_params still refuses a missing (required) var, any case,
#      and passes when it is set
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
LIB="$PROJ_ROOT/lib/bash/funcs"

# The reference: the parser as it was, with the forking trims.
sed -e 's/^do_parse_metadata()/ref_parse_metadata()/' "$LIB/parse-metadata.func.sh" >"$T/ref.sh"
python3 - "$T/ref.sh" <<'PY'
import re, sys
p = sys.argv[1]; s = open(p).read()
s = re.sub(r'      current_value="\$\{current_value#.*\n.*\n', '      current_value="$(echo "$current_value" | sed \'s/^[[:space:]]*//;s/[[:space:]]*$//\')"\n', s, count=1)
s = s.replace('    line="${line#"${line%%[![:space:]]*}"}"', '    line="$(echo "$line" | sed \'s/^[[:space:]]*//\')"', 1)
open(p, "w").write(s)
PY
grep -q "sed 's/^\[\[:space:\]\]\*//;s" "$T/ref.sh" && grep -q "line=\"\$(echo \"\$line\" | sed" "$T/ref.sh" &&
  pass "CONTROL the reference really is the forking parser" || fail "CONTROL the reference was not rebuilt"

n=0 bad=0
while IFS= read -r f; do
  n=$((n + 1))
  a="$(bash -c 'source "$1"; ref_parse_metadata "$2"' _ "$T/ref.sh" "$f")"
  b="$(bash -c 'source "$1"; do_parse_metadata "$2"' _ "$LIB/parse-metadata.func.sh" "$f")"
  [[ "$a" == "$b" ]] || { bad=$((bad + 1)); echo "  differs: $f"; }
done < <(find "$APP_ROOT" -name '*.func.sh' -not -path '*/node_modules/*' -not -path '*/tpl-gen/*' | sort)
[[ $n -gt 50 && $bad -eq 0 ]] && pass "1 all $n *.func.sh parse to the same bytes" || fail "1 $bad of $n differ"

printf '#!/bin/bash\n#---\n# @description \t lead and trail \t \n#   continued  \n# @param A_VAR (Required) - x\n# @param B_VAR (optional) - y  \n# @example\n#    ex on next line\n#---\nf() { :; }\n' >"$T/edge.func.sh"
a="$(bash -c 'source "$1"; ref_parse_metadata "$2"' _ "$T/ref.sh" "$T/edge.func.sh")"
b="$(bash -c 'source "$1"; do_parse_metadata "$2"' _ "$LIB/parse-metadata.func.sh" "$T/edge.func.sh")"
[[ "$a" == "$b" ]] && pass "2 tabs, trailing blanks and continuations match" || fail "2 edge: ref=[$a] new=[$b]"

v() { env -u A_VAR -u B_VAR "$@" bash -c 'do_log() { echo "$*"; }; source "$1"; source "$2"; do_validate_params "$3"' _ \
        "$LIB/parse-metadata.func.sh" "$LIB/validate-params.func.sh" "$T/edge.func.sh"; }
out="$(v)"; rc=$?
[[ $rc -eq 11 && "$out" == *"Required parameter A_VAR is not set."* && "$out" != *B_VAR* ]] &&
  pass "3 a missing (Required) var is refused (rc 11), an optional one is not" || fail "3 rc=$rc out=$out"
out="$(v A_VAR=1)"; rc=$?
[[ $rc -eq 0 ]] && pass "3 …and passes once it is set" || fail "3 set: rc=$rc out=$out"

echo "--- $fails failure(s)"
[[ "$fails" -eq 0 ]]
