#!/bin/bash
#------------------------------------------------------------------------------
# @description rdb 0028 live proof, READ-ONLY: sign one tenant member in on the
# @description env's API host (env.dns.api_fqdn) with its native password and
# @description read GET /v1/view/topics/{task_id}, asserting BOTH halves of
# @description the read door: the messages that member may read come back, and
# @description the ones it may not do not.
# @description   Both halves, always. A door that returns nothing passes every
# @description   "must not be readable" assertion vacuously, so the probe fails
# @description   unless at least PROBE_ALLOW_MIN messages also come back.
# @description   The interesting topic is one that MIXES a DM with a
# @description   channel-tagged reply, which is the shape the defect was
# @description   reported from (dev t1 57e6f191-582e-45b1-a08e-389c0b034803):
# @description   DENY_FROM names the id whose UNTAGGED messages this member is
# @description   not an end of, and none of them may appear.
# @description Nothing is written; the password is read from a 0600 file and
# @description never printed.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param TASK_ID - required: the task_id to read
# @param FILE_ID (optional) - check the ATTACHMENT door instead: GET /v1/files/{id} must answer FILE_WANT
# @param FILE_WANT (optional) - with FILE_ID: 200 (readable) or 404 (refused)
# @param DENY_FROM (optional) - a from id whose DM messages must NOT appear
# @param ALLOW_MIN (optional) - default 1; how many messages must come back
# @param PROBE_EMAIL (optional) - default m3-e2e-human@example.com (the M3 e2e member)
# @param PROBE_PW_FILE (optional) - default the M3 e2e file <state>/m3-e2e/<tenant>/pw-human
# @example ENV=dev TENANT_ID=t1 TASK_ID=<uuid> DENY_FROM=HUM-17 ./run -a do_spl_channel_privacy_probe
#------------------------------------------------------------------------------
do_spl_channel_privacy_probe() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" task="${TASK_ID:-}" api file="${FILE_ID:-}"
  [[ "$tenant" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL TENANT_ID must be a tenant slug, got: '$tenant'"; return 1; }
  if [[ -n "$file" ]]; then
    [[ "$file" =~ ^[0-9a-f]{64}$ ]] || { do_log "FATAL FILE_ID must be 64 hex chars, got: '$file'"; return 1; }
    [[ "${FILE_WANT:-}" =~ ^(200|404)$ ]] || { do_log "FATAL FILE_WANT must be 200 or 404 with FILE_ID"; return 1; }
    task="${task:-00000000-0000-4000-8000-000000000000}"
  fi
  [[ "$task" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || { do_log "FATAL TASK_ID must be a uuid, got: '$task'"; return 1; }
  api="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
  [[ -n "$api" ]] || { do_log "FATAL env.dns.api_fqdn is not set in $SPL_CNF"; return 1; }
  local pw="${PROBE_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}" out rc=0
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (run do_spl_m3_e2e first, or set PROBE_PW_FILE)"; return 1; }
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_EMAIL="${PROBE_EMAIL:-m3-e2e-human@example.com}" \
    PROBE_PW_FILE="$pw" PROBE_TASK="$task" PROBE_DENY_FROM="${DENY_FROM:-}" PROBE_ALLOW_MIN="${ALLOW_MIN:-1}" \
    PROBE_FILE="$file" PROBE_FILE_WANT="${FILE_WANT:-0}" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/channel-privacy-probe.py")" || rc=$?
  (( rc == 0 )) || { do_log "FATAL channel-privacy probe on $ENV/$tenant task $task (exit $rc): $out"; return 1; }
  do_log "OK channel-privacy probe on $ENV/$tenant task $task: $out"
}
