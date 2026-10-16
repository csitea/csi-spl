#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_parse_metadata / do_validate_params trim in bash, not with a
#          `sed`/`awk`/`grep` fork per line. They run on EVERY ./run, and the
#          forks were ~0.5 s of a desk reply (2026-09-25). The output must not
#          move by one byte. The same checks run on the iac copy and the orc
#          copy:
#   1. every *.func.sh in the repo parses to the SAME bytes as the reference
#      (the previous sed-based trim, kept below as the control)
#   2. whitespace edge cases: tabs, trailing blanks, continuation lines
#   3. do_validate_params still refuses a missing (required) var, any case,
#      and passes when it is set
#   4. do_require_var X '' exits 1. The line it prints is [FATAL] (that is
#      the level word in the function), and the text names the variable.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
ORC_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$ORC_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT

printf '#!/bin/bash\n#---\n# @description \t lead and trail \t \n#   continued  \n# @param A_VAR (Required) - x\n# @param B_VAR (optional) - y  \n# @example\n#    ex on next line\n#---\nf() { :; }\n' >"$T/edge.func.sh"

# One tree: rebuild the forking parser as the reference, then compare.
check_tree() {
  local which="$1"
  local proj="$2"
  local lib="$proj/lib/bash/funcs"
  local ref="$T/ref-$which.sh"
  local sref="$T/sref-$which.sh"
  local n=0 bad=0 i key f a b out rc

  sed -e 's/^do_parse_metadata()/ref_parse_metadata()/' "$lib/parse-metadata.func.sh" >"$ref"
  # $ref: one `echo | sed` fork per header line and per tag, as it was.
  # $sref: the same, its two sed programs ($T/sed-line, $T/sed-val) fed to one
  # long-lived `sed -u` each (fds 5/6 and 7/8) instead: same programs, same
  # bytes, ~40 k fewer forks over the corpus.
  python3 - "$ref" "$sref" "$T" <<'PY'
import re, sys
p, sp, t = sys.argv[1:4]; s = open(p).read()
lprog, vprog = 's/^[[:space:]]*//', 's/^[[:space:]]*//;s/[[:space:]]*$//'
open(t + "/sed-line", "w").write(lprog); open(t + "/sed-val", "w").write(vprog)
vold, lold = re.compile(r'      current_value="\$\{current_value#.*\n.*\n'), '    line="${line#"${line%%[![:space:]]*}"}"'
f = vold.sub(lambda m: '      current_value="$(echo "$current_value" | sed \'%s\')"\n' % vprog, s, count=1)
open(p, "w").write(f.replace(lold, '    line="$(echo "$line" | sed \'%s\')"' % lprog, 1))
st = vold.sub(lambda m: '      printf \'%s\\n\' "$current_value" >&7; IFS= read -r current_value <&8\n', s, count=1)
st = st.replace(lold, '    printf \'%s\\n\' "$line" >&5; IFS= read -r line <&6', 1)
open(sp, "w").write(st.replace("ref_parse_metadata()", "ref_stream_parse_metadata()", 1))
PY
  if grep -q "sed 's/^\[\[:space:\]\]\*//;s" "$ref" && grep -q "line=\"\$(echo \"\$line\" | sed" "$ref" \
    && grep -q '"$line" >&5; IFS= read -r line <&6' "$sref" \
    && grep -q '"$current_value" >&7; IFS= read -r current_value <&8' "$sref"; then
    pass "$which: CONTROL the reference really is the forking parser"
  else
    fail "$which: CONTROL the reference was not rebuilt"
  fi

  # One shell per parser, each file parsed in its own subshell. The forking
  # reference was ~0.1 s a file, nearly all of this test's time (191 s of the
  # orc suite, 2026-10-08), so the corpus runs on $sref, and its outputs are
  # kept per reference FUNCTION text: the orc and iac copies differ in
  # comments only, define the same function, and so the reference runs once,
  # not once per tree. The parser under test still runs on every file for
  # each tree.
  key="$(bash -c 'source "$1"; declare -f ref_parse_metadata' _ "$ref" | md5sum | cut -c1-32)"
  if [[ ! -d "$T/ref-out-$key" ]]; then
    mkdir "$T/ref-out-$key" "$T/fork-out-$key" "$T/fifo-$key"
    mkfifo "$T/fifo-$key/l.in" "$T/fifo-$key/l.out" "$T/fifo-$key/v.in" "$T/fifo-$key/v.out"
    bash -c 'source "$1"; d="$3"
      sed -u "$(cat "$4/sed-line")" <"$d/l.in" >"$d/l.out" &
      sed -u "$(cat "$4/sed-val")" <"$d/v.in" >"$d/v.out" &
      exec 5>"$d/l.in" 6<"$d/l.out" 7>"$d/v.in" 8<"$d/v.out"
      i=0; while IFS= read -r f; do i=$((i + 1)); printf %s "$(ref_stream_parse_metadata "$f")" >"$2/$i"; done
      exec 5>&- 7>&-; wait' \
      _ "$sref" "$T/ref-out-$key" "$T/fifo-$key" "$T" <"$T/files"
    # Every 50th file through the forking reference too: the stream one must
    # give its bytes, or the corpus check below proves nothing.
    bash -c 'source "$1"; while IFS= read -r i; do printf %s "$(ref_parse_metadata "$(sed -n "${i}p" "$3")")" >"$2/$i"; done' \
      _ "$ref" "$T/fork-out-$key" "$T/files" < <(awk 'NR % 50 == 1 { print NR }' "$T/files")
    i=0
    for f in "$T/fork-out-$key"/*; do
      i=$((i + 1)); cmp -s "$f" "$T/ref-out-$key/${f##*/}" || { bad=$((bad + 1)); echo "  stream ref differs: file #${f##*/}"; }
    done
    [[ $i -gt 10 && $bad -eq 0 ]] && pass "CONTROL the stream reference gives the forking bytes on $i sampled files" \
      || fail "CONTROL the stream reference differs on $bad of $i sampled files"
    bad=0
  fi
  mkdir "$T/new-out-$which"
  bash -c 'source "$1"; i=0; while IFS= read -r f; do i=$((i + 1)); printf %s "$(do_parse_metadata "$f")" >"$2/$i"; done' \
    _ "$lib/parse-metadata.func.sh" "$T/new-out-$which" <"$T/files"
  i=0
  while IFS= read -r f; do
    i=$((i + 1)); n=$((n + 1))
    cmp -s "$T/ref-out-$key/$i" "$T/new-out-$which/$i" || { bad=$((bad + 1)); echo "  differs: $f"; }
  done <"$T/files"
  [[ $n -gt 50 && $bad -eq 0 ]] && pass "$which: 1 all $n *.func.sh parse to the same bytes" || fail "$which: 1 $bad of $n differ"

  a="$(bash -c 'source "$1"; ref_parse_metadata "$2"' _ "$ref" "$T/edge.func.sh")"
  b="$(bash -c 'source "$1"; do_parse_metadata "$2"' _ "$lib/parse-metadata.func.sh" "$T/edge.func.sh")"
  [[ "$a" == "$b" ]] && pass "$which: 2 tabs, trailing blanks and continuations match" || fail "$which: 2 edge: ref=[$a] new=[$b]"

  rc=0
  out="$(env -u A_VAR -u B_VAR bash -c 'do_log() { echo "$*"; }; source "$1"; source "$2"; do_validate_params "$3"' _ \
        "$lib/parse-metadata.func.sh" "$lib/validate-params.func.sh" "$T/edge.func.sh")" || rc=$?
  [[ $rc -eq 11 && "$out" == *"Required parameter A_VAR is not set."* && "$out" != *B_VAR* ]] &&
    pass "$which: 3 a missing (Required) var is refused (rc 11), an optional one is not" || fail "$which: 3 rc=$rc out=$out"
  rc=0
  out="$(env -u A_VAR -u B_VAR A_VAR=1 bash -c 'do_log() { echo "$*"; }; source "$1"; source "$2"; do_validate_params "$3"' _ \
        "$lib/parse-metadata.func.sh" "$lib/validate-params.func.sh" "$T/edge.func.sh")" || rc=$?
  [[ $rc -eq 0 ]] && pass "$which: 3 …and passes once it is set" || fail "$which: 3 set: rc=$rc out=$out"
}

find "$APP_ROOT" -name '*.func.sh' -not -path '*/node_modules/*' -not -path '*/tpl-gen/*' | sort >"$T/files"
check_tree orc "$ORC_ROOT"
check_tree iac "$APP_ROOT/csi-spl-iac"

# iac do_require_var prints the level word it was given. Empty X is FATAL.
req_rc=0
req_out="$(bash -c 'source "$1"; do_require_var X ""' _ \
  "$APP_ROOT/csi-spl-iac/lib/bash/funcs/require-var.func.sh" 2>&1)" || req_rc=$?
[[ $req_rc -eq 1 \
  && "$req_out" == *'[FATAL]'*'The environment variable "X" does not have a value !!!'* \
  && "$req_out" == *'[INFO]'*'export X=your-X-value'* ]] \
  && pass "4 do_require_var X '' exits 1 and prints [FATAL] naming X" \
  || fail "4 do_require_var rc=$req_rc out=$req_out"

echo "--- $fails failure(s)"
[[ "$fails" -eq 0 ]]
