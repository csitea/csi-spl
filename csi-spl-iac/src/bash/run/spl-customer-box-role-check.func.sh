#!/bin/bash
#------------------------------------------------------------------------------
# @description Spec 181 row B6 (spec 122 4 point 4): prove the customer box
# @description role set (src/ansible/customer-box) carries nothing of ours that
# @description a private workspace's VM must never get. READ ONLY: it reads the
# @description role set's files and runs nothing on any box. It refuses:
# @description   link        any symlink in the set (it could point at a key)
# @description   vault       an Ansible Vault file (its content is unreadable)
# @description   key-file    a file shaped like a key or a login: its name
# @description               (key-*.json, *.pem, *.key, *.p12, id_rsa*, id_dsa*,
# @description               id_ecdsa*, id_ed25519*, *credentials*.json,
# @description               *token*, .netrc, auth.json, oauth_creds.json) or its
# @description               content (a service account in JSON or YAML, a PEM
# @description               private key, a GitHub or vendor API token)
# @description   estate-ref  a task line that reads an estate key, a GitHub
# @description               token or an AI login of ours (the gcp key dir, the
# @description               controller's env or files, gh, gcloud, a CLI
# @description               credentials file, a vendor API key variable)
# @description   ws-setup    no task calls ./run -a do_spl_box_workspace_setup
# @description   checks      no task calls spl_desk_start_checks (127 5.3)
# @description   when-false  a task switched off with when: false
# @description One "REFUSED <check>: <why>" line per finding, then exit 1.
# @description It is a ban list: it cannot prove absence. It never sees the
# @description inventory, host_vars or extra-vars kept outside the set, a path
# @description built from variables at run time, the content of an archive, or
# @description anything Ansible decrypts; review stays the check for those.
# @param CUSTOMER_BOX_ROLE_DIR (optional) - the role set to check; default src/ansible/customer-box of this tree
# @example ./run -a do_spl_customer_box_role_check
# @example CUSTOMER_BOX_ROLE_DIR=<dir> ./run -a do_spl_customer_box_role_check
#------------------------------------------------------------------------------
do_spl_customer_box_role_check() {
  local d="${CUSTOMER_BOX_ROLE_DIR:-${PROJ_PATH}/src/ansible/customer-box}" bad=0 pb
  pb="$d/customer-box-playbook.yaml"
  [[ -f "$pb" ]] || { do_log "FATAL no role set at $d (want customer-box-playbook.yaml)"; return 1; }
  spl_cbr_links "$d" || bad=1
  spl_cbr_key_files "$d" || bad=1
  spl_cbr_estate_refs "$d" || bad=1
  spl_cbr_runs "$d" '\./run -a do_spl_box_workspace_setup' ws-setup || bad=1
  spl_cbr_runs "$d" '^[[:space:]]*spl_desk_start_checks ' checks || bad=1
  spl_cbr_when_false "$d" || bad=1
  (( bad == 0 )) || { do_log "FATAL the customer box role set at $d carries an estate key or AI login, or skips a required step (spec 181 B6)"; return 1; }
  do_log "OK the customer box role set at $d: no estate key, no AI login of ours; it runs do_spl_box_workspace_setup and the 127 5.3 checks"
}

spl_cbr_refuse() { do_log "REFUSED $1: $2"; return 1; }

# spl_cbr_links <dir>: no symlink anywhere in the set.
spl_cbr_links() {
  local d="$1" f bad=0
  while IFS= read -r -d '' f; do
    spl_cbr_refuse link "${f#"$d"/} is a symlink (to $(readlink "$f"))"; bad=1
  done < <(find "$d" -type l -print0)
  return "$bad"
}

# Key material by content: a service account (JSON or YAML), a PEM private
# key, a GitHub token, a vendor API key.
SPL_CBR_KEY_CONTENT_RX='"?private_key"?[[:space:]]*:|service_account|-----BEGIN [A-Z ]*PRIVATE KEY|\b(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|sk-ant-[A-Za-z0-9_-]{10,}|\bsk-[A-Za-z0-9_-]{20,}|\bxai-[A-Za-z0-9]{20,}|\bAIza[A-Za-z0-9_-]{30,}'

# spl_cbr_key_files <dir>: no vault file, no file named or shaped like a key.
spl_cbr_key_files() {
  local d="$1" f n bad=0
  while IFS= read -r -d '' f; do
    n="${f##*/}"
    if head -c 14 "$f" 2>/dev/null | grep -F '$ANSIBLE_VAULT' >/dev/null; then
      spl_cbr_refuse vault "${f#"$d"/} is an Ansible Vault file"; bad=1; continue
    fi
    case "$n" in
      key-*.json | *.pem | *.key | *.p12 | id_rsa* | id_dsa* | id_ecdsa* | id_ed25519* | *credentials*.json | *token* | .netrc | auth.json | oauth_creds.json)
        spl_cbr_refuse key-file "${f#"$d"/} is named like a key or a login"; bad=1; continue ;;
    esac
    if grep -qE "$SPL_CBR_KEY_CONTENT_RX" "$f" 2>/dev/null; then
      spl_cbr_refuse key-file "${f#"$d"/} holds key material"; bad=1
    fi
  done < <(find "$d" -type f -print0)
  return "$bad"
}

# The estate keys, the GitHub token and our AI logins, as a task would read
# them, and any task run on the controller. Comment lines are not read: a
# header may say what the set leaves out.
SPL_CBR_ESTATE_RX='\.gcp/|key-\{\{|key-csi-|GOOGLE_APPLICATION_CREDENTIALS|application_default_credentials|\.config/g[c]loud|\.config/gh\b|GITHUB_TOKEN|GH_TOKEN|\.github/token|gh auth|controller_home|lookup\([^)]*env|ansible_env|delegate_to:[[:space:]]*(localhost|127\.)|local_action|connection:[[:space:]]*local|\.credentials\.json|\.claude\.json|\.claude/|\.codex/|\.gemini/|\.qwen/|\.vibe/|\.grok/|oauth_creds|auth\.json|\.netrc|\.aws/|ANTHROPIC_API_KEY|OPENAI_API_KEY|XAI_API_KEY|MISTRAL_API_KEY|DASHSCOPE_API_KEY|GEMINI_API_KEY|setup-token|claude login|g[c]loud auth|\.ssh/id_'

# spl_cbr_estate_refs <dir>: no task line names one of them.
spl_cbr_estate_refs() {
  local d="$1" hit bad=0
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    spl_cbr_refuse estate-ref "${hit#"$d"/}"; bad=1
  done < <(grep -rnE "$SPL_CBR_ESTATE_RX" "$d" 2>/dev/null | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#')
  return "$bad"
}

# spl_cbr_runs <dir> <call rx> <check>: a non-comment line calls it (a
# task's name: line does not count).
spl_cbr_runs() {
  grep -rhE "$2" "$1" 2>/dev/null | grep -vE '^[[:space:]]*(#|- name:|name:)' | grep . >/dev/null && return 0
  spl_cbr_refuse "$3" "no task calls $2"
}

# spl_cbr_when_false <dir>: no task is switched off.
spl_cbr_when_false() {
  local d="$1" hit bad=0
  while IFS= read -r hit; do
    [[ -n "$hit" ]] || continue
    spl_cbr_refuse when-false "${hit#"$d"/}"; bad=1
  done < <(grep -rnE '^[[:space:]]*when:[[:space:]]*(false|no|False|"false"|0)[[:space:]]*$' "$d" 2>/dev/null)
  return "$bad"
}
