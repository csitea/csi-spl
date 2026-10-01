#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the fleet-wide lane map (CLE-77920, specs/058 G4 / N2):
#          do_spl_lane_map + do_spl_lane_put across TWO simulated machines.
#          Each machine has its own clone with lanes at <repo>-wt/<ID> and its
#          own desk box (SPOOL_DESK_BOX); the hub is a stub with the real
#          contract of `spool lane` (one row per agent, upsert, list).
#   1. CONTROL: no fleet - each machine's map is its own worktrees only, so
#      pc cannot see sat's lane (the G4 defect) and a write is a no-op
#   2. both machines write their lanes; EACH map shows BOTH, <id>@<box>
#   3. the collision check: a path sat owns -> exit 3 naming CLE-100001@sat;
#      a parent / child path collides too; a disjoint path and the caller's
#      own lane do not
#   4. a lane spawned before the map existed (local worktree, no hub row)
#      still shows, src local
#   5. exit-clean: done keeps the row's fields; the default map hides it,
#      LANE_ALL=1 shows it, and it no longer collides
#   6. the hub down: WARN, the map falls back to this machine's worktrees,
#      a put is exit 2
#   7. json output carries fleet, hub state and the rows
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/hub"

# The hub stub: one JSON file per fleet, {"lanes":[...]}; the writing box is
# the caller's SPOOL_DESK_BOX, as the hub records it from the session.
cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
[ "${HUB_DOWN:-0}" = 1 ] && { echo "dial: connection refused" >&2; exit 1; }
shift
fleet="" agent="" box="" repo="" branch="" scope="" files="" topic="" state=live
while [ $# -gt 0 ]; do case "$1" in
  --fleet) fleet="$2";; --agent) agent="$2";; --box) box="$2";; --repo) repo="$2";; --branch) branch="$2";;
  --scope) scope="$2";; --files) files="$2";; --topic) topic="$2";; --state) state="$2";; esac; shift 2; done
f="$HUB_DIR/$fleet.json"; [ -s "$f" ] || echo '{"lanes":[]}' >"$f"
if [ -n "$agent" ]; then
  row="$(jq -n -c --arg a "$agent" --arg b "$box" --arg r "$repo" --arg br "$branch" --arg s "$scope" --arg fl "$files" \
    --arg t "$topic" --arg st "$state" --arg w "$SPOOL_DESK_BOX" \
    '{agent_id:$a, agent_box:$b, repo:$r, branch:$br, scope:$s, files:($fl | split(",") | map(select(length > 0))),
      topic:$t, state:$st, writer_box:$w, age_s:0}')"
  jq -c --argjson row "$row" '.lanes = ([.lanes[] | select(.agent_id != $row.agent_id)] + [$row])' "$f" >"$f.new" && mv "$f.new" "$f"
  jq -c --arg f "$fleet" --argjson row "$row" '{fleet:$f, lanes:[$row]}' <<<'{}'
else
  jq -c --arg f "$fleet" '{fleet:$f, lanes:.lanes}' "$f"
fi
STUB
chmod +x "$T/bin/hub"

# machine <name> <box>: a clone with an origin, and its spool root
machine() {
  local m="$1"
  git init -q --bare "$T/origin.git" 2>/dev/null
  git init -q "$T/$m/csi-spl" && git -C "$T/$m/csi-spl" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m init
  mkdir -p "$T/$m/spool"
}
# lane <machine> <id> <slug>: a worktree at <repo>-wt/<id>, as spawn-core makes
lane() { git -C "$T/$1/csi-spl" worktree add -q -b "$2-$3" "$T/$1/csi-spl-wt/$2" >/dev/null 2>&1; }

machine pc; machine sat
lane pc CLE-77920 lane-map
lane sat CLE-100001 lease-gate

# on <machine> <action> [env...]: run one action as that machine
on() {
  local m="$1" a="$2"; shift 2
  local box=box-desk; [[ "$m" == sat ]] && box=sat
  env PROJ_PATH="$T/$m/csi-spl" SPOOL_ROOT="$T/$m/spool" SPOOL_BOX_ENV="$T/$m/spool/box.env" SPOOL_DESK_BOX="$box" \
    LANE_REPO_DIRS="$T/$m/csi-spl" LANE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-lane-map.func.sh"
    source "'"$PROJ_ROOT"'/src/bash/run/spl-lane-put.func.sh"
    '"$a"
}

# 1. CONTROL: no fleet
out="$(on pc do_spl_lane_map)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"CLE-77920@box-desk"* && "$out" != *CLE-100001* ]]; then
  pass "control: without the fleet map, pc sees only its own lane (sat's CLE-100001 is invisible - the G4 defect)"
else fail "control: local-only map (rc=$rc): $out"; fi
out="$(on pc do_spl_lane_put LANE_AGENT=CLE-77920)"; rc=$?
[[ $rc -eq 0 && "$out" == *"nothing to write"* && ! -e "$T/hub/main.json" ]] && pass "no fleet: a put writes nothing, exit 0" || fail "no-fleet put (rc=$rc): $out"
out="$(on pc 'LANE_CHECK=csi-spl-orc/src/bash/run do_spl_lane_map')"; rc=$?
[[ $rc -eq 0 ]] && pass "control: the local-only collision check cannot see sat's files (exit 0)" || fail "control check rc=$rc"

# 2. both machines write
F=(LANE_FLEET=main)
on pc do_spl_lane_put "${F[@]}" LANE_AGENT=CLE-77920 LANE_REPO=csi-spl LANE_BRANCH=CLE-77920-lane-map \
  LANE_SCOPE=$'fleet lane map\nsecond line' LANE_FILES='csi-spl-orc/src/bash/run/spl-lane-map.func.sh, csi-spl-doc/specs/058-multi-machine-fleet/' LANE_TOPIC=t-77920 >/dev/null
on sat do_spl_lane_put "${F[@]}" LANE_AGENT=CLE-100001 LANE_REPO=csi-spl LANE_BRANCH=CLE-100001-lease-gate \
  LANE_SCOPE='lease gate' LANE_FILES=csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh,csi-spl-orc/src/bash/tests/fleet-lease.tst.sh >/dev/null
row="$(jq -c '.lanes[] | select(.agent_id == "CLE-77920")' "$T/hub/main.json")"
[[ "$(jq -r .scope <<<"$row")" == "fleet lane map second line" && "$(jq -r '.files | length' <<<"$row")" == 2 && "$(jq -r .agent_box <<<"$row")" == box-desk ]] &&
  pass "a put writes one line of scope, trimmed files, the agent's box from SPOOL_DESK_BOX" || fail "pc row: $row"
[[ "$(jq -r '.lanes[] | select(.agent_id == "CLE-100001") | .agent_box' "$T/hub/main.json")" == sat ]] && pass "sat's row carries box sat" || fail "sat row box"
for m in pc sat; do
  out="$(on "$m" do_spl_lane_map "${F[@]}")"
  if [[ "$out" == *"CLE-77920@box-desk"* && "$out" == *"CLE-100001@sat"* ]]; then pass "$m's map shows both machines' lanes"
  else fail "$m's map: $out"; fi
done
out="$(on pc do_spl_lane_map "${F[@]}")"
grep -E '^CLE-77920@box-desk .* hub\+local' <<<"$out" >/dev/null && grep -E '^CLE-100001@sat .* hub$' <<<"$out" >/dev/null &&
  pass "src: pc's own lane is hub+local, sat's is hub" || fail "src column: $out"

# 3. the collision check
out="$(on pc 'LANE_CHECK=csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh LANE_AGENT=CLE-77921 do_spl_lane_map' "${F[@]}")"; rc=$?
[[ $rc -eq 3 && "$out" == *"COLLISION csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh <-> CLE-100001@sat"* ]] &&
  pass "a file another machine's lane owns: exit 3, names CLE-100001@sat" || fail "collision (rc=$rc): $out"
out="$(on pc 'LANE_CHECK=./csi-spl-orc/src/bash/run/ do_spl_lane_map' "${F[@]}" LANE_AGENT=CLE-77921)"; rc=$?
[[ $rc -eq 3 && "$out" == *CLE-100001@sat* && "$out" == *CLE-77920@box-desk* ]] && pass "a parent dir collides with the files under it, on both machines" || fail "parent (rc=$rc): $out"
out="$(on pc 'LANE_CHECK=csi-spl-doc/specs/058-multi-machine-fleet/spec.md do_spl_lane_map' "${F[@]}" LANE_AGENT=CLE-77921)"; rc=$?
[[ $rc -eq 3 && "$out" == *CLE-77920@box-desk* ]] && pass "a file under a dir another lane owns collides" || fail "child (rc=$rc): $out"
out="$(on sat 'LANE_CHECK=csi-spl-wui/src,csi-spl-orc/src/bash/run/spl-dispatch-lease.func.shx do_spl_lane_map' "${F[@]}" LANE_AGENT=CLE-100002)"; rc=$?
[[ $rc -eq 0 && "$out" != *COLLISION* ]] && pass "disjoint paths (and a mere name prefix) do not collide" || fail "disjoint (rc=$rc): $out"
out="$(on sat 'LANE_CHECK=csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh do_spl_lane_map' "${F[@]}" LANE_AGENT=CLE-100001)"; rc=$?
[[ $rc -eq 0 ]] && pass "the caller's own lane never collides with itself" || fail "self (rc=$rc): $out"

# 4. a lane the hub has no row for
lane pc CLE-77930 old-lane
out="$(on pc do_spl_lane_map "${F[@]}")"
grep -E '^CLE-77930@box-desk .* local$' <<<"$out" >/dev/null && pass "a worktree with no hub row shows, src local" || fail "local-only lane: $out"
out="$(on sat do_spl_lane_map "${F[@]}")"
[[ "$out" != *CLE-77930* ]] && pass "...and only on its own machine until it is written" || fail "sat sees an unwritten lane"

# 5. exit-clean
on pc do_spl_lane_put "${F[@]}" LANE_AGENT=CLE-77920 LANE_STATE=done >/dev/null
row="$(jq -c '.lanes[] | select(.agent_id == "CLE-77920")' "$T/hub/main.json")"
[[ "$(jq -r .state <<<"$row")" == done && "$(jq -r .branch <<<"$row")" == CLE-77920-lane-map && "$(jq -r '.files | length' <<<"$row")" == 2 && "$(jq -r .topic <<<"$row")" == t-77920 ]] &&
  pass "done keeps the row's branch, files and topic" || fail "done row: $row"
git -C "$T/pc/csi-spl" worktree remove --force "$T/pc/csi-spl-wt/CLE-77920"
out="$(on sat do_spl_lane_map "${F[@]}")"
[[ "$out" != *CLE-77920@* ]] && pass "the default map hides a done lane" || fail "done shown: $out"
out="$(on sat do_spl_lane_map "${F[@]}" LANE_ALL=1)"
grep -E '^CLE-77920@box-desk +done' <<<"$out" >/dev/null && pass "LANE_ALL=1 shows it" || fail "LANE_ALL: $out"
out="$(on sat 'LANE_CHECK=csi-spl-doc/specs/058-multi-machine-fleet/ do_spl_lane_map' "${F[@]}" LANE_AGENT=CLE-100002)"; rc=$?
[[ $rc -eq 0 ]] && pass "a done lane no longer collides" || fail "done collides (rc=$rc): $out"

# 6. the hub down
out="$(on pc do_spl_lane_map "${F[@]}" HUB_DOWN=1)"; rc=$?
[[ $rc -eq 0 && "$out" == *"WARN the hub did not answer"* && "$out" == *CLE-77930@box-desk* && "$out" != *CLE-100001* ]] &&
  pass "hub down: WARN, the map falls back to this machine's worktrees" || fail "hub down map (rc=$rc): $out"
out="$(on pc do_spl_lane_put "${F[@]}" HUB_DOWN=1 LANE_AGENT=CLE-77930)"; rc=$?
[[ $rc -eq 2 && "$out" == *"not written"* ]] && pass "hub down: a put is exit 2" || fail "hub down put (rc=$rc): $out"
out="$(on pc 'LANE_CHECK=csi-spl-orc do_spl_lane_map' "${F[@]}" HUB_DOWN=1)"
[[ "$out" == *"saw this machine only"* ]] && pass "hub down: the collision check says it is partial" || fail "partial check: $out"

# 7. json
out="$(on pc do_spl_lane_map "${F[@]}" LANE_FORMAT=json | tail -1)"
[[ "$(jq -r '.fleet + " " + .hub + " " + (.lanes | map(.agent_id) | sort | join(","))' <<<"$out" 2>/dev/null)" == "main ok CLE-100001,CLE-77930" ]] &&
  pass "json: fleet, hub state and the live rows" || fail "json: $out"

# refusals
out="$(on pc do_spl_lane_put "${F[@]}" LANE_AGENT=cle-1)"; rc=$?
[[ $rc -eq 1 ]] && pass "a bad agent id is refused" || fail "bad id rc=$rc"
out="$(on pc do_spl_lane_put LANE_FLEET=Main LANE_AGENT=CLE-1)"; rc=$?
[[ $rc -eq 1 && "$out" == *"LANE_FLEET must be"* ]] && pass "a bad fleet name is refused" || fail "bad fleet rc=$rc: $out"

echo
if [ "$fails" -eq 0 ]; then echo "lane-map: all passed"; exit 0; fi
echo "lane-map: $fails FAILED"; exit 1
