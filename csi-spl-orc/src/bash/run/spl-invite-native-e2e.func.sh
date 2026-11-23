#!/bin/bash
#------------------------------------------------------------------------------
# @description An invite accepted with email + password, no Google, end to end
# @description in the deployed WUI (SPL-6286, owner HUM-10 t1 1269968d msg
# @description 01649437: "invite a fresh test address to the test workspace
# @description e2e, accept it with email and password"). dev, or prd in a TEST
# @description workspace only (e2e, e2e-*, spl_test_workspaces; never t1):
# @description   1 the hub invites a FRESH plus-address of the relay mailbox
# @description     (<local>+invnat-<utc>@<domain>) through POST
# @description     /v1/operator/invites as the env's project SA, and mails it
# @description   2..8 the WUI proof (csi-spl-wui tests/e2e/invite-native-live.proof.mjs,
# @description     headless Chrome, a screenshot per step): the invite mail's
# @description     link, the Register form on that page, the verify mail, the
# @description     verify page (signed in, landed in the tenant), a sign-in
# @description     from the invite link, a wrong password refused
# @description   9 read back from the hub Postgres (do_spl_hub_member_list,
# @description     read-only): the invite's accepted_at is set and the member
# @description     row holds the invited role, for the human the session named
# @description The invitee STAYS a member of the tenant (the owner's order),
# @description with a native credential: its address digest is logged for the
# @description later clean-up. No password, token, cookie or full address is
# @description printed; the passwords live in the proof's memory only.
# @param ENV (required) - dev, or prd in a test workspace
# @param TENANT_ID (required) - the tenant the invitee joins; on prd a test workspace
# @param INE_ORDERED_BY (required) - HUM-<n>, the owner who ordered the run (the invite's ordered_by)
# @param INE_ORDER_MSG (required) - the owner's message id that ordered it (logged, in ordered_via)
# @param INE_ROLE (optional) - the invited role, default regular_user
# @param INE_EMAIL (optional) - <relay>+<tag>@<relay domain> with no earlier mail; default <relay>+invnat-<utc>@<relay domain>
# @param INE_TTL_HOURS (optional) - the invite's lifetime, default 24
# @param M3_IMAP_TIMEOUT (optional) - seconds to wait for each mail (default 240)
# @param SPL_STATE_DIR (optional) - default $HOME/.local/share/<org>-<app>/cloud/<env>
# @example ENV=prd TENANT_ID=e2e INE_ORDERED_BY=HUM-10 INE_ORDER_MSG=01649437 ./run -a do_spl_invite_native_e2e
#------------------------------------------------------------------------------
do_spl_invite_native_e2e() {
  do_require_bin yq jq python3 curl node || return 1
  spl_require_cloud_env || return 1
  local tenant="${TENANT_ID:-}"
  spl_require_tenant_slug "$tenant" || return 1
  spl_ine_guard "$tenant" || return 1
  do_spl_cloud_cnf || return 1
  local relay email st
  relay="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // ""' "$SPL_CNF")"
  relay="${relay,,}"
  [[ "$relay" =~ ^[^@+]+@[^@]+$ ]] || { do_log "FATAL no mail.env.SPOOL_HUB_MAIL_SMTP_USER mailbox in the $ENV cnf"; return 1; }
  email="${INE_EMAIL:-${relay%@*}+invnat-$(date -u +%Y%m%dt%H%M%S)@${relay#*@}}"
  email="${email,,}"
  [[ "$email" == "${relay%@*}"+?*"@${relay#*@}" ]] ||
    { do_log "FATAL INE_EMAIL is no plus-address of the relay mailbox: use <relay>+<tag>@<relay domain>"; return 1; }
  st="${SPL_STATE_DIR:-$HOME/.local/share/$SPL_ORG_APP/cloud/$ENV}/invite-native-e2e/$(date -u +%Y%m%dT%H%M%SZ)"
  ( umask 077; mkdir -p "$st" ) || return 1
  do_log "INFO invite native e2e on $ENV/$tenant: ordered by $INE_ORDERED_BY msg $INE_ORDER_MSG; invitee $(spl_ine_tag "$email") (digest $(spl_ine_digest "$email"), stays a member); state $st"
  spl_ine_run "$tenant" "$email" "$relay" "$st"
}

# spl_ine_guard <tenant>: the order fields and the test-workspace rule, all
# checked before any cnf read, secret or call.
spl_ine_guard() {
  local t="$1"
  [[ "${INE_ORDERED_BY:-}" =~ ^HUM-[0-9]+$ ]] || { do_log "FATAL INE_ORDERED_BY must be HUM-<n>, got: '${INE_ORDERED_BY:-}'"; return 1; }
  [[ "${INE_ORDER_MSG:-}" =~ ^[0-9a-f-]{8,36}$ ]] || { do_log "FATAL INE_ORDER_MSG must be the owner's message id (hex), got: '${INE_ORDER_MSG:-}'"; return 1; }
  [[ "${INE_ROLE:-regular_user}" =~ ^[a-z_]+$ ]] || { do_log "FATAL INE_ROLE must be a role id, got: '${INE_ROLE}'"; return 1; }
  local ttl="${INE_TTL_HOURS:-24}"
  [[ "$ttl" =~ ^[1-9][0-9]{0,2}$ ]] && (( ttl <= 720 )) || { do_log "FATAL INE_TTL_HOURS must be 1..720, got: '$ttl'"; return 1; }
  [[ "$t" != t1 ]] || { do_log "FATAL TENANT_ID t1 is refused: this proof joins a TEST workspace only"; return 1; }
  [[ "$ENV" == dev ]] && return 0
  declare -F spl_invite_e2e_test_workspace >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/spl-invite-e2e.func.sh"
  spl_invite_e2e_test_workspace "$t" ||
    { do_log "FATAL on prd do_spl_invite_native_e2e runs only in a test workspace (e2e, e2e-*, spl_test_workspaces), got '$t'"; return 1; }
}

# spl_ine_tag <email>: the plus tag only (+invnat-...), never the mailbox.
spl_ine_tag() { local l="${1%@*}"; printf '+%s' "${l#*+}"; }
# spl_ine_digest <email>: the hub's own log digest (mail.Digest: sha256, 6 bytes hex).
spl_ine_digest() { printf '%s' "${1,,}" | sha256sum | cut -c1-12; }

# spl_ine_run <tenant> <email> <relay> <state>: invite, the WUI proof, the
# read-back; the verdict line. The relay password file is gone on every path.
spl_ine_run() {
  local tenant="$1" email="$2" relay="$3" st="$4" host api_fqdn rc=0
  host="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // ""' "$SPL_CNF")"
  spl_cnf_api_fqdn api_fqdn || return 1
  spl_hub_operator_url || return 1
  do_gcp_pin_account "$SPL_CNF" || return 1
  export M3_HUB_URL="https://$api_fqdn" M3_AUTH_URL="https://$api_fqdn" M3_TENANT="$tenant" M3_STATE="$st" \
    M3_HUMAN_EMAIL="$email" M3_IMAP_USER="$relay" M3_IMAP_HOST="${M3_IMAP_HOST:-imap.${host#smtp.}}" \
    M3_IMAP_PASS_FILE="$st/imap-pass"
  spl_m3_imap_pass "$M3_IMAP_PASS_FILE" || { rm -f "$M3_IMAP_PASS_FILE"; return 1; }
  if spl_ine_invite "$tenant" "$email" "$st"; then
    spl_ine_wui "$tenant" "$email" "$st" || rc=1
  else
    rc=1
  fi
  rm -f "$M3_IMAP_PASS_FILE"
  if [[ "$(jq -r .status "$st/invite.json" 2>/dev/null)" == 201 ]]; then
    spl_ine_readback "$tenant" "$email" "$st" || rc=1
    do_log "INFO left in $ENV/$tenant for the clean-up: invitee digest $(spl_ine_digest "$email") ($(spl_ine_tag "$email")): its invite, and when the proof got that far its membership and native credential"
  fi
  (( rc == 0 )) || { do_log "FAIL invite native e2e on $ENV/$tenant: $st/results.json"; return 1; }
  do_log "OK invite native e2e on $ENV/$tenant: every step held, screenshots + results.json in $st"
}

# spl_ine_invite <tenant> <email> <state>: POST /v1/operator/invites; the
# answer (status, role, mail outcome + Message-ID, never the address) in
# invite.json for the proof's step 1.
spl_ine_invite() {
  local tenant="$1" email="$2" st="$3" body
  body="$(jq -cn --arg t "$tenant" --arg e "$email" --arg r "${INE_ROLE:-regular_user}" --arg b "$INE_ORDERED_BY" \
    --arg v "invite-native-e2e msg $INE_ORDER_MSG" --argjson h "${INE_TTL_HOURS:-24}" \
    '{tenant: $t, email: $e, role: $r, ttl_hours: $h, ordered_by: $b, ordered_via: $v}')" || return 1
  if ! spl_hub_operator_call POST /v1/operator/invites "$body"; then
    echo '{"status": 0}' >"$st/invite.json"
    return 1
  fi
  jq -n --argjson s "$SPL_HUB_OP_STATUS" --arg b "$SPL_HUB_OP_BODY" \
    '{status: $s} + (($b | try fromjson catch {}) | {tenant_id, role, expires_at,
      mail_outcome: .mail.outcome, mail_message_id: .mail.message_id, error})' >"$st/invite.json"
  do_log "INFO invite: http $SPL_HUB_OP_STATUS $(jq -c 'del(.status)' "$st/invite.json")"
  [[ "$SPL_HUB_OP_STATUS" == 201 ]]
}

# spl_ine_wui <tenant> <email> <state>: the WUI proof, steps 0..8.
spl_ine_wui() {
  local tenant="$1" email="$2" st="$3" orc="$APP_PATH/$SPL_ORG_APP-orc"
  ( cd "$APP_PATH/$SPL_ORG_APP-wui" &&
    API="$M3_AUTH_URL" EMAIL="$email" TENANT="$tenant" OUT="$st" INVITE_JSON="$st/invite.json" \
    INVITE_LINK_CMD="python3 $orc/src/bash/scripts/invite-e2e.py link" \
    MAIL_TOKEN_CMD="cd $orc && ENV=$ENV ./run -a do_spl_mail_verify_token" \
      ${INE_CMD_NODE:-node tests/e2e/invite-native-live.proof.mjs} )
}

# spl_ine_readback <tenant> <email> <state>: step 9, the invite and the member
# row from the hub Postgres (read-only), appended to results.json. The
# address is matched here and never written out.
spl_ine_readback() {
  local tenant="$1" email="$2" st="$3" rows hum want="${INE_ROLE:-regular_user}" ev ok=false
  rows="$( (TENANT_ID="$tenant" MATCH="${email%@*}" ${INE_CMD_MEMBERS:-do_spl_hub_member_list}) 2>/dev/null | grep '^{' )"
  hum="$(jq -r '.session_hum // ""' "$st/bound.json" 2>/dev/null)"
  ev="$(jq -cs --arg e "$email" --arg h "$hum" '
    (map(select(.type == "invite" and .email == $e)) | last) as $i |
    (map(select(.type == "member" and .email == $e)) | last) as $m |
    {invite_accepted_at: $i.accepted_at, invite_role: $i.role, accepted_by_session_human: ($h != "" and $i.accepted_by == $h),
     member_human: $m.human_id, member_role: $m.role, member_admitted_by: $m.admitted_by,
     member_providers: [($m.identities // [])[].provider], session_human: $h}' <<<"$rows" 2>/dev/null)"
  [[ -n "$ev" ]] || ev='{"error": "no invite or member row read"}'
  jq -e --arg w "$want" '.invite_accepted_at != null and .member_role == $w and .invite_role == $w
    and .member_human == .session_human and .accepted_by_session_human' <<<"$ev" >/dev/null && ok=true
  do_log "$([[ $ok == true ]] && echo PASS || echo FAIL) 9 read-back: $ev"
  [[ -s "$st/results.json" ]] || echo '{"steps": []}' >"$st/results.json"
  jq --argjson ev "$ev" --argjson ok "$ok" '.steps += [{step: "9 read-back (hub Postgres)", ok: $ok} + $ev]' \
    "$st/results.json" >"$st/results.json.tmp" && mv "$st/results.json.tmp" "$st/results.json"
  [[ $ok == true ]]
}
