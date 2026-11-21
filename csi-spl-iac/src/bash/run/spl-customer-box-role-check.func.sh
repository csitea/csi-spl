#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 181 row B6 (spec 122 4 point 4): prove the customer box
# @description role set (src/ansible/customer-box) carries nothing of ours that
# @description a private workspace's VM must never get. READ ONLY: it reads the
# @description role set's files and runs nothing on any box. It refuses:
# @description   key-file    a file shaped like a key or a login: its name
# @description               (key-*.json, *.pem, *.key, *.p12, id_rsa*,
# @description               id_ed25519*, *credentials*.json, token) or its
# @description               content (a service-account JSON, a PEM private key)
# @description   estate-ref  a task line that reads an estate key, a GitHub
# @description               token or an AI login of ours (the gcp key dir, the
# @description               controller's env, gh auth, a CLI credentials file,
# @description               a vendor API key variable)
# @description   ws-setup    the playbook runs no do_spl_box_workspace_setup
# @description   checks      the playbook runs no spl_desk_start_checks (127 5.3)
# @description One "REFUSED <check>: <why>" line per finding, then exit 1.
# @param CUSTOMER_BOX_ROLE_DIR (optional) - the role set to check; default src/ansible/customer-box of this tree
# @example ./run -a do_spl_customer_box_role_check
# @example CUSTOMER_BOX_ROLE_DIR=<dir> ./run -a do_spl_customer_box_role_check
#------------------------------------------------------------------------------
do_spl_customer_box_role_check() {
  local d="${CUSTOMER_BOX_ROLE_DIR:-${PROJ_PATH}/src/ansible/customer-box}" bad=0 pb
  pb="$d/customer-box-playbook.yaml"
  [[ -f "$pb" ]] || { do_log "FATAL no role set at $d (want customer-box-playbook.yaml)"; return 1; }
  spl_cbr_key_files "$d" || bad=1
  spl_cbr_estate_refs "$d" || bad=1
  spl_cbr_runs "$d" 'do_spl_box_workspace_setup' ws-setup || bad=1
  spl_cbr_runs "$d" 'spl_desk_start_checks' checks || bad=1
  (( bad == 0 )) || { do_log "FATAL the customer box role set at $d carries an estate key or AI login, or skips a required step (spec 181 B6)"; return 1; }
  do_log "OK the customer box role set at $d: no estate key, no AI login of ours; it runs do_spl_box_workspace_setup and the 127 5.3 checks"
}

spl_cbr_refuse() { do_log "REFUSED $1: $2"; return 1; }

# spl_cbr_key_files <dir>: no file named or shaped like a key or a login.
spl_cbr_key_files() {
  local d="$1" f n bad=0
  while IFS= read -r -d '' f; do
    n="${f##*/}"
    case "$n" in
      key-*.json | *.pem | *.key | *.p12 | id_rsa* | id_ed25519* | *credentials*.json | token)
        spl_cbr_refuse key-file "${f#"$d"/} is named like a key or a login"; bad=1; continue ;;
    esac
    if grep -qE '"private_key"|"type"[[:space:]]*:[[:space:]]*"service_account"|-----BEGIN [A-Z ]*PRIVATE KEY' "$f" 2>/dev/null; then
      spl_cbr_refuse key-file "${f#"$d"/} holds key material"; bad=1
    fi
  done < <(find "$d" -type f -print0)
  return "$bad"
}

# The estate keys, the GitHub token and our AI logins, as a task would read
# them. Comment lines are not read: a header may say what the set leaves out.
SPL_CBR_ESTATE_RX='\.gcp/|key-\{\{|key-csi-|GOOGLE_APPLICATION_CREDENTIALS|GITHUB_TOKEN|GH_TOKEN|\.github/token|gh auth login|controller_home|lookup\(.env.|\.credentials\.json|\.claude\.json|ANTHROPIC_API_KEY|OPENAI_API_KEY|XAI_API_KEY|MISTRAL_API_KEY|DASHSCOPE_API_KEY|setup-token|claude login|g[c]loud auth|\.ssh/id_'

# spl_cbr_estate_refs <dir>: no task line names one of them.
spl_cbr_estate_refs() {
  local d="$1" hit bad=0
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    spl_cbr_refuse estate-ref "${hit#"$d"/}"; bad=1
  done < <(grep -rnE "$SPL_CBR_ESTATE_RX" "$d" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
  return "$bad"
}

# spl_cbr_runs <dir> <word> <check>: a non-comment line of the set runs <word>.
spl_cbr_runs() {
  grep -rhE "$2" "$1" 2>/dev/null | grep -vE '^[[:space:]]*#' | grep . >/dev/null && return 0
  spl_cbr_refuse "$3" "no task runs $2"
}
