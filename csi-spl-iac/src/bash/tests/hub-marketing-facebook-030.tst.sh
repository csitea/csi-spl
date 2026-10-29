#!/usr/bin/env bash
# pre-push-tier: slow -- its control render needs the tpl-gen venv (CI runs do_setup_tpl_gen)
#------------------------------------------------------------------------------
# Purpose: spec 090 T030 (SPL-4164) -- Facebook Page + Instagram publishing
#          reuses the sign-in Meta app (spec 049): cnf marketing.facebook names
#          the sign-in secret slot, 030 creates no second slot, and while
#          marketing.facebook.inject is "true" the hub gets
#          SPOOL_HUB_MARKETING_FACEBOOK_APP_ID (= the sign-in client id),
#          _API_VERSION, _SCOPES and _CLIENT_SECRET (the same slot, pinned).
#          CONTROL: the committed cnf keeps inject "false", so "nothing is
#          injected" proves nothing alone; a scratch render with inject "true"
#          must inject exactly those four, and the same render without
#          client_secret_secret or the sign-in client id must fail.
#          A missing tpl-gen venv is a SKIP.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
skip() { echo "SKIP: $1"; }

CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
fb_slot=$(yq -r '.env.marketing.facebook.client_secret_secret // ""' "$CNF/all.env.yaml")
signin_slot=$(yq -r '.env.auth.social.secret_env.SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET // ""' "$CNF/all.env.yaml")
[[ -n "$fb_slot" && "$fb_slot" == "$signin_slot" ]] \
  && pass "cnf marketing.facebook reuses the sign-in Meta app secret slot ($signin_slot)" \
  || fail "cnf marketing.facebook.client_secret_secret '$fb_slot' is not the sign-in slot '$signin_slot'"
for k in api_version scopes inject; do
  [[ -n "$(yq -r ".env.marketing.facebook.$k // \"\"" "$CNF/all.env.yaml")" ]] \
    && pass "cnf marketing.facebook.$k is set" || fail "cnf marketing.facebook.$k missing"
done

for env in dev prd; do
  v="$CNF/$env/tf/030-cloud-run-hub.vars.tfvars"
  grep -E '^auth_secret_ids ' "$v" | grep 'marketing-facebook' >/dev/null \
    && fail "$env 030 creates a second Meta secret slot" || pass "$env 030 creates no second Meta secret slot"
  inj=$(yq -r '.env.marketing.facebook.inject // "false"' "$CNF/$env.env.json")
  if [[ "$inj" != true ]]; then
    grep -qE '^(environment_variables|secret_environment_variables) .*SPOOL_HUB_MARKETING_FACEBOOK_' "$v" \
      && fail "$env inject=$inj but 030 hands the hub SPOOL_HUB_MARKETING_FACEBOOK_*" \
      || pass "$env inject=$inj: no SPOOL_HUB_MARKETING_FACEBOOK_* reaches the hub"
  fi
done

# --- control: inject=true hands the hub exactly the reused app ----------------
TPG="${TPL_GEN_PATH:-$APP_ROOT/tpl-gen}/src/python/tpl-gen"
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
  line() { grep -E "^$1 " <<<"$2" | cut -d= -f2-; }
  yq -i '.env.marketing.facebook.inject = "false"' "$tmp/dev.env.yaml"
  off=$(render)
  yq -i '.env.marketing.facebook.inject = "true"' "$tmp/dev.env.yaml"
  cp "$tmp/dev.env.yaml" "$tmp/on.yaml"
  on=$(render)
  app_id=$(yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID' "$tmp/dev.env.yaml")
  inv=$(python3 - "$(line environment_variables "$on")" "$(line secret_environment_variables "$on")" "$(line secret_environment_variables "$off")" "$(line secret_versions "$on")" "$app_id" "$signin_slot" <<'PY'
import json, sys
env, sec, sec_off, ver = (json.loads(a) for a in sys.argv[1:5])
app_id, slot = sys.argv[5], sys.argv[6]
bad = []
fb_env = {k: v for k, v in env.items() if k.startswith("SPOOL_HUB_MARKETING_FACEBOOK_")}
if set(fb_env) != {"SPOOL_HUB_MARKETING_FACEBOOK_APP_ID", "SPOOL_HUB_MARKETING_FACEBOOK_API_VERSION", "SPOOL_HUB_MARKETING_FACEBOOK_SCOPES"}: bad.append(f"env {sorted(fb_env)}")
if fb_env.get("SPOOL_HUB_MARKETING_FACEBOOK_APP_ID") != app_id: bad.append("APP_ID is not the sign-in client id")
added = {k: v for k, v in sec.items() if k not in sec_off}
if added != {"SPOOL_HUB_MARKETING_FACEBOOK_CLIENT_SECRET": slot}: bad.append(f"secrets added {added}")
if slot not in ver: bad.append(f"{slot} has no pinned version")
print("ok" if not bad else "; ".join(bad))
PY
)
  [[ "$inv" == ok ]] && pass "control: inject=true hands the hub the sign-in app id, api version, scopes and the same pinned secret" \
    || fail "control: inject=true: $inv ($(head -c 300 <<<"$on"))"
  [[ "$(line auth_secret_ids "$on")" == "$(line auth_secret_ids "$off")" ]] \
    && pass "control: inject=true creates no new secret slot" || fail "control: inject=true changed auth_secret_ids"
  # red controls: the render must refuse a block that does not name the reused app
  yq -i 'del(.env.marketing.facebook.client_secret_secret)' "$tmp/dev.env.yaml"
  grep -qE '^secret_environment_variables ' <<<"$(render)" \
    && fail "red control: inject=true without client_secret_secret still rendered" \
    || pass "red control: inject=true without client_secret_secret fails the render"
  cp "$tmp/on.yaml" "$tmp/dev.env.yaml"
  yq -i 'del(.env.auth.social.env.SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID)' "$tmp/dev.env.yaml"
  grep -qE '^secret_environment_variables ' <<<"$(render)" \
    && fail "red control: inject=true without the sign-in client id still rendered" \
    || pass "red control: inject=true without the sign-in client id fails the render"
  rm -rf "$tmp"
else
  skip "no tpl-gen venv at $TPG (control render)"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
