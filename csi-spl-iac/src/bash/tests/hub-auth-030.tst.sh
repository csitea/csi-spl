#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 010 T020/T021 -- 030 renders cnf env.auth.social into the hub:
#          the plain auth env joins environment_variables, no auth secret is a
#          plain env var, only the session key + the LISTED providers' secrets
#          are injected from Secret Manager, and 030 creates every auth slot
#          empty (no version resource).
#          CONTROL: the committed cnf lists no provider, so "no auth secret is
#          injected" proves nothing alone; a scratch render with
#          SPOOL_HUB_AUTH_PROVIDERS=google,xai must inject exactly the session
#          key + those two secrets. A missing tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
skip() { echo "SKIP: $1"; }

CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
slots=$(yq -r '(.env.auth.social.secret_env, .env.mail.secret_env) | to_entries | .[].value' "$CNF/all.env.yaml" | sort | tr '\n' ' ')
[[ "$(wc -w <<<"$slots")" -eq 7 ]] && pass "cnf names 7 secret slots (session key + 5 IdPs + SMTP password)" || fail "cnf secret slots: $slots"

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  envline=$(grep -E '^environment_variables ' "$v")
  secline=$(grep -E '^secret_environment_variables ' "$v")
  grep -q '"SPOOL_HUB_AUTH_PROVIDERS": ""' <<<"$envline" && pass "$env hub env carries SPOOL_HUB_AUTH_PROVIDERS (auth off)" || fail "$env hub env lacks SPOOL_HUB_AUTH_PROVIDERS"
  for p in GOOGLE FACEBOOK MICROSOFT LINKEDIN XAI; do
    grep -q "\"SPOOL_HUB_AUTH_${p}_REDIRECT_URI\": \"https://" <<<"$envline" \
      && pass "$env hub env carries the $p https redirect URI" || fail "$env hub env lacks the $p redirect URI"
  done
  grep -qE 'SESSION_KEY|CLIENT_SECRET' <<<"$envline" && fail "$env an auth secret is a plain env var" || pass "$env no auth secret is a plain env var"
  grep -q 'SPOOL_HUB_AUTH' <<<"$secline" && fail "$env injects an auth secret while no provider is listed" || pass "$env injects no auth secret while no provider is listed"
  got=$(grep -E '^auth_secret_ids ' "$v" | grep -oE 'csi-spl-hub-(auth|mail)-[a-z-]+' | sort | tr '\n' ' ')
  [[ "$got" == "$slots" ]] && pass "$env 030 creates all 7 slots" || fail "$env auth_secret_ids: $got"
done

TFD="$PROJ_ROOT/src/terraform/030-cloud-run-hub"
grep -q 'resource "google_secret_manager_secret" "auth"' "$TFD"/*.tf && pass "030 declares the auth slots" || fail "030 has no auth slot resource"
grep -q 'resource "google_secret_manager_secret_version"' "$TFD"/*.tf && fail "030 has a secret version resource" || pass "030 has no secret version resource"

# --- control: a listed provider set injects exactly its secrets ---------------
TPG="$APP_ROOT/tpl-gen/src/python/tpl-gen"
if [[ -x "$TPG/.venv/bin/python" ]]; then
  tmp=$(mktemp -d)
  # shellcheck disable=SC1091
  source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"
  do_spl_merged_cnf "$CNF" dev "$tmp/dev.env.yaml"
  render() { (cd "$TPG" && ENV=dev TPL="$PROJ_ROOT/src/tpl/%org%-%app%/%env%/tf/030-cloud-run-hub.vars.tfvars.tpl" CNF="$tmp/dev.env.yaml" \
    .venv/bin/python -c '
import os, yaml, jinja2
cnf = yaml.safe_load(open(os.environ["CNF"]))["env"]
tpl = jinja2.Environment(undefined=jinja2.StrictUndefined).from_string(open(os.environ["TPL"]).read())
print(tpl.render(**{**cnf, "ORG": "csi", "APP": "spl", "ENV": "dev"}))' 2>&1); }
  injected() { grep -E '^secret_environment_variables ' <<<"$1" | grep -oE '"SPOOL_HUB_[A-Z_]+"' | sort | tr '\n' ' '; }
  cp "$tmp/dev.env.yaml" "$tmp/base.yaml"
  yq -i '.env.auth.social.env.SPOOL_HUB_AUTH_PROVIDERS = "google, xai"' "$tmp/dev.env.yaml"
  out=$(render); sec=$(injected "$out")
  want='"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET" "SPOOL_HUB_AUTH_SESSION_KEY" "SPOOL_HUB_AUTH_XAI_CLIENT_SECRET" "SPOOL_HUB_DB_DSN" '
  [[ "$sec" == "$want" ]] && pass "control: providers=google,xai injects the session key + exactly those two secrets" \
    || fail "control: providers=google,xai injected: ${sec:-<nothing>} ($(head -c 300 <<<"$out"))"
  # spec 015: native sign-in on with no IdP listed still needs the session key;
  # SMTP transport injects the relay password, and both plain blocks reach env
  cp "$tmp/base.yaml" "$tmp/dev.env.yaml"
  yq -i '.env.auth.native.env.SPOOL_HUB_AUTH_NATIVE_ENABLED = "true" | .env.mail.env.SPOOL_HUB_MAIL_TRANSPORT = "smtp"' "$tmp/dev.env.yaml"
  out=$(render); sec=$(injected "$out")
  want='"SPOOL_HUB_AUTH_SESSION_KEY" "SPOOL_HUB_DB_DSN" "SPOOL_HUB_MAIL_SMTP_PASSWORD" '
  [[ "$sec" == "$want" ]] && grep -E '^environment_variables ' <<<"$out" | grep -q '"SPOOL_HUB_MAIL_TRANSPORT": "smtp"' \
    && pass "control: native on + smtp injects the session key + SMTP password, plain mail env rendered" \
    || fail "control: native on + smtp injected: ${sec:-<nothing>} ($(head -c 300 <<<"$out"))"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $TPG (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
