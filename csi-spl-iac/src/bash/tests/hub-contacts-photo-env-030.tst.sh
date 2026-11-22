#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 154 11.4 B16 (SPL-6276). The hub fetches a contact's picture
#          only from the hosts it is told, and keeps at most a cap per person:
#          SPOOL_HUB_CONTACTS_PHOTO_HOSTS (comma separated, the hub's
#          envSeparator; none = nothing is fetched) and
#          SPOOL_HUB_CONTACTS_PHOTO_MAX_PER_PERSON (code default 2000), from
#          cnf contacts.photo_hosts and contacts.photo_max_per_person. This
#          test proves the chain cnf -> tfvars:
#            1. the rendered dev and prd 030 tfvars carry both vars in
#               environment_variables, equal to the cnf (the env file's value,
#               else all.env.yaml's; the hosts joined with commas);
#            2. the tpl-gen template renders both vars.
#          030 passes environment_variables whole into hub_env, so no new
#          terraform variable is needed.
#          RED CONTROLS, each on a copy: a template without the photo line, a
#          tfvars without the hosts var, a tfvars with another cap, a tfvars
#          naming a host the cnf does not list: every one fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
tmp_dir
TPL="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"

# cnf_get <env> <yq expr under env.contacts>: the env file's value, else all's
cnf_get() {
  local v
  v="$(yq -r ".env.contacts.$2 // \"\"" "$CNF/$1.env.yaml")"
  [[ -n "$v" && "$v" != null ]] || v="$(yq -r ".env.contacts.$2 // \"\"" "$CNF/all.env.yaml")"
  [[ "$v" == null ]] && v=""
  printf '%s' "$v"
}

# hosts_get <env>: cnf contacts.photo_hosts joined with commas, the env file's
# list when it sets one (an empty list included), else all.env.yaml's
hosts_get() {
  local f="$CNF/$1.env.yaml"
  [[ "$(yq -r '.env.contacts | has("photo_hosts")' "$f")" == true ]] || f="$CNF/all.env.yaml"
  yq -r '.env.contacts.photo_hosts // [] | join(",")' "$f"
}

# tfvars_gaps <env> <tfvars>: why the tfvars do not carry cnf's two values
tfvars_gaps() {
  local env="$1" v="$2" hosts cap line
  hosts="$(hosts_get "$env")"
  cap="$(cnf_get "$env" photo_max_per_person)"
  [[ -n "$cap" ]] || { echo "no contacts.photo_max_per_person in the $env cnf"; return 0; }
  line="$(grep -E '^environment_variables +=' "$v")"
  grep -qF "\"SPOOL_HUB_CONTACTS_PHOTO_HOSTS\": \"$hosts\"" <<<"$line" || echo "SPOOL_HUB_CONTACTS_PHOTO_HOSTS is not '$hosts'"
  grep -qF "\"SPOOL_HUB_CONTACTS_PHOTO_MAX_PER_PERSON\": \"$cap\"" <<<"$line" || echo "SPOOL_HUB_CONTACTS_PHOTO_MAX_PER_PERSON is not '$cap'"
  return 0
}

# tpl_gaps <template>: the photo vars the template does not render
tpl_gaps() {
  local k
  for k in HOSTS MAX_PER_PERSON; do
    grep -qE "run_env\.update\(.*\"SPOOL_HUB_CONTACTS_PHOTO_$k\": " "$1" || echo "the template renders no SPOOL_HUB_CONTACTS_PHOTO_$k"
  done
  return 0
}

verdict() { # <label> <reasons>
  [[ -z "$2" ]] && pass "$1" || fail "$1: $(tr '\n' ';' <<<"$2")"
}

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  if [[ ! -f "$v" ]]; then fail "1. $env: no $v (ENV=$env ./run -a do_tpl_gen)"; continue; fi
  verdict "1. $env 030 tfvars carry cnf contacts.photo_hosts and photo_max_per_person" "$(tfvars_gaps "$env" "$v")"
done
verdict "2. the 030 template renders both contact-picture vars" "$(tpl_gaps "$TPL")"

# --- RED CONTROLS -------------------------------------------------------------
cp "$TPL" "$T/no-photo.tpl"
sed -i -E '/"SPOOL_HUB_CONTACTS_PHOTO_MAX_PER_PERSON": /d' "$T/no-photo.tpl"
[[ -n "$(tpl_gaps "$T/no-photo.tpl")" ]] && pass "CONTROL a template without the photo line is refused" ||
  fail "CONTROL a template without the photo line passed"
dev="$CNF/dev/tf/030-cloud-run-hub.vars.tfvars"
cp "$dev" "$T/no-hosts.tfvars"
sed -i -E 's/"SPOOL_HUB_CONTACTS_PHOTO_HOSTS": "[^"]*", //' "$T/no-hosts.tfvars"
[[ -n "$(tfvars_gaps dev "$T/no-hosts.tfvars")" ]] && pass "CONTROL a tfvars without the hosts var is refused" ||
  fail "CONTROL a tfvars without the hosts var passed"
cp "$dev" "$T/other-cap.tfvars"
sed -i -E 's/"SPOOL_HUB_CONTACTS_PHOTO_MAX_PER_PERSON": "[0-9]+"/"SPOOL_HUB_CONTACTS_PHOTO_MAX_PER_PERSON": "7"/' "$T/other-cap.tfvars"
[[ -n "$(tfvars_gaps dev "$T/other-cap.tfvars")" ]] && pass "CONTROL a tfvars with another cap is refused" ||
  fail "CONTROL a tfvars with another cap passed"
cp "$dev" "$T/extra-host.tfvars"
sed -i -E 's/"SPOOL_HUB_CONTACTS_PHOTO_HOSTS": "([^"]*)"/"SPOOL_HUB_CONTACTS_PHOTO_HOSTS": "\1,photos.example.com"/' "$T/extra-host.tfvars"
[[ -n "$(tfvars_gaps dev "$T/extra-host.tfvars")" ]] && pass "CONTROL a tfvars naming a host the cnf does not list is refused" ||
  fail "CONTROL a tfvars with an extra host passed"

[[ $fails -eq 0 ]] && echo "PASS: all $(basename "$0") assertions" || { echo "FAIL: $fails"; exit 1; }
