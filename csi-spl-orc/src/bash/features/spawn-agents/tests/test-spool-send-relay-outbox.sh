#!/usr/bin/env bash
# SPL-4430: a cross-box send (relayed through the hub) leaves ONE copy in the
# sender's outbox, with the msg_id and task_id the relay returned, so every
# reader that takes the outbox as "sent" (GC, done-claim) sees the post. A
# failed relay writes nothing and keeps its exit code; a failed copy only warns.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
t_spool_bin || { nok "cannot build spool"; t_done; exit 1; }
SS="$T_SCRIPTS/spool-send.sh"
MID="5b6c7d8e-9f0a-4b1c-8d2e-3f4a5b6c7d8e"
TID="6c7d8e9f-0a1b-4c2d-9e3f-4a5b6c7d8e9f"
REPLY="{\"delivery\":\"sent\",\"msg_id\":\"${MID}\",\"task_id\":\"${TID}\",\"ts\":\"2026-10-30T12:00:00Z\"}"
cat >"$T_TMP/hub-ok" <<SH
#!/usr/bin/env bash
echo '${REPLY}'
SH
cat >"$T_TMP/hub-fail" <<'SH'
#!/usr/bin/env bash
echo "relay: send via box failed" >&2; exit 1
SH
chmod +x "$T_TMP/hub-ok" "$T_TMP/hub-fail"
mkdir -p "$SPOOL_ROOT/CLE-70/inbox"
OB="$SPOOL_ROOT/CLE-70/outbox"
n_out() { find "$OB" -maxdepth 1 -name '*.json' 2>/dev/null | wc -l; }

# ---- 1. relay ok, the box named: one copy, the relay's ids ------------------
out="$(SPOOL_FLEET_RELAY_CMD="$T_TMP/hub-ok" bash "$SS" --from CLE-70 --to c-500@box-far \
  --kind result --body 'done on the far box' 2>"$T_TMP/err")"; rc=$?
eq "1. relayed send: exit 0" 0 "$rc"
eq "1. stdout still prints the relay's delivery JSON unchanged" "$REPLY" "$(printf '%s\n' "$out" | sed -n 1p)"
eq "1. exactly one outbox file" 1 "$(n_out)"
f="$(find "$OB" -maxdepth 1 -name '*.json' 2>/dev/null | sed -n 1p)"
eq "1. its msg_id is the relay's" "$MID" "$(jq -r .msg_id "${f:-/dev/null}" 2>/dev/null)"
eq "1. its task_id is the relay's" "$TID" "$(jq -r .task_id "${f:-/dev/null}" 2>/dev/null)"
eq "1. to is the peer with its box" "c-500@box-far" "$(jq -r .to "${f:-/dev/null}" 2>/dev/null)"
eq "1. from, kind and body are the send's" "CLE-70|result|done on the far box" \
  "$(jq -r '[.from, .kind, .body] | join("|")' "${f:-/dev/null}" 2>/dev/null)"
eq "1. a v:1 object" 1 "$(jq -r .v "${f:-/dev/null}" 2>/dev/null)"
has "1. the file name marks it relayed" "--CLE-70--relayed-" "${f##*/}"
check "1. no temp file is left" test -z "$(find "$OB" -name '.*' 2>/dev/null)"
# The marker is in the name, not a key: msg.Parse refuses an unknown key, and
# `spool tail` would then drop the copy without a word.
eq "1. spool tail reads the copy (the object parses strictly)" 1 \
  "$(SPOOL_ROOT="$SPOOL_ROOT" "$SPOOL_BIN" tail --task "$TID" 2>/dev/null | grep -c "CLE-70 -> c-500@box-far .*done on the far box")"

# ---- 2. relay ok, a bare id the hub placed: to is the bare id ----------------
sed "s/${MID}/7d8e9f0a-1b2c-4d3e-8f4a-5b6c7d8e9f0a/" "$T_TMP/hub-ok" >"$T_TMP/hub-ok2"; chmod +x "$T_TMP/hub-ok2"
SPOOL_FLEET_RELAY_CMD="$T_TMP/hub-ok2" bash "$SS" --from CLE-70 --to c-501 \
  --kind note --body 'bare id' >/dev/null 2>&1; rc=$?
eq "2. bare id relayed: exit 0" 0 "$rc"
eq "2. one more outbox file" 2 "$(n_out)"
eq "2. to is the bare id (the hub chose the box)" "c-501" \
  "$(cat "$OB"/*.json 2>/dev/null | jq -r 'select(.body == "bare id") | .to' 2>/dev/null)"

# ---- 3. relay fails: nothing written, exit as before ---------------------------
rm -f "$OB"/*.json
SPOOL_FLEET_RELAY_CMD="$T_TMP/hub-fail" bash "$SS" --from CLE-70 --to c-500@box-far \
  --kind note --body 'never arrives' >/dev/null 2>&1; rc=$?
eq "3. failed relay: exit 11 (10 + the relay's 1)" 11 "$rc"
eq "3. failed relay: no outbox file" 0 "$(n_out)"

# ---- 4. the copy fails: the send still succeeds, one WARN ---------------------
rm -rf "$OB"; : >"$OB"
err="$(SPOOL_FLEET_RELAY_CMD="$T_TMP/hub-ok" bash "$SS" --from CLE-70 --to c-500@box-far \
  --kind note --body 'copy fails' 2>&1 >/dev/null)"; rc=$?
eq "4. an unwritable outbox never fails the send: exit 0" 0 "$rc"
has "4. ... it WARNs on stderr" "outbox: WARN" "$err"
rm -f "$OB"

# ---- 5. the peers hub leg (RELAY=1, spec 068 L4): one copy, to peers -------
# N3 of the SPL-4430 review: the hub leg of a peers send left no sender copy;
# only the hub-down leg (send_peers_local) wrote one.
rm -rf "$OB"; mkdir -p "$OB"
PMID="8e9f0a1b-2c3d-4e4f-9a5b-6c7d8e9f0a1b"; PTID="9f0a1b2c-3d4e-4f5a-8b6c-7d8e9f0a1b2c"
cat >"$T_TMP/hub-peers" <<SH
#!/usr/bin/env bash
echo '{"delivery":"sent","msg_id":"${PMID}","task_id":"${PTID}","ts":"2026-11-01T08:00:00Z"}'
SH
chmod +x "$T_TMP/hub-peers"
SPOOL_TO_PEERS=1 SPOOL_FLEET_RELAY_CMD="$T_TMP/hub-peers" bash "$SS" --from CLE-70 --to peers \
  --kind result --body 'report to the peers' >/dev/null 2>&1; rc=$?
eq "5. peers hub leg: exit 0" 0 "$rc"
eq "5. peers hub leg: exactly one outbox file" 1 "$(n_out)"
f="$(find "$OB" -maxdepth 1 -name '*--relayed-*.json' 2>/dev/null | sed -n 1p)"
eq "5. peers hub leg: the copy holds the relay's ids, to peers" "${PMID}|${PTID}|peers" \
  "$(jq -r '[.msg_id, .task_id, .to] | join("|")' "${f:-/dev/null}" 2>/dev/null)"
eq "5. peers hub leg: no local peers inbox file (the hub holds it)" 0 \
  "$(find "$SPOOL_ROOT/peers/inbox" -name '*.json' 2>/dev/null | wc -l)"
eq "5. peers hub leg: the copy is never read as inbound" "[]" \
  "$(SPOOL_ROOT="$SPOOL_ROOT" "$SPOOL_BIN" recv --as CLE-70 2>/dev/null | jq -c . 2>/dev/null)"
eq "5. peers hub leg: spool tail shows it once" 1 \
  "$(SPOOL_ROOT="$SPOOL_ROOT" "$SPOOL_BIN" tail --task "$PTID" 2>/dev/null | grep -c "report to the peers")"
SPOOL_TO_PEERS=1 SPOOL_FLEET_RELAY_CMD="$T_TMP/hub-fail" bash "$SS" --from CLE-70 --to peers \
  --kind note --body 'hub down' >/dev/null 2>&1
eq "5. control: the hub-down leg still leaves its one local copy, no relayed one" "1 0" \
  "$(grep -l 'hub down' "$OB"/*.json 2>/dev/null | wc -l) $(grep -l 'hub down' "$OB"/*--relayed-*.json 2>/dev/null | wc -l)"
rm -rf "$SPOOL_ROOT/peers"

# ---- 6. the accept-via-hub leg (RELAY=2, spec 130 L3): one copy ------------
# A same-machine acceptance goes through the hub to this machine's desk box;
# the hub delivers it, nothing local was written for the sender.
rm -rf "$OB"; mkdir -p "$OB" "$SPOOL_ROOT/CLE-71/inbox"
RES="0e1f2a3b-4c5d-4e6f-8a7b-9c0d1e2f3a4b"
AMID="a1b2c3d4-e5f6-4a7b-8c9d-0e1f2a3b4c5d"; ATID="b2c3d4e5-f6a7-4b8c-9d0e-1f2a3b4c5d6e"
cat >"$T_TMP/hub-accept" <<SH
#!/usr/bin/env bash
echo '{"delivery":"sent","msg_id":"${AMID}","task_id":"${ATID}","ts":"2026-11-01T08:01:00Z"}'
SH
chmod +x "$T_TMP/hub-accept"
SPOOL_FLEET_RELAY_CMD="$T_TMP/hub-accept" bash "$SS" --from CLE-70 --to CLE-71 --kind result \
  --accept "$RES" --body 'ACCEPTED' --no-poke >/dev/null 2>&1; rc=$?
eq "6. accept via hub: exit 0" 0 "$rc"
eq "6. accept via hub: exactly one outbox file" 1 "$(n_out)"
f="$(find "$OB" -maxdepth 1 -name '*--relayed-*.json' 2>/dev/null | sed -n 1p)"
eq "6. accept via hub: the copy holds the relay's ids, the bare id, accepts" "${AMID}|${ATID}|CLE-71|${RES}" \
  "$(jq -r '[.msg_id, .task_id, .to, .accepts] | join("|")' "${f:-/dev/null}" 2>/dev/null)"
eq "6. accept via hub: no local inbox copy (the hub delivers)" 0 \
  "$(find "$SPOOL_ROOT/CLE-71/inbox" -name '*.json' | wc -l)"
eq "6. accept via hub: the copy is never read as inbound" "[]" \
  "$(SPOOL_ROOT="$SPOOL_ROOT" "$SPOOL_BIN" recv --as CLE-70 2>/dev/null | jq -c . 2>/dev/null)"
eq "6. accept via hub: spool tail shows it once" 1 \
  "$(SPOOL_ROOT="$SPOOL_ROOT" "$SPOOL_BIN" tail --task "$ATID" 2>/dev/null | grep -c "CLE-70 -> CLE-71")"
SPOOL_FLEET_RELAY_CMD="$T_TMP/hub-fail" bash "$SS" --from CLE-70 --to CLE-71 --kind result \
  --accept "$RES" --body 'ACCEPTED, hub down' --no-poke >/dev/null 2>&1
eq "6. control: a failed hub leg delivers locally, one outbox file, no relayed copy" "1 0" \
  "$(grep -l 'hub down' "$OB"/*.json 2>/dev/null | wc -l) $(grep -l 'hub down' "$OB"/*--relayed-*.json 2>/dev/null | wc -l)"

# ---- 7. a local send leaves exactly one outbox file --------------------------
rm -rf "$OB"; mkdir -p "$OB"
bash "$SS" --from CLE-70 --to CLE-71 --kind note --body 'local only' --no-poke >/dev/null 2>&1; rc=$?
eq "7. local send: exit 0" 0 "$rc"
eq "7. local send: exactly one outbox file, none relayed" "1 0" \
  "$(n_out) $(find "$OB" -maxdepth 1 -name '*--relayed-*.json' | wc -l)"

# ---- 8. N2: a relay reply whose msg_id is no uuid names no file -------------
rm -rf "$OB"; mkdir -p "$OB"
cat >"$T_TMP/hub-badid" <<'SH'
#!/usr/bin/env bash
echo '{"delivery":"sent","msg_id":"not-a-uuid-at-all","task_id":"6c7d8e9f-0a1b-4c2d-9e3f-4a5b6c7d8e9f","ts":"2026-11-01T08:02:00Z"}'
SH
chmod +x "$T_TMP/hub-badid"
err="$(SPOOL_FLEET_RELAY_CMD="$T_TMP/hub-badid" bash "$SS" --from CLE-70 --to c-500@box-far \
  --kind note --body 'bad id' 2>&1 >/dev/null)"; rc=$?
eq "8. a bad relay msg_id: the send still exits 0" 0 "$rc"
eq "8. ... writes no outbox file" 0 "$(n_out)"
has "8. ... and WARNs" "outbox: WARN" "$err"

t_done
