#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_desk_cron_checkout and spl_desk_cron_checkout_dry
# (lib/bash/funcs/spl-desk-cron-checkout.func.sh), the "create the
# self-updating checkout" step the install-cron actions share, against a stub
# git that records its calls. Every check has a failing control.
#   1. SPL_DESK_CRON_CREATE=0: no git call, rc 0, nothing printed
#   2. SPL_DESK_CRON_CREATE=1: fetch, then worktree add, in that order, rc 0
#   3. a failing git: the FATAL text byte for byte, rc 1, no worktree add
#      after a failed fetch
#   4. the dry twin: the DRY_RUN line only when CREATE=1, rc 0 either way
#   5. the helper never exits the caller and sets no trap
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CALLS="$T/git.calls"
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "git $*" >>%q\ncase "$*" in *" $GIT_FAIL_ON "*) exit 1 ;; esac\nexit 0\n' "$CALLS" >"$T/bin/git"
chmod +x "$T/bin/git"
run() {
  local fn="$1"; shift
  rm -f "$CALLS"
  env PATH="$T/bin:$PATH" PROJ_PATH="$PROJ_ROOT" GIT_FAIL_ON="${GIT_FAIL_ON:-none}" SPL_DESK_CRON_REPO=/r/repo "$@" \
    bash -c 'set -uo pipefail; do_log() { echo "$*"; }
      source "$PROJ_PATH/lib/bash/funcs/spl-desk-cron-checkout.func.sh"; "$0" /r/repo-desk-cron master' "$fn" 2>&1
}
calls() { [ -f "$CALLS" ] && cat "$CALLS" || true; }

# 1. CREATE=0: no git call
out="$(run spl_desk_cron_checkout SPL_DESK_CRON_CREATE=0)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ ! -f "$CALLS" ] && pass "1. CREATE=0: no git call, rc 0, silent" || fail "1. CREATE=0 ($rc: $out / $(calls))"
out="$(run spl_desk_cron_checkout SPL_DESK_CRON_CREATE=)"; rc=$?
[ "$rc" = 0 ] && [ ! -f "$CALLS" ] && pass "1. CREATE empty: no git call, rc 0" || fail "1. CREATE empty ($rc: $out / $(calls))"

# 2. CREATE=1: the two calls in order
want="$(printf '%s\n' 'git -C /r/repo fetch -q origin master' 'git -C /r/repo worktree add -q --detach /r/repo-desk-cron origin/master')"
out="$(run spl_desk_cron_checkout SPL_DESK_CRON_CREATE=1)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && [ "$(calls)" = "$want" ] && pass "2. CREATE=1: fetch, then worktree add, rc 0" || fail "2. CREATE=1 ($rc: $out / $(calls))"
[ "$(calls | sed -n 1p)" = "git -C /r/repo worktree add -q --detach /r/repo-desk-cron origin/master" ] &&
  fail "2. control: worktree add came first" || pass "2. control: worktree add is not the first call"

# 3. git fails: the FATAL text byte for byte, rc 1
fatal='FATAL could not create the self-updating checkout /r/repo-desk-cron'
out="$(GIT_FAIL_ON=fetch run spl_desk_cron_checkout SPL_DESK_CRON_CREATE=1)"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "$fatal" ] && [ "$(calls)" = 'git -C /r/repo fetch -q origin master' ] &&
  pass "3. a failed fetch: the FATAL text, rc 1, no worktree add" || fail "3. fetch fails ($rc: $out / $(calls))"
out="$(GIT_FAIL_ON=add run spl_desk_cron_checkout SPL_DESK_CRON_CREATE=1)"; rc=$?
[ "$rc" = 1 ] && [ "$out" = "$fatal" ] && [ "$(calls)" = "$want" ] &&
  pass "3. a failed worktree add: the FATAL text, rc 1" || fail "3. add fails ($rc: $out / $(calls))"
[ "$out" = "FATAL could not create the self-updating checkout" ] && fail "3. control: the path is missing" || pass "3. control: the FATAL names the path"

# 4. the dry twin
out="$(run spl_desk_cron_checkout_dry SPL_DESK_CRON_CREATE=1)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = 'INFO DRY_RUN would: git worktree add --detach /r/repo-desk-cron origin/master (the self-updating checkout)' ] &&
  [ ! -f "$CALLS" ] && pass "4. dry, CREATE=1: the DRY_RUN line, no git call" || fail "4. dry CREATE=1 ($rc: $out / $(calls))"
out="$(run spl_desk_cron_checkout_dry SPL_DESK_CRON_CREATE=0)"; rc=$?
[ "$rc" = 0 ] && [ -z "$out" ] && pass "4. dry, CREATE=0: silent, rc 0" || fail "4. dry CREATE=0 ($rc: $out)"

# 5. never exits, sets no trap
out="$(env PATH="$T/bin:$PATH" PROJ_ROOT="$PROJ_ROOT" GIT_FAIL_ON=fetch SPL_DESK_CRON_REPO=/r/repo SPL_DESK_CRON_CREATE=1 \
  bash -c 'do_log() { :; }; source "$PROJ_ROOT/lib/bash/funcs/spl-desk-cron-checkout.func.sh";
    traps_before="$(trap -p)";
    spl_desk_cron_checkout /r/x master; echo "after rc=$?";
    traps_after="$(trap -p)";
    [ "$traps_before" = "$traps_after" ] && echo "traps unchanged" || echo "traps changed: $traps_after"' 2>&1)"
rc_part="$(echo "$out" | grep -o 'after rc=[0-9]*' | cut -d= -f2)"
traps_part="$(echo "$out" | grep -o 'traps [a-z]*')"
[ "$rc_part" = "1" ] && [ "$traps_part" = "traps unchanged" ] && pass "5. a failure returns to the caller and leaves traps unchanged" || fail "5. exit/trap ($out)"
grep -nE '^[^#]*\b(exit|trap)\b' "$PROJ_ROOT/lib/bash/funcs/spl-desk-cron-checkout.func.sh" &&
  fail "5. the helper source holds exit or trap" || pass "5. the helper source holds no exit and no trap"

[ "$fails" -eq 0 ] && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
