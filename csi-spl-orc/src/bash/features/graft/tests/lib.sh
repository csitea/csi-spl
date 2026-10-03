#!/usr/bin/env bash
# lib.sh -- the three lines every graft suite needs.
# shellcheck disable=SC2034  # SCRIPTS, ASSETS: read by the suites that source this
FEATURE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPTS="$FEATURE_DIR/scripts"
ASSETS="$FEATURE_DIR/assets"
T_PASS=0; T_FAIL=0
ok()   { T_PASS=$((T_PASS+1)); echo "  ok   $*"; }
bad()  { T_FAIL=$((T_FAIL+1)); echo "  FAIL $*"; }
skip() { echo "  skip $*"; }
is()   { # got want label
  if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 -- got [$1] want [$2]"; fi
}
has()  { # haystack needle label
  case "$1" in *"$2"*) ok "$3" ;; *) bad "$3 -- [$2] not in output" ;; esac
}
hasnt() { case "$1" in *"$2"*) bad "$3 -- [$2] IS in output" ;; *) ok "$3" ;; esac }
finish() {
  echo "  -- $T_PASS passed, $T_FAIL failed"
  [ "$T_FAIL" -eq 0 ]
}
