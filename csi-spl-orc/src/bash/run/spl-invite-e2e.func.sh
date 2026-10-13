#!/bin/bash
#------------------------------------------------------------------------------
# @description Invite -> mail -> sign-in -> first message, end to end on DEV,
# @description and on PRD in a TEST workspace only (e2e, e2e-*, the
# @description spl_test_workspaces list; never t1 or a customer workspace)
# @description (t1 afa8a4fb, R7 of the issue triage 1457bb6f: "no end-to-end
# @description test drives it with a fresh person"). Each step is printed
# @description PASS/FAIL/SKIPPED with evidence, like do_spl_m3_e2e:
# @description   1 the hub invites a FRESH plus-address of the relay mailbox,
# @description     <local>+inv-<run id>@<domain> (cnf mail.env.SPOOL_HUB_MAIL_SMTP_USER),
# @description     through POST /v1/operator/invites as the env's project SA,
# @description     and mails it from GCP
# @description   2 the invite mail is read from that mailbox over IMAP; its
# @description     link names the tenant and the invitee (login_hint); the
# @description     mail carries Delivered-To (a real delivery, not a sent copy)
# @description   3 the link's page serves
# @description   4 the address signs up and signs in WITH the tenant
# @description   5 the session is bound to the tenant
# @description   6 its first message, a task to a box agent (box-inv-e2e /
# @description     EIV-1, pinned by the tenant root key), is answered and the
# @description     answer reaches the invitee's WUI socket. SKIPPED when no
# @description     root key is in hand (CI today): the agent box needs one
# @description The IMAP password is the relay's own (cnf
# @description mail.secret_env.SPOOL_HUB_MAIL_SMTP_PASSWORD), read as the
# @description project SA in a throwaway CLOUDSDK_CONFIG into a 0600 file
# @description removed when the run ends (spl_m3_imap_pass); never the owner
# @description account. Store or rotate it with do_spl_mail_secret_seed.
# @description TEARDOWN: the invitee leaves the tenant again (operator member
# @description remove; a pending invite is revoked instead), so dev's member
# @description list does not grow by one per run.
# @description Engine: csi-spl-orc/src/bash/scripts/invite-e2e.py (stdlib,
# @description reuses m3-e2e.py). Offline tests: tests/invite-e2e.tst.sh.
# @param ENV - required: dev, or prd in a test workspace (its other tenants are real)
# @param TENANT_ID - required: the tenant the invitee joins; on prd a test
# @param   workspace (spl_invite_e2e_test_workspace), refused before any call
# @param ROOT_KEY_JSON (optional) - the tenant's 0600 key JSON (field
# @param   root_private_key); default the newest $SPL_TENANTS_DIR/<tenant>.*.json
# @param   when readable. None: step 6 is SKIPPED
# @param SPL_TENANTS_DIR (optional) - default /var/<org>/<org>-<app>/tenants/<env>
# @param INVITE_E2E_RUN_ID (optional) - the plus tag; default the CI run id, else a UTC stamp
# @param INVITE_E2E_TIMEOUT (optional) - seconds to wait for the mail, default 240
# @param SPL_STATE_DIR (optional) - default $HOME/.local/share/<org>-<app>/cloud/<env>
# @example ENV=dev TENANT_ID=t1 ./run -a do_spl_invite_e2e
# @example ENV=prd TENANT_ID=e2e ./run -a do_spl_invite_e2e
#------------------------------------------------------------------------------
do_spl_invite_e2e() {
  do_require_bin yq jq python3 curl gcloud || return 1
  case "${ENV:-}" in
    dev) ;;
    prd) spl_invite_e2e_test_workspace "${TENANT_ID:-}" ||
      { do_log "FATAL on prd do_spl_invite_e2e runs only in a test workspace (e2e, e2e-*, spl_test_workspaces), got '${TENANT_ID:-}': prd tenants are real"; return 1; } ;;
    *) do_log "FATAL do_spl_invite_e2e runs on dev, or prd in a test workspace (ENV=dev|prd), got '${ENV:-}'"; return 1 ;;
  esac
  do_spl_cloud_cnf || return 1
  local tenant="${TENANT_ID:-}" rid="${INVITE_E2E_RUN_ID:-}"
  spl_require_tenant_slug "$tenant" || return 1
  [[ -n "$rid" ]] || rid="${GITHUB_RUN_ID:+gh${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT:-1}}"
  [[ -n "$rid" ]] || rid="$(date -u +%Y%m%dt%H%M%Sz)"
  [[ "$rid" =~ ^[a-z0-9-]{1,40}$ ]] || { do_log "FATAL INVITE_E2E_RUN_ID must be [a-z0-9-]{1,40}, got '$rid'"; return 1; }

  local user
  user="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_USER // ""' "$SPL_CNF")"
  [[ "$user" =~ ^[^@+]+@[^@]+$ ]] || { do_log "FATAL no mail.env.SPOOL_HUB_MAIL_SMTP_USER mailbox in the $ENV cnf (got '$user')"; return 1; }
  local email="${user%@*}+inv-$rid@${user#*@}" host api_fqdn
  host="$(yq -r '.env.mail.env.SPOOL_HUB_MAIL_SMTP_HOST // ""' "$SPL_CNF")"
  spl_cnf_api_fqdn api_fqdn || return 1
  spl_hub_operator_url || return 1

  local st="$SPL_STATE_DIR/invite-e2e/$rid"
  rm -rf "$st"; ( umask 077; mkdir -p "$st" ) || return 1
  do_log "INFO invite e2e on $ENV/$tenant: hub $SPL_HUB_URL invitee $email"

  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_invite_e2e_root_key "$tenant" "$st" || return 1

  export M3_HUB_URL="https://$api_fqdn" M3_AUTH_URL="https://$api_fqdn" M3_TENANT="$tenant" \
    M3_STATE="$st" M3_HUMAN_EMAIL="$email" M3_OUTSIDER_EMAIL="" M3_NOTIFY_CMD="" \
    M3_IMAP_USER="$user" M3_IMAP_HOST="${M3_IMAP_HOST:-imap.${host#smtp.}}" M3_IMAP_PASS_FILE="$st/imap-pass"
  spl_m3_imap_pass "$M3_IMAP_PASS_FILE" || return 1

  local body rc=0
  body="$(jq -cn --arg t "$tenant" --arg e "$email" '{tenant: $t, email: $e, role: "developer", ttl_hours: 1, ordered_via: "invite-e2e"}')"
  if spl_hub_operator_call POST /v1/operator/invites "$body"; then
    jq -n --argjson s "$SPL_HUB_OP_STATUS" --arg b "$SPL_HUB_OP_BODY" \
      '{status: $s, body: ($b | try fromjson catch $b)}' >"$st/invite.json"
  else
    echo '{"status": 0}' >"$st/invite.json"
  fi

  python3 "$APP_PATH/$SPL_ORG_APP-orc/src/bash/scripts/invite-e2e.py" run || rc=$?
  spl_m3_imap_forget
  rm -f "$st"/cookie-* "$st"/pw-*
  spl_invite_e2e_teardown "$tenant" "$email" "$st"
  (( rc == 0 )) || { do_log "FAIL invite e2e on $ENV/$tenant: see $st/results.json"; return 1; }
  do_log "OK invite e2e on $ENV/$tenant: no step failed ($st/results.json)"
}

# spl_invite_e2e_test_workspace <tenant>: 0 when <tenant> is a prd test
# workspace: e2e or e2e-<x>, or on the shared list (spl_test_workspaces:
# SWEEP_SKIP_TENANTS plus <spool root>/dispatch/test-workspaces). t1 never.
spl_invite_e2e_test_workspace() {
  local t="$1"
  [[ -n "$t" && "$t" != t1 ]] || return 1
  [[ "$t" =~ ^e2e(-[a-z0-9]+)?$ ]] && return 0
  declare -F spl_test_workspaces >/dev/null || return 1
  [[ " $(spl_test_workspaces) " == *" $t "* ]]
}

# spl_invite_e2e_root_key <tenant> <state dir>: stage the tenant root key and
# the spool CLI for step 6, when a key JSON is readable. None = step 6 SKIPPED.
spl_invite_e2e_root_key() {
  local tenant="$1" st="$2" json="${ROOT_KEY_JSON:-}" org="${SPL_ORG_APP%%-*}"
  if [[ -z "$json" ]]; then
    # shellcheck source=../../../lib/bash/funcs/spl-newest-tenant-key.func.sh
    declare -F spl_newest_tenant_key >/dev/null ||
      source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-newest-tenant-key.func.sh"
    json="$(spl_newest_tenant_key "${SPL_TENANTS_DIR:-/var/$org/$SPL_ORG_APP/tenants/$ENV}" "$tenant" 2>/dev/null)" || json=""
  fi
  export M3_ROOT_KEY="" M3_SPOOL=""
  if [[ -z "$json" || ! -r "$json" ]]; then
    do_log "WARN no readable root key JSON for $tenant: step 6 (the agent answers) will be SKIPPED"
    return 0
  fi
  ( umask 077
    python3 -c 'import json,sys; open(sys.argv[2],"w").write(json.load(open(sys.argv[1]))["root_private_key"].strip()+"\n")' \
      "$json" "$st/root.key" ) 2>/dev/null && [[ -s "$st/root.key" ]] ||
    { rm -f "$st/root.key"; do_log "FATAL $json holds no root_private_key"; return 1; }
  spl_host_spool || return 1
  export M3_ROOT_KEY="$st/root.key" M3_SPOOL="$SPL_SPOOL"
}

# spl_invite_e2e_teardown <tenant> <email> <state dir>: the invitee leaves the
# tenant again (member remove when step 5 bound it, else revoke the invite).
# A teardown fault is a WARN: the verdict is the run's, not the cleanup's.
spl_invite_e2e_teardown() {
  local tenant="$1" email="$2" st="$3"
  rm -f "$st/root.key"
  if [[ -s "$st/bound.json" ]]; then
    ( ENV="$ENV" TENANT_ID="$tenant" EMAIL="$email" HUMAN_ID="" DRY_RUN=0 do_spl_tenant_member_remove ) >/dev/null 2>&1 &&
      { do_log "OK teardown: $email left $tenant"; return 0; }
    do_log "WARN teardown: could not remove $email from $tenant (do_spl_tenant_member_remove)"
    return 0
  fi
  local q
  q="$(jq -rn --arg t "$tenant" --arg e "$email" '"tenant=\($t|@uri)&email=\($e|@uri)"')"
  if spl_hub_operator_call DELETE "/v1/operator/invites?$q" && [[ "$SPL_HUB_OP_STATUS" =~ ^(204|404)$ ]]; then
    do_log "OK teardown: the invite of $email to $tenant is closed ($SPL_HUB_OP_STATUS)"
  else
    do_log "WARN teardown: could not revoke the invite of $email to $tenant (${SPL_HUB_OP_STATUS:-no answer})"
  fi
}
