#!/usr/bin/env bash
# spec 058 section 7 (SPL-6513, latency action 3): a same-box send leaves
# exactly one inbox file and one poke, and starts ONE detached record-only
# forward of the same msg_id; a slow or dead hub leg never slows the send.
# The hub half (stored once, delivered to no box, replay records nothing,
# queued while the hub is down) is internal/hub/record_only_test.go.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
. "$(dirname "${BASH_SOURCE[0]}")/../../../tests/wait-event.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
FWD="$T_SCRIPTS/spool-record-forward.sh"
RELAY="$T_SCRIPTS/spool-fleet-relay.sh"

t_tmux
P92="$(t_window c-092 'sleep 600')"
printf 'c-092\tclaude\t%s\t/x\t20260101T000000Z\n' "$P92" >> "$SPOOL_ROOT/registry.tsv"
mkdir -p "$SPOOL_ROOT/c-091/inbox" "$SPOOL_ROOT/c-092/inbox"

# The record stub logs its argv as one line per call.
REC="$T_TMP/records.log"
cat >"$T_TMP/rec-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$REC"
EOF
chmod +x "$T_TMP/rec-stub"

# ---- n = 20 same-box sends ------------------------------------------------
N=20 ids=() ms=()
for i in $(seq 1 "$N"); do
  t0=$(date +%s%3N)
  out="$(SPOOL_RECORD_CMD="$T_TMP/rec-stub" bash "$SS" --from c-091 --to c-092 --kind note --body "same box $i" 2>/dev/null)"; rc=$?
  ms+=($(( $(date +%s%3N) - t0 )))
  [ "$rc" = 0 ] || nok "send $i exit $rc"
  ids+=("$(printf '%s' "$out" | sed -n 's/.*"msg_id" *: *"\([^"]*\)".*/\1/p')")
done
recs() { [ "$(wc -l <"$REC" 2>/dev/null || echo 0)" -ge "$N" ]; }
wait_event 10 recs
eq "one inbox file per send (n=$N)" "$N" "$(find "$SPOOL_ROOT/c-092/inbox" -name '*.json' | wc -l)"
eq "one poke per send (input.log lines)" "$N" "$(grep -c ' note$' "$SPOOL_ROOT/c-092/lifetime/input.log")"
eq "one record forward per send" "$N" "$(wc -l <"$REC")"
miss=0
for id in "${ids[@]}"; do
  grep -q -- "--msg-id $id " "$REC" || miss=$((miss + 1))
done
eq "every forward carries its send's msg_id" 0 "$miss"
has "the forward names from, to and kind" "--from c-091 --to c-092 --kind note" "$(sed -n 1p "$REC")"
p95="$(printf '%s\n' "${ms[@]}" | sort -n | sed -n "$(( (N * 95 + 99) / 100 ))p")"
echo "info - same-box send wall time with the record leg: n=$N p95=${p95} ms"

# ---- a probe line is not recorded ------------------------------------------
: >"$REC"
SPOOL_RECORD_CMD="$T_TMP/rec-stub" bash "$SS" --from c-091 --to c-092 --kind note --body '[spool-probe] attach L1 lobby zz87' >/dev/null 2>&1
SPOOL_RECORD_CMD="$T_TMP/rec-stub" bash "$SS" --from c-091 --to c-092 --kind note --body 'after the probe' >/dev/null 2>&1
wait_event 10 grep -q 'after the probe' "$REC"
hasnt "a probe line starts no record forward" "zz87" "$(cat "$REC")"

# ---- the hub leg never slows or fails the local send -----------------------
cat >"$T_TMP/rec-slow" <<EOF
#!/usr/bin/env bash
sleep 8
printf 'late\n' >>"$T_TMP/slow.log"
exit 1
EOF
chmod +x "$T_TMP/rec-slow"
t0=$(date +%s%3N)
SPOOL_RECORD_CMD="$T_TMP/rec-slow" bash "$SS" --from c-091 --to c-092 --kind note --body 'hub down' >/dev/null 2>&1; rc=$?
el=$(( $(date +%s%3N) - t0 ))
eq "a dead hub leg: the send still exits 0" 0 "$rc"
check "…and returns before the 8 s hub leg ends (${el} ms)" test "$el" -lt 6000
check "…and the message is in the inbox" grep -lqF 'hub down' "$SPOOL_ROOT/c-092/inbox/"*.json

# ---- the forwarder hands the relay --record-of ------------------------------
RL="$T_TMP/relay.log"
cat >"$T_TMP/relay-stub" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$RL"
echo '{"delivery":"recorded","msg_id":"x"}'
EOF
chmod +x "$T_TMP/relay-stub"
MID=0b6a3c1e-1111-4222-8333-444455556666
SPOOL_FLEET_RELAY_CMD="$T_TMP/relay-stub" bash "$FWD" --from c-091 --to c-092 --kind note --msg-id "$MID" --task dispatch-x --body hi; rc=$?
eq "forwarder: exit 0 when the relay took it" 0 "$rc"
has "forwarder: the relay gets --record-of <msg_id>" "--record-of $MID" "$(cat "$RL")"
has "forwarder: … and the task" "--task dispatch-x" "$(cat "$RL")"
has "forwarder: one log line with the delivery" "$MID rc=0" "$(cat "$SPOOL_ROOT/.record/forward.log")"
has "forwarder: … recorded" "recorded" "$(tail -1 "$SPOOL_ROOT/.record/forward.log")"
SPOOL_FLEET_RELAY=0 bash "$FWD" --from c-091 --to c-092 --kind note --msg-id "$MID" --body hi; rc=$?
eq "forwarder: no fleet desk -> exit 3" 3 "$rc"
has "forwarder: … logged, not recorded" "no fleet desk" "$(tail -1 "$SPOOL_ROOT/.record/forward.log")"
bash "$FWD" --from c-091 --to c-092 --kind note --msg-id not-a-uuid --body hi 2>/dev/null; eq "forwarder: a bad msg_id is usage, exit 2" 2 "$?"

# ---- the relay's --record-of guards ----------------------------------------
bash "$RELAY" --from c-091 --to c-092 --kind note --body x --record-of nope 2>/dev/null; eq "relay: a bad --record-of is exit 2" 2 "$?"
bash "$RELAY" --from c-091 --to c-092 --kind note --body x --record-of "$MID" --to-box box-b 2>/dev/null; eq "relay: --record-of with --to-box is exit 2" 2 "$?"
bash "$RELAY" --from c-091 --to c-092 --kind note --body x --record-of "$MID" --to-this-box 2>/dev/null; eq "relay: --record-of with --to-this-box is exit 2" 2 "$?"

t_done
