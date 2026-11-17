#!/bin/bash
#------------------------------------------------------------------------------
# @description One-time adoption of the Outlook entries written by hand before
# @description the import existed (spec 180 T6, section 1.5: 16 private rows of
# @description 2026-11-17 with no source_key). Each live private row of
# @description EVENT_OWNER in TENANT_ID that has no source_key and whose
# @description description holds "source: <id>", <id> shaped as an Outlook id
# @description (<hex>@YYYYMMDDTHHMMSS, what the one-off run and the export
# @description script write), gets the import's key,
# @description outlook:<owner>:<first 24 hex of SHA-256(id)> (the hub's
# @description outlookSourceKey), so the first import run updates these rows
# @description instead of writing them twice. Same path as do_spl_db_query: the
# @description env's project service account (never the owner account), the
# @description Cloud SQL proxy, operator RLS scope, ONE transaction.
# @description Prints counts only, never a title or a source id:
# @description candidates (rows it would key), distinct_keys, other_source
# @description (rows with a "source:" token that is not an Outlook id: left
# @description alone), taken (keys already on another row).
# @description DRY_RUN=1 (default): a READ ONLY transaction, rolled back.
# @description DRY_RUN=0: sets the keys and commits only when exactly
# @description ADOPT_EXPECT rows changed; on prd it also needs OWNER_GO.
# @param ENV (required) - dev or prd
# @param TENANT_ID (required) - the workspace slug
# @param EVENT_OWNER (required) - the member whose rows these are, a HUM-* id
# @param ADOPT_EXPECT (optional) - the row count the write must change; needed with DRY_RUN=0
# @param OWNER_GO (optional) - the owner's go message id; needed with ENV=prd DRY_RUN=0
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default: a free port
# @example ENV=prd TENANT_ID=csitea EVENT_OWNER=HUM-10 ./run -a do_spl_calendar_adopt_outlook
# @example ENV=prd TENANT_ID=csitea EVENT_OWNER=HUM-10 ADOPT_EXPECT=16 OWNER_GO=<msg id> DRY_RUN=0 ./run -a do_spl_calendar_adopt_outlook
#------------------------------------------------------------------------------
do_spl_calendar_adopt_outlook() {
  spl_require_cloud_env || return 1
  spl_require_tenant_slug "${TENANT_ID:-}" || return 1
  [[ "${EVENT_OWNER:-}" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL EVENT_OWNER must be a HUM-* id, got: '${EVENT_OWNER:-}'"; return 1; }
  local dry=1 out rc=0
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  if (( ! dry )); then
    [[ "${ADOPT_EXPECT:-}" =~ ^[1-9][0-9]{0,3}$ ]] || { do_log "FATAL DRY_RUN=0 needs ADOPT_EXPECT, the row count the dry run printed"; return 1; }
    [[ "$ENV" != prd || "${OWNER_GO:-}" =~ ^[0-9a-f]{8}([0-9a-f-]{28})?$ ]] \
      || { do_log "FATAL ENV=prd DRY_RUN=0 needs OWNER_GO, the owner's go message id"; return 1; }
  fi
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  out="$(mktemp)" || return 1
  ADOPT_DRY="$dry" spl_via_proxy _spl_calendar_adopt_outlook_run "$out" || rc=$?
  if (( rc != 0 )); then
    do_log "FATAL the adoption in $ENV failed, nothing was committed: $(tr '\n' ' ' <"$out")"
    rm -f "$out"; return 1
  fi
  _spl_calendar_adopt_outlook_report "$out" "$dry"
  rc=$?
  rm -f "$out"
  return "$rc"
}

# _spl_calendar_adopt_outlook_report <out> <dry>: print the counts as JSON
# and log the outcome; a write that did not change ADOPT_EXPECT rows is a
# failure (it was rolled back).
_spl_calendar_adopt_outlook_report() {
  local counts adopted
  counts="$(grep -m 1 -E '^[0-9]+\|[0-9]+\|[0-9]+\|[0-9]+$' "$1")"
  [[ -n "$counts" ]] || { do_log "FATAL no counts in the answer: $(tr '\n' ' ' <"$1")"; return 1; }
  IFS='|' read -r c d s k <<<"$counts"
  printf '{"env":"%s","tenant":"%s","owner":"%s","dry_run":%s,"candidates":%s,"distinct_keys":%s,"other_source":%s,"taken":%s}\n' \
    "$ENV" "$TENANT_ID" "$EVENT_OWNER" "$([[ "$2" == 1 ]] && echo true || echo false)" "$c" "$d" "$s" "$k"
  if [[ "$2" == 1 ]]; then
    do_log "OK DRY_RUN: $c rows of $EVENT_OWNER in $TENANT_ID ($ENV) would get an outlook: key; wrote nothing. Re-run with ADOPT_EXPECT=$c DRY_RUN=0."
    return 0
  fi
  adopted="$(sed -n 's/^adopted=\([0-9]*\) committed=\(t\|f\)$/\1 \2/p;T;q' "$1")"
  if [[ "$adopted" != "$ADOPT_EXPECT t" ]]; then
    do_log "FATAL the write changed '${adopted% *}' rows, not ADOPT_EXPECT=$ADOPT_EXPECT: rolled back, nothing written"
    return 1
  fi
  do_log "OK adopted $ADOPT_EXPECT rows of $EVENT_OWNER in $TENANT_ID ($ENV), owner go ${OWNER_GO:-none}"
}

# _spl_calendar_adopt_outlook_run <out>: the counts (ADOPT_DRY=1, read only)
# or the counts then the keyed update (ADOPT_DRY=0), one transaction through
# $SPL_PROXY_DSN; it commits only when ADOPT_EXPECT rows changed.
_spl_calendar_adopt_outlook_run() {
  local begin='BEGIN READ ONLY;' write='' rows
  rows="WITH c AS (
      SELECT event_id, owner_id, substring(description from '(?:^|[^A-Za-z0-9_])source:[ \t]*([^ \t\r\n]+)') AS src
      FROM calendar_events WHERE tenant_id = :'t' AND owner_id = :'o' AND source_key IS NULL
        AND deleted_at IS NULL AND audience = 'private'),
    k AS (SELECT event_id, src, 'outlook:' || owner_id || ':' || left(encode(sha256(convert_to(src, 'UTF8')), 'hex'), 24) AS key
      FROM c WHERE src ~ '^[0-9A-Fa-f]{16,}@[0-9]{8}T[0-9]{6}\$')"
  if [[ "$ADOPT_DRY" == 0 ]]; then
    begin='BEGIN;'
    write="$rows, u AS (UPDATE calendar_events e SET source_key = k.key FROM k
        WHERE e.tenant_id = :'t' AND e.event_id = k.event_id RETURNING 1)
      SELECT count(*) AS n, count(*) = :expect AS ok FROM u \\gset
      \\echo adopted=:n committed=:ok
      \\if :ok
        COMMIT;
      \\else
        ROLLBACK;
      \\endif"
  fi
  printf '%s\nSET LOCAL app.rls_scope = '"'"'operator'"'"';\n%s\n%s\n%s\n' "$begin" \
    "$rows SELECT count(*), count(DISTINCT key), (SELECT count(*) FROM c WHERE src IS NOT NULL) - count(*),
      (SELECT count(*) FROM calendar_events e WHERE e.tenant_id = :'t' AND e.source_key IN (SELECT key FROM k)) FROM k;" \
    "$write" "$([[ "$ADOPT_DRY" == 1 ]] && echo 'ROLLBACK;')" |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 -v t="$TENANT_ID" -v o="$EVENT_OWNER" \
      -v expect="${ADOPT_EXPECT:-0}" >"$1" 2>&1
}
