#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-5124 (spec 091 5.5): is the gate's customer list still whole?
# @description Reads the channels of the private overlay's customer_channels
# @description (<workspace>/<channel>, READ ONLY, operator scope) for URL hosts
# @description and ticket-key prefixes, and fails when one is covered by
# @description neither customer_strings nor customer_ignore. A new host under a
# @description listed domain and a new number of a listed prefix are covered by
# @description the gate itself; this catches a new domain or prefix.
# @description Output is counts only, never a value (cron and CI logs).
# @description No overlay, or no customer_strings or customer_channels: FATAL.
# @param ENV - required: dev or prd
# @param PD_CUSTOMER_NEW_OUT (optional) - a new file (mode 600) listing what is uncovered, for the overlay's editor
# @example ENV=prd ./run -a do_spl_public_dataset_customer_check
#------------------------------------------------------------------------------
do_spl_public_dataset_customer_check() {
  do_require_bin yq psql python3 || return 1
  do_spl_cloud_cnf || return 1
  # shellcheck source=/dev/null
  source "$APP_PATH/csi-spl-iac/lib/bash/funcs/spl-private-cnf.func.sh" || return 1
  local h rc=0 where
  h="$(mktemp -d)" && chmod 700 "$h" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$h'; trap - RETURN" RETURN
  spl_private_require 2>/dev/null || { do_log "FATAL no private overlay: the customer check needs it"; return 1; }
  spl_private_list_strict customer_strings >"$h/list" && spl_private_list_strict customer_ignore >"$h/ignore" ||
    { do_log "FATAL a customer list line of the private overlay is not in the form '  - entry'"; return 1; }
  [[ -s "$h/list" ]] || { do_log "FATAL the private overlay has no customer_strings entry"; return 1; }
  where="$(spl_pd_cc_where)" || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_via_proxy _spl_pd_cc_read "$(spl_pd_cc_sql "$where")" "$h/rows" ||
    { do_log "FATAL cannot read the customer channels (the database's message is not shown)"; return 1; }
  python3 "$PROJ_PATH/src/bash/scripts/public-dataset-customer-check.py" --rows "$h/rows" --customer-list "$h/list" \
    --ignore-list "$h/ignore" --out "${PD_CUSTOMER_NEW_OUT:-}" >"$h/log" 2>&1 || rc=$?
  do_log "$(cat "$h/log")"
  return "$rc"
}

# spl_pd_cc_where -> the SQL (tenant_id, channel) IN list of customer_channels.
spl_pd_cc_where() {
  local c w ch out="" list
  list="$(spl_private_list_strict customer_channels)" ||
    { do_log "FATAL a customer_channels line of the private overlay is not in the form '  - entry'" >&2; return 1; }
  [[ -n "$list" ]] || { do_log "FATAL the private overlay has no customer_channels entry" >&2; return 1; }
  while IFS= read -r c; do
    w="${c%%/*}"; ch="${c#*/}"
    [[ "$c" == */* && "$w" =~ ^[a-z0-9][a-z0-9-]*$ && "$ch" =~ ^[a-z0-9][a-z0-9_-]*$ ]] ||
      { do_log "FATAL a customer_channels entry is not <workspace>/<channel>" >&2; return 1; }
    out+="${out:+,}('$w','$ch')"
  done <<<"$list"
  printf '%s\n' "$out"
}

# spl_pd_cc_sql <where>: one statement, the distinct hosts and key prefixes.
spl_pd_cc_sql() {
  cat <<EOF_SQL
SELECT 'host', lower((regexp_matches(body, 'https?://(?:[^/[:space:]@]*@)?([^/[:space:]:)>"''|\`?#\]]+)', 'gi'))[1]) FROM messages WHERE (tenant_id, channel) IN ($1)
UNION
SELECT 'key', (regexp_matches(body, '\\m([A-Z][A-Z0-9]{1,9})-[0-9]+\\M', 'g'))[1] FROM messages WHERE (tenant_id, channel) IN ($1)
EOF_SQL
}

_spl_pd_cc_read() {
  PGOPTIONS='-c default_transaction_read_only=on' spl_pg_env "$SPL_PROXY_DSN" \
    psql -X -q -At -v ON_ERROR_STOP=1 -c 'BEGIN TRANSACTION READ ONLY' \
      -c "SET LOCAL app.rls_scope = 'operator'" -c "$1" -c 'ROLLBACK' >"$2" 2>/dev/null
}
