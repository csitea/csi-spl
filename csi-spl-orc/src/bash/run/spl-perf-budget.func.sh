#!/bin/bash
#------------------------------------------------------------------------------
# @description Record three performance numbers and fail when a ceiling breaks.
# @description   1. WUI initial JS gzip — the chunks the document names, the
# @description      same set as csi-spl-wui/src/node/test/bundle-size.mjs
# @description   2. first-load transfer p50/p95 — wall time to GET that
# @description      document and those chunks. Not a browser paint time
# @description   3. p50/p95 of GET /v1/view/me, /v1/view/channels and
# @description      /v1/view/roster on this env (the signed-in shell's first
# @description      three view reads), one sign-in, then PERF_N samples
# @description The ceilings live in specs/027-spool-performance/contracts/
# @description perf-budgets.json. A measured value above its ceiling exits 1.
# @description The password file is read and never printed. Dry run unless
# @description DRY_RUN=0: the dry run names the hosts and makes no request.
# @description CI does not call this action. The quality gate's wui-e2e job
# @description runs `perf-budget.py bundle` on the mock nuxt generate output,
# @description which is the check that fails a push when the initial JS gzip
# @description exceeds ci_initial_gzip_kb. This action is the dev measurement.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant the member signs in to
# @param PERF_N (optional) - scored samples, 8..40, default 12
# @param PERF_WARMUP (optional) - discarded samples before those, 0..5, default 1
# @param PERF_EMAIL (optional) - default m3-e2e-human@example.com
# @param PERF_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @param PERF_BUDGETS (optional) - the ceilings file
# @param PERF_REQUIRE (optional) - live (default), ci, or none
# @param PERF_OUT (optional) - where the JSON report is written
# @param PERF_WUI_URL / PERF_API_URL (optional) - override the cnf hosts
# @param PERF_POST (optional) - 1 posts the one-line summary into a topic
# @param PERF_POST_AGENT / PERF_POST_TO / PERF_POST_TASK - required when posting
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ENV=dev TENANT_ID=t1 DRY_RUN=0 ./run -a do_spl_perf_budget
#------------------------------------------------------------------------------
do_spl_perf_budget() {
  do_require_bin python3 yq || return 1
  do_spl_cloud_cnf || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local tenant="${TENANT_ID:-}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  local n="${PERF_N:-12}" warm="${PERF_WARMUP:-1}" req="${PERF_REQUIRE:-live}"
  [[ "$n" =~ ^[0-9]+$ && "$warm" =~ ^[0-9]+$ ]] || { do_log "FATAL PERF_N and PERF_WARMUP must be whole numbers"; return 1; }
  [[ "$req" == live || "$req" == ci || "$req" == none ]] || { do_log "FATAL PERF_REQUIRE must be live, ci or none, got: '$req'"; return 1; }
  local wui_host api_host
  wui_host="$(yq -r '.env.dns.fqdn // ""' "$SPL_CNF")"
  api_host="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$wui_host" && "$wui_host" != null && -n "$api_host" && "$api_host" != null ]] || {
    do_log "FATAL env.dns.fqdn or env.dns.api_fqdn is empty in $SPL_CNF"; return 1; }
  local wui_url="${PERF_WUI_URL:-https://$wui_host}"
  local api_url="${PERF_API_URL:-https://$api_host}"
  local budgets="${PERF_BUDGETS:-$APP_PATH/csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json}"
  local post="${PERF_POST:-0}"
  [[ "$post" == 0 || "$post" == 1 ]] || { do_log "FATAL PERF_POST must be 0 or 1, got: '$post'"; return 1; }
  if [[ "$post" == 1 ]]; then
    local pagent="${PERF_POST_AGENT:-}" pto="${PERF_POST_TO:-}" ptask="${PERF_POST_TASK:-}"
    spl_desk_validate "$tenant" "${DESK_BOX:-box-desk}" "$pagent" || return 1
    [[ "$pto" =~ ^HUM-[A-Za-z0-9_-]{1,64}$ ]] || { do_log "FATAL PERF_POST_TO must be a human id (HUM-...), got: '$pto'"; return 1; }
    [[ "$ptask" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] || {
      do_log "FATAL PERF_POST_TASK must be a lowercase task UUID, got: '$ptask'"; return 1; }
  fi
  if (( dry )); then
    do_log "INFO DRY_RUN would: on $wui_url and $api_url tenant $tenant, n=$n warmup=$warm require=$req, record initial JS gzip, first-load transfer p50/p95, and p50/p95 of GET /v1/view/me /v1/view/channels /v1/view/roster, then compare to $budgets"
    do_log "OK DRY_RUN nothing was fetched."
    return 0
  fi
  local pw="${PERF_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}"
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (run do_spl_m3_e2e first, or set PERF_PW_FILE)"; return 1; }
  local out="${PERF_OUT:-$SPL_STATE_DIR/perf-budget/$ENV-report.json}"
  mkdir -p "$(dirname "$out")" || return 1
  local tree py rc=0 log
  tree="$(git -C "$APP_PATH" rev-parse --verify HEAD 2>/dev/null || echo unknown)"
  py="$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/perf-budget.py"
  [[ -f "$py" ]] || { do_log "FATAL missing $py"; return 1; }
  log="$(PERF_WUI_URL="$wui_url" PERF_API_URL="$api_url" PERF_EMAIL="${PERF_EMAIL:-m3-e2e-human@example.com}" \
    PERF_PW_FILE="$pw" PERF_TENANT="$tenant" PERF_N="$n" PERF_WARMUP="$warm" PERF_TREE="$tree" PERF_ENV="$ENV" \
    python3 "$py" live --budgets "$budgets" --require "$req" --out "$out")" || rc=$?
  local line
  while IFS= read -r line; do
    [[ -n "$line" ]] && do_log "$line"
  done <<<"$log"
  if [[ "$post" == 1 && -s "$out" ]]; then
    local body orc prc=0
    body="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["summary"])' "$out")" || prc=$?
    [[ -n "$body" ]] || prc=1
    if (( prc == 0 )); then
      orc="$APP_PATH/$SPL_ORG_APP-orc"
      (
        cd "$orc" || exit 1
        ENV=prd TENANT_ID="${PERF_POST_TENANT:-t1}" DESK_AGENT="$PERF_POST_AGENT" DESK_TO="$PERF_POST_TO" \
          DESK_TASK="$PERF_POST_TASK" DESK_BODY="$body" DESK_KIND=note DRY_RUN=0 \
          ./run -a do_spl_desk_reply
      ) || prc=$?
    fi
    if (( prc != 0 )); then
      do_log "FATAL the report is at $out but posting the summary failed"
      return 1
    fi
    do_log "OK posted the summary"
  fi
  return "$rc"
}
