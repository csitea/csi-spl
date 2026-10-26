#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-3524 (fix D of grok-dispatch-grade-2026-10-25.md section 5,
#          how-to-post.md rule 19) - do_spl_desk_reply refuses a post that
#          says a lane is placed unless the fleet lane map shows that lane
#          live. The grade lost points on lanes said placed and then never
#          placed. The lane map is stubbed (SPL_DESK_LANE_MAP_CMD).
#   1. RED CONTROL: "placed c-777" with no live row for c-777 is refused,
#      the FATAL names c-777, nothing reaches the spool
#   2. the same post with c-777 live is sent unchanged
#   3. c-777@box-b: a live row on box-a is not that lane (refused); on box-b, sent
#   4. a done row is not live (refused)
#   5. a placed line naming no lane is refused, naming the line
#   6. a role seat on the line is not the lane ("c-001 placed it")
#   7. two lanes, one missing: refused naming only the missing one
#   8. the hub did not answer (hub: unreachable), or the map failed: refused
#   9. not placed / never placed / a > quote / a ``` fence / "replaced":
#      sent without reading the map
#  10. a fleet-sized map (over 128 KB, one argv word's limit) is read
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"

fails=0

orc_stub 1 gcloud curl docker cloud-sql-proxy spool tmux
TOPIC=99ffa592-0000-4000-8000-000000000001

mkdir -p "$T/state/dev/desk/t1/box-desk/spool/CLE-00"
STUBS='do_spl_desk_cnf() { SPL_HUB_URL=https://hub.invalid; }
spl_host_spool() { :; }
spl_desk_spool() {
  while [[ $# -gt 0 && "$1" != -- ]]; do shift; done; shift
  local a prev=""; for a in "$@"; do [[ "$prev" == --body ]] && printf "%s" "$a" >"$SENT_BODY"; prev="$a"; done
  echo "{\"msg_id\":\"m1\"}"
}'

# map <hub> <id:box:state>...: the stubbed lane map JSON in $T/map.json
map() {
  local hub="$1" r rows="" sep=""; shift
  for r in "$@"; do
    IFS=: read -r a b s <<<"$r"
    rows+="$sep{\"agent_id\":\"$a\",\"agent_box\":\"$b\",\"state\":\"$s\"}"; sep=,
  done
  printf '{"fleet":"main","hub":"%s","lanes":[%s]}\n' "$hub" "$rows" >"$T/map.json"
}
# send <body> [VAR=value]... -> rc; output in $T/o, the sent body in $T/sent
send() {
  local body="$1"; shift
  rm -f "$T/sent" "$T/map.read"
  SNIPPET="$STUBS"$'\n'do_spl_desk_reply in_orc TENANT_ID=t1 DESK_BOX=box-desk DESK_AGENT=CLE-00 DESK_TO=HUM-10 \
    DESK_TASK="$TOPIC" DESK_BODY="$body" DRY_RUN=0 SENT_BODY="$T/sent" \
    SPL_DESK_LANE_MAP_CMD="touch '$T/map.read'; cat '$T/map.json'" "$@" >"$T/o" 2>&1
}
refused() { # <label> <must-name>...: rc != 0, nothing sent, the FATAL names each piece
  local label="$1" n ok=1; shift
  (( rc != 0 )) && [[ ! -e "$T/sent" ]] && grep -q 'FATAL nothing was sent' "$T/o" && grep -q 'how-to-post.md rule 19' "$T/o" || ok=0
  for n in "$@"; do grep -qF -- "$n" "$T/o" || ok=0; done
  (( ok )) && pass "$label" || fail "$label (rc $rc): $(cat "$T/o")"
}
sent() { # <label> <body>: rc 0 and the body reached the spool byte for byte
  (( rc == 0 )) && [[ -f "$T/sent" && "$(cat "$T/sent")" == "$2" ]] && ! grep -q FATAL "$T/o" &&
    pass "$1" || fail "$1 (rc $rc, sent '$(cat "$T/sent" 2>/dev/null)'): $(cat "$T/o")"
}

# --- 1. RED CONTROL ---------------------------------------------------------------
map ok c-123:box-a:live
B="Fix D: placed c-777 on box-a (SPL-3524)."
send "$B"; rc=$?
refused "1. a placed lane with no live row is refused, nothing sent" 'FATAL placed lane c-777 is not live'

# --- 2. live -> sent ----------------------------------------------------------------
map ok c-123:box-a:live c-777:box-a:live
send "$B"; rc=$?
sent "2. the same post with c-777 live is sent unchanged" "$B"
[[ -e "$T/map.read" ]] && pass "2. the lane map was read" || fail "2. the lane map was not read"

# --- 3. box -------------------------------------------------------------------------
B3="**Placed** c-777@box-b for fix D."
send "$B3"; rc=$?
refused "3. c-777@box-b with only a box-a row is refused" 'FATAL placed lane c-777@box-b is not live'
map ok c-777:box-b:live
send "$B3"; rc=$?
sent "3. c-777@box-b live on box-b is sent" "$B3"

# --- 4. done ------------------------------------------------------------------------
map ok c-777:box-a:done
send "$B"; rc=$?
refused "4. a done row is not live" 'FATAL placed lane c-777 is not live'

# --- 5. no lane named ----------------------------------------------------------------
map ok c-777:box-a:live
send $'Status:\nFix D placed, the lane starts soon.'; rc=$?
refused "5. a placed line naming no lane is refused" "names no lane on that line: 'Fix D placed, the lane starts soon.'"

# --- 6. role seat ---------------------------------------------------------------------
send "c-001 placed it for fix D."; rc=$?
refused "6. a role seat is not the placed lane" 'names no lane on that line'
send "c-001@box-b placed c-777 for fix D."; rc=$?
sent "6. a role seat next to a live lane is sent" "c-001@box-b placed c-777 for fix D."

# --- 7. two lanes ------------------------------------------------------------------------
send "Placed c-777 and c-778."; rc=$?
refused "7. two lanes, one missing: refused" 'FATAL placed lane c-778 is not live'
grep -q 'lane c-777 is not live' "$T/o" && fail "7. the live c-777 was named missing" || pass "7. only the missing lane is named"

# --- 8. hub down / map fails ---------------------------------------------------------------
map unreachable c-777:box-a:live
send "$B"; rc=$?
refused "8. hub unreachable: refused (other machines unread)" "hub 'unreachable'"
send "$B" SPL_DESK_LANE_MAP_CMD="exit 1"; rc=$?
refused "8. the lane map failed: refused" 'the lane map is no JSON'

# --- 9. no placement claim -------------------------------------------------------------------
map unreachable
for B9 in "Fix D is not placed yet: queued as an ask." "c-777 was never placed." "It isn't yet placed." \
  $'> placed c-999\nQuoted above, from the old post.' $'```text\nplaced c-999\n```' "The hook replaced c-999's check." "No lane news."; do
  send "$B9"; rc=$?
  sent "9. sent without a placement claim: ${B9%%$'\n'*}" "$B9"
  [[ -e "$T/map.read" ]] && fail "9. the lane map was read for: $B9" || :
done

# --- 10. a big map ------------------------------------------------------------------------
rows=(); for i in $(seq 100 999); do rows+=("m-$i:box-with-a-long-name-$i:done"); done
map ok "${rows[@]}" "${rows[@]}" "${rows[@]}" c-777:box-a:live
(( $(wc -c <"$T/map.json") > 131072 )) || fail "10. the map is not over 128 KB"
send "$B"; rc=$?
sent "10. a map over 128 KB is read, the live lane found" "$B"

echo "desk-placed-check: $fails failure(s)"
((fails == 0))
