#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the action header tags gate (r44-05, developer guide 2.4.2). Every
#          src/bash/run/*.func.sh of iac, orc and utl that defines a do_*()
#          is parsed by do_parse_metadata (lib/bash/funcs/parse-metadata.func.sh,
#          the parser ./run --help reads) and must carry:
#   1. a description= and an example= line, unless the baseline's [missing]
#      section lists the file;
#   2. no example= value over MAX_EXAMPLE (200) characters, unless the
#      [long-example] section lists it: the header ends at its closing #---
#      (r46-01), so only an @example and its continuation lines are read;
#   3. a listed file that now passes FAILS: the baseline only shrinks, like
#      .shellcheck-warning-baseline.txt. Fix a header, delete its line.
# Red controls in a mktemp tree: a file without @example, a file with one
# @example line over 200 characters, a listed file that now has both tags.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
APP_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
BASELINE="$TEST_DIR/action-header-tags-baseline.txt"
MAX_EXAMPLE=200
# shellcheck source=SCRIPTDIR/../../../lib/bash/funcs/parse-metadata.func.sh
source "$APP_ROOT/csi-spl-iac/lib/bash/funcs/parse-metadata.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# section <baseline> <name> -> the file paths listed under [<name>].
section() {
  awk -v s="[$2]" '/^[[:space:]]*(#|$)/ { next } /^\[/ { on = ($1 == s); next } on { print $1 }' "$1"
}

# action_files <root> -> every run/*.func.sh (repo-relative) that defines a do_*().
action_files() {
  local f
  for f in "$1"/csi-spl-{iac,orc,utl}/src/bash/run/*.func.sh; do
    [[ -f "$f" ]] || continue
    echo "$f"
  done | xargs -r grep -lE '^[[:space:]]*(function[[:space:]]+)?do_[A-Za-z0-9_]+[[:space:]]*\(\)' | sed "s#^$1/##"
}

# has_tag <meta> <tag>: true when the parsed header carries a <tag>= line.
# has_long_example <meta>: true when one example= value is over MAX_EXAMPLE.
# Pure bash, no fork: the walk runs them on ~765 files.
has_tag() { [[ $'\n'"$1" == *$'\n'"$2="* ]]; }
has_long_example() {
  local l
  while IFS= read -r l; do
    [[ "$l" == example=* ]] && (( ${#l} - 8 > MAX_EXAMPLE )) && return 0
  done <<<"$1"
  return 1
}

# check_tree <root> <baseline>: one FAIL line per violation, then the summary
# line "measured <n> files: <m> missing, <l> long-example".
check_tree() {
  local root=$1 base=$2 rel meta n=0 nm=0 nl=0
  local -A lmiss=() llong=() miss=() long=()
  while read -r rel; do [[ -n "$rel" ]] && lmiss[$rel]=1; done < <(section "$base" missing)
  while read -r rel; do [[ -n "$rel" ]] && llong[$rel]=1; done < <(section "$base" long-example)
  while read -r rel; do
    n=$((n + 1))
    meta=$(do_parse_metadata "$root/$rel")
    if ! has_tag "$meta" description || ! has_tag "$meta" example; then
      miss[$rel]=1; nm=$((nm + 1))
      [[ -n "${lmiss[$rel]:-}" ]] || echo "FAIL: $rel: no description= or no example= in its parsed header (add @description and @example; never list a new file)"
    fi
    if has_long_example "$meta"; then
      long[$rel]=1; nl=$((nl + 1))
      [[ -n "${llong[$rel]:-}" ]] || echo "FAIL: $rel: an example= over $MAX_EXAMPLE characters (shorten the @example, or split it into two)"
    fi
  done < <(action_files "$root")
  for rel in "${!lmiss[@]}"; do
    [[ -n "${miss[$rel]:-}" ]] || echo "FAIL: $rel is listed under [missing] but now has both tags (or is gone): delete its line"
  done
  for rel in "${!llong[@]}"; do
    [[ -n "${long[$rel]:-}" ]] || echo "FAIL: $rel is listed under [long-example] but has no example= over $MAX_EXAMPLE now (or is gone): delete its line"
  done
  echo "measured $n files: $nm missing, $nl long-example"
}

# --- red controls: each planted defect must FAIL ----------------------------
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
mkdir -p "$T/csi-spl-iac/src/bash/run" "$T/csi-spl-orc/src/bash/run" "$T/csi-spl-utl/src/bash/run"
good='#!/bin/bash
#------------------------------------------------------------------------------
# @description Say hello.
# @example ./run -a do_say_hello
#------------------------------------------------------------------------------

do_say_hello() { echo hello; }'
printf '%s\n' "$good" >"$T/csi-spl-iac/src/bash/run/say-hello.func.sh"
printf '[missing]\n[long-example]\n' >"$T/base.txt"

# control <name>: the temp tree as set up must FAIL; quote the FAIL line.
control() {
  local out line
  out=$(check_tree "$T" "$T/base.txt")
  line=$(grep -m1 '^FAIL' <<<"$out")
  if [[ -n "$line" ]]; then pass "RED CONTROL $1 -> $line"; else fail "RED CONTROL $1 did not fail: $out"; fi
}

out=$(check_tree "$T" "$T/base.txt")
if grep -q '^FAIL' <<<"$out"; then fail "CONTROL: a clean tree fails: $out"
else pass "CONTROL: a clean tree passes ($(tail -1 <<<"$out"))"; fi

printf '%s\n' "$good" | sed '/@example/d' >"$T/csi-spl-orc/src/bash/run/no-example.func.sh"
control "an action without @example"
rm "$T/csi-spl-orc/src/bash/run/no-example.func.sh"

long="# @example ./run -a do_say_hello $(printf 'x%.0s' {1..200})"
printf '%s\n' "$good" | sed "s|^# @example .*|$long|" >"$T/csi-spl-utl/src/bash/run/long.func.sh"
control "an action with one @example line over 200 characters"
rm "$T/csi-spl-utl/src/bash/run/long.func.sh"

printf '%s\n' "$good" >"$T/csi-spl-orc/src/bash/run/fixed.func.sh"
printf '[missing]\ncsi-spl-orc/src/bash/run/fixed.func.sh\n[long-example]\n' >"$T/base.txt"
control "a listed file given both tags"

# --- the real tree -----------------------------------------------------------
if [[ -s "$BASELINE" ]]; then
  out=$(check_tree "$APP_ROOT" "$BASELINE")
  grep '^FAIL' <<<"$out"
  fails=$((fails + $(grep -c '^FAIL' <<<"$out")))
  n=$(tail -1 <<<"$out" | awk '{ print $2 }')
  if [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 500 )); then pass "the real tree: $(tail -1 <<<"$out")"
  else fail "the walk measured only '$n' action files: the walk is broken, not the code"; fi
  grep -q '^FAIL' <<<"$out" || pass "the real tree matches the baseline"
else
  fail "no baseline at $BASELINE"
fi

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
