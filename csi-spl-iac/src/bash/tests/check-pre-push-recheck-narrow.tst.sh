#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: when the orc part fails on the tree, its base re-check runs only the
#          orc test files the tree run named FAILED: (the `suite <file>` items
#          of the tree signature), not the whole --changed plan again (perf
#          round 12 row 01, p12-01-orc-recheck-failed-files). The verdict
#          compares only the tree's failures, so the other files cost minutes
#          (415..672 s, n=3) and change nothing.
#   A stub orc runner (run-all-tests.sh) plans with the REAL changed-tests.sh
#   and records the files each run is asked to run; a file fails when the
#   tree's `red` file names it. The push changes thing.func.sh, which all 3
#   test files name, so the tree plan is a b c.
#     1. tree fails b, base fails b  -> base asked for 1 file (b), WARN-pre-existing
#     2. tree fails b, base green    -> base asked for 1 file (b), FAIL (NEW)
#     3. only bash-cleancode fails (no `suite` item) -> base runs the whole
#        plan (a b c), WARN-pre-existing, as before
#     4. PRE_PUSH_TIER=full, tree fails b, base fails b -> base asked for b only
#     5. the hand-over is unset after the base run: the next part never sees it
#     6. _pp_sig_suites: the suite items alone; none, or one that is not a
#        plain *.tst.sh name (`suite a`), -> empty (the whole part)
#   Red control: PP_FUNC_FROM=<check-pre-push.func.sh before p12-01> runs the
#   cases on that file: 1, 2 and 4 FAIL (base asked for 3 files; 4 for all).
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"
MAP="$PROJ_ROOT/../csi-spl-orc/src/bash/tests/changed-tests.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

do_log() { :; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"
# red control hook: the whole gate file of another commit
# shellcheck disable=SC1090
[[ -n "${PP_FUNC_FROM:-}" ]] && . "$PP_FUNC_FROM"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export PRE_PUSH_PART_TIMEOUT=120
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export RUNLOG="$ROOT/runs.log"

# The fixture repo's files: the stub runner, the real map, 3 tests naming
# thing.func.sh, and a stub bash-cleancode that fails when `cleanred` is 1.
_fixture() {  # <repo>
  local o="$1/csi-spl-orc/src/bash" c="$1/csi-spl-iac/src/bash/tests" t
  mkdir -p "$o/tests" "$o/run" "$c"
  cp "$MAP" "$o/tests/changed-tests.sh"
  : >"$o/run/run.sh"
  printf 'do_thing_x() { :; }\n' >"$o/run/thing.func.sh"
  for t in a b c; do printf '# tests thing.func.sh\n' >"$o/tests/$t.tst.sh"; done
  cat >"$o/tests/run-all-tests.sh" <<'EOF'
#!/usr/bin/env bash
dir=$(cd "$(dirname "$0")" && pwd); root=$(cd "$dir/../../../.." && pwd)
if [[ "${1:-}" == --changed ]]; then
  list=$(bash "$dir/changed-tests.sh" | awk -F'\t' '$1 == "run" { print $2 }' | sort | paste -sd' ' -)
else
  list=$(cd "$dir" && ls -- *.tst.sh | sort | paste -sd' ' -)
fi
echo "$(cat "$root/which") $list" >>"$RUNLOG"
rc=0
for f in $list; do grep -qx "$f" "$root/red" && { echo "FAILED: $f"; rc=1; }; done
exit "$rc"
EOF
  cat >"$c/bash-cleancode.tst.sh" <<'EOF'
#!/usr/bin/env bash
root=$(cd "$(dirname "$0")/../../../.." && pwd)
[[ "$(cat "$root/cleanred")" == 1 ]] && { echo "FAIL: long function do_thing_x -- 80 lines"; exit 1; }
exit 0
EOF
}

# Build a repo whose base ref has red=<base-red>, cleanred=<base-clean> and
# whose HEAD changes thing.func.sh with red=<tree-red>, cleanred=<tree-clean>;
# run the orc part through _pp_run; print "<stat>|<base files>|<hand-over>".
recheck() {  # <base-red> <tree-red> <base-clean> <tree-clean> [<tier>]
  local R; R="$ROOT/r$RANDOM$RANDOM"
  {
    git init -q "$R"; _fixture "$R"
    echo base >"$R/which"; printf '%s\n' "$1" >"$R/red"; echo "$3" >"$R/cleanred"
    git -C "$R" add -A; git -C "$R" commit -qm base; git -C "$R" branch trunkbase
    echo tree >"$R/which"; printf '%s\n' "$2" >"$R/red"; echo "$4" >"$R/cleanred"
    echo '# changed' >>"$R/csi-spl-orc/src/bash/run/thing.func.sh"
    git -C "$R" commit -qam head
  } >/dev/null 2>&1
  : >"$RUNLOG"
  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT=""
  local _PP_TOP="$R" _PP_TIER="${5:-fast}"
  _pp_run "orc" _pp_part_orc "$R" trunkbase >/dev/null 2>&1
  _pp_baseline_cleanup "$R" >/dev/null 2>&1
  printf '%s|%s|%s' "${_PP_STAT[0]:-}" "$(sed -n 's/^base //p' "$RUNLOG" | paste -sd'/' -)" "${_PP_BASE_ONLY:-}"
}

out="$(recheck b.tst.sh b.tst.sh 0 0)"; echo "1: $out"
eq "1. tree fails b, base fails b -> base asked for 1 file" "b.tst.sh" "$(cut -d'|' -f2 <<<"$out")"
eq "1. ... the verdict is WARN-pre-existing, as before" "WARN" "$(cut -d'|' -f1 <<<"$out")"

out="$(recheck '' b.tst.sh 0 0)"; echo "2: $out"
eq "2. tree fails b, base green -> base asked for 1 file" "b.tst.sh" "$(cut -d'|' -f2 <<<"$out")"
eq "2. ... the verdict is FAIL (NEW), as before" "FAIL" "$(cut -d'|' -f1 <<<"$out")"

out="$(recheck '' '' 1 1)"; echo "3: $out"
eq "3. only bash-cleancode fails (no suite item) -> base runs the whole plan" "a.tst.sh b.tst.sh c.tst.sh" "$(cut -d'|' -f2 <<<"$out")"
eq "3. ... the verdict is WARN-pre-existing, as before" "WARN" "$(cut -d'|' -f1 <<<"$out")"

out="$(recheck b.tst.sh b.tst.sh 0 0 full)"; echo "4: $out"
eq "4. full tier, tree fails b -> base asked for 1 file" "b.tst.sh" "$(cut -d'|' -f2 <<<"$out")"
eq "4. ... the verdict is WARN-pre-existing, as before" "WARN" "$(cut -d'|' -f1 <<<"$out")"

eq "5. the hand-over is unset after the base run" "" "$(cut -d'|' -f3 <<<"$out")"

if declare -F _pp_sig_suites >/dev/null; then
  eq "6a. suite items alone" "a.tst.sh b.tst.sh" "$(_pp_sig_suites $'fail x\nsuite a.tst.sh\nsuite b.tst.sh')"
  eq "6b. no suite item -> empty" "" "$(_pp_sig_suites $'fail long function do_thing_x')"
  eq "6c. a suite item that is no *.tst.sh name -> empty" "" "$(_pp_sig_suites $'suite a\nsuite b.tst.sh')"
else
  fail "6. _pp_sig_suites" "not defined"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
