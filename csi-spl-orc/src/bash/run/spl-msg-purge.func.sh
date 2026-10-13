#!/bin/bash
#------------------------------------------------------------------------------
# @description Delete an exact list of messages and archive their topics, in
# @description a cloud env (SPL-1641, owner SPL-971 "A"). LIST_FILE holds one
# @description "<tenant> <msg_id> <task_id>" per line ('#' and blank lines are
# @description skipped). The rows go the way the hub deletes a message (a hard
# @description DELETE, its ON DELETE CASCADE children with it); each listed
# @description topic is archived the way the hub archives one (archived_at /
# @description archived_by on its card, the first remaining is_parent=1 row,
# @description and the card's DM mirrors), so the WUI lists it as archived and
# @description its link still opens it. An issue's discussion is skipped: the
# @description hub archives it with its issue.
# @description
# @description ONE transaction per tenant under its RLS context, through the
# @description Cloud SQL proxy as the env's project service account. Every
# @description tenant is checked first; nothing is deleted unless every listed
# @description id exists in its task and the file's row count is EXPECT_N.
# @description Before each delete the full rows (messages and every cascade
# @description child) go to an undo journal, PURGE_JOURNAL_DIR/<env>-<tenant>-
# @description <utc>.undo.tsv; do_spl_msg_purge_undo puts them back.
# @description DRY_RUN=1 (default): the per-tenant counts, nothing changed.
# @param ENV - required: dev or prd
# @param LIST_FILE - required: the "<tenant> <msg_id> <task_id>" list
# @param EXPECT_N - required: the number of rows LIST_FILE must hold
# @param ARCHIVED_BY - required: the archived_by stamp, e.g. HUM-10
# @param DRY_RUN (optional) - 1 (default) or 0
# @param PURGE_JOURNAL_DIR (optional) - default: $SPL_STATE_DIR/msg-purge
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=prd LIST_FILE=/var/spool-hub/dispatch/x.tsv EXPECT_N=76 ARCHIVED_BY=HUM-10 ./run -a do_spl_msg_purge
#------------------------------------------------------------------------------
do_spl_msg_purge() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local by="${ARCHIVED_BY:-}" lobby plan dry=1
  [[ "$by" =~ ^[A-Z]+-[0-9]+$ ]] || { do_log "FATAL ARCHIVED_BY must look like HUM-10, got: '$by'"; return 1; }
  lobby="$(yq -r '.env.hub.env.SPOOL_HUB_LOBBY_TASK_ID // ""' "$SPL_CNF")" || return 1
  plan="$(_spl_msg_purge_plan "${LIST_FILE:-}" "${EXPECT_N:-}" "$lobby")" || return 1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local jdir="${PURGE_JOURNAL_DIR:-$SPL_STATE_DIR/msg-purge}"
  (( dry )) || { mkdir -p "$jdir" && chmod 700 "$jdir"; } || { do_log "FATAL cannot make the journal dir $jdir"; return 1; }
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_MP_PLAN="$plan" SPL_MP_BY="$by" SPL_MP_DRY="$dry" SPL_MP_JDIR="$jdir" spl_via_proxy _spl_msg_purge_all
}

# _spl_msg_purge_plan <file> <expect_n> <lobby task> -> one line per tenant,
# "<tenant> <msg>:<task>,...", tenants sorted; fails on a missing file, a
# malformed line, a msg id given twice, the lobby's task, or a row count that
# is not expect_n.
_spl_msg_purge_plan() {
  local file="$1" want="$2" lobby="$3" tenant msg task extra n=0 seen=" " t
  local -A pairs=()
  [[ -n "$file" && -r "$file" ]] || { do_log "FATAL LIST_FILE must be a readable file, got: '$file'" >&2; return 1; }
  [[ "$want" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL EXPECT_N must be the list's row count (a positive number), got: '$want'" >&2; return 1; }
  local re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  while read -r tenant msg task extra; do
    [[ -z "$tenant" || "$tenant" == \#* ]] && continue
    n=$((n + 1))
    [[ -z "$extra" && "$msg" =~ $re && "$task" =~ $re ]] &&
      [[ "$tenant" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]] ||
      { do_log "FATAL LIST_FILE line $n is not '<tenant> <msg uuid> <task uuid>': $tenant $msg $task $extra" >&2; return 1; }
    [[ "$seen" != *" $msg "* ]] || { do_log "FATAL LIST_FILE: msg $msg is listed twice" >&2; return 1; }
    [[ -z "$lobby" || "$task" != "$lobby" ]] ||
      { do_log "FATAL LIST_FILE: msg $msg is in the lobby task; archiving it would hide one row, not a topic" >&2; return 1; }
    seen+="$msg "
    pairs[$tenant]+="${pairs[$tenant]:+,}$msg:$task"
  done <"$file"
  [[ "$n" == "$want" ]] || { do_log "FATAL LIST_FILE holds $n row(s), EXPECT_N=$want: refused" >&2; return 1; }
  for t in $(printf '%s\n' "${!pairs[@]}" | sort); do printf '%s %s\n' "$t" "${pairs[$t]}"; done
}

# Every tenant checked as a dry run first; then, when SPL_MP_DRY=0, each
# tenant's real transaction. A tenant that fails stops the run there.
_spl_msg_purge_all() {
  local tenant pairs total=0
  while read -r tenant pairs; do
    _spl_msg_purge_tenant "$tenant" "$pairs" 1 || return 1
  done <<<"$SPL_MP_PLAN"
  if (( SPL_MP_DRY )); then
    do_log "OK DRY_RUN rolled back: nothing changed in $ENV. Re-run with DRY_RUN=0."
    return 0
  fi
  while read -r tenant pairs; do
    _spl_msg_purge_tenant "$tenant" "$pairs" 0 || return 1
    total=$((total + $(tr ',' '\n' <<<"$pairs" | wc -l)))
  done <<<"$SPL_MP_PLAN"
  do_log "OK purged $total message(s) in $ENV ($GCP_ACCOUNT); undo: ENV=$ENV JOURNAL=<file above> ./run -a do_spl_msg_purge_undo"
}

# _spl_msg_purge_tenant <tenant> <pairs> <dry>: one purge.sql transaction,
# its counts printed; fails when it is refused or (dry=0) not committed.
_spl_msg_purge_tenant() {
  local tenant="$1" pairs="$2" dry="$3" out journal=/dev/null n nids ok s states=""
  local sql="$PROJ_PATH/src/sql/msg-purge/purge.sql"
  (( dry )) || journal="$SPL_MP_JDIR/$ENV-$tenant-$(date -u +%Y%m%dT%H%M%SZ).undo.tsv"
  out="$(umask 077; spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v tenant="$tenant" \
    -v pairs="$pairs" -v by="$SPL_MP_BY" -v dry="$dry" -v journal="$journal" -f "$sql" </dev/null)" ||
    { [[ "$journal" == /dev/null ]] || rm -f "$journal"
      do_log "FATAL the purge statement failed on $ENV/$tenant (nothing was committed): $out"; return 1; }
  grep '^MISSING|' <<<"$out" | sed 's/^MISSING|/MISSING msg=/; s/|/ task=/'
  IFS='|' read -r _ n nids ok < <(grep '^N|' <<<"$out")
  for s in STAMP ARCHIVED GONE ISSUE NOCARD; do
    states+=" $s=$(grep -c "^TOPIC|[^|]*|$s|" <<<"$out")"
  done
  do_log "INFO $ENV/$tenant: n=$n of $nids listed, topics=$(grep -c '^TOPIC|' <<<"$out"):$states," \
    "children: $(grep '^CHILD|' <<<"$out" | awk -F'|' '$3 > 0 {printf "%s=%s ", $2, $3}')$(grep '^MIRRORS|' <<<"$out" | tr '|' '=')"
  [[ "$ok" == t ]] || { do_log "FATAL $ENV/$tenant: n=$n of $nids listed ids found in their task (or a cascade the journal cannot hold): refused, nothing changed"; return 1; }
  (( dry )) && return 0
  if ! grep -qx COMMITTED <<<"$out"; then
    rm -f "$journal"
    do_log "FATAL $ENV/$tenant: $(grep '^DELETE|' <<<"$out") $(grep '^STAMP|' <<<"$out") did not match n=$n: rolled back, nothing changed"
    return 1
  fi
  do_log "OK $ENV/$tenant: $(grep '^DELETE|' <<<"$out" | tr '|' ' '), $(grep '^STAMP|' <<<"$out" | tr '|' ' ') card(s) archived by $SPL_MP_BY; journal $journal"
}
