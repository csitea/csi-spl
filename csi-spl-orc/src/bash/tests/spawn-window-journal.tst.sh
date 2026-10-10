#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 115 ORC-2, spawn-window.sh writes the tries journal row:
#          ONE row `task_id kind vendor id start_epoch outcome source` (7
#          tab-separated columns) in $SPOOL_ROOT/dispatch/attempts.tsv.
#          No live agent, no tmux, no claude: a tmux stub on PATH answers
#          list-sessions and new-window, so the launcher never runs.
#   1. a started lane writes outcome `run`, task from LANE_MIX_TASK, kind
#      from LANE_MIX_KIND; do_spl_lane_mix_journal reads it as a try
#   2. a start failure (new-window prints no pane: exit 4) writes `fail:F1`,
#      read as a failed try; no tmux session (exit 5) does the same
#   3. HOLD (exit 10) writes nothing; a dry run writes nothing
#   4. the old per-id file $SPOOL_ROOT/<id>/attempts.tsv is not written
#   5. 8 concurrent spawns: 8 whole rows (flock)
#   6. control: a copy of spawn-window.sh with the outcome field dropped
#      fails the row check of 1
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
SW="$PROJ_ROOT/src/bash/features/spawn-agents/scripts/spawn-window.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
case "$(readlink -f "$T")" in /var/spool-hub|/var/spool-hub/*) echo "FAIL: refusing to run inside the live spool root ($T)"; exit 1 ;; esac
mkdir -p "$T/bin"
TASK=caef117a-6767-57f3-b805-b4ed1bc96608

# The tmux stub: one session; new-window prints a pane id unless
# $T/no-pane exists; no session at all when $T/no-session exists.
cat >"$T/bin/tmux" <<STUB
#!/usr/bin/env bash
while [ "\${1:-}" = -u ] || [ "\${1:-}" = -S ]; do [ "\$1" = -S ] && shift; shift; done
case "\${1:-}" in
  list-sessions) [ -e "$T/no-session" ] || echo '\$1' ;;
  new-window) [ -e "$T/no-pane" ] || echo '%42' ;;
esac
exit 0
STUB
chmod +x "$T/bin/tmux"

# sw <script> <title> [VAR=value...]: one spawn into spool root $T/spool,
# its rc in $T/rc
sw() {
  local script="$1" title="$2"; shift 2
  env -u TMUX -u TMUX_PANE -u SPOOL_AGENT_ID -u MCP_BOT_AGENT_ID -u SPAWN_REQUESTER \
    -u LANE_MIX_TASK -u LANE_MIX_KIND -u SPAWN_LANE_TOPIC -u SPAWN_DRY_RUN -u SPOOL_BOX_TAG \
    -u LANE_FLEET -u SPAWN_BOX PATH="$T/bin:$PATH" SPOOL_TEST=1 SPAWN_TEST_SANDBOX=1 \
    SPOOL_ROOT="$T/spool" SPOOL_BOX_USER="$(id -un)" SPOOL_TMUX_SOCKET="$T/tmux.sock" \
    SPOOL_SESSION= SPOOL_BIN=/bin/true SPAWN_REUSE_ID=1 SPAWN_START_CHECK=0 SPOOL_SHOW_PANE=0 \
    SPAWN_BOX_PICK=0 "$@" bash "$script" claude "$title" "$T" >"$T/so" 2>&1
  echo $? >"$T/rc"
}
fresh() { rm -rf "$T/spool" "$T/no-pane" "$T/no-session"; mkdir -p "$T/spool/dispatch"; }
J="$T/spool/dispatch/attempts.tsv"
rows() { [ -f "$J" ] && grep -c . "$J" || echo 0; }
# row_ok <task> <kind> <id> <outcome>: the journal is exactly one 7-column row
row_ok() {
  [ "$(rows)" = 1 ] && awk -F'\t' -v t="$1" -v k="$2" -v i="$3" -v o="$4" '
    NF == 7 && $1 == t && $2 == k && $3 == "claude" && $4 == i && $5 ~ /^[0-9]+$/ && $6 == o && $7 == "spawn-window" { ok = 1 }
    END { exit !ok }' "$J"
}
journal() {
  env SPOOL_ROOT="$T/spool" LANE_MIX_TASK="$TASK" LANE_MIX_JOURNAL="$J" bash -c '
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-lane-mix-journal.func.sh"; do_spl_lane_mix_journal'
}

# ---- 1. a started lane writes run --------------------------------------------
fresh
sw "$SW" c-901 LANE_MIX_TASK="$TASK" LANE_MIX_KIND=complex_coding
[ "$(cat "$T/rc")" = 0 ] && grep -qx 'c-901 %42' "$T/so" && row_ok "$TASK" complex_coding c-901 run &&
  pass "1. a started lane: exit 0, 'c-901 %42' printed, one 7-column row outcome run" ||
  fail "1. rc=$(cat "$T/rc") $(cat "$T/so") journal: $(cat "$J" 2>/dev/null)"
grep -qx 'claude  tries=1 failed=0' <<<"$(journal)" &&
  pass "1. do_spl_lane_mix_journal reads it: claude tries=1 failed=0" || fail "1. reader: $(journal)"
fresh
sw "$SW" c-901 SPAWN_LANE_TOPIC=topic-1
row_ok topic-1 - c-901 run && pass "1. no LANE_MIX_TASK: task_id is the lane topic, kind '-'" || fail "1. topic: $(cat "$J" 2>/dev/null)"

# ---- 2. a start failure writes fail:F1 ---------------------------------------
fresh; touch "$T/no-pane"
sw "$SW" c-901 LANE_MIX_TASK="$TASK" LANE_MIX_KIND=complex_coding
[ "$(cat "$T/rc")" = 4 ] && grep -q 'printed no pane id' "$T/so" && row_ok "$TASK" complex_coding c-901 fail:F1 &&
  pass "2. new-window printed no pane: exit 4 unchanged, one row fail:F1" ||
  fail "2. rc=$(cat "$T/rc") $(cat "$T/so") journal: $(cat "$J" 2>/dev/null)"
grep -qx 'claude  tries=1 failed=1' <<<"$(journal)" &&
  pass "2. do_spl_lane_mix_journal reads it: claude tries=1 failed=1" || fail "2. reader: $(journal)"
fresh; touch "$T/no-session"
sw "$SW" c-901 LANE_MIX_TASK="$TASK" LANE_MIX_KIND=tests
[ "$(cat "$T/rc")" = 5 ] && row_ok "$TASK" tests c-901 fail:F1 &&
  pass "2. no tmux session: exit 5 unchanged, one row fail:F1" || fail "2. rc=$(cat "$T/rc") journal: $(cat "$J" 2>/dev/null)"

# ---- 3. HOLD and dry run write nothing --------------------------------------
fresh
sw "$SW" auto LANE_MIX_TASK="$TASK" LANE_FLEET=fl SPAWN_BOX_PICK=1 SPAWN_BOX_PICK_CMD="echo pick=hold reason=every-box-full"
[ "$(cat "$T/rc")" = 10 ] && grep -q 'HOLD' "$T/so" && [ "$(rows)" = 0 ] &&
  pass "3. HOLD: exit 10, no journal row" || fail "3. rc=$(cat "$T/rc") rows=$(rows) $(cat "$T/so")"
fresh
sw "$SW" c-901 LANE_MIX_TASK="$TASK" SPAWN_DRY_RUN=1 SPAWN_SKIP_WORKTREE=1
[ "$(rows)" = 0 ] && pass "3. dry run (rc $(cat "$T/rc")): no journal row" || fail "3. dry run rows=$(rows)"

# ---- 4. the old per-id file is gone -----------------------------------------
fresh
sw "$SW" c-901 LANE_MIX_TASK="$TASK"
[ ! -e "$T/spool/c-901/attempts.tsv" ] && [ "$(rows)" = 1 ] &&
  pass "4. no \$SPOOL_ROOT/c-901/attempts.tsv; the row is in dispatch/attempts.tsv" || fail "4. old file written"

# ---- 5. concurrent spawns ---------------------------------------------------
fresh
for i in 1 2 3 4 5 6 7 8; do
  ( env -u TMUX -u TMUX_PANE -u SPOOL_AGENT_ID -u MCP_BOT_AGENT_ID -u SPAWN_REQUESTER -u SPOOL_BOX_TAG -u LANE_FLEET -u SPAWN_BOX \
      PATH="$T/bin:$PATH" SPOOL_TEST=1 SPAWN_TEST_SANDBOX=1 SPOOL_ROOT="$T/spool" SPOOL_BOX_USER="$(id -un)" \
      SPOOL_TMUX_SOCKET="$T/tmux.sock" SPOOL_SESSION= SPOOL_BIN=/bin/true SPAWN_REUSE_ID=1 SPAWN_START_CHECK=0 \
      SPOOL_SHOW_PANE=0 SPAWN_BOX_PICK=0 LANE_MIX_TASK="$TASK" bash "$SW" claude "c-90$i" "$T" >/dev/null 2>&1 ) &
done
wait
[ "$(rows)" = 8 ] && [ "$(awk -F'\t' 'NF == 7' "$J" | cut -f4 | sort -u | wc -l)" = 8 ] &&
  pass "5. 8 concurrent spawns: 8 whole 7-column rows" || fail "5. rows=$(rows): $(cat "$J")"

# ---- 6. control: drop the outcome field -------------------------------------
mkdir -p "$T/fa"
cp -r "$PROJ_ROOT/src/bash/features/spawn-agents/lib" "$PROJ_ROOT/src/bash/features/spawn-agents/scripts" "$T/fa/"
sed -i 's/ "\$SW_START" "\$outcome" spawn-window/ "$SW_START" spawn-window/; s/%s\\t%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n/%s\\t%s\\t%s\\t%s\\t%s\\t%s\\n/' "$T/fa/scripts/spawn-window.sh"
if grep -q '"\$outcome"' "$T/fa/scripts/spawn-window.sh"; then
  fail "6. control: the outcome field was not dropped from the copy"
else
  fresh
  sw "$T/fa/scripts/spawn-window.sh" c-901 LANE_MIX_TASK="$TASK" LANE_MIX_KIND=complex_coding
  row_ok "$TASK" complex_coding c-901 run &&
    fail "6. control: the row check passed with no outcome field" ||
    pass "6. control: no outcome field -> the row check of 1 is red ($(cat "$J" 2>/dev/null | tr '\t' ' '))"
fi

echo "---"
[ "$fails" = 0 ] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
