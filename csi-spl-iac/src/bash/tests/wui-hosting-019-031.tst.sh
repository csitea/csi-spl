#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 007 §3/§4 (T072-T076). The WUI is served THROUGH the 031 load
#          balancer: <fqdn> and *.<fqdn> send every path except the hub paths
#          to the 019 Firebase site (internet NEG, Host rewritten), so 019
#          binds no custom domain by default; the hub Cloud Armor policy can
#          add L7 host + path deny rules. dev has both on, prd both off until
#          the owner says so (OQ-H1, OQ-H2).
#          The Host regex is evaluated by terraform itself (console) and
#          checked against names that must pass and names that must be
#          refused; a missing terraform is a FAIL unless SPL_TF_ALLOW_SKIP=1.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
TFD="$PROJ_ROOT/src/terraform"
CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# --- 019: the site, and a custom domain only on request -----------------------
grep -qE '^\s*count\s*=\s*var[.]bind_custom_domain \? 1 : 0' "$TFD/019-firebase-static-site/03-firebase-site.tf" \
  && pass "019 custom domain is gated by bind_custom_domain" || fail "019 custom domain is not gated"
for env in dev prd; do
  grep -qx 'bind_custom_domain = false' "$CNF/$env/tf/019-firebase-static-site.vars.tfvars" \
    && pass "$env 019 binds no custom domain (the 031 LB fronts the site)" || fail "$env 019 bind_custom_domain is not false"
done

# --- 031: the WUI route --------------------------------------------------------
lb="$TFD/031-gcp-hub-ingress/05-load-balancer.tf"
grep -q 'host_rewrite = var.wui_origin_host' "$lb" && pass "031 rewrites Host to the Firebase site" || fail "031 has no host_rewrite"
grep -q 'hosts        = \[var.fqdn, "\*.${var.fqdn}"\]' "$lb" \
  && pass "031 WUI route covers <fqdn> and *.<fqdn> only (extra hosts stay hub-only)" || fail "031 WUI host_rule"
grep -q 'network_endpoint_type = "INTERNET_FQDN_PORT"' "$TFD/031-gcp-hub-ingress/08-wui-origin.tf" \
  && pass "031 WUI origin is an internet FQDN NEG" || fail "031 WUI NEG type"
grep -q 'security_policy' "$TFD/031-gcp-hub-ingress/08-wui-origin.tf" \
  && fail "031 WUI backend carries a security policy (static files are public)" || pass "031 WUI backend has no security policy"
# WebSockets must stay on the hub: both live under /v1/*.
grep -A4 'variable "hub_paths"' "$TFD/031-gcp-hub-ingress/02-variables.tf" | grep -q '"/v1/\*", "/api/\*", "/healthz", "/version"' \
  && pass "031 hub_paths default keeps /v1/* (ws + wui ws), /api/*, /healthz, /version on the hub" || fail "031 hub_paths default"

site_dev=$(sed -n 's/^site_id = "\(.*\)"$/\1/p' "$CNF/dev/tf/019-firebase-static-site.vars.tfvars")
grep -qx "wui_origin_host = \"$site_dev.web.app\"" "$CNF/dev/tf/031-gcp-hub-ingress.vars.tfvars" \
  && pass "dev 031 WUI origin is the dev 019 site ($site_dev.web.app)" || fail "dev 031 wui_origin_host is not <dev site_id>.web.app"
grep -qx 'l7_narrowing = true' "$CNF/dev/tf/031-gcp-hub-ingress.vars.tfvars" \
  && pass "dev 031 L7 narrowing on" || fail "dev 031 l7_narrowing is not true"
# prd is the owner's call: both stay off until spec 007 OQ-H1 / OQ-H2 are answered.
grep -qx 'wui_origin_host = ""' "$CNF/prd/tf/031-gcp-hub-ingress.vars.tfvars" \
  && pass "prd 031 serves no WUI route (OQ-H1 open)" || fail "prd 031 wui_origin_host is set without the owner"
grep -qx 'l7_narrowing = false' "$CNF/prd/tf/031-gcp-hub-ingress.vars.tfvars" \
  && pass "prd 031 L7 narrowing off (OQ-H2 open)" || fail "prd 031 l7_narrowing is on without the owner"

# --- 016: WIF for the WUI deploy SA only on request ---------------------------
grep -qE '^\s*count = var[.]bind_github_wif \? 1 : 0' "$TFD/016-firebase-deploy-iam/03-firebase-deploy-sa.tf" \
  && pass "016 WIF binding is gated by bind_github_wif" || fail "016 WIF binding is not gated"
grep -q 'attribute.ref/${var.github_ref}' "$TFD/016-firebase-deploy-iam/03-firebase-deploy-sa.tf" \
  && pass "016 WIF binding is pinned to the trunk ref (as 017)" || fail "016 WIF binding is not ref-pinned"

# --- the WUI deploy workflow ---------------------------------------------------
W="$APP_ROOT/.github/workflows/30_wui-build-deploy.yml"
if [[ -f "$W" ]]; then
  pass "30_wui-build-deploy.yml exists"
  grep -q 'pnpm run generate' "$W" && pass "workflow runs nuxt generate" || fail "workflow does not generate"
  grep -q 'render-wui-firebase-json.sh' "$W" && pass "workflow renders firebase.json from cnf" || fail "workflow does not render firebase.json"
  grep -q 'deploy --only hosting' "$W" && pass "workflow deploys hosting only" || fail "workflow deploy command"
  # T080 (owner 2026-09-19): the project key GCP_KEY_CSI_SPL_<ENV> from iac 120
  # is primary, WIF the alternative. Any OTHER secret or a Firebase token is a leak path.
  code=$(grep -vE '^\s*#' "$W")
  grep -q "credentials_json: \${{ secrets\[format('GCP_KEY_CSI_SPL_{0}'" <<<"$code" \
    && pass "workflow authenticates with the project key GCP_KEY_CSI_SPL_<ENV>" || fail "workflow does not use GCP_KEY_CSI_SPL_<ENV>"
  grep -q 'workload_identity_provider:' <<<"$code" && pass "workflow keeps WIF as the alternative" || fail "workflow lost the WIF alternative"
  grep -qE 'FIREBASE_TOKEN|GOOGLE_CREDENTIALS' <<<"$code" && fail "workflow uses a Firebase token or raw credentials env" || pass "workflow uses no Firebase token"
  others=$(grep -oE "secrets(\.[A-Za-z0-9_]+|\[format\('[A-Za-z0-9_{}]+')" <<<"$code" | grep -vE "GCP_KEY_CSI_SPL_(DEV|PRD|\{0\})" | sort -u)
  [[ -z "$others" ]] && pass "workflow reads no secret but GCP_KEY_CSI_SPL_<ENV>" || fail "workflow reads other secrets: $others"
  grep -qE 'echo .*secrets|cat .*credentials' <<<"$code" && fail "workflow may print a secret" || pass "workflow prints no secret"
  # an env deploys only where its site exists: cnf 019 wui_deploy (dev true, prd false until the owner go)
  grep -q '"019-firebase-static-site"\]\.get("wui_deploy", False)' "$W" \
    && pass "workflow gates each env on cnf 019 wui_deploy" || fail "workflow does not read the 019 wui_deploy gate"
  for env in dev prd; do
    want=false; [[ $env == dev ]] && want=true
    got=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["env"]["steps"]["019-firebase-static-site"].get("wui_deploy", False)).lower())' "$CNF/$env.env.json")
    [[ "$got" == "$want" ]] && pass "$env wui_deploy = $want" || fail "$env wui_deploy is $got, want $want (prd needs the owner go + 019 applied)"
  done
else
  fail "missing .github/workflows/30_wui-build-deploy.yml"
fi

# --- the Host regex, as terraform computes it ---------------------------------
TF="${TF_BIN:-}"
[[ -x "$TF" ]] || TF=$(ls "$HOME"/.local/share/csi-spl/bin/terraform-* 2>/dev/null | sort -V | tail -1)
[[ -x "$TF" ]] || TF=$(command -v terraform 2>/dev/null || true)
if [[ -n "$TF" && -x "$TF" ]]; then
  tmp=$(mktemp -d); cp -r "$TFD/031-gcp-hub-ingress/." "$tmp/"
  printf '%s\n' 'terraform {' '  backend "local" {}' '}' >"$tmp/backend_override.tf"
  tf_cache="$HOME/.terraform.d/plugin-cache/csi/spl/test-$$"; mkdir -p "$tf_cache"
  re=""
  if TF_PLUGIN_CACHE_DIR="$tf_cache" "$TF" -chdir="$tmp" init -input=false >/dev/null 2>&1; then
    re=$(echo 'local.host_regex' | "$TF" -chdir="$tmp" console -var-file="$CNF/dev/tf/031-gcp-hub-ingress.vars.tfvars" 2>/dev/null | tr -d '"')
  fi
  rm -rf "$tmp" "$tf_cache"
  if [[ -z "$re" ]]; then
    fail "terraform console could not evaluate local.host_regex for dev"
  else
    fqdn=$(sed -n 's/^fqdn *= "\(.*\)"$/\1/p' "$CNF/dev/tf/031-gcp-hub-ingress.vars.tfvars")
    base=$(sed -n 's/^base_domain *= "\(.*\)"$/\1/p' "$CNF/dev/tf/031-gcp-hub-ingress.vars.tfvars")
    ok=1
    for h in "$fqdn" "t1.$fqdn" "t1.$fqdn:443" "dev.api.$base"; do
      python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$re" "$h" || { ok=0; echo "  should pass: $h"; }
    done
    for h in "evil.example" "$fqdn.evil.example" "a.b.$fqdn" "x$fqdn" "$base" "api.$base" "34.1.2.3"; do
      python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$re" "$h" && { ok=0; echo "  should be refused: $h"; }
    done
    (( ok )) && pass "dev Host regex admits <fqdn>, <tenant>.<fqdn>, dev.api and refuses 7 planted foreign names" \
             || fail "dev Host regex $re"
  fi
elif [[ "${SPL_TF_ALLOW_SKIP:-0}" == 1 ]]; then
  echo "SKIP: no terraform; Host regex not evaluated"
else
  fail "no terraform (TF_BIN, \$HOME/.local/share/csi-spl/bin/terraform-*, PATH); SPL_TF_ALLOW_SKIP=1 to accept"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
