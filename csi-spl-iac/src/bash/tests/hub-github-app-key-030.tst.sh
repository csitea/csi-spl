#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: spec 075 repo-edit T01 -- the GitHub App key's slot in step 030 and
#          the cnf block env.docs.repo_edit:
#          - cnf docs.repo_edit.secret_env maps SPOOL_GITHUB_APP_KEY to ONE
#            Secret Manager slot; 030 IMPORTS that slot (do_spl_gh_app_manifest
#            created it with the key) with the live slot's arguments (no
#            labels), so the import changes nothing, and has no version resource;
#          - the runtime SA reads the slot whether or not it is injected, and
#            the generic binding of 03 skips it (one member, managed once);
#          - SPOOL_GITHUB_APP_KEY is injected exactly while inject is "true";
#            it is never a plain env var nor an auth_secret_ids slot;
#          - the feature is OFF on dev and prd; the hub env carries every
#            SPOOL_HUB_DOCS_EDIT_* derived from the cnf (dev env cap 50);
#            SPOOL_HUB_DOCS_EDIT_GITHUB_REPO is step 017's github_repository.
#          CONTROL: a scratch render flips inject both ways; a missing tpl-gen
#          venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
ENVVAR=SPOOL_GITHUB_APP_KEY
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
TFD="$PROJ_ROOT/src/terraform/030-cloud-run-hub"

slot=$(yq -r ".env.docs.repo_edit.secret_env.$ENVVAR // \"\"" "$CNF/all.env.yaml")
[[ "$slot" == spool-hub-github-app-key ]] && pass "cnf maps $ENVVAR to the slot do_spl_gh_app_key_put fills" || fail "cnf slot: '${slot}'"
grep -q "sec=\"\${GH_APP_SECRET:-$slot}\"" "$PROJ_ROOT/src/bash/run/spl-gh-app-key-put.func.sh" \
  && pass "do_spl_gh_app_key_put defaults to the same slot" || fail "do_spl_gh_app_key_put names another slot"
n=$(yq -r '.env.docs.repo_edit.deny | length' "$CNF/all.env.yaml")
[[ "$n" == 23 ]] && pass "deny holds the 23 globs of spec 5.2 rows 1-13" || fail "deny has $n globs"

want="ENABLED GITHUB_APP_ID INSTALLATION_ID GITHUB_API DENY COALESCE_AFTER COALESCE_MAX RATE_MEMBER_PER_HOUR RATE_AGENT_PER_HOUR RATE_WORKSPACE_PER_DAY RATE_ENV_PER_DAY MIN_MEMBER_AGE BLOCKED_WORKSPACES GITHUB_REPO"
for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  j="$CNF/$env.env.json"
  [[ "$(yq -r '.env.docs.repo_edit.enabled' "$j")" == false ]] && pass "$env repo_edit is OFF" || fail "$env repo_edit.enabled is not false"
  inject=$(yq -r '.env.docs.repo_edit.inject // "false"' "$j")
  grep -qx "github_app_key_secret_id *= \"$slot\"" "$v" && pass "$env 030 imports $slot" || fail "$env github_app_key_secret_id is not $slot"
  grep -E '^auth_secret_ids ' "$v" | grep -F "\"$slot\"" >/dev/null && fail "$env $slot is also an auth slot (06 would create it)" || pass "$env $slot is not an auth_secret_ids slot"
  envline=$(grep -E '^environment_variables ' "$v")
  grep -qF "\"$ENVVAR\"" <<<"$envline" && fail "$env $ENVVAR is a plain env var" || pass "$env $ENVVAR is never a plain env var"
  miss=""
  for k in $want; do grep -qF "\"SPOOL_HUB_DOCS_EDIT_$k\": " <<<"$envline" || miss+=" $k"; done
  [[ -z "$miss" ]] && pass "$env hub env carries the 14 SPOOL_HUB_DOCS_EDIT_*" || fail "$env hub env lacks:$miss"
  repo=$(grep -E '^github_repository ' "$CNF/$env/tf/017-github-wif-deploy.vars.tfvars" | grep -oE '"[^"]+"')
  [[ "$repo" == *?/?* ]] && grep -qF "\"SPOOL_HUB_DOCS_EDIT_GITHUB_REPO\": $repo" <<<"$envline" \
    && pass "$env SPOOL_HUB_DOCS_EDIT_GITHUB_REPO = 017 github_repository $repo" || fail "$env SPOOL_HUB_DOCS_EDIT_GITHUB_REPO is not 017's '$repo'"
  secline=$(grep -E '^secret_environment_variables ' "$v")
  if [[ "$inject" == true ]]; then
    grep -qF "\"$ENVVAR\": \"$slot\"" <<<"$secline" && pass "$env inject=true: the service names $ENVVAR from $slot" || fail "$env inject=true but $ENVVAR not injected"
  else
    grep -qF "\"$ENVVAR\"" <<<"$secline" && fail "$env inject=false yet $ENVVAR injected" || pass "$env inject=false: slot only, $ENVVAR not referenced yet"
  fi
done
cap() { grep -E '^environment_variables ' "$CNF/$1/tf/030-cloud-run-hub.vars.tfvars" | grep -oE '"SPOOL_HUB_DOCS_EDIT_RATE_ENV_PER_DAY": "[0-9]+"' | grep -oE '[0-9]+'; }
[[ "$(cap dev)" == 50 && "$(cap prd)" == 300 ]] && pass "env cap: dev 50, prd 300" || fail "env cap: dev '$(cap dev)', prd '$(cap prd)'"

grep -q 'resource "google_secret_manager_secret_version"' "$TFD"/*.tf && fail "030 has a secret version resource" || pass "030 has no secret version resource (no value in state)"
f07="$TFD/07-github-app-key.tf"
grep -qE '^import \{' "$f07" && grep -q 'to = google_secret_manager_secret.github_app_key' "$f07" \
  && pass "07 imports the existing slot" || fail "07 has no import block for the slot"
grep -q 'location = var.gcp_region' "$f07" && ! grep -qE '^\s*labels\s*=' "$f07" \
  && pass "07 matches the live slot (user-managed in the region, no labels): a no-op import" || fail "07 replication or labels drift from the live slot"
grep -q 'secretmanager.secretAccessor' "$f07" && grep -q 'google_service_account.hub.email' "$f07" \
  && pass "07 grants the hub runtime SA read on the slot" || fail "07 lacks the accessor binding"
grep -q 'setsubtract(toset(values(var.secret_environment_variables)), \[var.github_app_key_secret_id\])' "$TFD/03-runtime-sa.tf" \
  && pass "03's generic binding skips the slot (bound once, in 07)" || fail "03 would bind the slot twice"

# --- control: inject flips the reference, never the slot ---------------------
TPG="$APP_ROOT/tpl-gen/src/python/tpl-gen"
if [[ -x "$TPG/.venv/bin/python" ]]; then
  tmp=$(mktemp -d)
  # shellcheck disable=SC1091
  source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"
  do_spl_merged_cnf "$CNF" dev "$tmp/dev.env.yaml"
  render() { (cd "$TPG" && TPL="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl" CNF="$tmp/dev.env.yaml" \
    .venv/bin/python -c '
import os, yaml, jinja2
cnf = yaml.safe_load(open(os.environ["CNF"]))["env"]
tpl = jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(open(os.environ["TPL"]).read())
print(tpl.render(**{**cnf, "ORG": "csi", "APP": "spl", "ENV": "dev"}))' 2>&1); }
  yq -i '.env.docs.repo_edit.inject = "false"' "$tmp/dev.env.yaml"
  out=$(render)
  ! grep -E '^secret_environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\"" >/dev/null && grep -qx "github_app_key_secret_id *= \"$slot\"" <<<"$out" \
    && pass "control: inject=false keeps the slot and references nothing" || fail "control inject=false: $(head -c 300 <<<"$out")"
  yq -i '.env.docs.repo_edit.inject = "true"' "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^secret_environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\": \"$slot\"" >/dev/null \
    && pass "control: inject=true names $ENVVAR from $slot" || fail "control inject=true: $(head -c 300 <<<"$out")"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $TPG (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
