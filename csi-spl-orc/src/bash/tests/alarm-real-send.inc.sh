#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Shared by the alarm-kind tests (SPL-4869, RCA 8c64225e A1.3): a sandbox
# spool root where the REAL spool-send.sh delivers locally, so a test reads
# the kind of the message that landed and the ask it journaled (or not).
#   alarm_sandbox DIR   DIR/spool with c-001 (the orchestrator, lease.conf),
#                       c-002 and c-009; DIR/bin/send = spool-send.sh on it
#   alarm_kinds DIR ID  the kinds in ID's inbox, oldest first, one per line
#   alarm_asks DIR      "<n> <kinds>": the asks journaled under asks/
#   alarm_reset DIR     empties every inbox, outbox and the asks journal
# The spool binary is a stub that writes the v:1 object into <to>/inbox, as
# the real one does for a local delivery. Not a test itself (*.tst.sh only).
#------------------------------------------------------------------------------
alarm_sandbox() {
  local d="$1" scripts="$PROJ_ROOT/src/bash/features/spawn-agents/scripts" a
  mkdir -p "$d/bin" "$d/spool/dispatch"
  for a in c-001 c-002 c-009; do mkdir -p "$d/spool/$a/inbox" "$d/spool/$a/outbox"; done
  printf 'LEASE_ORCH=c-001\nLEASE_FLEET=main\n' >"$d/spool/dispatch/lease.conf"
  cat >"$d/bin/spool" <<'STUB'
#!/usr/bin/env bash
[ "$1" = send ] || { echo "stub spool: only send" >&2; exit 1; }
shift; from="" to="" kind="" body="" task=""
while [ $# -gt 0 ]; do case "$1" in
  --from) from="$2";; --to) to="$2";; --kind) kind="$2";; --body) body="$2";; --task) task="$2";; esac; shift 2; done
id="$(python3 -c 'import uuid; print(uuid.uuid4())')"; task="${task:-$id}"
ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
mkdir -p "$SPOOL_ROOT/$to/inbox" "$SPOOL_ROOT/$from/outbox"
jq -n -c --arg id "$id" --arg t "$task" --arg ts "$ts" --arg f "$from" --arg to "$to" --arg k "$kind" --arg b "$body" \
  '{v:1, msg_id:$id, task_id:$t, ts:$ts, from:$f, to:$to, kind:$k, body:$b, files:[]}' \
  >"$SPOOL_ROOT/$to/inbox/$(date -u +%Y%m%dT%H%M%S%NZ)--$from--${id:0:8}.json"
printf '{"delivery":"local","msg_id":"%s","task_id":"%s","ts":"%s"}\n' "$id" "$task" "$ts"
STUB
  chmod +x "$d/bin/spool"
  cat >"$d/bin/send" <<STUB
#!/usr/bin/env bash
exec env SPOOL_TEST=1 SPOOL_ROOT="$d/spool" SPOOL_BOX_ENV="$d/spool/box.env" SPOOL_DESK_BOX=box-a \\
  SPOOL_BIN="$d/bin/spool" SPOOL_ORCHESTRATOR_ID=c-001 SPOOL_TMUX_SOCKET="$d/tmux.sock" SPOOL_FLEET_RELAY=0 \\
  SPOOL_ASKS_SYNC_CMD=true SPOOL_AGENT_ID= bash "$scripts/spool-send.sh" --no-poke "\$@"
STUB
  chmod +x "$d/bin/send"
}

alarm_kinds() {
  local f
  for f in "$1/spool/$2/inbox"/*.json; do [ -e "$f" ] && jq -r .kind "$f"; done
  return 0
}

alarm_asks() {
  local n=0 k="" f
  for f in "$1/spool/asks"/*.json; do
    [ -e "$f" ] || continue
    n=$((n + 1)); k="${k:+$k,}$(jq -r .kind "$f")"
  done
  echo "$n ${k:--}"
}

alarm_reset() {
  rm -rf "$1/spool/asks"
  find "$1/spool" \( -path '*/inbox/*' -o -path '*/outbox/*' \) -type f -delete 2>/dev/null || true
}
