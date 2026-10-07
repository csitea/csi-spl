#!/usr/bin/env bash
# spool-asks.inc.sh — the local journal of asks to the orchestrator
# (CLE-77929, owner bug t1 #spool-hub-bugs 2f7996aa; SPEC-spool-fleet-roles.md
# section 4.3). Sourced by spool-send.sh (after spool-env.inc.sh and
# spool-fleet.inc.sh) and by the do_spl_ask* / do_spl_asks_* actions.
#
# The owner's ask: "a state mechanism both in the db and on the file system,
# that you must fire and forget and then the orchestrator (or the next
# orchestrator if the previous one just died) would know to check". The db
# half is the hub's fleet_asks (rdb 0097, `spool ask`); this is the file
# system half, one JSON file per ask under <spool root>/asks/:
#
#   <spool root>/asks/<ask id>.json   the record: ask_id role kind from to topic
#                                     summary deadline_at state acked_by
#                                     closed_by reason raised_n created_at
#                                     updated_at synced (false = the hub has
#                                     not got this version yet)
#   <spool root>/asks/journal.log     one append-only line per event:
#                                     <utc> <op> <ask id> <by> <state>
#
# The ask id is the spool msg_id of the message that carried the ask, so the
# hub row, this file and the inbox file name one thing. Writes are atomic
# (temp file + mv) and group-writable: every agent user and the box user
# write here.
#
#   spool_asks_dir                    the journal dir (made on first use)
#   spool_ask_wanted <to> <kind> <force> <no>
#                                     prints the ask kind when this send is an
#                                     ask (blocker/task to the orchestrator, or
#                                     --ask <kind>); prints nothing otherwise
#   spool_ask_summary <body>          the body's first line, cleaned, <= 200 bytes
#   spool_ask_journal_open <id> <kind> <from> <to> <topic> <summary> [<deadline>]
#                                     record a NEW open ask (an existing id is
#                                     left alone: a replay changes nothing)
#   spool_ask_journal_set <id> <jq object> <op> <by>
#                                     merge fields into an ask, log the event
#   spool_ask_journal_get <id>        print the record (exit 1 when absent)
#   spool_ask_journal_list            every record, one JSON object per line

spool_asks_dir() {
  local d="${SPOOL_ASKS_DIR:-$SPOOL_ROOT/asks}"
  if [ ! -d "$d" ]; then
    ( umask 002; mkdir -p "$d" ) 2>/dev/null || return 1
    chmod 2775 "$d" 2>/dev/null || true
  fi
  printf '%s' "$d"
}

spool_asks_now() { date -u +%Y-%m-%dT%H:%M:%SZ; }

# The orchestrator ids of this machine: the fleet lease holder, the local
# lease.conf LEASE_ORCH and SPOOL_ORCHESTRATOR_ID (bare ids, one per line).
spool_asks_orch_ids() {
  local h
  h="$(spool_fleet_orchestrator 2>/dev/null)"; printf '%s\n' "${h%@*}"
  _spool_fleet_conf LEASE_ORCH 2>/dev/null; echo
  printf '%s\n' "${SPOOL_ORCHESTRATOR_ID:-}"
}

spool_ask_wanted() {  # TO KIND FORCE NO
  local to="${1%@*}" kind="$2" force="$3" no="$4"
  [ "$no" = 1 ] && return 0
  [ "${SPOOL_ASKS:-1}" = 0 ] && return 0
  if [ -n "$force" ]; then printf '%s' "$force"; return 0; fi
  case "$kind" in blocker|task) ;; *) return 0 ;; esac
  # grep without -q: an early exit would SIGPIPE the writer, and pipefail
  # (spool-send.sh) would then read the match as a miss
  spool_asks_orch_ids | grep -x -- "$to" >/dev/null && printf '%s' "$kind"
  return 0
}

spool_ask_summary() {  # BODY
  printf '%s' "$1" | sed -n '/[^[:space:]]/{p;q;}' | tr -d '\000-\037\177' |
    sed -E 's/^[[:space:]#>*-]+//; s/\*\*//g' | head -c 200
}

_spool_ask_file() { printf '%s/%s.json' "$(spool_asks_dir)" "$1"; }

_spool_ask_log() {  # OP ID BY STATE
  ( umask 002; printf '%s %s %s %s %s\n' "$(spool_asks_now)" "$1" "$2" "${3:--}" "${4:--}" >>"$(spool_asks_dir)/journal.log" ) 2>/dev/null || true
}

# Write a record atomically: JSON on stdin -> <id>.json.
_spool_ask_write() {  # ID
  local f tmp
  f="$(_spool_ask_file "$1")"; tmp="$f.tmp.$$"
  ( umask 002; cat >"$tmp" ) && mv -f "$tmp" "$f"
}

spool_ask_journal_open() {  # ID KIND FROM TO TOPIC SUMMARY [DEADLINE]
  local id="$1" f now
  [[ "$id" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || { echo "spool-asks: bad ask id '$id'" >&2; return 2; }
  command -v jq >/dev/null || { echo "spool-asks: jq is missing; ask $id not journaled" >&2; return 3; }
  spool_asks_dir >/dev/null || { echo "spool-asks: cannot make the journal dir" >&2; return 3; }
  f="$(_spool_ask_file "$id")"
  [ -e "$f" ] && return 0
  now="$(spool_asks_now)"
  jq -n -c --arg id "$id" --arg k "$2" --arg f "$3" --arg to "$4" --arg t "$5" --arg s "$6" --arg d "${7:-}" --arg now "$now" \
    --arg r "${SPOOL_ASK_ROLE:-orch}" '{ask_id:$id, role:$r, kind:$k, from:$f, to:$to, topic:$t, summary:$s, deadline_at:$d, state:"open",
      acked_by:"", closed_by:"", reason:"", raised_n:0, created_at:$now, updated_at:$now, synced:false}' |
    _spool_ask_write "$id" || return 3
  _spool_ask_log open "$id" "$3" open
}

spool_ask_journal_get() {  # ID
  local f
  f="$(_spool_ask_file "$1")"
  [ -s "$f" ] && cat "$f"
}

spool_ask_journal_set() {  # ID FIELDS-JSON OP BY
  local id="$1" cur
  cur="$(spool_ask_journal_get "$id")" || return 1
  jq -c --argjson m "$2" --arg now "$(spool_asks_now)" '. + {updated_at:$now} + $m' <<<"$cur" | _spool_ask_write "$id" || return 3
  _spool_ask_log "$3" "$id" "$4" "$(jq -r '.state' "$(_spool_ask_file "$id")")"
}

# One jq over every file (a jq per file was ~840 forks, seconds of sys time on
# a busy box, c-509); a file jq cannot parse sends the whole read to the
# per-file loop, which skips just that file.
spool_ask_journal_list() {
  local d f out
  d="$(spool_asks_dir)" || return 0
  compgen -G "$d/*.json" >/dev/null || return 0
  if out="$(printf '%s\0' "$d"/*.json | xargs -0 jq -c . 2>/dev/null)"; then
    [ -n "$out" ] && printf '%s\n' "$out"
    return 0
  fi
  for f in "$d"/*.json; do
    [ -s "$f" ] && jq -c . "$f" 2>/dev/null
  done
  return 0
}
