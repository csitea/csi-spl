#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the pre-push gate refuses only NEW failures, never pre-existing trunk
#          red (SPL-1252 deadlock fix), and never hangs (SPL-1251 timeout).
#          _pp_run re-runs a FAILED part against origin/master and blocks only
#          when it passes there.
#     1. green trunk + a break        -> FAIL (blocks): fails on HEAD, ok on base
#     2. red trunk + a real fix       -> PASS: passes on HEAD (no failure at all)
#     3. red trunk + still broken     -> WARN, NOT blocking: fails on HEAD AND base
#     4. a part that HANGS            -> killed by the timeout, counted, compared
#     7. (c-304, 2026-10-05) "pre-existing" compares failure SIGNATURES, not rcs:
#        a. same failure on HEAD and base          -> WARN, push allowed
#        b. base fails A, HEAD fails A+B           -> FAIL naming B (c-304's case;
#           the old rc-only compare WARNed it)
#        c. unparseable output on HEAD and base    -> FAIL (fail closed)
#        d. HEAD green                             -> PASS
#        e. unparseable output on HEAD, base GREEN -> FAIL (a new crash; red
#           control: waving an empty HEAD signature through as WARN when the
#           base is green passed a-d, none of which pairs a mute HEAD with a
#           green base)
#     8. (SPL-2813) the wui e2e runner's FAIL lines are a signature too (they
#        read 0 lines before, so a trunk-red e2e blocked every wui push):
#        a. same e2e check fails on HEAD and base        -> WARN, push allowed
#        b. HEAD adds a second failing check, same file  -> FAIL "NEW on your tree"
#        c. same check, another detail (px number)       -> WARN (detail dropped)
#        d. real log line shapes -> e2e-file <path> + e2e <check>
#        Red control: PP_SIG_FROM=<file holding the old _pp_sig> runs the cases
#        on that function instead (8a and 8c FAIL "unparseable" on the old one).
#     9. (SPL-3128) the base tree's path is stable per lane tree, so Go's build
#        cache (keyed on the source dir) is re-used, not re-written per re-check:
#        a. two re-checks of one tree build the base at the same path
#        b. a concurrent run of that tree (lock held) gets a pid path and
#           leaves the held one alone
#        c. no lock file is left behind
#        d. a SIGKILLed run's stable leftover is reaped; a held one is kept
#        e. (with go on PATH) a second re-check compiles nothing: Go's own
#           `go build -v` list of what it compiled, not a count of GOCACHE
#           files, so an unrelated cache file cannot red it (SPL-3464, I7)
#        Red control: PP_FUNC_FROM=<the func file before SPL-3128>: 9a, 9d
#        (reaped) and 9e FAIL there (9e: the second re-check compiles x).
#   A stub part passes iff <tree>/flag contains 'good'; HEAD and the base ref
#   carry different flags, so the same part yields different verdicts per tree.
#------------------------------------------------------------------------------
set -uo pipefail
# Defensive git-env scrub: this test creates commits in throwaway repos; a leaked
# GIT_DIR/GIT_INDEX_FILE (e.g. when run through the pre-push hook) would override
# "git -C" and land commits on the real pushing branch. The hook scrubs them; do
# it here too so the test is safe however it is invoked.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

do_log() { :; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"
# red control hook (section 8): another _pp_sig, e.g. the one before SPL-2813
# shellcheck disable=SC1090
[[ -n "${PP_SIG_FROM:-}" ]] && . "$PP_SIG_FROM"
# red control hook (section 9): the whole gate file of another commit
# shellcheck disable=SC1090
[[ -n "${PP_FUNC_FROM:-}" ]] && . "$PP_FUNC_FROM"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT

# a stub part: pass iff <tree>/flag contains 'good'; a failure prints a FAIL line
# naming the tree (normalised away), so the same red reads the same on both trees
_stub_part() { grep -q good "$1/flag" 2>/dev/null || { echo "FAIL: flag in $1 is not good"; return 1; }; }

# Build a repo whose base ref 'trunkbase' has flag=$1 and whose worktree HEAD
# has flag=$2, then run one part and report the verdict via the arrays.
verdict() {  # <base-flag> <head-flag> <part-fn>
  local bflag="$1" hflag="$2" fn="$3" R
  R="$ROOT/r$RANDOM$RANDOM"
  {
    git init -q "$R"
    cd "$R" || return 1
    echo "$bflag" >flag; git add flag; git commit -qm base
    git branch trunkbase
    echo "$hflag" >flag; git add flag; git commit --allow-empty -qm head
    cd - >/dev/null || return 1
  } >/dev/null 2>&1
  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT=""
  _pp_run "stub" "$fn" "$R" trunkbase >/dev/null 2>&1
  _pp_baseline_cleanup "$R" >/dev/null 2>&1
  printf '%s|%s' "$_PP_FAILED" "${_PP_STAT[0]:-}"
}

# 1. green trunk (base good), broken HEAD (bad) -> NEW break, blocks
eq "1. green trunk + break -> FAIL (blocks)" "1|FAIL" "$(verdict good bad _stub_part)"
# 2. red trunk (base bad), fixed HEAD (good) -> the part passes, no failure
eq "2. red trunk + real fix -> PASS (lands)" "0|PASS" "$(verdict bad good _stub_part)"
# 3. red trunk (base bad), still broken HEAD (bad) -> pre-existing, WARN not block
eq "3. red trunk + still broken -> WARN (not blocking)" "0|WARN" "$(verdict bad bad _stub_part)"

# 7. signatures: every flag line that is not 'good' is one failing go test,
#    printed with a duration that differs per run (normalised away)
_sig_part() {
  local l rc=0
  while IFS= read -r l; do
    [[ "$l" == good ]] && continue
    echo "--- FAIL: $l (0.$RANDOM""s)"; rc=1
  done <"$1/flag"
  return "$rc"
}
_mute_part() { echo "something went wrong"; return 1; }
# green on a 'good' tree, else a crash whose output names no failing item
_mute_head_part() { grep -q good "$1/flag" 2>/dev/null && return 0; echo "something went wrong"; return 1; }
names() {  # <base-flag> <head-flag> <part-fn> -> "<failed>|<stat>|<name>"
  local R; R="$ROOT/n$RANDOM$RANDOM"
  { git init -q "$R"; printf '%b\n' "$1" >"$R/flag"; git -C "$R" add flag; git -C "$R" commit -qm base
    git -C "$R" branch trunkbase; printf '%b\n' "$2" >"$R/flag"; git -C "$R" commit -qam head --allow-empty; } >/dev/null 2>&1
  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT=""
  _pp_run "stub" "$3" "$R" trunkbase >/dev/null 2>&1
  _pp_baseline_cleanup "$R" >/dev/null 2>&1
  printf '%s|%s|%s' "$_PP_FAILED" "${_PP_STAT[0]:-}" "${_PP_NAMES[0]:-}"
}
eq "7a. same failure on HEAD and base -> WARN (push allowed)" "0|WARN" "$(names TestA TestA _sig_part | cut -d'|' -f1,2)"
out7b="$(names TestA 'TestA\nTestB' _sig_part)"
eq "7b. base fails A, HEAD fails A+B -> FAIL" "1|FAIL" "$(cut -d'|' -f1,2 <<<"$out7b")"
case "$out7b" in *"NEW on your tree: go-test TestB)"*) pass "7b. ... naming only B as NEW" ;; *) fail "7b. ... naming only B as NEW" "$out7b" ;; esac
eq "7c. unparseable output on HEAD and base -> FAIL (fail closed)" "1|FAIL" "$(names bad bad _mute_part | cut -d'|' -f1,2)"
eq "7d. HEAD green -> PASS" "0|PASS" "$(names TestA good _sig_part | cut -d'|' -f1,2)"
eq "7e. unparseable crash on HEAD, green base -> FAIL" "1|FAIL" "$(names good bad _mute_head_part | cut -d'|' -f1,2)"

# 8. the wui e2e runner shape: every flag line that is not 'good' is one failing
#    check '<check>|<detail>' in one test file, then the runner's file line
_e2e_part() {
  local l rc=0
  while IFS= read -r l; do
    [[ "$l" == good ]] && continue
    echo "  FAIL ${l%%|*}: ${l#*|}"; rc=1
  done <"$1/flag"
  [[ "$rc" -eq 0 ]] || echo "  FAIL tests/e2e/issues-crud-modal.test.mjs (exit 1, then exit 1)"
  return "$rc"
}
k4='K4 1440|switching to History moves neither {"list":"0,0,235,58"}'
eq "8a. same e2e check fails on HEAD and base -> WARN (push allowed)" "0|WARN" "$(names "$k4" "$k4" _e2e_part | cut -d'|' -f1,2)"
out8b="$(names "$k4" "$k4\nK5 1024|the tab row wraps {\"h\":58}" _e2e_part)"
eq "8b. HEAD adds a second failing check -> FAIL" "1|FAIL" "$(cut -d'|' -f1,2 <<<"$out8b")"
case "$out8b" in *"NEW on your tree: e2e K5 1024)"*) pass "8b. ... naming only K5 1024 as NEW" ;; *) fail "8b. ... naming only K5 1024 as NEW" "$out8b" ;; esac
eq "8c. same check, another px number -> WARN" "0|WARN" "$(names "$k4" "${k4/235/232}" _e2e_part | cut -d'|' -f1,2)"
# 8d. line shapes copied from wf 10 job 119555792585 (run 39696071548), JSON cut
f8="$ROOT/e2e-8d.log"
cat >"$f8" <<'LOG'
  OK   control: the copy check FAILs on a plain new event's sheet {"mode":"create","title":""}
  FAIL K4 1440: switching to History moves neither the tabs nor the clip control's box {"discussion":{"list":"0,0,235,58","tabs":"8,50|8,50","clip":"577,31,99,26"}}
  FAIL K4 390x844: switching to History moves neither the tabs nor the clip control's box {"discussion":{"list":"0,0,228,58","tabs":"8,50|8,50","clip":"236,11,134,46"}}
──[14/35] FAIL tests/e2e/issues-crud-modal.test.mjs (exit 1, then exit 1 on retry)
e2e runner: 1 of 35 file(s) FAILED (twice: first run and retry)
  FAIL tests/e2e/issues-crud-modal.test.mjs (exit 1, then exit 1)
LOG
eq "8d. real e2e log lines -> e2e-file + e2e <check>" \
  "e2e K4 1440;e2e K4 390x844;e2e-file tests/e2e/issues-crud-modal.test.mjs" \
  "$(_pp_sig "$f8" "$ROOT" | LC_ALL=C sort | paste -sd';' -)"

# 10. (SPL-5094) the wui unit runner's lines are signature items: an indented
#     FAIL with no ': ' and the runner's file line read 0 items before, and a
#     check name cut at its first ': ' merged every 'mock: ...' into one, so a
#     NEW unit failure on a red trunk read as pre-existing. Flag lines are the
#     part's output, verbatim. Red control: PP_SIG_FROM=<the old _pp_sig>
#     (10b, 10c, 10d and 10f FAIL there).
_unit_part() { grep -q '^good$' "$1/flag" && return 0; cat "$1/flag"; return 1; }
h1='──[1/2] a.test.mjs'; h2='──[2/2] agent-split-kinds.test.mjs'; sum='unit runner: 1 of 2 file(s) FAILED'
a="$h1\n  FAIL mock: a row reads"
new="  FAIL the tests default is the cnf row"
eq "10a. identical unit red on HEAD and base -> WARN" "0|WARN" "$(names "$a\n$sum\n  FAIL a.test.mjs (exit 1)" "$a\n$sum\n  FAIL a.test.mjs (exit 1)" _unit_part | cut -d'|' -f1,2)"
out10b="$(names "$a\n$sum\n  FAIL a.test.mjs (exit 1)" "$a\n$h2\n$new\n$sum\n  FAIL a.test.mjs (exit 1)\n  FAIL agent-split-kinds.test.mjs (exit 1)" _unit_part)"
eq "10b. HEAD adds a failing file and a no-colon check -> FAIL" "1|FAIL" "$(cut -d'|' -f1,2 <<<"$out10b")"
case "$out10b" in *"unit agent-split-kinds.test.mjs › the tests default is the cnf row"*"unit-file agent-split-kinds.test.mjs"*) pass "10b. ... naming the check and the file as NEW" ;; *) fail "10b. ... naming the check and the file as NEW" "$out10b" ;; esac
eq "10c. a second 'mock: ...' check in the same file -> FAIL" "1|FAIL" "$(names "$a" "$a\n  FAIL mock: another row writes" _unit_part | cut -d'|' -f1,2)"
eq "10d. the same check, another JSON detail -> WARN" "0|WARN" "$(names "$h1\n  FAIL box stays {\"h\":58}" "$h1\n  FAIL box stays {\"h\":61}" _unit_part | cut -d'|' -f1,2)"
eq "10e. the same check name in another file -> FAIL" "1|FAIL" "$(names "$h1\n$new" "$h1\n$new\n$h2\n$new" _unit_part | cut -d'|' -f1,2)"
f10="$ROOT/unit-10f.log"
printf '%b\n' "$a\n$h2\n$new\n$sum\n  FAIL agent-split-kinds.test.mjs (exit 1)\n  FAIL a.test.mjs (signal SIGKILL)" >"$f10"
eq "10f. the runner's lines -> unit <file> › <check> + unit-file <file>" \
  "unit a.test.mjs › mock: a row reads;unit agent-split-kinds.test.mjs › the tests default is the cnf row;unit-file a.test.mjs;unit-file agent-split-kinds.test.mjs" \
  "$(_pp_sig "$f10" "$ROOT" | LC_ALL=C sort | paste -sd';' -)"

# 11. (SPL-5320) a unit check's FAIL line counts only when its file failed:
#     auth-i18n-keys.test.mjs prints its planted control as '  FAIL key present
#     ...' and exits 0, and that line read as a failing item, so a mute red
#     (typecheck, a crash) on HEAD and base WARNed "pre-existing" with the
#     control as its signature. The runner's summary lists the failed files;
#     with no summary (a killed run) every FAIL line still counts (10c-10e).
#     Lines from the wui unit output of e2e5b45fd, verbatim. Red control:
#     PP_SIG_FROM=<the old _pp_sig> (11a and 11b FAIL there).
ctl='──[1/2] auth-i18n-keys.test.mjs\n  FAIL key present auth.native_error.__control_missing__: missing in en.json\n  OK   CONTROL: a missing key fails\n\nAll auth-i18n-keys checks passed.'
real='──[2/2] b.test.mjs\n  FAIL the row is sorted'
f11="$ROOT/unit-11a.log"
printf '%b\n' "$ctl\n$real\n\nunit runner: 1 of 2 file(s) FAILED\n  FAIL b.test.mjs (exit 1)" >"$f11"
eq "11a. a planted FAIL in a passing file -> no item; a FAIL in a failing file -> its item" \
  "unit b.test.mjs › the row is sorted;unit-file b.test.mjs" \
  "$(_pp_sig "$f11" "$ROOT" | LC_ALL=C sort | paste -sd';' -)"
mute="$ctl\n\nunit runner: all 1 file(s) passed\nsomething went wrong"
eq "11b. a mute red beside a passing file's planted FAIL, on HEAD and base -> FAIL (fail closed)" \
  "1|FAIL" "$(names "$mute" "$mute" _unit_part | cut -d'|' -f1,2)"

# 12. (SPL-5330) a perf-*.sh run is report-only (run-ci-tests.sh): its lines,
#     from '=== perf, reported, not gating: <f>' to that file's PASS / OVER
#     BUDGET line, are no item. Its 'FAIL - ... (50 ms) ...' carries the
#     measured ms mid-line, so it read NEW on every run and blocked a push
#     whose part was red for another reason on a red trunk (c-542, msg
#     ebe2f8aa). A FAIL before or after the section still counts; so does
#     CI's '::warning::' prefix on the closing line. Red control:
#     PP_SIG_FROM=<the old _pp_sig> (12a, 12b and 12c FAIL there).
perf='=== perf, reported, not gating: spawn-agents/perf-agent-hook.sh'
perf="$perf\nFAIL - the hook's fastest of 300 runs (50 ms) is not under 50 ms (bare interpreter: 18 ms, load 71.69)"
over='=== perf spawn-agents/perf-agent-hook.sh: OVER BUDGET (rc=1), reported only'
f12="$ROOT/perf-12.log"
printf '%b\n' "FAIL - x\n$perf\n$over\nFAIL - y" >"$f12"
eq "12a. a perf section's FAIL -> no item; a FAIL before and after it -> its item" \
  "fail x;fail y" "$(_pp_sig "$f12" "$ROOT" | LC_ALL=C sort | paste -sd';' -)"
printf '%b\n' "$perf\n::warning::$over\nFAIL - y" >"$f12"
eq "12b. ... CI's ::warning:: closing line ends the section too" \
  "fail y" "$(_pp_sig "$f12" "$ROOT" | LC_ALL=C sort | paste -sd';' -)"
_perf_part() { grep -q '^good$' "$1/flag" && return 0; cat "$1/flag"; return 1; }
eq "12c. the same red on HEAD and base, another perf ms -> WARN" "0|WARN" \
  "$(names "FAIL - x\n$perf\n$over" "FAIL - x\n${perf/(50 ms)/(51 ms)}\n$over" _perf_part | cut -d'|' -f1,2)"
# 12d. (R7 c-843, B1) the part's timeout kills the runner in the perf run: no
#      closing line, and _pp_part_orc_features appends its FAILED: lines after
#      the open section. They end it and keep their items (fail closed).
printf '%b\n' "$perf\nUNFINISHED spawn-agents/perf-agent-hook.sh\nFAILED: spawn-agents/b.tst.sh\nFAILED: spawn-agents/perf-agent-hook.sh (still running at the timeout)" >"$f12"
eq "12d. an unclosed perf section: the part's FAILED: lines after it still count" \
  "suite spawn-agents/b.tst.sh;suite spawn-agents/perf-agent-hook.sh" "$(_pp_sig "$f12" "$ROOT" | LC_ALL=C sort | paste -sd';' -)"

# 4. the per-part timeout kills a hanging suite (the tf-steps hang) instead of
#    blocking the push forever. Point _pp_part_iac at a fake hanging suite.
FT="$ROOT/faketree"; mkdir -p "$FT/csi-spl-iac/src/bash/tests"
printf '#!/usr/bin/env bash\nsleep 30\n' >"$FT/csi-spl-iac/src/bash/tests/run-all-tests.sh"
# The fast iac budget is load-scaled from 500 s, so a planted _pp_timeout no
# longer shortens it. PRE_PUSH_PART_TIMEOUT=1 is set only inside the subshell:
# a prefix on the function would stay set in this shell and the full-tier case
# below would then take the override instead of PRE_PUSH_IAC_FULL_TIMEOUT.
unset PRE_PUSH_PART_TIMEOUT PRE_PUSH_IAC_FULL_TIMEOUT PRE_PUSH_IAC_FAST_CAP
_PP_TIER=fast
t0=$SECONDS; ( PRE_PUSH_PART_TIMEOUT=1 _pp_part_iac "$FT" ) >/dev/null 2>&1; trc=$?; tel=$((SECONDS - t0))
[ "$trc" -eq 124 ] && pass "4. a hanging suite is killed (rc 124)" || fail "4. a hanging suite is killed (rc 124)" "rc=$trc"
[ "$tel" -lt 10 ] && pass "4. ... within the timeout, not the full 30s" || fail "4. ... within the timeout" "took ${tel}s"
# the full tier kills it too, under the budget the iac part reads there
t0=$SECONDS; _PP_TIER=full PRE_PUSH_IAC_FULL_TIMEOUT=1 _pp_part_iac "$FT" >/dev/null 2>&1; trc=$?; tel=$((SECONDS - t0))
[ "$trc" -eq 124 ] && [ "$tel" -lt 10 ] && pass "4. ... and in the full tier (rc 124)" || fail "4. ... and in the full tier" "rc=$trc took ${tel}s"

# 5. a dead run's baseline worktree is reaped; a live run's is kept; a TERM
#    mid-run removes the run's own one
R5="$ROOT/r5"; git init -q "$R5"; echo a >"$R5/f"; git -C "$R5" add -A; git -C "$R5" commit -qm s
dead="$(mktemp -d "${TMPDIR:-/tmp}/csi-spl-pre-push-base.999999.XXXXXX")"; rmdir "$dead"
git -C "$R5" worktree add -q --detach "$dead" HEAD
live="$(mktemp -d "${TMPDIR:-/tmp}/csi-spl-pre-push-base.$$.XXXXXX")"; rmdir "$live"
git -C "$R5" worktree add -q --detach "$live" HEAD
_pp_baseline_reap "$R5"
wl="$(git -C "$R5" worktree list)"
{ ! grep -qF "$dead" <<<"$wl" && [[ ! -d "$dead" ]]; } && pass "5a. a dead run's baseline worktree is reaped" || fail "5a. reap dead" "$wl"
grep -qF "$live" <<<"$wl" && pass "5b. a live run's baseline worktree is kept" || fail "5b. keep live" "$wl"
git -C "$R5" worktree remove --force "$live" >/dev/null 2>&1
( _PP_BASE_WT=""; _pp_baseline_tree "$R5" HEAD; echo "$_PP_BASE_WT" >"$ROOT/r5.wt"
  trap '_pp_baseline_cleanup "$R5"; exit 143' TERM; kill -TERM $BASHPID; sleep 5 ) 2>/dev/null
wt5="$(cat "$ROOT/r5.wt")"
{ [[ -n "$wt5" ]] && ! git -C "$R5" worktree list | grep -F "$wt5" >/dev/null && [[ ! -d "$wt5" ]]; } \
  && pass "5c. TERM mid-run removes the run's own baseline worktree" || fail "5c. term cleanup" "$(git -C "$R5" worktree list)"

# 6. regression: a part that fails on HEAD AND on the base (the re-check
#    builds a baseline worktree) leaves NO worktree behind after the run
R6="$ROOT/r6"; git init -q "$R6"; echo bad >"$R6/flag"; git -C "$R6" add -A; git -C "$R6" commit -qm base
git -C "$R6" branch trunkbase; git -C "$R6" commit -q --allow-empty -m head
( _PP_NAMES=(); _PP_STAT=(); _PP_SECS=(); _PP_FAILED=0; _PP_BASE_WT=""
  _pp_run "stub" _stub_part "$R6" trunkbase >/dev/null 2>&1; _pp_baseline_cleanup "$R6" >/dev/null 2>&1 )
n6="$(git -C "$R6" worktree list | wc -l)"
eq "6. a pre-existing re-check leaves no baseline worktree behind" 1 "$n6"

# 9. (SPL-3128) a stable base-tree path per lane tree; TMPDIR inside ROOT, so
#    nothing lands in the box's /tmp
_old_tmpdir="${TMPDIR-}"; export TMPDIR="$ROOT/tmp9"; mkdir -p "$TMPDIR"
R9="$ROOT/r9"; git init -q "$R9"; echo bad >"$R9/flag"; git -C "$R9" add -A; git -C "$R9" commit -qm s
_pp_recheck_path() {  # <tree>: build the base tree, print its path, clean up
  local _PP_BASE_WT=""; _pp_baseline_tree "$1" HEAD || return 1
  echo "$_PP_BASE_WT"; _pp_baseline_cleanup "$1"
}
p1="$(_pp_recheck_path "$R9")"; p2="$(_pp_recheck_path "$R9")"
if [[ -n "$p1" && "$p1" == "$p2" ]]; then pass "9a. two re-checks of one tree build the base at the same path"
else fail "9a. same base path per tree" "first '$p1' then '$p2'"; fi
lk="$p1.lock"
if [[ ! -e "$lk" ]]; then pass "9c. no lock file is left behind"; else fail "9c. lock file left" "$lk"; fi
exec {h9}>>"$lk"; flock -n "$h9"
( _PP_BASE_WT=""; _pp_baseline_tree "$R9" HEAD; echo "$_PP_BASE_WT" >"$ROOT/r9.busy"; _pp_baseline_cleanup "$R9" )
busy="$(cat "$ROOT/r9.busy")"
if [[ -n "$busy" && "$busy" != "$p1" && "$busy" == *"/csi-spl-pre-push-base.$$."* ]]; then
  pass "9b. a concurrent run (lock held) gets a pid path"
else fail "9b. busy fallback" "got '$busy' (stable '$p1')"; fi
# 9d. a SIGKILL leftover: registered at the stable path, nobody holds its lock
git -C "$R9" worktree add -q --detach "$p1" HEAD
_pp_baseline_reap "$R9"
if git -C "$R9" worktree list | grep -F "$p1" >/dev/null; then pass "9d. a held stable base tree is kept"
else fail "9d. keep held" "$(git -C "$R9" worktree list)"; fi
rm -f "$lk"; exec {h9}>&-
_pp_baseline_reap "$R9"
if ! git -C "$R9" worktree list | grep -F "$p1" >/dev/null && [[ ! -e "$p1" && ! -e "$lk" ]]; then
  pass "9d. a dead run's stable base tree is reaped"
else fail "9d. reap stable" "$(git -C "$R9" worktree list)"; fi
# 9e. the point of it: the second re-check re-uses Go's cache entries
# Go is found the way the gate's api part finds it (use-go-toolchain.sh), not
# on the bare PATH: the hook runs as a non-login user whose PATH has no Go,
# and a fast-tier SKIP reds the whole iac suite (SPL-3329).
# shellcheck source=/dev/null
source "$TEST_DIR/../../../../csi-spl-api/src/bash/use-go-toolchain.sh" 2>/dev/null && spl_export_go_path 2>/dev/null
if command -v go >/dev/null 2>&1; then
  RG="$ROOT/rg"; git init -q "$RG"
  printf 'module x\n\ngo 1.21\n' >"$RG/go.mod"; printf 'package p\n\nfunc F() int { return 1 }\n' >"$RG/p.go"
  echo good >"$RG/flag"; git -C "$RG" add -A; git -C "$RG" commit -qm base; git -C "$RG" branch trunkbase
  echo bad >"$RG/flag"; git -C "$RG" commit -qam head
  # -v lists each package Go compiles; a cache hit lists nothing
  _go_part() { (cd "$1" && go build -v ./... 2>>"$GLOG") && grep -q good "$1/flag"; }
  _go_recheck() { local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT=""
    : >"$GLOG"; _pp_run "go" _go_part "$RG" trunkbase >/dev/null 2>&1; _pp_baseline_cleanup "$RG" >/dev/null 2>&1
    grep -c . "$GLOG"; }
  # goindex=0: Go's module index caches a dir only once its files are >2 s
  # old (wf 10 run 40046892424); kept off so the runner's speed stays out
  export GOCACHE="$ROOT/gocache" GOTOOLCHAIN=local GOFLAGS="" GODEBUG=goindex=0 GLOG="$ROOT/go-build.log"
  n1="$(_go_recheck)"; n2="$(_go_recheck)"
  if [[ "$n1" -ge 1 && "$n2" -eq 0 ]]; then
    pass "9e. a second re-check compiles nothing for the same input (the first compiled $n1)"
  else fail "9e. Go cache re-use" "want first >= 1, second 0 compiled; got $n1 then $n2"; fi
else
  echo "SKIP: 9e. go is not on PATH"
fi
if [[ -n "$_old_tmpdir" ]]; then export TMPDIR="$_old_tmpdir"; else unset TMPDIR; fi

echo "-- check-pre-push-baseline.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
