#!/usr/bin/env bash
# SPL-6270: `--to <ID>@<box>` is refused (exit 8, nothing written) when the
# fleet lane map has <ID> live on another box and NOT on <box>; a GO sent
# `--to c-346@<box2>` while c-346 was live on <box1> never arrived (2026-11-22).
# Everything else sends as before: an id live on <box>, a role seat, a bare
# id, an id the map does not know, a done row elsewhere; a map that cannot be
# read WARNs once and sends. A FAKE lane map and a stub relay: no hub.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
# shellcheck source=../../../tests/wait-event.inc.sh
. "$T_FEAT/../../tests/wait-event.inc.sh"
t_sandbox
SS="$T_SCRIPTS/spool-send.sh"
export SPOOL_DESK_BOX=box-a
mkdir -p "$SPOOL_ROOT/c-370/inbox" "$SPOOL_ROOT/dispatch"
OB="$SPOOL_ROOT/c-370/outbox"
cat >"$T_TMP/map.json" <<'EOF'
{"hub":"ok","lanes":[
 {"agent_id":"c-346","agent_box":"box-a","state":"live"},
 {"agent_id":"c-500","agent_box":"box-far","state":"live"},
 {"agent_id":"c-501","agent_box":"box-far","state":"done"},
 {"agent_id":"c-001","agent_box":"box-a","state":"live"}]}
EOF
cat >"$T_TMP/map" <<SH
#!/usr/bin/env bash
echo x >>"$T_TMP/map.calls"; cat "$T_TMP/map.json"
SH
cat >"$T_TMP/map-fail" <<SH
#!/usr/bin/env bash
echo x >>"$T_TMP/map.calls"; echo "hub down" >&2; exit 1
SH
cat >"$T_TMP/map-local" <<SH
#!/usr/bin/env bash
echo x >>"$T_TMP/map.calls"; echo '{"hub":"unreachable","lanes":[{"agent_id":"c-500","agent_box":"box-far","state":"live"}]}'
SH
cat >"$T_TMP/relay" <<SH
#!/usr/bin/env bash
echo "\$*" >>"$T_TMP/relay.calls"
echo '{"delivery":"sent","msg_id":"5b6c7d8e-9f0a-4b1c-8d2e-3f4a5b6c7d8e","task_id":"6c7d8e9f-0a1b-4c2d-9e3f-4a5b6c7d8e9f","ts":"2026-11-22T19:00:00Z"}'
SH
chmod +x "$T_TMP/map" "$T_TMP/map-fail" "$T_TMP/map-local" "$T_TMP/relay"
export SPOOL_FLEET_RELAY_CMD="$T_TMP/relay" SPOOL_LANE_MAP_CMD="$T_TMP/map" SPOOL_LANE_MAP_TTL=0
n_out() { find "$OB" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l; }
n_relay() { grep -c . "$T_TMP/relay.calls" 2>/dev/null || echo 0; }
n_map() { grep -c . "$T_TMP/map.calls" 2>/dev/null || echo 0; }
reset() { rm -f "$T_TMP/relay.calls" "$T_TMP/map.calls" "$SPOOL_ROOT/dispatch/lane-map-send.cache.json"; rm -rf "$OB"; }
send() {  # TO -> rc; stderr in $T_TMP/err
  bash "$SS" --from c-370 --to "$1" --kind note --body "go $1" --no-poke >/dev/null 2>"$T_TMP/err"
}

# ---- 1. the defect: live on THIS box, sent @another box -> refused ---------
reset; send c-346@box-b; rc=$?
err="$(cat "$T_TMP/err")"
eq "1. live here, named @box-b: exit 8" 8 "$rc"
has "1. the ERROR names where it is live" "c-346 is live on box-a, not on box-b" "$err"
has "1. ... and the corrected --to (the bare id: this box)" "send it with --to c-346." "$err"
has "1. ... and that nothing was sent" "Nothing was sent." "$err"
eq "1. no relay call" 0 "$(n_relay)"
eq "1. no outbox file" 0 "$(n_out)"

# ---- 2. live on another box, sent @a third box -> refused, names the box --
reset; send c-500@box-near; rc=$?
eq "2. live on box-far, named @box-near: exit 8" 8 "$rc"
has "2. the corrected --to is c-500@box-far" "send it with --to c-500@box-far." "$(cat "$T_TMP/err")"
eq "2. no relay call, no outbox file" "0 0" "$(n_relay) $(n_out)"

# ---- 3. allowed: the id live on the named box -> relayed as today ----------
reset; send c-500@box-far; rc=$?
eq "3. live on box-far, named @box-far: exit 0" 0 "$rc"
has "3. relayed with that to-box" "--to-box box-far" "$(cat "$T_TMP/relay.calls" 2>/dev/null)"
eq "3. one outbox copy, to c-500@box-far" "c-500@box-far" "$(jq -r .to "$OB"/*.json 2>/dev/null)"
hasnt "3. no ERROR, no WARN" "ERROR" "$(cat "$T_TMP/err")"

# ---- 4. allowed: a role seat (001-003 exist on every box) -------------------
reset; send c-001@box-far; rc=$?
eq "4. role seat c-001@box-far (map: live on box-a): exit 0, relayed" "0 1" "$rc $(n_relay)"
eq "4. the map is not read for a role seat" 0 "$(n_map)"
printf 'c-002@box-far 1795000000\n' >"$SPOOL_ROOT/dispatch/lease.orch"
reset; bash "$SS" --from c-370 --to orchestrator --kind note --body 'to orch' --no-poke >/dev/null 2>"$T_TMP/err"; rc=$?
eq "4. --to orchestrator (lease.orch c-002@box-far): exit 0, relayed" "0 1" "$rc $(n_relay)"
rm -f "$SPOOL_ROOT/dispatch/lease.orch"

# ---- 5. allowed: a bare id, never a map read ---------------------------------
reset; send c-500; rc=$?
eq "5. bare c-500: exit 0, relayed (the hub places it)" "0 1" "$rc $(n_relay)"
eq "5. a bare id reads no map" 0 "$(n_map)"
hasnt "5. ... and the relay got no to-box" "--to-box" "$(cat "$T_TMP/relay.calls" 2>/dev/null)"

# ---- 6. allowed: an id the map does not know; a done row elsewhere ----------
reset; send c-777@box-far; rc=$?
eq "6. unknown c-777@box-far: exit 0, relayed" "0 1" "$rc $(n_relay)"
reset; send c-501@box-near; rc=$?
eq "6. c-501 done on box-far, named @box-near: exit 0, relayed" "0 1" "$rc $(n_relay)"

# ---- 7. the map cannot be read: WARN once, send --------------------------
reset; SPOOL_LANE_MAP_CMD="$T_TMP/map-fail" send c-500@box-near; rc=$?
eq "7. map read fails: exit 0, relayed as today" "0 1" "$rc $(n_relay)"
eq "7. exactly one WARN line" 1 "$(grep -c 'WARN cannot read the fleet lane map' "$T_TMP/err")"
reset; SPOOL_LANE_MAP_CMD="$T_TMP/map-local" send c-500@box-near; rc=$?
eq "7. a local-only map (hub unreachable) is not the fleet's: exit 0, relayed" "0 1" "$rc $(n_relay)"
eq "7. ... one WARN" 1 "$(grep -c 'WARN cannot read the fleet lane map' "$T_TMP/err")"
check "7. ... and it is not cached" test ! -e "$SPOOL_ROOT/dispatch/lane-map-send.cache.json"

# ---- 8. the cache: one map read for two sends inside the TTL -----------
reset; SPOOL_LANE_MAP_TTL=120 send c-500@box-far; SPOOL_LANE_MAP_TTL=120 send c-346@box-b; rc=$?
eq "8. two @box sends inside the TTL: one map read" 1 "$(n_map)"
eq "8. the cached map still refuses the wrong box" 8 "$rc"
touch -d '-200 seconds' "$SPOOL_ROOT/dispatch/lane-map-send.cache.json"
SPOOL_LANE_MAP_TTL=120 send c-500@box-far; rc=$?
eq "8. a cache older than the TTL still answers: exit 0" 0 "$rc"
wait_event 10 env_idle "SPOOL_ROOT=$SPOOL_ROOT"
eq "8. ... and is read again, by the detached refresh (SPL-6512)" 2 "$(n_map)"
check "8. ... which made the cache fresh" test "$(( $(date +%s) - $(stat -c %Y "$SPOOL_ROOT/dispatch/lane-map-send.cache.json") ))" -lt 100
touch -d '-200 seconds' "$SPOOL_ROOT/dispatch/lane-map-send.cache.json"
SPOOL_LANE_MAP_TTL=120 send c-346@box-b; rc=$?
eq "8. a refusal from a stale cache is re-read first, then refused: exit 8" 8 "$rc"
eq "8. ... one more map read, on the send path" 3 "$(n_map)"

# ---- 9. SPOOL_SEND_BOX_GUARD=0 turns it off ---------------------------------
reset; SPOOL_SEND_BOX_GUARD=0 send c-346@box-b; rc=$?
eq "9. guard off: the wrong box is relayed as before" "0 1" "$rc $(n_relay)"


# ---- 10. W1: lane-map.sh stdout carries do_log lines around the JSON -------
# (./run without --json echoes INFO/WARN/OK; R7 g-379 msg 3563e4f6 P1, P2)
for lead in "INFO the hub answered on try 2" "WARN the hub read try 1/3: timeout"; do
  cat >"$T_TMP/map-log" <<SH
#!/usr/bin/env bash
echo x >>"$T_TMP/map.calls"; echo "$lead"; cat "$T_TMP/map.json"; echo "OK lane map"
SH
  chmod +x "$T_TMP/map-log"
  reset; SPOOL_LANE_MAP_CMD="$T_TMP/map-log" send c-346@box-b; rc=$?
  eq "10. a '${lead%% *}' line before the map: still refused, exit 8" 8 "$rc"
  eq "10. ... no relay, no outbox, no WARN" "0 0 0" "$(n_relay) $(n_out) $(grep -c WARN "$T_TMP/err")"
done
reset; SPOOL_LANE_MAP_CMD="$T_TMP/map-log" send c-500@box-far; rc=$?
eq "10. a log-wrapped map still allows the right box" "0 1" "$rc $(n_relay)"
eq "10. ... and the cache holds the JSON alone" ok "$(jq -r .hub "$SPOOL_ROOT/dispatch/lane-map-send.cache.json" 2>/dev/null)"

# ---- 11. N1: --to <ID>@<this box> is checked too ---------------------------
reset; send c-500@box-a; rc=$?
eq "11. c-500 live on box-far, named @box-a (this box): exit 8" 8 "$rc"
has "11. ... the corrected --to is c-500@box-far" "send it with --to c-500@box-far." "$(cat "$T_TMP/err")"
eq "11. ... nothing written" "0 0" "$(n_relay) $(n_out)"
reset; send c-346@box-a; rc=$?
eq "11. c-346 live on box-a, named @box-a: exit 0, sent" "0 1" "$rc $(n_out)"
hasnt "11. ... as a this-box send (no to-box)" "--to-box" "$(cat "$T_TMP/relay.calls" 2>/dev/null)"

# ---- 12. N2: a cache whose lanes is not a list is read again ----------------
reset; echo '{"hub":"ok","lanes":{}}' >"$SPOOL_ROOT/dispatch/lane-map-send.cache.json"
SPOOL_LANE_MAP_TTL=120 send c-346@box-b; rc=$?
eq "12. a lanes-not-a-list cache is not used: one map read, exit 8" "1 8" "$(n_map) $rc"

# ---- 13. N3: --to peers reads no map (no <ID>@<box>) ------------------------
reset; SPOOL_TO_PEERS=1 bash "$SS" --from c-370 --to peers --kind note --body 'to peers' --no-poke >/dev/null 2>"$T_TMP/err"; rc=$?
eq "13. --to peers: exit 0, no map read" "0 0" "$rc $(n_map)"

t_done
