#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_private_overlay_merge (SPL-5124), offline, on a synthetic
#          overlay in the test's temp dir.
#   1. refusals, nothing written: another box, DRY_RUN=2, no file, a symlink,
#      not YAML, two keys, an owned section, not a list, an empty list, a
#      non-string item, a bad line form, an invalid overlay
#   2. DRY_RUN is the default: reports, writes nothing, no backup
#   3. DRY_RUN=0 adds the section: other sections byte-equal, mode kept, backup
#   4. a re-run changes nothing; a new list replaces the section whole
#   5. the readers (spl_private_list, spl_private_map) read the result
#   6. red control: a merge step that eats another section is refused
#   7. the section's content never reaches the output
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
for b in yq python3; do command -v "$b" >/dev/null || { echo "SKIP: no $b"; exit 0; }; done

O="$T/overlay.yaml"
base() {
  printf '# head\nworkspaces:\n  ws-hidden-01: plant-slug\nforms_only:\n  - plant-word\ndeny:\n  - %s\n' "'plant-rx'" >"$O"
  chmod 640 "$O"; rm -f "$O".bak.*
}
base; cp "$O" "$T/orig"
printf 'customer_strings:\n  - key:QZX\n  - domain:planted-customer.example.invalid\n' >"$T/sec.yaml"
# run <name> [ENV=VAL ...]: the action; output in $T/<name>.log, rc in $T/<name>.rc
run() {
  local n="$1"; shift
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_PRIVATE_CNF="$O" BOX=sat OVERLAY_SECTION_FILE="$T/sec.yaml" MUT="${MUT:-}" "$@" bash -c '
    set -uo pipefail
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh; do source "$f"; done
    do_log() { echo "$*"; }
    do_require_bin() { :; }
    spl_desk_box_default() { echo "$BOX"; }
    source "$PROJ_PATH/src/bash/run/spl-private-overlay-merge.func.sh"
    if [[ -n "$MUT" ]]; then eval "$(declare -f spl_pom_build | sed "s/s != want/s != want \&\& s != \"forms_only\"/")"; fi
    do_spl_private_overlay_merge' >"$T/$n.log" 2>&1 </dev/null
  echo $? >"$T/$n.rc"
}
# refused <label> <name> <needle> [env ...]: rc 1, the reason, overlay untouched
refused() {
  local l="$1" n="$2" w="$3"; shift 3
  run "$n" DRY_RUN=0 "$@"
  [[ "$(cat "$T/$n.rc")" != 0 ]] && grep -q -- "$w" "$T/$n.log" && cmp -s "$O" "$T/orig" && ! ls "$O".bak.* >/dev/null 2>&1 \
    && pass "1. $l" || fail "1. $l: rc=$(cat "$T/$n.rc") $(cat "$T/$n.log")"
}
sec() { printf "$2" >"$T/$1.yaml"; }
refused "another box" box 'does not hold the master' BOX=other-box
run badd DRY_RUN=2; [[ "$(cat "$T/badd.rc")" != 0 ]] && cmp -s "$O" "$T/orig" && pass "1. a bad DRY_RUN" || fail "1. bad DRY_RUN: $(cat "$T/badd.log")"
refused "no section file" nof 'unset, unreadable' OVERLAY_SECTION_FILE="$T/none.yaml"
ln -s "$T/sec.yaml" "$T/lnk.yaml"; refused "a symlink" lnk 'symlink' OVERLAY_SECTION_FILE="$T/lnk.yaml"
sec notyaml 'a: [\n'; refused "not YAML" ny 'exactly one top-level' OVERLAY_SECTION_FILE="$T/notyaml.yaml"
sec two 'a_s:\n  - x\nb_s:\n  - y\n'; refused "two keys" two 'exactly one top-level' OVERLAY_SECTION_FILE="$T/two.yaml"
for s in workspaces forms_only orgs deny; do sec "own-$s" "$s:\n  - x\n"; refused "owned section $s" "own-$s" 'has its own owner' OVERLAY_SECTION_FILE="$T/own-$s.yaml"; done
sec map 'a_s:\n  k: v\n'; refused "a map" map 'not a non-empty list' OVERLAY_SECTION_FILE="$T/map.yaml"
sec empty 'a_s: []\n'; refused "an empty list" empty 'not a non-empty list' OVERLAY_SECTION_FILE="$T/empty.yaml"
sec nums 'a_s:\n  - 12\n'; refused "a non-string item" nums 'not a non-empty list' OVERLAY_SECTION_FILE="$T/nums.yaml"
sec flow 'a_s: [x, y]\n'; refused "a flow list" flow "in the form" OVERLAY_SECTION_FILE="$T/flow.yaml"
cp "$O" "$T/keep"; printf 'a: [\n' >"$O"; cp "$O" "$T/orig"; refused "an invalid overlay" badov 'not valid YAML'; cp "$T/keep" "$O"; cp "$O" "$T/orig"

run dry
[[ "$(cat "$T/dry.rc")" == 0 ]] && grep -q 'DRY_RUN would' "$T/dry.log" && cmp -s "$O" "$T/orig" && ! ls "$O".bak.* >/dev/null 2>&1 \
  && pass "2. the default is a dry run: nothing written, no backup" || fail "2. dry: $(cat "$T/dry.log")"

run go DRY_RUN=0
[[ "$(cat "$T/go.rc")" == 0 ]] && [[ "$(yq -r '.customer_strings | length' "$O")" == 2 ]] && [[ "$(stat -c %a "$O")" == 640 ]] \
  && pass "3. the section is added and the mode kept" || fail "3. merge: $(cat "$T/go.log")"
[[ "$(head -n "$(wc -l <"$T/orig")" "$O" | sha256sum)" == "$(sha256sum <"$T/orig")" ]] && pass "3. the rest of the overlay is byte-equal" || fail "3. other sections changed"
baks=("$O".bak.*); cmp -s "${baks[0]}" "$T/orig" && pass "3. the backup is the old overlay" || fail "3. backup"

cp "$O" "$T/after"; run again DRY_RUN=0; cmp -s "$O" "$T/after" && grep -q 'nothing to merge' "$T/again.log" && pass "4. a re-run changes nothing" || fail "4. rerun: $(cat "$T/again.log")"
printf 'customer_strings:\n  - server:zz-planted1\n' >"$T/sec2.yaml"; run repl DRY_RUN=0 OVERLAY_SECTION_FILE="$T/sec2.yaml"
[[ "$(yq -r '.customer_strings | join(",")' "$O")" == server:zz-planted1 && "$(yq -r '.forms_only[0]' "$O")" == plant-word ]] \
  && pass "4. a new list replaces the section whole, the others stay" || fail "4. replace: $(cat "$T/repl.log")"

r="$(SPL_PRIVATE_CNF="$O" bash -c 'source "$1/csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh"; spl_private_list customer_strings; spl_private_map' _ "$APP_ROOT" 2>&1 | paste -sd,)"
[[ "$r" == $'server:zz-planted1,ws-hidden-01\tplant-slug' ]] && pass "5. the overlay's readers read the merged file" || fail "5. readers: $r"

base; cp "$O" "$T/orig"; MUT=1 refused "red control: a merge that eats another section is refused" mut 'would change another section'

grep -lE 'QZX|planted-customer|zz-planted1|plant-slug|plant-word' "$T"/*.log >/dev/null && fail "7. a value reached the output" || pass "7. no section or overlay value in any output"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1
