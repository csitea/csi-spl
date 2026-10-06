#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: B18. do_gcp_sm_secrets_to_env_file was a dead csi-rel port.
#          Nothing called it. It truncated
#          ${APP_PATH}/${ORG}-${APP}-api/backend_api/djangorest/.env
#          (that directory is not in this tree) and activated
#          key-sa-ci-${ORG}-${APP}-${ENV}-bck_srvs.json, which is not the
#          per-env key-<project>.json name. The action file is gone, no
#          production shell still names the path, the key or the function,
#          and the run loader still registers the other actions.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

dead_rel="csi-spl-iac/src/bash/run/gcp-sm-secrets-to-env-file.func.sh"
if [[ -e "$APP_ROOT/$dead_rel" ]]; then
  fail "dead action file is still present ($dead_rel)"
else
  pass "dead action file is gone"
fi

if [[ -d "$APP_ROOT/csi-spl-api/backend_api" ]]; then
  fail "csi-spl-api/backend_api exists, so the old target may be live"
else
  pass "csi-spl-api/backend_api is absent"
fi

search=()
for d in \
  "$APP_ROOT/csi-spl-iac/src/bash" \
  "$APP_ROOT/csi-spl-iac/lib/bash" \
  "$APP_ROOT/csi-spl-orc/src/bash" \
  "$APP_ROOT/csi-spl-orc/lib/bash" \
  "$APP_ROOT/csi-spl-cnf/src/bash"
do
  [[ -d "$d" ]] && search+=("$d")
done
hits=$(grep -R -l -F \
  -e 'backend_api/djangorest' \
  -e 'bck_srvs.json' \
  -e 'do_gcp_sm_secrets_to_env_file' \
  --include='*.sh' --include='*.func.sh' \
  "${search[@]}" 2>/dev/null | grep -v '/tests/' || true)
if [[ -z "$hits" ]]; then
  pass "no production shell names the dead path, key or function"
else
  fail "production shell still names the dead action: ${hits}"
fi

run_sh="$PROJ_ROOT/src/bash/run/run.sh"
map_out=$(bash -c '
  source <(sed "/^main \"\$@\"$/d" "$0")
  do_set_vars >/dev/null 2>&1 || true
  do_load_functions >/dev/null 2>&1
  printf "%s\n" "${!_func_to_file[@]}"
' "$run_sh")
n_actions=$(grep -c '^do_' <<<"$map_out" || true)
if grep -qx 'do_gcp_sm_secrets_to_env_file' <<<"$map_out"; then
  fail "loader still registers do_gcp_sm_secrets_to_env_file"
else
  pass "loader does not register do_gcp_sm_secrets_to_env_file"
fi
if grep -qx 'do_print_help' <<<"$map_out" && grep -qx 'do_check_dist_hygiene' <<<"$map_out"; then
  pass "loader still registers do_print_help and do_check_dist_hygiene"
else
  fail "loader did not register do_print_help and do_check_dist_hygiene"
fi
if [[ "$n_actions" -ge 100 ]]; then
  pass "loader registered $n_actions actions"
else
  fail "loader registered only $n_actions actions"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"
exit 1
