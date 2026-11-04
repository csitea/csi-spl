#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the commit-links part of do_check_pre_push (SPL-4789). The
#          decision (keys, the hub check, the FATALs) is the orc action's and
#          is tested there (csi-spl-orc/src/bash/tests/spl-commit-links-check.tst.sh);
#          this file proves the part runs it on PRE_PUSH_BASE..HEAD:
#   1. every tier and mode plans commit-links right after owner-orders; a
#      lint-only run has none
#   2. the action refuses (rc 3) -> the gate fails, logged PART commit-links FAIL
#   3. the action passes -> PART commit-links PASS; it got the tree and the range
#   4. CONTROL: a tree without the action -> PASS, saying so
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
unset PRE_PUSH_BASE PRE_PUSH_MODE PRE_PUSH_TIER PRE_PUSH_ONLY PRE_PUSH_PLAN PRE_PUSH_LINT PRE_PUSH_LINT_ONLY PRE_PUSH_SKIP_PASSED 2>/dev/null || true
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

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
R="$ROOT/r"
git init -q "$R"; echo a >"$R/a.md"; git -C "$R" add a.md; git -C "$R" commit -qm seed; git -C "$R" branch trunk
echo b >>"$R/a.md"; git -C "$R" commit -qam "docs: one outgoing commit"
# a stand-in orc: its ./run records what the part passed and exits STUB_RC
mkdir -p "$R/csi-spl-orc/src/bash/run"
: >"$R/csi-spl-orc/src/bash/run/spl-commit-links-check.func.sh"
cat >"$R/csi-spl-orc/run" <<'SH'
#!/usr/bin/env bash
echo "$* repo=$COMMIT_LINKS_REPO range=$COMMIT_LINKS_RANGE" >>"$STUB_CALLS"
exit "${STUB_RC:-0}"
SH
chmod +x "$R/csi-spl-orc/run"
printf 'csi-spl-orc/\n' >>"$R/.git/info/exclude"
export STUB_CALLS="$ROOT/calls"

# 1. the plan
plan() {  # [env...] -> the parts= field
  ( for kv in "$@"; do export "${kv?}"; done; PRE_PUSH_PLAN=1 PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk do_check_pre_push 2>/dev/null ) \
    | sed -n 's/^PRE_PUSH_PLAN .* parts=//p'
}
for m in "PRE_PUSH_MODE=fast PRE_PUSH_TIER=fast" "PRE_PUSH_MODE=full PRE_PUSH_TIER=full"; do
  # shellcheck disable=SC2086
  p="$(plan $m)"
  case "$p" in "hygiene stale-tree owner-orders commit-links"*) pass "1. $m plans commit-links after owner-orders" ;; *) fail "1. $m plans commit-links" "$p" ;; esac
done
p="$(plan PRE_PUSH_ONLY=lint)"
case " $p " in *" commit-links "*) fail "1. a lint-only run has no commit-links part" "$p" ;; *) pass "1. a lint-only run has no commit-links part" ;; esac

LOG="$ROOT/pp.log"
gate() {
  ( env PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$LOG" PRE_PUSH_CACHE="$ROOT/pp.cache" \
      PRE_PUSH_PASS="$ROOT/pp.pass" PRE_PUSH_EXTRA_PATH='' PRE_PUSH_NO_CACHE=1 "$@" \
      bash -c '. "$0"; do_log() { :; }; do_check_dist_hygiene() { :; }; _pp_part_stale_tree() { :; }; _pp_part_owner_orders() { :; }
        _pp_missing_tools() { :; }; _ppl_plan() { _PPL_SELECTED=""; }; _ppl_typos() { :; }; _pp_release_note() { :; }
        do_check_pre_push' "$FUNC" ) >"$ROOT/out" 2>&1
}

# 2. refused
: >"$LOG"; : >"$STUB_CALLS"; gate STUB_RC=3; eq "2. the action refuses (rc 3) -> the gate fails (rc 1)" 1 "$?"
grep -q ' PART commit-links FAIL ' "$LOG" && pass "2. ... logged PART commit-links FAIL" || fail "2. ... logged FAIL" "$(cat "$LOG")"

# 3. passed, with the tree and the range
: >"$LOG"; : >"$STUB_CALLS"; gate STUB_RC=0; eq "3. the action passes -> the gate passes" 0 "$?"
grep -q ' PART commit-links PASS ' "$LOG" && pass "3. ... logged PART commit-links PASS" || fail "3. ... logged PASS" "$(cat "$LOG")"
eq "3. ... ran the action on the tree and PRE_PUSH_BASE..HEAD" "-a do_spl_commit_links_check repo=$R range=trunk..HEAD" "$(cat "$STUB_CALLS")"

# 4. control
rm -rf "$R/csi-spl-orc"
PRE_PUSH_BASE=trunk _pp_part_commit_links "$R" >"$ROOT/part" 2>&1; eq "4. CONTROL: a tree without the action -> PASS" 0 "$?"
grep -q 'commit-links: PASS no gate in this tree' "$ROOT/part" && pass "4. ... says so" || fail "4. ... says so" "$(cat "$ROOT/part")"

echo "check-pre-push-commit-links: $fails failure(s)"
((fails == 0))
