#!/bin/bash
#------------------------------------------------------------------------------
# @description Undo one do_spl_msg_purge tenant run from its journal: the
# @description messages and their cascade children go back with every column
# @description they had, and the archive stamps that run set are cleared where
# @description they still hold. ONE transaction under the tenant's RLS; it is
# @description refused when any journaled message exists again.
# @description DRY_RUN=1 (default): restores inside the transaction, prints the
# @description counts, rolls back.
# @param ENV - required: dev or prd
# @param JOURNAL - required: the .undo.tsv the purge run printed
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=prd JOURNAL=~/.local/share/csi-spl/cloud/prd/msg-purge/prd-t1-20261013T120000Z.undo.tsv DRY_RUN=0 ./run -a do_spl_msg_purge_undo
#------------------------------------------------------------------------------
do_spl_msg_purge_undo() {
  do_require_bin psql || return 1
  do_spl_cloud_cnf || return 1
  local j="${JOURNAL:-}" tenant dry=1
  [[ -n "$j" && -s "$j" ]] || { do_log "FATAL JOURNAL must be a non-empty .undo.tsv, got: '$j'"; return 1; }
  tenant="$(sed -n 's/^=meta\t.*"tenant": "\([a-z0-9-]*\)".*/\1/p' "$j")"
  tenant="${tenant%%$'\n'*}"
  spl_require_tenant_slug "$tenant" || { do_log "FATAL $j has no =meta tenant line"; return 1; }
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  SPL_MP_J="$j" SPL_MP_TENANT="$tenant" SPL_MP_DRY="$dry" spl_via_proxy _spl_msg_purge_undo_run
}

# undo.sql with the journal on stdin, backslashes doubled for \copy.
_spl_msg_purge_undo_run() {
  local out n na nc ok
  out="$(sed 's/\\/\\\\/g' "$SPL_MP_J" | spl_pg_env "$SPL_PROXY_DSN" psql -X -q -At -v ON_ERROR_STOP=1 \
    -v tenant="$SPL_MP_TENANT" -v dry="$SPL_MP_DRY" -f "$PROJ_PATH/src/sql/msg-purge/undo.sql")" ||
    { do_log "FATAL the undo failed on $ENV/$SPL_MP_TENANT (nothing was committed): $out"; return 1; }
  IFS='|' read -r _ n na nc ok < <(grep '^J|' <<<"$out")
  do_log "INFO $ENV/$SPL_MP_TENANT journal: $n message(s), $nc child row(s), $na archive stamp(s);" \
    "$(grep '^UNSTAMP|' <<<"$out" | tr '|' ' ') $(grep '^RESTORED|' <<<"$out" | tr '|' ' ')"
  [[ "$ok" == t ]] || { do_log "FATAL $SPL_MP_J is not this tenant's, names a table that is not a messages child, or a message is back already: refused, nothing changed"; return 1; }
  if (( SPL_MP_DRY )); then
    do_log "OK DRY_RUN rolled back: nothing changed in $ENV/$SPL_MP_TENANT. Re-run with DRY_RUN=0."
    return 0
  fi
  grep -qx COMMITTED <<<"$out" || { do_log "FATAL restored $(grep '^RESTORED|' <<<"$out") != $n: rolled back, nothing changed"; return 1; }
  do_log "OK restored $n message(s) in $ENV/$SPL_MP_TENANT ($GCP_ACCOUNT)"
}
