#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the owner-orders part of do_check_pre_push (spec 168 part c, build
#          row B3, SPL-4372). The decision itself (paths, renames, the hub
#          check of the go) is the orc action's and is tested there
#          (csi-spl-orc/src/bash/tests/spl-owner-order-gate.tst.sh); this file
#          proves the part runs it on PRE_PUSH_BASE..HEAD:
#   1. every tier and mode plans owner-orders right after stale-tree; a
#      lint-only run has none
#   2. an outgoing commit that changes a path a gate go order covers, with no
#      Owner-go trailer -> the gate REFUSED (rc 1), logged PART owner-orders FAIL
#   3. the same commit with its Owner-go trailer -> PASS (no hub: form only)
#   4. CONTROL: an uncovered change -> PASS; a tree without the orc gate lib
#      -> PASS, saying so
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
unset PRE_PUSH_BASE PRE_PUSH_MODE PRE_PUSH_TIER PRE_PUSH_ONLY PRE_PUSH_PLAN PRE_PUSH_LINT PRE_PUSH_LINT_ONLY PRE_PUSH_SKIP_PASSED 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
REPO="$(cd "$PROJ_ROOT/.." && pwd)"
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"
SA="$REPO/csi-spl-orc/src/bash/features/spawn-agents"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

do_log() { :; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
O_GO=aaaaaaaa-1111-4bbb-8ccc-000000000001 G=d0d0d0d0-2222-4bbb-8ccc-000000000004
# no prd key on this "box": the box default is none (a caller's ORDER_GO_HUB=none alone is ignored, R7 c-718 W1)
export ORDER_GO_HUB=none GCP_SA_KEY_FILE="$ROOT/no-such-key.json" OWNER_ORDER_DIR="$ROOT/oo" OOG_ORC_DIR="$REPO/csi-spl-orc"
mkdir -p "$OWNER_ORDER_DIR"
jq -n -c --arg o "$O_GO" '{op: "add", order: $o, repo: "r", paths: ["docs/**"], text: "synthetic", source: "given",
  gate: "go", ts: "2026-10-29T10:00:00Z", owner: "HUM-10", topic: "", expires: "", note: "", by: "c-900",
  at: "2026-10-29T10:00:00Z"}' >"$OWNER_ORDER_DIR/r.jsonl"

R="$ROOT/r"
git init -q "$R"; mkdir -p "$R/docs" "$R/other"; echo a >"$R/docs/a.md"; echo o >"$R/other/o.md"
git -C "$R" add -A; git -C "$R" commit -qm seed; git -C "$R" branch trunk
L="$R/csi-spl-orc/src/bash/features/spawn-agents/lib"; mkdir -p "$L"
cp "$SA/lib/owner-order-guard.inc.sh" "$SA/lib/force-push-guard.inc.sh" "$L/"
printf 'csi-spl-orc/\n' >>"$R/.git/info/exclude"

# 1. the plan
plan() {  # [env...] -> the parts= field
  ( for kv in "$@"; do export "${kv?}"; done; PRE_PUSH_PLAN=1 PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk do_check_pre_push 2>/dev/null ) \
    | sed -n 's/^PRE_PUSH_PLAN .* parts=//p'
}
for m in "PRE_PUSH_MODE=fast PRE_PUSH_TIER=fast" "PRE_PUSH_MODE=full PRE_PUSH_TIER=full"; do
  # shellcheck disable=SC2086
  p="$(plan $m)"
  case "$p" in "hygiene stale-tree owner-orders"*) pass "1. $m plans owner-orders after stale-tree" ;; *) fail "1. $m plans owner-orders" "$p" ;; esac
done
p="$(plan PRE_PUSH_ONLY=lint)"
case " $p " in *" owner-orders "*) fail "1. a lint-only run has no owner-orders part" "$p" ;; *) pass "1. a lint-only run has no owner-orders part" ;; esac

LOG="$ROOT/pp.log"
gate() {
  ( env PRE_PUSH_TREE="$R" PRE_PUSH_BASE=trunk PRE_PUSH_LOG="$LOG" PRE_PUSH_CACHE="$ROOT/pp.cache" \
      PRE_PUSH_PASS="$ROOT/pp.pass" PRE_PUSH_EXTRA_PATH='' PRE_PUSH_NO_CACHE=1 \
      bash -c '. "$0"; do_log() { :; }; do_check_dist_hygiene() { :; }; _pp_part_stale_tree() { :; }
        _pp_missing_tools() { :; }; _ppl_plan() { _PPL_SELECTED=""; }; _ppl_typos() { :; }; _pp_release_note() { :; }
        do_check_pre_push' "$FUNC" ) >"$ROOT/out" 2>&1
}
part() { PRE_PUSH_BASE=trunk _pp_part_owner_orders "$R" >"$ROOT/part" 2>&1; }

# 2. uncited
echo more >>"$R/docs/a.md"; git -C "$R" commit -qam "docs: edit"
: >"$LOG"; gate; eq "2. an uncited outgoing change to a covered path -> REFUSED (rc 1)" 1 "$?"
grep -q ' PART owner-orders FAIL ' "$LOG" && pass "2. ... logged PART owner-orders FAIL" || fail "2. ... logged FAIL" "$(cat "$LOG")"
part; eq "2. the part itself -> rc 3" 3 "$?"
grep -q "REFUSED .* owner order ${O_GO:0:8}" "$ROOT/part" && pass "2. ... names the order" || fail "2. ... names the order" "$(cat "$ROOT/part")"

# 3. cited
git -C "$R" commit -q --amend -m "docs: edit" -m "Owner-go: $G"
: >"$LOG"; gate; eq "3. the same commit with its Owner-go trailer -> PASS" 0 "$?"
grep -q ' PART owner-orders PASS ' "$LOG" && pass "3. ... logged PART owner-orders PASS" || fail "3. ... logged PASS" "$(cat "$LOG")"

# 4. controls
git -C "$R" reset -q --hard trunk; echo more >>"$R/other/o.md"; git -C "$R" commit -qam "other: edit"
part; eq "4. CONTROL: an uncovered change -> PASS" 0 "$?"
rm -rf "$R/csi-spl-orc"
part; eq "4. CONTROL: a tree without the gate lib -> PASS" 0 "$?"
grep -q 'PASS no gate in this tree' "$ROOT/part" && pass "4. ... and says so" || fail "4. ... says so" "$(cat "$ROOT/part")"

((fails == 0)) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
