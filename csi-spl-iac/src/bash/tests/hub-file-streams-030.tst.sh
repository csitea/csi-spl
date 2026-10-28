#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 160 3.7 (row B7, SPL-3888) -- the hub's file stream caps are
#          ONE cnf block, env.hub.file_streams; do_spl_merged_cnf derives
#          SPOOL_HUB_FILE_STREAMS_<KEY> from every key of it, the hub reads
#          exactly those names (config.go), and the rendered 030 tfvars of dev
#          and prd carry each value from cnf.
#          CONTROL: a scratch cnf with a changed value and an extra key; the
#          extra key has no hub field, so the name check goes red on it.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
CFG="$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/config/config.go"
# shellcheck disable=SC1091
source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"

# unread_names <merged yaml>: the SPOOL_HUB_FILE_STREAMS_* names config.go does not read
unread_names() {
  local n
  for n in $(yq -r '.env.hub.env | keys | .[] | select(test("^SPOOL_HUB_FILE_STREAMS_"))' "$1"); do
    grep -qF "env:\"$n\"" "$CFG" || echo "$n"
  done
}

keys=$(yq -r '.env.hub.file_streams | keys | .[]' "$CNF/all.env.yaml")
[[ $(wc -w <<<"$keys") -eq 6 ]] && pass "env.hub.file_streams has the 6 caps of spec 160 3.7" \
  || fail "env.hub.file_streams keys: $(tr '\n' ' ' <<<"$keys")"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for env in dev prd; do
  do_spl_merged_cnf "$CNF" "$env" "$tmp/$env.yaml" || { fail "$env: do_spl_merged_cnf"; continue; }
  miss=$(unread_names "$tmp/$env.yaml")
  [[ -z "$miss" ]] && pass "$env: the hub reads every SPOOL_HUB_FILE_STREAMS_<KEY> (config.go)" \
    || fail "$env: config.go does not read: $miss"
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  for k in $keys; do
    n="SPOOL_HUB_FILE_STREAMS_${k^^}"
    want=$(yq -r ".env.hub.file_streams.$k" "$tmp/$env.yaml")
    grep -E '^environment_variables ' "$v" | grep -F "\"$n\": \"$want\"" >/dev/null \
      && pass "$env 030 carries $n=\"$want\" from cnf" || fail "$env 030 lacks $n=\"$want\" (re-render: ENV=$env ./run -a do_tpl_gen)"
  done
done

# --- control: a changed value is derived; a key the hub has no field for is caught
cp "$CNF/all.env.yaml" "$tmp/all.env.yaml"
cp "$CNF/dev.env.yaml" "$tmp/dev.env.yaml"
yq -i '.env.hub.file_streams.max_workspaces = 2 | .env.hub.file_streams.not_a_cap = 1' "$tmp/all.env.yaml"
do_spl_merged_cnf "$tmp" dev "$tmp/ctl.yaml"
[[ $(yq -r '.env.hub.env.SPOOL_HUB_FILE_STREAMS_MAX_WORKSPACES' "$tmp/ctl.yaml") == 2 ]] \
  && pass "control: a changed cap reaches SPOOL_HUB_FILE_STREAMS_MAX_WORKSPACES" || fail "control: max_workspaces 2 not derived"
[[ $(unread_names "$tmp/ctl.yaml") == SPOOL_HUB_FILE_STREAMS_NOT_A_CAP ]] \
  && pass "control: a cnf key with no hub field is reported" || fail "control: the unread name check missed NOT_A_CAP"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
