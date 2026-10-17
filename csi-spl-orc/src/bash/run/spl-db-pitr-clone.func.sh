#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY reads from a POINT-IN-TIME CLONE of a cloud env's hub
# @description Cloud SQL instance (SPL-2230 option A: read back rows deleted
# @description from the live database). One run makes ONE throwaway clone
# @description (`gcloud sql instances clone <src> <src>-pitr-<utc stamp>
# @description --point-in-time=PITR_AT`), runs every statement against it
# @description through the Cloud SQL proxy as the hub runtime login (the clone
# @description carries the source's users), and DELETES the clone in an EXIT
# @description trap whatever happens: success, a failed read, an error or
# @description Ctrl-C. A clone that cannot be deleted is named with the exact
# @description delete command and the run fails.
# @description Every statement gets do_spl_db_query's guards and more: one
# @description statement each (no ';' inside), SELECT only (anything else is
# @description refused before any gcloud call), a READ ONLY transaction that is
# @description rolled back, the operator row-level-security scope. The DSN is
# @description never printed. Output: per statement a line "-- stmt <n>", then
# @description its rows as CSV (header first), on stdout.
# @description DRY_RUN=1 (the default) validates and prints the plan: no
# @description gcloud mutation, no proxy.
# @param ENV - required: dev or prd
# @param PITR_AT - required: the UTC point in time, YYYY-MM-DDTHH:MM:SSZ, inside the PITR window
# @param SQL (optional) - one SELECT statement
# @param SQL_FILE (optional) - a file of SELECT statements, each ended by ';' (one clone serves all)
# @param DRY_RUN (optional) - 1 (default) plan only; 0 clone, read, delete
# @param SPL_PITR_DELETE_TRIES (optional) - delete attempts, default 45 (a clone still being made refuses one)
# @param SPL_PITR_DELETE_WAIT (optional) - seconds between attempts, default 20
# @example ENV=prd PITR_AT=2026-10-17T01:59:00Z SQL='select count(*) from fleet_tokens' ./run -a do_spl_db_pitr_clone
# @example ENV=prd PITR_AT=2026-10-17T01:59:00Z SQL_FILE=/path/reads.sql DRY_RUN=0 ./run -a do_spl_db_pitr_clone
#------------------------------------------------------------------------------
do_spl_db_pitr_clone() {
  do_require_bin gcloud psql yq || return 1
  local at="${PITR_AT:-}" dry=1
  [[ "$at" =~ ^20[0-9]{2}-[01][0-9]-[0-3][0-9]T[0-2][0-9]:[0-5][0-9]:[0-5][0-9]Z$ ]] ||
    { do_log "FATAL PITR_AT must be a UTC time YYYY-MM-DDTHH:MM:SSZ, got: '$at'"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local -a stmts=()
  spl_db_pitr_statements stmts || return 1
  do_spl_cloud_cnf || return 1
  local clone
  clone="$SPL_SQL_INSTANCE-pitr-$(date -u +%Y%m%d%H%M%S)"
  do_log "INFO $ENV: plan: clone $SPL_SQL_INSTANCE at $at -> $clone, run ${#stmts[@]} SELECT(s), delete $clone"
  if (( dry )); then
    do_log "OK DRY RUN: nothing cloned. DRY_RUN=0 to clone, read and delete."
    printf 'src=%s clone=%s pitr_at=%s statements=%s\n' "$SPL_SQL_INSTANCE" "$clone" "$at" "${#stmts[@]}"
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  # a subshell owns the trap: traps are shell-global, and the clone must be
  # deleted on every way out of THIS run, Ctrl-C included
  (
    trap 'spl_db_pitr_clone_delete "$clone"' EXIT
    trap 'exit 130' INT TERM
    spl_db_pitr_clone_run "$clone" "$at" "${stmts[@]}"
  )
}

# spl_db_pitr_statements <array name> -> fills the array with the statements of
# SQL or SQL_FILE (exactly one of them), each checked by spl_db_pitr_select_ok.
spl_db_pitr_statements() {
  local -n _out="$1"
  local s
  if [[ -n "${SQL:-}" && -n "${SQL_FILE:-}" ]]; then do_log "FATAL set SQL or SQL_FILE, not both"; return 1; fi
  if [[ -n "${SQL_FILE:-}" ]]; then
    [[ -r "$SQL_FILE" ]] || { do_log "FATAL SQL_FILE is not readable: $SQL_FILE"; return 1; }
    local -a parts=()
    mapfile -d ';' -t parts <"$SQL_FILE"
    for s in "${parts[@]}"; do
      s="$(spl_db_pitr_trim "$s")"
      [[ -n "$s" ]] && _out+=("$s")
    done
  else
    s="$(spl_db_pitr_trim "${SQL:-}")"; s="${s%;}"
    [[ -n "$s" ]] && _out+=("$s")
  fi
  (( ${#_out[@]} > 0 )) || { do_log "FATAL SQL or SQL_FILE with at least one SELECT is required"; return 1; }
  for s in "${_out[@]}"; do spl_db_pitr_select_ok "$s" || return 1; done
}

# spl_db_pitr_trim <text> -> the text without whole-line '--' comments and
# leading/trailing whitespace.
spl_db_pitr_trim() {
  local t
  t="$(sed -e 's/^[[:space:]]*--.*$//' <<<"$1")"
  t="${t#"${t%%[![:space:]]*}"}"; t="${t%"${t##*[![:space:]]}"}"
  printf '%s' "$t"
}

# spl_db_pitr_select_ok <statement> -> 0 for ONE plain SELECT; refuses a ';'
# inside, a psql meta-command and every other verb (WITH included: a CTE can
# carry a data-modifying statement).
spl_db_pitr_select_ok() {
  [[ "$1" != *";"* ]] || { do_log "FATAL ONE statement each: a ';' inside one is refused"; return 1; }
  [[ "$1" =~ ^[Ss][Ee][Ll][Ee][Cc][Tt][[:space:]] ]] ||
    { do_log "FATAL only a SELECT is allowed, got: '${1:0:40}'"; return 1; }
}

# spl_db_pitr_clone_run <clone> <at> <stmt>... -> clones, then reads every
# statement through ONE proxy to the clone.
spl_db_pitr_clone_run() {
  local clone="$1" at="$2"; shift 2
  do_log "INFO $ENV: cloning $SPL_SQL_INSTANCE at $at into $clone (minutes)"
  gcloud sql instances clone "$SPL_SQL_INSTANCE" "$clone" --point-in-time="$at" \
    --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" --quiet >"$SPL_STATE_DIR/pitr-clone.log" 2>&1 ||
    { do_log "FATAL $ENV: clone failed: $(tail -5 "$SPL_STATE_DIR/pitr-clone.log" | tr '\n' ' ')"; return 1; }
  do_log "INFO $ENV: $clone is up; reading"
  SPL_SQL_CONN="$SPL_PROJECT:$SPL_REGION:$clone" spl_via_proxy _spl_db_pitr_read "$@"
}

# _spl_db_pitr_read <stmt>... -> per statement "-- stmt <n>" then CSV rows,
# each in its own READ ONLY transaction, rolled back, operator RLS scope.
_spl_db_pitr_read() {
  local n=0 s
  for s in "$@"; do
    n=$((n + 1))
    printf -- '-- stmt %s\n' "$n"
    PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
      psql -X -q --csv -v ON_ERROR_STOP=1 -P pager=off -c 'BEGIN TRANSACTION READ ONLY' \
        -c "SET LOCAL app.rls_scope = 'operator'" -c "$s" -c 'ROLLBACK' ||
      { do_log "FATAL $ENV: statement $n failed on the clone"; return 1; }
  done
}

# spl_db_pitr_clone_delete <clone> -> the EXIT trap: deletes the throwaway
# clone if it exists, retrying while an operation on it still runs, deletion
# protection turned off first in case the clone inherited it. Exits with the
# run's status, or 6 when the clone is still there.
spl_db_pitr_clone_delete() {
  local rc=$?
  local clone="$1" names i tries="${SPL_PITR_DELETE_TRIES:-45}" wait="${SPL_PITR_DELETE_WAIT:-20}"
  [[ "$clone" == "$SPL_SQL_INSTANCE"-pitr-* ]] || { do_log "FATAL refusing to delete '$clone': not a pitr clone"; exit 1; }
  for ((i = 1; i <= tries; i++)); do
    # gone only on a list that WORKED and names no clone: a failed list is not proof
    if names="$(gcloud sql instances list --filter="name=$clone" --format='value(name)' \
      --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" 2>/dev/null)" && [[ -z "$names" ]]; then
      do_log "INFO $ENV: $clone is gone"; exit "$rc"
    fi
    gcloud sql instances patch "$clone" --no-deletion-protection --project="$SPL_PROJECT" \
      --account="$GCP_ACCOUNT" --quiet >/dev/null 2>&1 || true
    if gcloud sql instances delete "$clone" --project="$SPL_PROJECT" --account="$GCP_ACCOUNT" \
      --quiet >/dev/null 2>&1; then
      do_log "INFO $ENV: deleted the clone $clone"; exit "$rc"
    fi
    (( i < tries )) && sleep "$wait"
  done
  do_log "ERROR $ENV: could not delete $clone - delete it now: gcloud sql instances delete $clone --project=$SPL_PROJECT --account=$GCP_ACCOUNT"
  exit 6
}
