#!/bin/bash
#------------------------------------------------------------------------------
# @description specs/032 live proof that editing a sent message WORKS on a
# @description deployed env: sign one tenant member in on the env's API host,
# @description post a message over the browser socket, PATCH it, and check the
# @description whole chain - the 200 with edited_at / revision 2, that the edit
# @description did NOT move the message, that a live socket got the
# @description message_edited frame, that a re-read agrees, and that the hub
# @description still refuses an empty body and changes nothing when it does.
# @description
# @description WHY IT EXISTS: every cheaper probe stops at rule 1. An
# @description unauthenticated PATCH is refused before the handler touches the
# @description database, so a 401 reads exactly the same whether 0026 applied,
# @description applied without the runtime grants, or never ran. Only a real
# @description round-trip exercises the endpoint, the DDL and the grants
# @description together.
# @description
# @description It WRITES one message into the tenant's lobby and then edits
# @description it, so point it at a TEST tenant (dev t1, prd e2e), never at a
# @description tenant carrying a human's conversation. It reads no database;
# @description check the register with do_spl_db_query against the msg_id it
# @description prints. The password is read from a 0600 file and never printed.
# @param ENV - required: dev or prd
# @param TENANT_ID - required: the tenant slug (use the m3-e2e test tenant)
# @param PROBE_EMAIL (optional) - default the M3 e2e file <state>/m3-e2e/<tenant>/human-email, else m3-e2e-human@example.com
# @param PROBE_PW_FILE (optional) - default the M3 e2e file <state>/m3-e2e/<tenant>/pw-human
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_msg_edit_probe
# @example ENV=prd TENANT_ID=e2e ./run -a do_spl_msg_edit_probe
#------------------------------------------------------------------------------
do_spl_msg_edit_probe() {
  do_require_bin yq python3 || return 1
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" api fqdn
  spl_require_tenant_slug "$tenant" || return 1
  spl_cnf_api_fqdn api || return 1
  fqdn="$(yq -r '.env.dns.fqdn // ""' "$SPL_CNF")"
  local pw="${PROBE_PW_FILE:-$SPL_STATE_DIR/m3-e2e/$tenant/pw-human}" out rc=0
  [[ -r "$pw" ]] || { do_log "FATAL no readable password file $pw (run do_spl_m3_e2e first, or set PROBE_PW_FILE)"; return 1; }
  # The member's address is per-env state, not a constant: prd's m3-e2e run
  # wrote a human-email file and dev's did not, so a single hard default
  # signs in on one env and answers 401 invalid_credentials on the other
  # (measured 2026-09-22, prd/e2e). Read the file when it is there.
  local email="${PROBE_EMAIL:-}" email_file="$SPL_STATE_DIR/m3-e2e/$tenant/human-email"
  [[ -n "$email" ]] || { [[ -r "$email_file" ]] && email="$(tr -d '[:space:]' <"$email_file")"; }
  email="${email:-m3-e2e-human@example.com}"
  out="$(PROBE_API="${PROBE_API:-https://$api}" PROBE_AUTH="${PROBE_AUTH:-https://${fqdn:-$api}}" \
    PROBE_TENANT="$tenant" PROBE_EMAIL="$email" PROBE_PW_FILE="$pw" \
    python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/msg-edit-probe.py")" || rc=$?
  printf '%s\n' "$out"
  (( rc == 0 )) || { do_log "FATAL msg-edit probe on $ENV/$tenant (exit $rc)"; return 1; }
  do_log "OK msg-edit probe on $ENV/$tenant: a real edit round-trip, the live frame, the re-read and the empty-body refusal"
}
