#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a role seat row with nothing running it is not a live lane (SPL-5091).
#          The hub keeps a role seat's row live for ever (lane-map.sh refuses
#          done for a seat), so the map listed dead seats as live for days.
#          do_spl_lane_map against a stub hub, this box "sat", the other "box2":
#   1. no pane on its box, identity file alive=false: state gone, not in the
#      default map; no pane and NO identity file: the same
#   2. a live pane here, or the id in the other box's BOX-0 live=: still live
#   3. nothing to read: tmux unreadable, a box with no BOX-0 row, a BOX-0
#      row that may be cut at 500 chars: the row stays live (unsure is not gone)
#   4. a seat row written after the BOX-0 row: still live (a fresh start)
#   5. a plain lane is left as it was; a gone seat's files own nothing
#------------------------------------------------------------------------------
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$HERE/../../.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "ok - $*"; }
fail() { echo "NOT OK - $*"; fails=$((fails + 1)); }

mkdir -p "$T/spool/agents" "$T/repo"
git init -q "$T/repo"
echo '{"id":"c-002","alive":false}' >"$T/spool/agents/c-002.json"
cat >"$T/hub" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do [[ "$a" == --agent ]] && exit 0; done
cat "$HUB_FILE"
STUB
chmod +x "$T/hub"

row() {  # ID BOX AGE_S [FILES]
  jq -n -c --arg a "$1" --arg b "$2" --argjson s "$3" --arg f "${4:-}" \
    '{agent_id:$a, agent_box:$b, repo:"csi-spl", branch:"b", scope:"", files:($f | split(",") | map(select(length > 0))), topic:"", state:"live", age_s:$s}'
}
box0() {  # BOX AGE_S SCOPE
  jq -n -c --arg b "$1" --argjson s "$2" --arg sc "$3" \
    '{agent_id:"BOX-0", agent_box:$b, repo:"", branch:"", scope:$sc, files:[], topic:"", state:"live", age_s:$s}'
}
hub() { printf '%s\n' "$@" | jq -s -c '{lanes: .}' >"$T/hub.json"; }

printf '0 c-001@sat\n' >"$T/panes"
map() {  # PANES_CMD [env...]
  local panes="$1"; shift
  env PROJ_PATH="$T/repo" SPOOL_ROOT="$T/spool" SPOOL_BOX_ENV="$T/spool/box.env" SPOOL_DESK_BOX=sat LANE_BOX=sat \
    LANE_FLEET=f LANE_REPO_DIRS="$T/repo" LANE_HUB_CMD="$T/hub" HUB_FILE="$T/hub.json" LANE_PANES_CMD="$panes" \
    LANE_CI_CMD="echo 0" SPOOL_VENDOR_CLIS_CMD=false LANE_HUB_BACKOFF=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-lane-map.func.sh"
    do_spl_lane_map' 2>/dev/null
}
# state <json map> <ID@BOX>: the row's state, "absent" when there is none
state() { jq -r --arg k "$2" '[.lanes[] | select("\(.agent_id)@\(.agent_box)" == $k) | .state][0] // "absent"' <<<"$1"; }
is() {  # WANT GOT WHAT
  [[ "$2" == "$1" ]] && pass "$3" || fail "$3: want $1, got $2"
}

hub "$(row c-002 sat 180000)" "$(row g-001 sat 500000)" "$(row c-001 sat 180000)" \
  "$(row g-002 box2 400000)" "$(row c-003 box2 180000)" "$(row c-900 sat 180000)" \
  "$(box0 box2 60 'mem_kb=1 live=c-003,c-500')"
all="$(map "cat $T/panes" LANE_ALL=1 LANE_FORMAT=json)"
def="$(map "cat $T/panes" LANE_FORMAT=json)"
table="$(map "cat $T/panes")"
# 1
is gone "$(state "$all" c-002@sat)" "--all: alive=false and no pane is gone"
is gone "$(state "$all" g-001@sat)" "--all: no identity file and no pane is gone"
is gone "$(state "$all" g-002@box2)" "--all: not in the other box's BOX-0 live= is gone"
is absent "$(state "$def" c-002@sat)" "default json: the dead seat is not listed"
is absent "$(state "$def" g-002@box2)" "default json: nor the other box's dead seat"
[[ "$table" != *g-001@sat* && "$table" != *c-002@sat* ]] && pass "default table: the dead seats are not listed" || fail "default table: $table"
# 2
is live "$(state "$all" c-001@sat)" "a live pane here stays live"
is live "$(state "$all" c-003@box2)" "an id in BOX-0 live= stays live"
[[ "$table" == *c-001@sat* && "$table" == *c-003@box2* ]] && pass "default table: the running seats stay at any age" || fail "default table: $table"
# 5
is live "$(state "$all" c-900@sat)" "a plain lane with no pane is left as it was"
# 3
out="$(map false LANE_ALL=1 LANE_FORMAT=json)"
is live "$(state "$out" c-002@sat)" "tmux unreadable and no BOX-0 row here: the row stays"
long="mem_kb=1 live=$(printf 'c-500,%.0s' {1..90})"
hub "$(row g-001 far 500000)" "$(row g-002 box2 400000)" "$(box0 box2 60 "${long:0:500}")"
out="$(map "cat $T/panes" LANE_ALL=1 LANE_FORMAT=json)"
is live "$(state "$out" g-001@far)" "a box with no BOX-0 row: the row stays"
is live "$(state "$out" g-002@box2)" "a BOX-0 row that may be cut at 500 chars: the row stays"
hub "$(row g-002 box2 3000)" "$(box0 box2 3500 'mem_kb=1 live=c-500')"
out="$(map "cat $T/panes" LANE_ALL=1 LANE_FORMAT=json)"
is live "$(state "$out" g-002@box2)" "a seat row written after the BOX-0 row stays"
hub "$(row g-002 box2 400000)" "$(box0 box2 7000 'mem_kb=1 live=c-500')"
out="$(map "cat $T/panes" LANE_ALL=1 LANE_FORMAT=json)"
is live "$(state "$out" g-002@box2)" "a BOX-0 row too old to read: the row stays"
# 5
hub "$(row g-001 sat 500000 csi-spl-orc/x.sh)"
out="$(map "cat $T/panes" LANE_CHECK=csi-spl-orc/x.sh LANE_AGENT=c-387)"; rc=$?
is "0 free" "$rc $(head -1 <<<"$out")" "--check: a gone seat's files own nothing"
hub "$(row c-001 sat 500000 csi-spl-orc/x.sh)"
map "cat $T/panes" LANE_CHECK=csi-spl-orc/x.sh LANE_AGENT=c-387 >/dev/null; rc=$?
is 3 "$rc" "control --check: a running seat's files stay owned"

echo
if [ "$fails" -eq 0 ]; then echo "lane-map-dead-role-seat: all passed"; exit 0; fi
echo "lane-map-dead-role-seat: $fails FAILED"; exit 1
