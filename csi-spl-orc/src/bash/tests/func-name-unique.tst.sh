#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no top-level function is defined in two orc *.func.sh files.
#   ./run sources every lib/bash/funcs + src/bash/run *.func.sh in sorted
#   order, so of two same-named functions the later file silently wins. wf 30
#   run 37892580445 died that way: spl-blog-media-put.func.sh redefined
#   copy-blog-media.func.sh's spl_blog_media_check with another signature.
#   1. the real tree: 0 names defined at column 0 in two files
#   2. CONTROL: a fixture tree with one duplicate is caught, file names given
# Indented (nested or deliberately overriding) definitions are not counted.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# dups <dir>...: "<name> <file> <file>..." per name defined in two files
dups() {
  find "$@" -type f -name '*.func.sh' -print0 | sort -z |
    xargs -0 grep -HoE '^(function[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)' |
    sed -E 's/:(function[[:space:]]+)?/\t/; s/[[:space:]]*\(\)$//' |
    awk -F'\t' '!seen[$2 FS $1]++ { n[$2]++; f[$2] = f[$2] " " $1 }
      END { for (k in n) if (n[k] > 1) print k f[k] }' | sort
}

out=$(dups "$PROJ_ROOT/lib/bash/funcs" "$PROJ_ROOT/src/bash/run")
if [[ -z "$out" ]]; then pass "no function is defined in two orc *.func.sh files"
else fail "defined in two files (the later one wins under ./run): $out"; fi

mkdir -p "$T/fx/a"
printf 'do_one() { :; }\nhelper() { echo 1; }\n' >"$T/fx/a/one.func.sh"
printf 'do_two() {\n  inner() { :; }\n}\nfunction helper () { echo 2; }\n' >"$T/fx/a/two.func.sh"
printf 'do_three() {\n  inner() { :; }\n}\n' >"$T/fx/three.func.sh"
out=$(dups "$T/fx")
[[ "$out" == "helper $T/fx/a/one.func.sh $T/fx/a/two.func.sh" ]] &&
  pass "CONTROL: a duplicate helper is caught and both files named; nested inner() is not" ||
  fail "CONTROL: got '$out'"

((fails == 0)) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
