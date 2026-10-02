#!/bin/bash
#------------------------------------------------------------------------------
# @description Move this machine's desk in ONE tenant from its old hub box id
# @description (FROM_BOX, required: e.g. box-desk) to its own box id (TO_BOX, the
# @description machine's 3-letter name from box.env SPOOL_DESK_BOX): specs/058
# @description M5 and section 6.5. One REBOX_STEP per call, in this order:
# @description   pin    - mint TO_BOX's key and pin it with the tenant root key
# @description            (do_spl_desk_pin self mode). Nothing goes offline
# @description   copy   - copy FROM_BOX's box_operators and channel_subscriptions
# @description            rows to TO_BOX, backfilled_at set, so no channel
# @description            back-fill burst fires and every channel seat, removal
# @description            and operator binding carries over. Idempotent
# @description   drain  - pause the desk cron for ENV (it would re-seat the old
# @description            box), stop FROM_BOX's sidecar, record the seated agents
# @description            in <desk>/rebox-seated.txt, move their dirs out of the
# @description            desk root, then ONE `spool hub-sync` as FROM_BOX: its
# @description            hello announces an empty roster and it pulls every
# @description            delivery still queued for FROM_BOX into the inboxes
# @description            (fleet copy + pane notice as the sidecar does). A
# @description            delivery cannot be re-pointed at TO_BOX: the envelope
# @description            is signed with its to_box, and a box refuses a frame
# @description            for another box. Re-runnable
# @description   seat   - seat the recorded agents on TO_BOX (their mute marks
# @description            kept) with do_spl_desk_up_all DESK_SEATED_ONLY=1
# @description   resume - remove the cron pause (the cron now reconciles the
# @description            box box.env names)
# @description   retire - drain again (a WUI DM to an old <ID>@<from> page queues
# @description            for FROM_BOX), delete FROM_BOX's channel_subscriptions
# @description            and box_operators rows, revoke its pin
# @description Between drain and seat an agent is on no roster for seconds: a
# @description box send to it is refused loudly (never queued and lost); the
# @description fleet lease holds the roles on the other machine meanwhile.
# @description SQL values travel as psql variables, never spliced; the
# @description statement sets app.tenant_id (rdb 0014).
# @description Dry run unless DRY_RUN=0: prints the step, calls no cloud.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param REBOX_STEP - required: pin | copy | drain | seat | resume | retire
# @param FROM_BOX - required: the old box id (e.g. box-desk). No default: no desk
# @param   action keeps a literal box-desk default (specs/058, test-desk-box-default case 8)
# @param TO_BOX (optional) - default spl_desk_box_default; never box-desk, never FROM_BOX
# @param ROOT_KEY_JSON (optional) - pin / retire: the tenant's 0600 create JSON;
# @param   default the newest $SPL_TENANTS_DIR/<tenant>.*.json
# @param SPL_TENANTS_DIR (optional) - default /var/<org>/<org>-<app>/tenants/<env>
# @param DESK_NOTIFY_CMD (optional) - drain: the terminal leg, as do_spl_desk_up
# @param DESK_MUTE (optional) - seat: as do_spl_desk_up_all
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd TENANT_ID=t1 FROM_BOX=box-desk TO_BOX=<box> REBOX_STEP=pin ./run -a do_spl_desk_rebox
# @example ENV=prd TENANT_ID=t1 FROM_BOX=box-desk TO_BOX=<box> REBOX_STEP=drain DRY_RUN=0 ./run -a do_spl_desk_rebox
#------------------------------------------------------------------------------
do_spl_desk_rebox() {
  do_require_bin python3 yq || return 1
  do_spl_desk_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}" step="${REBOX_STEP:-}" from="${FROM_BOX:-}" to="${TO_BOX:-$(spl_desk_box_default)}"
  [[ -n "$from" ]] || { do_log "FATAL FROM_BOX is required: the old box id this desk moves from (e.g. box-desk)"; return 1; }
  spl_desk_validate "$tenant" "$from" none || return 1
  spl_desk_validate "$tenant" "$to" none || return 1
  [[ "$to" != box-desk && "$to" != "$from" ]] ||
    { do_log "FATAL TO_BOX '$to' must be this machine's own box (box.env SPOOL_DESK_BOX), not box-desk and not FROM_BOX"; return 1; }
  case "$step" in
    pin | copy | drain | seat | resume | retire) ;;
    *) do_log "FATAL REBOX_STEP must be pin | copy | drain | seat | resume | retire, got: '$step'"; return 1 ;;
  esac
  SPL_REBOX_FROM="$SPL_STATE_DIR/desk/$tenant/$from" SPL_REBOX_TO="$SPL_STATE_DIR/desk/$tenant/$to"
  SPL_REBOX_PAUSE="${SPOOL_ROOT:-/var/spool-hub}/.desk-reconcile.$ENV.pause"
  if (( dry )); then
    do_log "INFO DRY_RUN would run step $step for $tenant on $ENV: $from -> $to (desk state $SPL_REBOX_FROM -> $SPL_REBOX_TO)"
    do_log "OK DRY_RUN nothing was touched. Re-run with DRY_RUN=0."
    return 0
  fi
  "_spl_rebox_$step" "$tenant" "$from" "$to"
}

# _spl_rebox_root_key <tenant> -> ROOT_KEY_JSON, or the newest saved create JSON.
_spl_rebox_root_key() {
  [[ -n "${ROOT_KEY_JSON:-}" ]] && { printf '%s\n' "$ROOT_KEY_JSON"; return 0; }
  local org="${SPL_ORG_APP%%-*}" dir k
  dir="${SPL_TENANTS_DIR:-/var/$org/$SPL_ORG_APP/tenants/$ENV}"
  k="$(ls -1 "$dir/$1".*.json 2>/dev/null | sort | tail -n 1)"
  [[ -n "$k" ]] || { do_log "FATAL no root key for $1: pass ROOT_KEY_JSON or keep it as $dir/$1.<ts>.json"; return 1; }
  printf '%s\n' "$k"
}

_spl_rebox_pin() {
  local key
  key="$(_spl_rebox_root_key "$1")" || return 1
  ( TENANT_ID="$1" DESK_BOX="$3" ROOT_KEY_JSON="$key" BOX_PUBKEY="" PIN_REVOKE=0 DRY_RUN=0 do_spl_desk_pin ) ||
    { do_log "FATAL pin of $3 in $1 failed"; return 1; }
  do_log "OK $3 is pinned in $1 ($ENV); $2 is untouched"
}

_spl_rebox_copy() {
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_rebox_copy_run "$1" "$2" "$3"
}

_spl_rebox_copy_run() {
  local out
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v from="$2" -v to="$3" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
WITH o AS (
  INSERT INTO box_operators (tenant_id, box_id, human_id, granted_by, granted_at)
  SELECT tenant_id, :'to', human_id, granted_by, granted_at FROM box_operators
   WHERE tenant_id = :'tenant' AND box_id = :'from'
  ON CONFLICT (tenant_id, box_id, human_id) DO NOTHING RETURNING 1)
SELECT 'operators ' || count(*) FROM o;
WITH c AS (
  INSERT INTO channel_subscriptions (tenant_id, channel_id, agent_id, box_id, subscribed_at, origin, backfilled_at)
  SELECT tenant_id, channel_id, agent_id, :'to', subscribed_at, origin, COALESCE(backfilled_at, now())
    FROM channel_subscriptions WHERE tenant_id = :'tenant' AND box_id = :'from'
  ON CONFLICT (tenant_id, channel_id, agent_id, box_id) DO NOTHING RETURNING 1)
SELECT 'channel_seats ' || count(*) FROM c;
COMMIT;
SQL
)" || { do_log "FATAL copy $2 -> $3 in $1 failed (rolled back): $out"; return 1; }
  do_log "OK $1: copied to $3 from $2: $(tr '\n' ' ' <<<"$out")"
}

_spl_rebox_drain() {
  local tenant="$1" from="$2" d="$SPL_REBOX_FROM" ts id n=0
  printf 'do_spl_desk_rebox %s %s -> %s %s\n' "$tenant" "$from" "$3" "$(date -u +%FT%TZ)" >"$SPL_REBOX_PAUSE" ||
    { do_log "FATAL cannot write the cron pause $SPL_REBOX_PAUSE"; return 1; }
  [[ -d "$d/spool" ]] || { do_log "FATAL $d has no desk spool: $from was never seated in $tenant"; return 1; }
  ( TENANT_ID="$tenant" DESK_BOX="$from" DESK_ALL=1 DESK_AGENT="" DRY_RUN=0 do_spl_desk_down ) >/dev/null ||
    { do_log "FATAL cannot stop the $from sidecar of $tenant"; return 1; }
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  _spl_rebox_park "$d" "$ts" seated
  spl_host_spool || return 1
  local notify="${DESK_NOTIFY_CMD-$APP_PATH/$SPL_ORG_APP-orc/src/bash/features/spawn-agents/scripts/spool-notify.sh}"
  local fleet="${SPOOL_FLEET_ROOT-/var/spool-hub}"
  [[ -n "$fleet" && -d "$fleet" ]] || fleet=""
  SPOOL_NOTIFY_CMD="$notify" SPOOL_FLEET_ROOT="$fleet" \
    spl_desk_spool "$d" "$from" "$tenant" "$SPL_HUB_URL" -- hub-sync >>"$d/spool/.hub/rebox-drain.log" 2>&1 ||
    { do_log "FATAL hub-sync of $from in $tenant failed: see $d/spool/.hub/rebox-drain.log"; return 1; }
  n="$(_spl_rebox_park "$d" "$ts-drain" drained)"
  do_log "OK $tenant: $from is off the air; seated $(wc -l <"$d/rebox-seated.txt") agent(s) recorded; drained $n message(s) still queued for $from into their inboxes"
}

# _spl_rebox_park <desk dir> <ts> seated|drained -> move every agent dir out of
# the desk root into <desk>/rebox-retired/<ts>/ (the root is what the box
# announces). "seated" also records the ids; "drained" prints how many message
# files the hub-sync wrote.
_spl_rebox_park() {
  local d="$1" dst="$1/rebox-retired/$2" e id n=0
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  for e in "$d/spool"/*/; do
    id="$(basename "$e")"
    [[ "$id" =~ ^${SPOOL_PARTICIPANT_RX}$ ]] || continue
    if [[ "$3" == seated ]]; then
      grep -qx "$id" "$d/rebox-seated.txt" 2>/dev/null || echo "$id" >>"$d/rebox-seated.txt"
    else
      n=$((n + $(find "$e/inbox" -maxdepth 1 -type f -name '*.json' 2>/dev/null | wc -l)))
    fi
    mkdir -p "$dst" && mv "${e%/}" "$dst/" || { do_log "FAIL cannot park $e"; continue; }
  done
  [[ "$3" == drained ]] && echo "$n"
  return 0
}

_spl_rebox_seat() {
  local tenant="$1" d="$SPL_REBOX_FROM" t="$SPL_REBOX_TO" id muted
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  [[ -s "$d/rebox-seated.txt" ]] || { do_log "FATAL no $d/rebox-seated.txt: run REBOX_STEP=drain first"; return 1; }
  [[ -s "$t/pinned" ]] || { do_log "FATAL $3 is not pinned in $tenant: run REBOX_STEP=pin first"; return 1; }
  while IFS= read -r id; do
    [[ "$id" =~ ^${SPOOL_PARTICIPANT_RX}$ ]] || continue
    mkdir -p "$t/spool/$id/inbox" "$t/spool/$id/outbox" "$t/spool/$id/archive" || return 1
    muted="$(find "$d/rebox-retired" -path "*/$id/.no-poke" -print -quit 2>/dev/null)"
    [[ -n "$muted" ]] && : >"$t/spool/$id/.no-poke"
  done <"$d/rebox-seated.txt"
  chmod -R go-rwx "$t" || return 1
  ( TENANT_ID="$tenant" DESK_BOX="$3" DESK_SEATED_ONLY=1 DESK_RETIRE=0 DESK_HUB_CHECK=0 DRY_RUN=0 do_spl_desk_up_all ) ||
    { do_log "FAIL not every agent was seated on $3 in $tenant (see above); re-run this step"; return 1; }
  do_log "OK $tenant: the recorded agents are seated on $3"
}

_spl_rebox_resume() {
  rm -f "$SPL_REBOX_PAUSE" && do_log "OK the desk cron of $ENV reconciles again ($SPL_REBOX_PAUSE removed)"
}

_spl_rebox_retire() {
  local key
  key="$(_spl_rebox_root_key "$1")" || return 1
  _spl_rebox_drain "$@" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_rebox_retire_run "$1" "$2" || return 1
  ( TENANT_ID="$1" DESK_BOX="$2" ROOT_KEY_JSON="$key" BOX_PUBKEY="" PIN_REVOKE=1 DRY_RUN=0 do_spl_desk_pin ) ||
    { do_log "FATAL revoke of $2 in $1 failed"; return 1; }
  do_log "OK $1: $2 is retired (pin revoked, channel seats and operators removed); the cron pause stays until REBOX_STEP=resume"
}

_spl_rebox_retire_run() {
  local out
  out="$(spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$1" -v from="$2" <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
WITH c AS (DELETE FROM channel_subscriptions WHERE tenant_id = :'tenant' AND box_id = :'from' RETURNING 1)
SELECT 'channel_seats ' || count(*) FROM c;
WITH o AS (DELETE FROM box_operators WHERE tenant_id = :'tenant' AND box_id = :'from' RETURNING 1)
SELECT 'operators ' || count(*) FROM o;
COMMIT;
SQL
)" || { do_log "FATAL retire rows of $2 in $1 failed (rolled back): $out"; return 1; }
  do_log "OK $1: removed from $2: $(tr '\n' ' ' <<<"$out")"
}
