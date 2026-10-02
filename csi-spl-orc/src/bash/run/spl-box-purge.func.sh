#!/bin/bash
#------------------------------------------------------------------------------
# @description Purge dead boxes from a cloud tenant's ROSTER: the pin, the
# @description boxes row, the announced agents and the channel subscriptions,
# @description plus the local probe state that would stop the next run
# @description re-pinning. The teardown half of do_spl_box_msg_probe /
# @description do_spl_box_file_probe / do_spl_m3_e2e, which pin a box ONCE and
# @description reuse it, so nothing ever removed one and the rigs piled up.
# @description
# @description WHY A ROW DELETE AND NOT DELETE /v1/pins/{box_id}: the signed
# @description revoke (hub handleRevoke) sets pins.revoked_at, and view-v1 4.1
# @description is explicit that "revoked pins are listed with revoked: true".
# @description GET /v1/view/roster is built FROM pins (store ViewBoxes:
# @description FROM pins LEFT JOIN boxes LEFT JOIN roster), so a revoked box
# @description stays in the owner's JSON forever. Only removing the pins row
# @description takes it out of the roster. The WUI hides revoked boxes
# @description (rosterFromView); the JSON the owner reads does not.
# @description
# @description WHAT IT KEEPS: messages, deliveries and pins_history. The
# @description purge removes an IDENTITY, never history - the box's traffic
# @description and the record that it was once pinned stay readable.
# @description
# @description SAFETY. BOX_IDS is an explicit list, never a pattern: nothing
# @description here can match a box nobody named. box-wui is refused outright
# @description (it is the hub's own WUI-dispatch signing box, cnf-declared,
# @description owned by do_spl_pin_box_wui / do_spl_cloud_pin_box_wui - it
# @description shows last_hello_at null because it never opens a box socket,
# @description not because it is dead). A box that said hello within
# @description PURGE_MIN_IDLE_HOURS is refused, so a live box cannot be
# @description purged by a typo. Every statement runs under
# @description SET LOCAL app.tenant_id, so the rdb 0014 row-level-security
# @description policy - not this script - is what makes a cross-tenant delete
# @description impossible. The delete is ONE statement in ONE transaction and
# @description is rolled back unless exactly the expected number of pins went.
# @description
# @description DRY_RUN=1 (default) prints the tenant's FULL pin list with a
# @description purge/keep column - the enumeration to read before a prd run -
# @description and deletes nothing.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param BOX_IDS - required: space-separated box ids, explicitly named
# @param PURGE_MIN_IDLE_HOURS (optional) - refuse a box that said hello more recently; default 24
# @param PURGE_KEEP_STATE (optional) - 1 keeps the local probe/e2e state dirs; default 0 (remove them)
# @param DRY_RUN (optional) - 1 (default) or 0
# @param SPL_PROXY_PORT (optional) - local proxy port, default 55499
# @example ENV=dev TENANT_ID=t1 BOX_IDS="box-orc-probe box-rls-probe" ./run -a do_spl_box_purge
# @example ENV=dev TENANT_ID=t1 BOX_IDS="box-orc-probe" DRY_RUN=0 ./run -a do_spl_box_purge
#------------------------------------------------------------------------------
do_spl_box_purge() {
  do_require_bin yq psql || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" idle="${PURGE_MIN_IDLE_HOURS:-24}" dry=1
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$idle" =~ ^[0-9]+$ ]] && (( idle <= 8760 )) || { do_log "FATAL PURGE_MIN_IDLE_HOURS must be 0..8760, got: '$idle'"; return 1; }
  (( idle > 0 )) || do_log "WARN PURGE_MIN_IDLE_HOURS=0: a box that said hello a second ago can be purged"

  local -a boxes=() seen=()
  local b
  for b in ${BOX_IDS:-}; do
    [[ "$b" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL BOX_IDS holds '$b', which is not a box id"; return 1; }
    [[ "$b" != box-wui ]] || { do_log "FATAL box-wui is reserved: it is the hub's WUI-dispatch signing box (spec 014 wui-dispatch 2.2), pinned by do_spl_pin_box_wui / do_spl_cloud_pin_box_wui. Refusing."; return 1; }
    [[ " ${seen[*]-} " != *" $b "* ]] || { do_log "FATAL BOX_IDS names $b twice"; return 1; }
    seen+=("$b"); boxes+=("$b")
  done
  (( ${#boxes[@]} > 0 )) || { do_log "FATAL BOX_IDS is required: name every box explicitly (there is no pattern form)"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_PURGE_BOXES="${boxes[*]}" SPL_PURGE_TENANT="$tenant" SPL_PURGE_IDLE="$idle" SPL_PURGE_DRY="$dry" \
    spl_via_proxy _spl_box_purge_run || return 1
  (( dry )) && return 0
  _spl_box_purge_state "$tenant" "${boxes[@]}"
}

# The plan (always) and, unless SPL_PURGE_DRY, the delete. Both run under
# SET LOCAL app.tenant_id, so rdb 0014 RLS scopes them to that tenant.
_spl_box_purge_run() {
  local plan want
  want="$(wc -w <<<"$SPL_PURGE_BOXES")"
  plan="$(PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -v ON_ERROR_STOP=1 -P pager=off -v tenant="$SPL_PURGE_TENANT" -v boxes="$SPL_PURGE_BOXES" <<'SQL'
BEGIN TRANSACTION READ ONLY;
SET LOCAL app.tenant_id = :'tenant';
SELECT p.box_id,
       (p.box_id = ANY (string_to_array(:'boxes', ' '))) AS purge,
       (p.revoked_at IS NOT NULL) AS revoked,
       b.last_hello_at,
       floor(extract(epoch FROM (now() - coalesce(b.last_hello_at, to_timestamp(0)))) / 3600)::bigint AS idle_h,
       (SELECT count(*) FROM roster r WHERE r.tenant_id = p.tenant_id AND r.box_id = p.box_id) AS agents,
       (SELECT count(*) FROM channel_subscriptions c WHERE c.tenant_id = p.tenant_id AND c.box_id = p.box_id) AS subs,
       (SELECT count(*) FROM messages m WHERE m.tenant_id = p.tenant_id AND m.from_box = p.box_id) AS msgs_from
  FROM pins p
  LEFT JOIN boxes b ON b.tenant_id = p.tenant_id AND b.box_id = p.box_id
 WHERE p.tenant_id = :'tenant'
 ORDER BY p.box_id;
ROLLBACK;
SQL
  )" || { do_log "FATAL cannot read the $SPL_PURGE_TENANT pin list in $ENV"; return 1; }
  do_log "INFO every pin of $ENV/$SPL_PURGE_TENANT, purge=t is what BOX_IDS named (enumeration, not a pattern):"
  printf '%s\n' "$plan"

  # Every named box must actually be pinned here, or the list is wrong.
  local b miss=()
  for b in $SPL_PURGE_BOXES; do
    grep -qE "^ *$b *\| *t *\|" <<<"$plan" || miss+=("$b")
  done
  (( ${#miss[@]} == 0 )) || { do_log "FATAL not pinned under $SPL_PURGE_TENANT in $ENV: ${miss[*]} (nothing was touched)"; return 1; }

  if (( SPL_PURGE_DRY )); then
    do_log "OK DRY_RUN would purge $want box(es) from $ENV/$SPL_PURGE_TENANT: $SPL_PURGE_BOXES. Re-run with DRY_RUN=0."
    return 0
  fi

  local out
  out="$(_spl_box_purge_sql |
    spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
    -v tenant="$SPL_PURGE_TENANT" -v boxes="$SPL_PURGE_BOXES" -v idle="$SPL_PURGE_IDLE" -v want="$want")" || { do_log "FATAL the purge statement failed on $ENV/$SPL_PURGE_TENANT (nothing was committed): $out"; return 1; }

  local line npins nboxes nroster nsubs ok gone
  line="$(tail -n1 <<<"$out")"
  read -r npins nboxes nroster nsubs ok gone <<<"$line"
  [[ "$ok" == t ]] || {
    do_log "FATAL $npins of $want pin(s) matched in $ENV/$SPL_PURGE_TENANT: ROLLED BACK, nothing was deleted. A box that said hello within $SPL_PURGE_IDLE h is held back on purpose."
    return 1
  }
  do_log "OK purged $npins box(es) from $ENV/$SPL_PURGE_TENANT ($GCP_ACCOUNT): $gone — pins=$npins boxes=$nboxes roster=$nroster channel_subscriptions=$nsubs; messages, deliveries and pins_history kept"
}

# _spl_box_purge_sql: the one-transaction purge - delete the subscriptions,
# roster rows, boxes and pins of the requested boxes that are idle past :idle
# hours, COMMIT only when :want pins went, and echo the counts as one line.
_spl_box_purge_sql() {
  cat <<'SQL'
BEGIN;
SET LOCAL app.tenant_id = :'tenant';
WITH req AS (SELECT unnest(string_to_array(:'boxes', ' ')) AS box_id),
     target AS (
       SELECT p.tenant_id, p.box_id
         FROM pins p
         JOIN req ON req.box_id = p.box_id
         LEFT JOIN boxes b ON b.tenant_id = p.tenant_id AND b.box_id = p.box_id
        WHERE p.tenant_id = :'tenant'
          AND (b.last_hello_at IS NULL OR b.last_hello_at < now() - make_interval(hours => :idle))
     ),
     d_sub AS (DELETE FROM channel_subscriptions c USING target t
                WHERE c.tenant_id = t.tenant_id AND c.box_id = t.box_id RETURNING 1),
     d_ros AS (DELETE FROM roster r USING target t
                WHERE r.tenant_id = t.tenant_id AND r.box_id = t.box_id RETURNING 1),
     d_box AS (DELETE FROM boxes b USING target t
                WHERE b.tenant_id = t.tenant_id AND b.box_id = t.box_id RETURNING 1),
     d_pin AS (DELETE FROM pins p USING target t
                WHERE p.tenant_id = t.tenant_id AND p.box_id = t.box_id RETURNING p.box_id)
SELECT (SELECT count(*) FROM d_pin)::int                                   AS npins,
       coalesce((SELECT string_agg(box_id, ' ' ORDER BY box_id) FROM d_pin), '') AS gone,
       (SELECT count(*) FROM d_box)::int                                   AS nboxes,
       (SELECT count(*) FROM d_ros)::int                                   AS nroster,
       (SELECT count(*) FROM d_sub)::int                                   AS nsubs \gset
SELECT :npins = :want AS ok \gset
\if :ok
COMMIT;
\else
ROLLBACK;
\endif
\echo :npins :nboxes :nroster :nsubs :ok :gone
SQL
}

# Remove the box-scoped local state, so the next probe/e2e run re-pins instead
# of trusting a `pinned` marker whose pin no longer exists on the hub.
_spl_box_purge_state() {
  local tenant="$1"; shift
  if [[ "${PURGE_KEEP_STATE:-0}" == 1 ]]; then
    do_log "INFO PURGE_KEEP_STATE=1: the local state under $SPL_STATE_DIR is left as it is (the next probe will NOT re-pin)"
    return 0
  fi
  local b kind d gone=()
  for b in "$@"; do
    for kind in probe m3-e2e desk; do
      d="$SPL_STATE_DIR/$kind/$tenant/$b"
      [[ -d "$d" ]] || continue
      rm -rf -- "$d" && gone+=("$kind/$tenant/$b")
    done
  done
  (( ${#gone[@]} > 0 )) &&
    do_log "INFO removed the local state of the purged box(es) under $SPL_STATE_DIR: ${gone[*]} (the next probe run re-pins, and needs ROOT_KEY_JSON)" ||
    do_log "INFO no local box state to remove under $SPL_STATE_DIR"
  return 0
}
