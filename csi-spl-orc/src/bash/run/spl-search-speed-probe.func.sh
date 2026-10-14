#!/bin/bash
#------------------------------------------------------------------------------
# @description SPL-1832, READ-ONLY: how fast search answers on a cloud env, per
# @description term, as a member sees it. Signs one tenant member in on the
# @description env's API host (env.dns.api_fqdn) and, per term, times PROBE_N
# @description first pages (GET /v1/view/search?q=<term>, the WUI's first
# @description call) and PROBE_N "Load more" pages of the message section (its
# @description cursor). Prints per term and call: n, statuses, p50 / max ms
# @description (client wall clock) and the message rows; then a JSON summary.
# @description The before/after of a search change: run it before the roll and
# @description after it. The server's own time per query is
# @description do_spl_hub_route_latency ROUTE_QUERY=1. Nothing is written;
# @description the password is read from a file and never printed.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param PROBE_TERMS - required: comma list of search terms, e.g. archive,spool,deploy
# @param PROBE_N (optional) - searches per term and call, 1..50, default 5
# @param PROBE_EMAIL (optional) - default the e2e member's stored address
# @param PROBE_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @example ENV=prd TENANT_ID=t1 PROBE_TERMS=archive,spool,deploy PROBE_N=5 PROBE_PW_FILE=<file> ./run -a do_spl_search_speed_probe
#------------------------------------------------------------------------------
do_spl_search_speed_probe() {
  do_require_bin yq python3 || return 1
  local tenant="${TENANT_ID:-}" n="${PROBE_N:-5}" terms="${PROBE_TERMS:-}" api
  spl_search_speed_probe_check "$tenant" "$n" "$terms" || return 1
  do_spl_cloud_cnf || return 1
  spl_cnf_api_fqdn api || return 1
  local st="$SPL_STATE_DIR/m3-e2e/$tenant" out rc=0
  local pw="${PROBE_PW_FILE:-$st/pw-human}" email="${PROBE_EMAIL:-}"
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set PROBE_PW_FILE)"; return 1; }
  [[ -n "$email" ]] || email="$(cat "$(dirname "$pw")/human-email" 2>/dev/null)"
  [[ -n "$email" ]] || { do_log "FATAL no member address (set PROBE_EMAIL)"; return 1; }
  printf '===== search speed probe: env=%s tenant=%s n=%s terms=%s\n' "$ENV" "$tenant" "$n" "$terms"
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_EMAIL="$email" PROBE_PW_FILE="$pw" \
    PROBE_N="$n" PROBE_TERMS="$terms" python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/search-speed-probe.py")" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL search speed probe on $ENV/$tenant (exit $rc)"; return 1; }
  do_log "OK search speed probe on $ENV/$tenant: $n searches per term and call, all 200"
}

# spl_search_speed_probe_check <tenant> <n> <terms> -> 0 when well formed;
# refuses before any cnf or network call.
spl_search_speed_probe_check() {
  [[ "${ENV:-}" == dev || "${ENV:-}" == prd ]] || { do_log "FATAL ENV must be dev or prd, got '${ENV:-}'"; return 1; }
  [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got '$1'"; return 1; }
  [[ "$2" =~ ^[0-9]+$ ]] && (( $2 >= 1 && $2 <= 50 )) || { do_log "FATAL PROBE_N must be 1..50, got '$2'"; return 1; }
  [[ "$3" =~ ^[^,]+(,[^,]+)*$ ]] || { do_log "FATAL PROBE_TERMS must be a comma list of terms, got '$3'"; return 1; }
}
