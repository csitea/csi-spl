#!/bin/bash
# @description The open asks to the orchestrator, oldest first (CLE-77929,
# @description owner bug t1 #spool-hub-bugs 2f7996aa; SPEC-spool-fleet-roles.md
# @description 4.3). An ask is a blocker or task sent to the orchestrator (or any
# @description spool-send.sh --ask <kind>): the sender fires and forgets, and the
# @description ask stays OPEN until the acting orchestrator acks it
# @description (do_spl_ask_ack) and closes it (do_spl_ask_close, done | declined
# @description with a reason). The acting orchestrator runs this ON START and the
# @description lease loop re-raises what nobody acks (do_spl_asks_tick).
# @description Two halves, one ask id (the spool msg_id that carried it):
# @description   hub     - rdb 0097 fleet_asks via `spool ask` (every machine of
# @description             the fleet reads the same rows, so a successor on
# @description             another machine sees what the dead holder left)
# @description   journal - <spool root>/asks/<id>.json (lib/spool-asks.inc.sh),
# @description             written first by the sender, mirrored from the hub on
# @description             every read; an entry the hub has not got yet is
# @description             pushed here first (do_spl_asks_sync) and shown src
# @description             journal while the hub does not answer
# @description Without a fleet (no ASKS_FLEET / lease.conf LEASE_FLEET) the
# @description journal is the whole book: the one-machine behaviour.
# @param ASKS_FORMAT (optional) - table (default) or json
# @param ASKS_ALL (optional) - 1 also lists the closed asks (the hub keeps them a week)
# @param ASKS_ROLE (optional) - the recipient role whose log this is (the topic), default orch
# @param ASKS_FLEET / ASKS_ENV / ASKS_TENANT / ASKS_DESK_BOX (optional) - the hub fleet, env, tenant and pinned desk box; default the LEASE_* values (env, then <spool root>/dispatch/lease.conf)
# @param ASKS_HUB_CMD (optional, tests) - replaces the hub call: gets `ask <op> <args>`, prints the hub's answer
# @param SPOOL_ROOT (optional) - default /var/spool-hub; the journal is <root>/asks
# @example ./run -a do_spl_asks_open
# @example ASKS_ALL=1 ASKS_FORMAT=json ./run -a do_spl_asks_open

declare -F spl_lane_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"

do_spl_asks_open() {
  local fmt="${ASKS_FORMAT:-table}" rows
  [[ "$fmt" =~ ^(table|json)$ ]] || { do_log "FATAL ASKS_FORMAT must be table or json"; return 1; }
  spl_asks_init || return 1
  spl_asks_sync_pending
  spl_asks_load || return 1
  rows="$ASKS_ROWS"
  [[ "${ASKS_ALL:-0}" == 1 ]] || rows="$(jq -c '[.[] | select(.state == "open" or .state == "acked")]' <<<"$rows")"
  if [[ "$fmt" == json ]]; then
    jq -c --arg f "${LANE_FLEET:-}" --arg h "$ASKS_HUB_STATE" '{fleet: $f, hub: $h, asks: .}' <<<"$rows"
  else
    spl_asks_table "$rows"
    do_log "INFO $(jq '[.[] | select(.state == "open")] | length' <<<"$rows") open, $(jq '[.[] | select(.state == "acked")] | length' <<<"$rows") in progress (hub: $ASKS_HUB_STATE); work one: ASK_ID=<id> ./run -a do_spl_ask_ack | do_spl_ask_close"
  fi
}

# Source the spool libs, settle the hub settings (spl_lane_init: the same
# fleet, env, tenant and desk box the lane map uses) and this machine's box.
spl_asks_init() {
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"
  local feat
  feat="$(cd "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib" && pwd)"
  declare -F spool_valid_id >/dev/null || source "$feat/spool-env.inc.sh"
  declare -F spool_fleet_orchestrator >/dev/null || source "$feat/spool-fleet.inc.sh"
  declare -F spool_ask_journal_open >/dev/null || source "$feat/spool-asks.inc.sh"
  spl_asks_conf
  local k
  for k in FLEET ENV TENANT DESK_BOX; do
    local a="ASKS_$k" l="LANE_$k"
    [[ -n "${!a:-}" ]] && printf -v "$l" '%s' "${!a}"
  done
  # read by spl_lane_init (a tests' hub stub)
  # shellcheck disable=SC2034
  [[ -n "${ASKS_HUB_CMD:-}" ]] && LANE_HUB_CMD="$ASKS_HUB_CMD"
  ASKS_HUB_STATE=off
  if ! spl_lane_init; then
    # a fleet whose hub cannot be reached from here (no pinned desk): the
    # journal still works; the hub half is reported, never a reason to drop
    # an ask
    do_log "WARN the hub half is not configured on this machine: journal only"
    LANE_MODE=local
  fi
  [[ "$LANE_MODE" == hub ]] && ASKS_HUB_STATE=ok
  ASKS_BOX="${LANE_BOX:-$(spl_desk_box_default)}"
  return 0
}

# The ASKS_* knobs from the dispatch lease.conf for the keys not already in
# the environment. Read, never sourced.
spl_asks_conf() {
  local f="$SPOOL_ROOT/dispatch/lease.conf" k v
  [[ -f "$f" ]] || return 0
  while IFS='=' read -r k v; do
    [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "$v"
  done < <(grep -E '^(ASKS_(RERAISE_MIN|OWNER_MIN|OWNER)=[A-Za-z0-9-]+|LEASE_ORCH=[A-Z]{2,4}-[0-9]+)$' "$f")
  return 0
}

# `spool ask <op> <args>` through the lane map's hub call (same desk, same timeout).
spl_asks_hub() {
  if [[ -n "${ASKS_HUB_CMD:-}" ]]; then "$ASKS_HUB_CMD" ask "$@"; return; fi
  SPOOL_ROOT="$LANE_DESK_DIR/spool" SPOOL_KEYS_DIR="$LANE_DESK_DIR/keys" SPOOL_BOX_ID="$LANE_DESK_BOX" \
    SPOOL_HUB_URL="$SPL_HUB_URL" SPOOL_TENANT="$LANE_TENANT" timeout "${ASKS_TIMEOUT:-30}" "$SPL_SPOOL" ask "$@"
}

# The hub's asks (all states) as a JSON array, or exit 1 when it does not answer.
spl_asks_hub_list() {
  local out
  [[ "$LANE_MODE" == hub ]] || return 1
  out="$(spl_asks_hub list --fleet "$LANE_FLEET" --role "${ASKS_ROLE:-orch}" --all 2>"${ASKS_ERR:-/dev/null}")" || return 1
  jq -e -c '.asks | if type == "array" then . else error("no asks") end' <<<"$out" 2>/dev/null
}

# Push every journal entry the hub has not got (synced false): a new ask is
# put, a later state is replayed as its op. A 409 (closed elsewhere) takes the
# hub's row. Best effort: what fails stays unsynced for the next tick.
spl_asks_sync_pending() {
  [[ "$LANE_MODE" == hub ]] || return 0
  local rec id state by out n=0 bad=0
  while IFS= read -r rec; do
    [[ -n "$rec" ]] || continue
    id="$(jq -r '.ask_id' <<<"$rec")"; state="$(jq -r '.state' <<<"$rec")"
    if ! out="$(spl_asks_hub put --fleet "$LANE_FLEET" --id "$id" --kind "$(jq -r '.kind' <<<"$rec")" \
      --role "$(jq -r '.role // "orch"' <<<"$rec")" --from "$(jq -r '.from' <<<"$rec")" --topic "$(jq -r '.topic' <<<"$rec")" \
      --summary "$(jq -r '.summary' <<<"$rec")" --deadline "$(jq -r '.deadline_at // ""' <<<"$rec")" 2>&1)"; then
      bad=$((bad + 1)); continue
    fi
    if [[ "$state" != open ]]; then
      by="$(jq -r 'if .state == "acked" then .acked_by else .closed_by end' <<<"$rec")"
      local op="$state"
      case "$state" in acked) op=ack ;; declined) op=decline ;; esac
      if ! out="$(spl_asks_hub "$op" --fleet "$LANE_FLEET" --id "$id" --by "${by:-${ASKS_BY:-CLE-0}}" --reason "$(jq -r '.reason' <<<"$rec")" 2>&1)" &&
         ! grep -q 'ask_closed' <<<"$out"; then
        bad=$((bad + 1)); continue
      fi
    fi
    spool_ask_journal_set "$id" '{"synced":true}' sync hub
    n=$((n + 1))
  done < <(spool_ask_journal_list | jq -c 'select(.synced == false)')
  (( n > 0 )) && do_log "INFO pushed $n journal ask(s) to the hub"
  (( bad > 0 )) && { do_log "WARN $bad journal ask(s) not on the hub yet (kept, retried next tick)"; ASKS_HUB_STATE=partial; }
  return 0
}

# The merged book as a JSON array, open first then oldest first. Hub rows win
# for the ids the hub knows and are mirrored into the journal; a journal
# entry the hub does not know is kept while unsynced (src journal) and dropped
# once synced (the hub pruned it a week after it closed).
spl_asks_rows() {
  local hub="" now ok=false
  now="$(date -u +%s)"
  if [[ "$LANE_MODE" == hub ]]; then
    if hub="$(spl_asks_hub_list)"; then
      ok=true
      spl_asks_mirror "$hub"
    else
      ASKS_HUB_STATE=unreachable hub=""
      do_log "WARN the hub did not answer: these are this machine's journal asks only" >&2
    fi
  fi
  jq -c -n --argjson hub "${hub:-[]}" --argjson ok "$ok" --arg role "${ASKS_ROLE:-orch}" --argjson now "$now" --slurpfile loc <(spool_ask_journal_list) '
    def secs: if . == null or . == "" then null else (sub("\\.[0-9]+"; "") | fromdateiso8601) end;
    ($hub | map(. + {src: "hub"})) as $h
    | ($h | map({key: .ask_id, value: true}) | from_entries) as $known
    | $h + [ $loc[] | select((.role // "orch") == $role) | select(($known[.ask_id] // false) | not) | select(.synced == false or ($ok | not))
             | . + {src: "journal", age_s: ($now - (.created_at | secs)),
                    quiet_s: ($now - ([(.updated_at | secs), (.raised_at | secs // 0)] | max))} ]
    | map(. + {overdue: ((.deadline_at | secs) as $d | $d != null and $d < $now and (.state == "open" or .state == "acked"))})
    | sort_by((if .state == "open" or .state == "acked" then 0 else 1 end), -(.age_s // 0))'
}

# spl_asks_rows into ASKS_ROWS in THIS shell (not a $(...) subshell), so the
# ASKS_HUB_STATE it settles (unreachable) reaches the caller.
spl_asks_load() {
  local tmp rc=0
  tmp="$(mktemp)" || return 1
  spl_asks_rows >"$tmp" || rc=$?
  ASKS_ROWS="$(cat "$tmp")"; rm -f "$tmp"
  return "$rc"
}

# Write the hub's rows into this machine's journal, so the file system holds
# the state too; a local change the hub has not got yet (synced false) wins.
spl_asks_mirror() {
  local row id cur
  while IFS= read -r row; do
    id="$(jq -r '.ask_id' <<<"$row")"
    cur="$(spool_ask_journal_get "$id" 2>/dev/null)" || cur=""
    if [[ -n "$cur" ]] && [[ "$(jq -r '.synced' <<<"$cur")" == false ]]; then continue; fi
    # the hub omits empty fields: compare them as "" so an unchanged row is not rewritten
    local key='[.state, (.raised_n // 0), (.acked_by // ""), (.closed_by // ""), (.escalated_at // "")]'
    if [[ -n "$cur" ]] && [[ "$(jq -c "$key" <<<"$cur")" == "$(jq -c "$key" <<<"$row")" ]]; then continue; fi
    jq -c '{ask_id, role: (.role // "orch"), kind, from, to: "", topic, summary, deadline_at: (.deadline_at // ""), state,
            acked_by: (.acked_by // ""), closed_by: (.closed_by // ""), reason: (.reason // ""),
            raised_n, raised_at: (.raised_at // ""), escalated_at: (.escalated_at // ""),
            created_at, updated_at, synced: true}' <<<"$row" | _spool_ask_write "$id" &&
      _spool_ask_log mirror "$id" hub "$(jq -r '.state' <<<"$row")"
  done < <(jq -c '.[]' <<<"$1")
}

# One ask by its id or a unique prefix of it (8 hex digits is the usual
# hand-typed form): prints the full id, exit 1 when none or several match.
spl_asks_resolve() {
  local want="$1" rows="$2" hits
  [[ "$want" =~ ^[0-9a-f-]{4,36}$ ]] || { do_log "FATAL ASK_ID must be an ask id (or its first 8 hex digits), got '$want'" >&2; return 1; }
  hits="$(jq -r --arg w "$want" '[.[] | select(.ask_id | startswith($w)) | .ask_id] | unique | .[]' <<<"$rows")"
  case "$(grep -c . <<<"$hits")" in
    1) printf '%s' "$hits" ;;
    0) do_log "FATAL no ask $want in this fleet's book (do_spl_asks_open ASKS_ALL=1)" >&2; return 1 ;;
    *) do_log "FATAL $want matches several asks: $(tr '\n' ' ' <<<"$hits")" >&2; return 1 ;;
  esac
}

# The acting agent: ASK_BY, else this machine's orchestrator, as <ID>@<box>.
spl_asks_by() {
  local by="${ASK_BY:-${SPOOL_AGENT_ID:-${LEASE_ORCH:-${SPOOL_ORCHESTRATOR_ID:-}}}}"
  [[ "$by" == *@* ]] || by="$by@$ASKS_BOX"
  [[ "$by" =~ ^[A-Z]{2,4}-[0-9]{1,9}@[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL ASK_BY must be <ID>@<box>, got '$by'" >&2; return 1; }
  printf '%s' "$by"
}

spl_asks_table() {
  jq -r '
    def cut($n): if length > $n then .[0:$n-1] + "~" else . end;
    def dur: if . == null then "-" elif . < 3600 then "\(. / 60 | floor)m" elif . < 172800 then "\(. / 3600 | floor)h" else "\(. / 86400 | floor)d" end;
    (["ASK", "KIND", "STATE", "AGE", "QUIET", "RAISED", "FROM", "TOPIC", "BY", "SUMMARY", "SRC"] | @tsv),
    (.[] | [ .ask_id[0:8], .kind, (.state + (if .overdue then "!" else "" end)), (.age_s | dur), (.quiet_s | dur),
             (.raised_n | tostring), .from, (.topic | cut(10)),
             ((if .state == "acked" then .acked_by else .closed_by end) // "" | if . == "" then "-" else . end),
             ((.summary + (if .reason != "" and .reason != null then " | " + .reason else "" end)) | cut(70)), .src ] | @tsv)' <<<"$1" |
    column -t -s $'\t'
}
