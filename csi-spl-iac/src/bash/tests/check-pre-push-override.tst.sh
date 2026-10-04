#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL_PREPUSH_OVERRIDE=1 skips the slow parts, never the cheap
#          correctness ones (2026-10-04: an override that skipped everything
#          landed a duplicate migration 0119), and lint-migration's verdict
#          cache sees the whole migration dir and the base, not only the touched
#          files. Drives do_check_pre_push PRE_PUSH_ONLY=override, which the hook
#          runs under the override (the hook side: test-pre-push-hook.sh case 3).
#     1. override + a duplicate migration prefix after a rebase   -> REFUSED
#        ... although that file passed (and was cached) before the rebase
#     2. override + a clean new migration -> passes; runs hygiene + lint-migration
#        and nothing else (no iac / wui / api / other lint part)
#     3. PRE_PUSH_LINT=0 cannot drop lint-migration from the override
#     4. a re-push with nothing changed re-uses the lint-migration verdict
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
# The prefix rule needs no parser: a stand-in pglast python accepts everything.
export XDG_CACHE_HOME="$T/xdg"
mkdir -p "$XDG_CACHE_HOME/csi-spl/lint-venv-pglast/bin"
printf '#!/bin/sh\nexit 0\n' >"$XDG_CACHE_HOME/csi-spl/lint-venv-pglast/bin/python"
chmod +x "$XDG_CACHE_HOME/csi-spl/lint-venv-pglast/bin/python"

do_log() { echo "$*"; }
HYG="$T/hygiene.runs"
do_check_dist_hygiene() { echo x >>"$HYG"; return 0; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"

MIG="csi-spl-rdb/src/sql/postgres/spool-hub"
R="$T/repo"; LOG="$T/pre-push.log"; CACHE="$T/cache"
git init -q "$R"; mkdir -p "$R/$MIG" "$R/csi-spl-api" "$R/csi-spl-wui" "$R/csi-spl-iac"
printf 'SELECT 1;\n' >"$R/$MIG/0118_old.sql"; echo a >"$R/csi-spl-api/a.go"; echo w >"$R/csi-spl-wui/w.ts"
git -C "$R" add -A; git -C "$R" commit -qm seed; git -C "$R" branch trunk; git -C "$R" checkout -q -b lane

gate() {  # [env...] -> rc; output in $T/out
  : >"$LOG"
  ( for kv in "$@"; do export "${kv?}"; done
    export PRE_PUSH_ONLY=override PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$LOG" \
      PRE_PUSH_CACHE="$CACHE" PRE_PUSH_EXTRA_PATH=''
    do_check_pre_push ) >"$T/out" 2>&1
}
verdict() { sed -nE "s/.* PART $1 ([A-Za-z-]+) .*/\\1/p" "$LOG" | tail -1; }

# 2 + 4 first: a clean new migration passes, runs only the cheap parts, then is cached
printf 'SELECT 2;\n' >"$R/$MIG/0119_mine.sql"; echo b >>"$R/csi-spl-api/a.go"; echo v >>"$R/csi-spl-wui/w.ts"
git -C "$R" add -A; git -C "$R" commit -qm "mine: 0119 + api + wui"
: >"$HYG"; gate; eq "2. override + a clean new migration -> passes" 0 "$?"
eq "2. ... lint-migration ran" PASS "$(verdict lint-migration)"
eq "2. ... hygiene ran" 1 "$(wc -l <"$HYG" | tr -d ' ')"
others="$(awk '$3=="PART" && $4!="hygiene" && $4!="lint-migration" {print $4}' "$LOG" | paste -sd' ' -)"
eq "2. ... and no other part (no iac / wui / api / other lint)" "" "$others"
grep -q '^PRE_PUSH_PLAN .* parts=hygiene lint-migration$' "$T/out" \
  && pass "2. ... the plan line names exactly hygiene + lint-migration" || fail "2. plan line" "$(grep PRE_PUSH_PLAN "$T/out")"
gate; eq "4. a re-push with nothing changed -> passes" 0 "$?"
eq "4. ... lint-migration verdict re-used" PASS-cached "$(verdict lint-migration)"

# 1. trunk gains ANOTHER lane's 0119 while this push waits; rebase; override
git -C "$R" checkout -q trunk; printf 'SELECT 3;\n' >"$R/$MIG/0119_theirs.sql"
git -C "$R" add -A; git -C "$R" commit -qm "theirs: 0119"; git -C "$R" checkout -q lane
git -C "$R" rebase -q trunk
gate; eq "1. override + a duplicate migration prefix after the rebase -> REFUSED" 1 "$?"
eq "1. ... lint-migration FAIL, not the pre-rebase green re-used" FAIL "$(verdict lint-migration)"
grep -q 'prefix 0119 is taken by more than one file' "$T/out" \
  && pass "1. ... the message names the taken prefix" || fail "1. message" "$(grep MIGRATION "$T/out")"

# 3. PRE_PUSH_LINT=0 (the lint rollback) does not drop it from the override
gate PRE_PUSH_LINT=0; eq "3. PRE_PUSH_LINT=0 + override + duplicate -> still REFUSED" 1 "$?"
eq "3. ... lint-migration still ran" FAIL "$(verdict lint-migration)"

echo "-- check-pre-push-override.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
