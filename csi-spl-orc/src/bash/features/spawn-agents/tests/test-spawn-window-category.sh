#!/usr/bin/env bash
# test-spawn-window-category.sh — spec 143 4.4 (SPL-2790): spawn-window.sh
# writes the brief's "Kind:" and "Category:" header to
# <spool root>/<id>/lifetime/category.json, the lane's own record of what
# its tokens are spent on.
#   1. live: a brief with both -> {"work_kind":"complex_coding","category_path":"coding/hard"}
#   2. live: Kind: only -> category_path ""; a dry run plans it, writes nothing
#   3. CONTROL: a brief with neither writes no file and the spawn is unchanged
#   4. a "Category:" that is not at a line start is not read (a quote in prose)
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_tmux
unset LEASE_MACHINE LANE_FLEET SPAWN_BOX SPAWN_REMOTE_CMD SPAWN_PLACE_MAP_CMD SPAWN_DRY_RUN SPAWN_BOX_PICK_CMD \
  SPAWN_ORC_RUN SPAWN_ISSUE SPAWN_ISSUE_CREATE SPAWN_ISSUE_CMD SPAWN_REUSE_ID SPAWN_LANE_TOPIC REPORT_TO
export SPAWN_BOX_PICK=0 SPOOL_BIN=/opt/x/spool SPAWN_START_CHECK=0
SW="$T_SCRIPTS/spawn-window.sh"
mkdir -p "$T_TMP/plain"
printf '# Brief\nKind: complex_coding\nCategory: coding/hard\n\n## Task\nDo it.\n' >"$T_TMP/both.md"
printf '# Brief\nKind: tests\n\n## Task\nDo it.\n' >"$T_TMP/kind.md"
printf '# Brief\n\n## Task\nDo it.\n' >"$T_TMP/none.md"
printf '# Brief\nSee the "Category: coding/hard" line of spec 143.\n' >"$T_TMP/prose.md"
sw() {  # ID BRIEF [ENV...] -> stdout+stderr in $T_TMP/o, rc in $RC
  local id="$1" brief="$2"; shift 2
  env "$@" bash "$SW" claude "$id" "$T_TMP/plain" "$brief" cat-proof >"$T_TMP/o" 2>&1; RC=$?
}
cj() { cat "$SPOOL_ROOT/$1/lifetime/category.json" 2>/dev/null; }

sw c-301 "$T_TMP/both.md"
eq "1 live spawn with Kind: and Category: exits 0" 0 "$RC"
eq "1 ... category.json holds both" '{"work_kind":"complex_coding","category_path":"coding/hard"}' "$(cj c-301)"

sw c-302 "$T_TMP/kind.md" SPAWN_DRY_RUN=1
eq "2 dry run exits 0" 0 "$RC"
has "2 ... plans the category" "PLAN category   work_kind tests, category_path none -> $SPOOL_ROOT/c-302/lifetime/category.json" "$(cat "$T_TMP/o")"
check "2 ... and writes nothing" test ! -e "$SPOOL_ROOT/c-302/lifetime/category.json"
sw c-303 "$T_TMP/kind.md"
eq "2 live, Kind: only: category_path empty" '{"work_kind":"tests","category_path":""}' "$(cj c-303)"

sw c-304 "$T_TMP/none.md"
eq "3 CONTROL a brief with neither: the spawn exits 0" 0 "$RC"
check "3 ... and writes no category.json" test ! -e "$SPOOL_ROOT/c-304/lifetime/category.json"
hasnt "3 ... and says nothing of a category" "category" "$(cat "$T_TMP/o")"

sw c-305 "$T_TMP/prose.md"
check "4 a quoted Category: in prose is not read" test ! -e "$SPOOL_ROOT/c-305/lifetime/category.json"

t_done
