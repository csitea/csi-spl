#!/bin/bash
#------------------------------------------------------------------------------
# @description spec 099 T009, READ-ONLY: drive every topic-list shape the
# @description topic-head shadow counts (hub view.go topicShape) on a cloud env,
# @description so do_spl_topic_head_shadow_report sees all six. Signs one
# @description tenant member in on the env's API host (env.dns.api_fqdn) and
# @description issues PROBE_N GETs per shape:
# @description   all       /v1/view/topics
# @description   all_flat  /v1/view/topics?roots=false
# @description   channel   /v1/view/topics?channel=<c>
# @description   dm        /v1/view/topics?dm=true
# @description   agent     /v1/view/topics?agent=<id>
# @description   children  /v1/view/topics/<task_id>/children
# @description Prints per shape the request count and HTTP statuses. Nothing is
# @description written; the password is read from a file and never printed.
# @description The hub logs topic_head_shadow per instance on the first compare
# @description 10 min after its window opened: run the report >= 10 min later
# @description (any list read then flushes the counters).
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param PROBE_N (optional) - reads per shape, 1..500, default 10
# @param PROBE_SHAPES (optional) - comma list, default all six
# @param PROBE_CHANNEL / PROBE_AGENT / PROBE_PARENT (optional) - the channel,
# @param   agent id and parent task_id; default ones the member's lists show
# @param PROBE_EMAIL (optional) - default m3-e2e-human@example.com (the M3 e2e member)
# @param PROBE_PW_FILE (optional) - default <state>/m3-e2e/<tenant>/pw-human
# @example ENV=dev TENANT_ID=t1 PROBE_N=20 ./run -a do_spl_topic_head_shape_probe
#------------------------------------------------------------------------------
do_spl_topic_head_shape_probe() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" n="${PROBE_N:-10}" api
  spl_require_tenant_slug "$tenant" || return 1
  [[ "$n" =~ ^[0-9]+$ ]] && (( n >= 1 && n <= 500 )) || { do_log "FATAL PROBE_N must be 1..500, got: '$n'"; return 1; }
  [[ "${PROBE_SHAPES:-all}" =~ ^[a-z_]+(,[a-z_]+)*$ ]] || { do_log "FATAL PROBE_SHAPES must be a comma list of shapes"; return 1; }
  [[ -z "${PROBE_PARENT:-}" || "$PROBE_PARENT" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] ||
    { do_log "FATAL PROBE_PARENT must be a uuid, got: '$PROBE_PARENT'"; return 1; }
  spl_cnf_api_fqdn api || return 1
  local pw="${PROBE_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}" out rc=0
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (set PROBE_PW_FILE)"; return 1; }
  printf '===== topic-head shape probe: env=%s tenant=%s n=%s\n' "$ENV" "$tenant" "$n"
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_EMAIL="${PROBE_EMAIL:-m3-e2e-human@example.com}" \
    PROBE_PW_FILE="$pw" PROBE_N="$n" PROBE_SHAPES="${PROBE_SHAPES:-}" PROBE_CHANNEL="${PROBE_CHANNEL:-}" \
    PROBE_AGENT="${PROBE_AGENT:-}" PROBE_PARENT="${PROBE_PARENT:-}" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/topic-head-shape-probe.py")" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL topic-head shape probe on $ENV/$tenant (exit $rc)"; return 1; }
  do_log "OK topic-head shape probe on $ENV/$tenant: $n reads per shape, all 200"
}
