#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_lane_backfill_links (spec 153 3.11, SPL-4457; owner
#          HUM-10, t1 0acd4eaa, msg 69522885): THIS box's live lane rows that
#          lack a topic or an issue are filled from the lane's own task brief
#          ($SPOOL_ROOT/<ID>/lifetime/brief.md) and lifetime/issue. The hub is
#          a stub with the contract of `spool lane` (one row per agent@box).
#   1. dry run (the default): BEFORE / AFTER per row, the counts, nothing
#      written; a role seat, another box's row, a done row and a complete
#      row are not looked at
#   2. DRY_RUN=0: the filled rows are written with their repo, branch, scope
#      and files kept; a lane whose brief names nothing stays as it was
#   3. a second run finds only the lane that names nothing
#   4. (R7 c-287 N2) a live row whose agent has no pane on this box is left
#      out: a write would bump updated_at and bring a dead lane back onto
#      the page (the 3.2 active rule). RED on 5a5a1b955: c-507 was filled.
#   RED CONTROL (master 4cd5b29d2): the action did not exist.
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
mkdir -p "$T/bin" "$T/hub" "$T/spool"

cat >"$T/bin/hub" <<'STUB'
#!/usr/bin/env bash
shift
fleet="" agent="" box="" repo="" branch="" scope="" files="" topic="" issue="" state=live
while [ $# -gt 0 ]; do case "$1" in
  --fleet) fleet="$2";; --agent) agent="$2";; --box) box="$2";; --repo) repo="$2";; --branch) branch="$2";;
  --scope) scope="$2";; --files) files="$2";; --topic) topic="$2";; --issue) issue="$2";; --state) state="$2";; esac; shift 2; done
f="$HUB_DIR/$fleet.json"
if [ -n "$agent" ]; then
  echo "$agent" >>"$HUB_DIR/writes"
  row="$(jq -n -c --arg a "$agent" --arg b "$box" --arg r "$repo" --arg br "$branch" --arg s "$scope" --arg fl "$files" \
    --arg t "$topic" --arg i "$issue" --arg st "$state" \
    '{agent_id:$a, agent_box:$b, repo:$r, branch:$br, scope:$s, files:($fl | split(",") | map(select(length > 0))), topic:$t, issue_key:$i, state:$st}')"
  jq -c --argjson row "$row" '.lanes = ([.lanes[] | select(.agent_id != $row.agent_id or .agent_box != $row.agent_box)] + [$row])' "$f" >"$f.new" && mv "$f.new" "$f"
  jq -c --arg f "$fleet" --argjson row "$row" '{fleet:$f, lanes:[$row]}' <<<'{}'
else
  jq -c --arg f "$fleet" '{fleet:$f, lanes:.lanes}' "$f"
fi
STUB
chmod +x "$T/bin/hub"

U1=1a2b3c4d-1111-4222-8333-444455556666 U2=5e7b15c9-2995-427d-8b05-659762fbb9d8
row() {  # ID BOX TOPIC ISSUE STATE
  printf '{"agent_id":"%s","agent_box":"%s","repo":"csi-spl","branch":"%s-b","scope":"scope %s","files":["a/%s","b"],"topic":"%s","issue_key":"%s","state":"%s"}' \
    "$1" "$2" "$1" "$1" "$1" "$3" "$4" "$5"
}
{ printf '{"lanes":['
  row c-501 sat "" "" live; printf ','
  row c-502 sat "$U2" "" live; printf ','
  row c-503 sat "" "" live; printf ','
  row c-001 sat "" "" live; printf ','
  row c-504 box-b "" "" live; printf ','
  row c-505 sat "$U2" SPL-9 live; printf ','
  row c-506 sat "" "" "done"; printf ','
  row c-507 sat "" "" live
  printf ']}\n'; } >"$T/hub/main.json"
brief() { mkdir -p "$T/spool/$1/lifetime"; printf '%b' "$2" >"$T/spool/$1/lifetime/brief.md"; }
brief c-501 "# Lane brief\nSource: owner topic \`topic:$U1\`.\n"
printf 'SPL-5\n' >"$T/spool/c-501/lifetime/issue"
brief c-502 "# Lane brief\nIssue: SPL-6\n"
brief c-503 "# Lane brief\nReport on --task dispatch-r42.\n"
brief c-001 "# Brief: orchestrator\nIssue: SPL-1\n"
brief c-504 "# Lane brief\ntopic:$U1\nIssue: SPL-7\n"
brief c-507 "# Lane brief\ntopic:$U1\nIssue: SPL-8\n"

run() {
  env PROJ_PATH="$PROJ_ROOT" SPOOL_ROOT="$T/spool" LANE_FLEET=main LANE_BOX=sat SPOOL_DESK_BOX=sat \
    LANE_HUB_CMD="$T/bin/hub" HUB_DIR="$T/hub" LANE_HUB_BACKOFF=0 \
    LANE_BACKFILL_LIVE_IDS="c-501 c-502 c-503 c-001 c-504 c-505 c-506" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-lane-backfill-links.func.sh"
    do_spl_lane_backfill_links'
}
field() { jq -r --arg a "$1" --arg k "$2" '.lanes[] | select(.agent_id == $a and .agent_box == "sat") | .[$k] | if type == "array" then join(",") else . end' "$T/hub/main.json"; }

# 1. dry run
out="$(run)"; rc=$?
if [[ $rc -eq 0 && "$out" == *"BEFORE c-501@sat topic=- issue=-"* && "$out" == *"AFTER  c-501@sat topic=$U1 issue=SPL-5"* &&
      "$out" == *"AFTER  c-502@sat topic=$U2 issue=SPL-6"* && "$out" == *"AFTER  c-503@sat topic=- issue=-"* ]]; then
  pass "dry run: each row before and after, from lifetime/issue, the brief's topic and Issue: line"
else fail "dry run (rc=$rc): $out"; fi
[[ "$out" == *"3 live lane row(s) lacked a topic or an issue; 2 can be filled"*"missing after: 1 (was 3)"* ]] &&
  pass "dry run: the counts" || fail "dry run counts: $out"
bad=""; for id in c-001 c-504 c-505 c-506 c-507; do [[ "$out" == *"$id@"* ]] && bad+=" $id"; done
[[ -z "$bad" ]] && pass "a role seat, another box's row, a complete row, a done row and a row with no pane are left out" || fail "rows looked at:$bad"
[[ ! -e "$T/hub/writes" ]] && pass "dry run writes nothing" || fail "dry run wrote: $(cat "$T/hub/writes")"

# 2. DRY_RUN=0
out="$(run DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$(sort "$T/hub/writes" | paste -sd,)" == "c-501,c-502" ]] && pass "DRY_RUN=0 writes the two filled rows only" ||
  fail "writes (rc=$rc): $(cat "$T/hub/writes" 2>/dev/null) $out"
[[ "$(field c-501 topic)|$(field c-501 issue_key)|$(field c-502 issue_key)" == "$U1|SPL-5|SPL-6" ]] &&
  pass "the hub rows carry the filled topic and issue" || fail "filled: $(cat "$T/hub/main.json")"
[[ "$(field c-501 scope)|$(field c-501 branch)|$(field c-501 repo)|$(field c-501 files)|$(field c-502 topic)" == "scope c-501|c-501-b|csi-spl|a/c-501,b|$U2" ]] &&
  pass "every other field of the row is kept" || fail "kept fields: $(cat "$T/hub/main.json")"
[[ "$(field c-503 topic)|$(field c-503 issue_key)" == "|" ]] && pass "a brief that names nothing leaves the row as it was" || fail "c-503: $(field c-503 topic)"

# 3. a second run
out="$(run)"
[[ "$out" == *"1 live lane row(s) lacked a topic or an issue; 0 can be filled"* ]] && pass "a second run finds only the lane that names nothing" ||
  fail "second run: $out"

echo
if [ "$fails" -eq 0 ]; then echo "lane-backfill-links: all passed"; exit 0; fi
echo "lane-backfill-links: $fails FAILED"; exit 1
