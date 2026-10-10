#!/usr/bin/env bash
# A brief's `Files:` line is the lane-map row's files from spawn on (c-904
# follow-up): `lane-map.sh --check` then names the lane as soon as it starts,
# not exit 4 `unknown:`. Dry-run spawns plan the put; the planned --files then
# go through do_spl_lane_put into a stub hub with the real row contract.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
command -v jq >/dev/null || { nok "jq is required"; t_done; }
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool
WD="$T_TMP/plain"; mkdir -p "$WD" "$T_TMP/bin" "$T_TMP/hub"
printf '# Brief: two files\nFiles: a,b\n' >"$T_TMP/brief-ab.md"
printf '# Brief: as a dispatcher writes it\n\nFiles: `x/y.sh`, x/z.md, x/tests/.\n' >"$T_TMP/brief-md.md"
printf '# Brief: no files\nbody\n' >"$T_TMP/brief-none.md"

# planned <id> <brief> [env...]: the --files of the lane put a dry-run spawn plans
planned() {
  local id="$1" brief="$2"; shift 2
  env "$@" bash "$T_SCRIPTS/spawn-claude.sh" "$id" "$WD" "$brief" "do it" 2>&1 |
    sed -n "s/^PLAN lane .* --files '\([^']*\)' --topic .*/\1/p"
}
eq "Files: a,b -> the put plans --files a,b" "a,b" "$(planned CLE-71 "$T_TMP/brief-ab.md")"
eq "a markdown Files: line -> trimmed, backticks and trailing dot dropped" "x/y.sh,x/z.md,x/tests/" "$(planned CLE-72 "$T_TMP/brief-md.md")"
eq "no Files: line -> --files '' (today's behaviour)" "" "$(planned CLE-73 "$T_TMP/brief-none.md")"
eq "SPAWN_LANE_FILES wins over the brief's Files: line" "c" "$(planned CLE-74 "$T_TMP/brief-ab.md" SPAWN_LANE_FILES=c)"
check "the dry runs wrote no spool dir" test ! -e "$SPOOL_ROOT/CLE-71"

# The hub stub (lane-map.tst.sh's contract): one row per agent, files split on ','.
cat >"$T_TMP/bin/hub" <<'STUB'
#!/usr/bin/env bash
shift; agent="" files=""
while [ $# -gt 0 ]; do case "$1" in --agent) agent="$2";; --files) files="$2";; esac; shift 2; done
f="$HUB_DIR/rows.json"; [ -s "$f" ] || echo '{"lanes":[]}' >"$f"
if [ -n "$agent" ]; then
  row="$(jq -n -c --arg a "$agent" --arg fl "$files" '{agent_id:$a, files:($fl | split(",") | map(select(length > 0)))}')"
  jq -c --argjson row "$row" '.lanes = ([.lanes[] | select(.agent_id != $row.agent_id)] + [$row])' "$f" >"$f.new" && mv "$f.new" "$f"
  echo "{\"lanes\":[$row]}"
else jq -c . "$f"; fi
STUB
chmod +x "$T_TMP/bin/hub"
# row <id> <files>: put the lane as the spawn would, print its files array
row() {
  env LANE_FLEET=main LANE_AGENT="$1" LANE_FILES="$2" LANE_HUB_CMD="$T_TMP/bin/hub" HUB_DIR="$T_TMP/hub" \
    SPOOL_DESK_BOX=box-desk LANE_REPO_DIRS="$WD" LANE_PANES_CMD=false bash -c '
    do_log() { :; }
    source "'"$T_REPO"'/csi-spl-orc/src/bash/run/spl-lane-put.func.sh"
    do_spl_lane_put' >/dev/null 2>&1
  jq -c --arg a "$1" '.lanes[] | select(.agent_id == $a) | .files' "$T_TMP/hub/rows.json" 2>/dev/null
}
eq "Files: a,b -> the row's files are [a,b]" '["a","b"]' "$(row CLE-71 "$(planned CLE-71 "$T_TMP/brief-ab.md")")"
eq "no Files: line -> the row's files are []" '[]' "$(row CLE-73 "$(planned CLE-73 "$T_TMP/brief-none.md")")"
t_done
