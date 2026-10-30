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

t_done
