#!/bin/bash
#------------------------------------------------------------------------------
# @description specs/025 live proof, READ-ONLY: sign one tenant member in on
# @description the env's API host (env.dns.api_fqdn) with its native password,
# @description read GET /v1/view/me and check that two hub gates agree with the
# @description permissions it lists (channels.manage via an invalid channel
# @description name, members.roles via HUM-0: neither can write anything).
# @description The password is read from a 0600 file and never printed.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug
# @param PROBE_EMAIL (optional) - default m3-e2e-human@example.com (the M3 e2e member)
# @param PROBE_PW_FILE (optional) - default the M3 e2e file <state>/m3-e2e/<tenant>/pw-human
# @param PROBE_EXPECT_ROLE (optional) - fail unless /v1/view/me answers this role
# @example ENV=dev TENANT_ID=t1 PROBE_EXPECT_ROLE=developer ./run -a do_spl_rbac_probe
#------------------------------------------------------------------------------
do_spl_rbac_probe() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" api
  spl_require_tenant_slug "$tenant" || return 1
  if [[ -n "${PROBE_EXPECT_ROLE:-}" ]]; then
    spl_role_id "$PROBE_EXPECT_ROLE" >/dev/null || { do_log "FATAL PROBE_EXPECT_ROLE is not a role id: '$PROBE_EXPECT_ROLE'"; return 1; }
  fi
  spl_cnf_api_fqdn api || return 1
  local pw="${PROBE_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}" out rc=0
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (run do_spl_m3_e2e first, or set PROBE_PW_FILE)"; return 1; }
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_TENANT="$tenant" PROBE_EMAIL="${PROBE_EMAIL:-m3-e2e-human@example.com}" \
    PROBE_PW_FILE="$pw" PROBE_EXPECT_ROLE="${PROBE_EXPECT_ROLE:-}" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/rbac-probe.py")" || rc=$?
  (( rc == 0 )) || { do_log "FATAL rbac probe on $ENV/$tenant (exit $rc): $out"; return 1; }
  do_log "OK rbac probe on $ENV/$tenant: $out"
}
