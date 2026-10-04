#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: spec 065 L4 -- the hub's Cloud Run service NAMES the release-note
#          bans env SPOOL_HUB_RELEASE_NOTE_BANS, and never carries its value:
#          - cnf hub.release_note_bans.secret_env maps the env to ONE Secret
#            Manager slot; 030 creates that slot empty in dev and prd (no
#            version resource, so no value in tfvars or state);
#          - the env is never a plain environment variable; it is injected
#            from the slot exactly while hub.release_note_bans.inject is
#            "true" (Cloud Run refuses a version-less secret), and then the
#            runtime SA reads that slot (03 binds every injected secret).
#          CONTROL: a scratch render flips inject both ways; a missing tpl-gen
#          venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }
ENVVAR=SPOOL_HUB_RELEASE_NOTE_BANS

CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
slot=$(yq -r ".env.hub.release_note_bans.secret_env.$ENVVAR // \"\"" "$CNF/all.env.yaml")
[[ "$slot" =~ ^csi-spl-hub-[a-z-]+$ ]] && pass "cnf maps $ENVVAR to one Secret Manager slot" || fail "cnf slot: '${slot}'"
grep -q "\"$ENVVAR\"" "$APP_ROOT/csi-spl-api/src/go/spool-hub-api/internal/hub/release_notes.go" \
  && pass "the hub reads exactly $ENVVAR (release_notes.go ReleaseNoteBansEnv)" || fail "release_notes.go does not name $ENVVAR"

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  inject=$(yq -r '.env.hub.release_note_bans.inject // "false"' "$CNF/$env.env.json")
  grep -E '^auth_secret_ids ' "$v" | grep -F "\"$slot\"" >/dev/null && pass "$env 030 creates the $slot slot" || fail "$env auth_secret_ids lacks $slot"
  grep -E '^environment_variables ' "$v" | grep -F "\"$ENVVAR\"" >/dev/null && fail "$env $ENVVAR is a plain env var" || pass "$env $ENVVAR is never a plain env var"
  secline=$(grep -E '^secret_environment_variables ' "$v")
  if [[ "$inject" == true ]]; then
    grep -qF "\"$ENVVAR\": \"$slot\"" <<<"$secline" && pass "$env inject=true: the service names $ENVVAR from $slot" || fail "$env inject=true but $ENVVAR not injected from $slot"
  else
    grep -qF "\"$ENVVAR\"" <<<"$secline" && fail "$env inject=false yet $ENVVAR injected (Cloud Run refuses a version-less secret)" || pass "$env inject=false: slot only, $ENVVAR not referenced yet"
  fi
done

TFD="$PROJ_ROOT/src/terraform/030-cloud-run-hub"
grep -q 'resource "google_secret_manager_secret_version"' "$TFD"/*.tf && fail "030 has a secret version resource" || pass "030 has no secret version resource (no value in state)"
grep -q 'for_each = toset(values(var.secret_environment_variables))' "$TFD/03-runtime-sa.tf" \
  && pass "030 grants the runtime SA every injected secret, this one included" || fail "03-runtime-sa.tf no longer binds every injected secret"

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
  yq -i '.env.hub.release_note_bans.inject = "false"' "$tmp/dev.env.yaml"
  out=$(render)
  ! grep -E '^secret_environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\"" >/dev/null && grep -E '^auth_secret_ids ' <<<"$out" | grep -F "\"$slot\"" >/dev/null \
    && pass "control: inject=false creates the slot and references nothing" || fail "control inject=false: $(head -c 300 <<<"$out")"
  yq -i '.env.hub.release_note_bans.inject = "true"' "$tmp/dev.env.yaml"
  out=$(render)
  grep -E '^secret_environment_variables ' <<<"$out" | grep -F "\"$ENVVAR\": \"$slot\"" >/dev/null \
    && pass "control: inject=true names $ENVVAR from $slot" || fail "control inject=true: $(head -c 300 <<<"$out")"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $TPG (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
