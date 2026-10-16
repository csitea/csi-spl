#!/bin/bash
#------------------------------------------------------------------------------
# @description Plan or apply step 061 (the dev wine box) with a tester's
# @description access read at run time from the hub message where the tester
# @description posted their PUBLIC ssh key: the key becomes
# @description TF_VAR_desktop_user_ssh_public_keys, the poster's account
# @description (user:<email>, an active member of the message's tenant)
# @description becomes TF_VAR_iap_members. Neither is ever in git, cnf, a
# @description tfvars or this run's output: the key body, its comment and the
# @description address are masked; only the key type and its SHA256
# @description fingerprint are printed. The message is read with
# @description do_spl_db_query (read-only, the KEY_ENV project SA).
# @description Terraform runs only through make / tf-runner, dev only.
# @param KEY_MSG_ID - required: the msg_id (uuid) whose body is the key
# @param KEY_ENV (optional) - the hub env that holds the message, default prd
# @param TF_VERB (optional) - plan (default) or provision (apply)
# @example KEY_MSG_ID=<uuid> ./run -a do_spl_wine_box_tester_tf
# @example TF_VERB=provision KEY_MSG_ID=<uuid> ./run -a do_spl_wine_box_tester_tf
#------------------------------------------------------------------------------
do_spl_wine_box_tester_tf() {
  local verb="${TF_VERB:-plan}" msg="${KEY_MSG_ID:-}" kenv="${KEY_ENV:-prd}"
  local target out rc key email fp
  case "${verb}" in
    plan) target=do-tf-plan ;;
    provision) target=do-provision ;;
    *) do_log "FATAL TF_VERB must be plan or provision, got: ${verb}"; return 1 ;;
  esac
  [[ "${msg}" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] \
    || { do_log "FATAL KEY_MSG_ID must be a full msg uuid, got: '${msg}'"; return 1; }
  [[ "${kenv}" == dev || "${kenv}" == prd ]] || { do_log "FATAL KEY_ENV must be dev or prd, got: ${kenv}"; return 1; }
  do_require_bin jq || return 1

  # Two marked rows (psql expands a tab): KEY <body>, then MAIL <address>.
  out=$(ENV="${kenv}" SQL="select r from messages m join humans h on h.human_id = m.from_id join tenant_memberships tm on tm.human_id = m.from_id and tm.tenant_id = m.tenant_id cross join lateral (values (1, 'KEY ' || btrim(m.body)), (2, 'MAIL ' || coalesce(h.email, ''))) v(n, r) where m.msg_id = '${msg}' and h.disabled_at is null order by v.n" \
    do_spl_db_query 2>&1)
  rc=$?
  key=$(_spl_wine_box_tester_field KEY "${out}")
  email=$(_spl_wine_box_tester_field MAIL "${out}")
  [[ ${rc} == 0 && -n "${key}" && -n "${email}" ]] || {
    do_log "FATAL msg ${msg} in ${kenv}: no single row from an active member of its tenant (query rc ${rc}). REPORT it; nothing ran"
    return 1
  }
  [[ "${key}" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com)\ [A-Za-z0-9+/]+={0,3}(\ [^\']+)?$ && "${key}" != *PRIVATE* ]] \
    || { do_log "FATAL msg ${msg}: the body is not one OpenSSH public key. REPORT it; nothing ran"; return 1; }
  [[ "${email}" =~ ^[^[:space:]@]+@[^[:space:]@]+$ ]] \
    || { do_log "FATAL msg ${msg}: the poster has no sign-in address. REPORT it; nothing ran"; return 1; }
  fp=$(ssh-keygen -lf - <<<"${key}" 2>/dev/null | awk '{print $2}')
  [[ "${fp}" == SHA256:* ]] || { do_log "FATAL msg ${msg}: ssh-keygen is missing or cannot read the key. REPORT it; nothing ran"; return 1; }

  do_log "INFO tester key ${key%% *} ${fp} and its poster's account (never printed) from msg ${msg} (${kenv}); running make ${target} ENV=dev STEP=061-gcp-vm-wine-box"
  TF_VAR_desktop_user_ssh_public_keys=$(jq -cn --arg k "${key}" '[$k]') \
    TF_VAR_iap_members=$(jq -cn --arg m "user:${email}" '[$m]') \
    make -C "${PROJ_PATH}" "${target}" ENV=dev STEP=061-gcp-vm-wine-box 2>&1 \
    | _spl_wine_box_tester_mask "${key}" "${email}"
  rc=${PIPESTATUS[0]}
  key="" email=""
  return "${rc}"
}

# _spl_wine_box_tester_field <KEY|MAIL> <psql output>: the value of the one
# row with that mark, trimmed; empty unless there is exactly one.
_spl_wine_box_tester_field() {
  local rows
  rows=$(sed -nE "s/^ ?$1 (.*[^[:space:]])[[:space:]]*\$/\\1/p" <<<"$2")
  [[ -n "${rows}" && "${rows}" != *$'\n'* ]] && printf '%s\n' "${rows}"
}

# _spl_wine_box_tester_mask <key> <email>: stdin to stdout with the key body,
# the key comment and the address replaced, so a plan that echoes them
# (metadata, the ansible extra-vars) leaks neither.
_spl_wine_box_tester_mask() {
  local body comment line
  read -r _ body comment <<<"$1"
  while IFS= read -r line; do
    line="${line//"$2"/<TESTER>}"
    line="${line//"${body}"/<KEY>}"
    [[ -n "${comment}" ]] && line="${line//"${comment}"/<KEY-COMMENT>}"
    printf '%s\n' "${line}"
  done
}
