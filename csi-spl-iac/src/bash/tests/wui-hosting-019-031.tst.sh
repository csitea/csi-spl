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
# owner 2026-09-19, exactly as csi-rel: env.dns.fqdn IS the site's custom domain,
# 031 holds no A record for it, and the DNS comes from csi-rel's script (unchanged)
for env in dev prd; do
  grep -qx 'bind_custom_domain = true' "$CNF/$env/tf/019-firebase-static-site.vars.tfvars" \
    && pass "$env 019 binds env.dns.fqdn as a Firebase custom domain (csi-rel)" || fail "$env 019 bind_custom_domain is not true"
  grep -qx 'fqdn_a_record = false' "$CNF/$env/tf/031-gcp-hub-ingress.vars.tfvars" \
    && pass "$env 031 writes no A record for env.dns.fqdn (it belongs to Firebase)" || fail "$env 031 fqdn_a_record is not false"
done
# csi-rel's file at csi-rel f50f6b4c, pinned by hash so the check runs without a csi-rel checkout (CI)
want_sha=73ffb71f8e606173a37609a588e103cbf7103e841532fd4edeef2aa1549f13f8
got_sha=$(sha256sum "$PROJ_ROOT/src/bash/run/provision-firebase-dns.func.sh" | cut -d' ' -f1)
[[ "$got_sha" == "$want_sha" ]] \
  && pass "provision-firebase-dns.func.sh is byte-identical to csi-rel's (f50f6b4c)" || fail "provision-firebase-dns.func.sh differs from csi-rel's f50f6b4c (sha256 $got_sha)"
R=/opt/csi/csi-rel/csi-rel-iac/src/bash/run/provision-firebase-dns.func.sh
if [[ -f "$R" && "$(sha256sum "$R" | cut -d' ' -f1)" != "$want_sha" ]]; then
  echo "NOTE: csi-rel's provision-firebase-dns.func.sh moved on since f50f6b4c; re-port it and update want_sha"
fi
grep -q 'do_provision_firebase_dns || rc' "$PROJ_ROOT/src/bash/run/provision-firebase-dns-env.func.sh" \
  && grep -q 'activate-service-account --key-file' "$PROJ_ROOT/src/bash/run/provision-firebase-dns-env.func.sh" \
  && pass "do_provision_firebase_dns_env runs csi-rel's action as the env SA" || fail "provision-firebase-dns-env wrapper"

# a deleted Firebase site id can never be reused: the site must refuse a destroy
awk '/resource "google_firebase_hosting_site" "default"/,/^}/' "$TFD/019-firebase-static-site/03-firebase-site.tf" | grep -q 'prevent_destroy = true' \
  && pass "019 site carries prevent_destroy (a deleted site id is gone forever)" || fail "019 site lacks prevent_destroy"

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
# superseded by the owner (csi-rel has no LB route and no Cloud Armor): off in both envs
for env in dev prd; do
  grep -qx 'wui_origin_host = ""' "$CNF/$env/tf/031-gcp-hub-ingress.vars.tfvars" \
    && pass "$env 031 serves no WUI route" || fail "$env 031 wui_origin_host is set"
  grep -qx 'l7_narrowing = false' "$CNF/$env/tf/031-gcp-hub-ingress.vars.tfvars" \
    && pass "$env 031 L7 narrowing off" || fail "$env 031 l7_narrowing is on"
done

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
    want=true
    got=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["env"]["steps"]["019-firebase-static-site"].get("wui_deploy", False)).lower())' "$CNF/$env.env.json")
    [[ "$got" == "$want" ]] && pass "$env wui_deploy = $want" || fail "$env wui_deploy is $got, want $want (owner 2026-09-19: deploy the latest WUI to dev and prd)"
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
    extras=$(sed -n 's/^extra_host_labels = \[\(.*\)\]$/\1/p' "$CNF/dev/tf/031-gcp-hub-ingress.vars.tfvars" | tr -d '" ' | tr ',' ' ')
    for h in "$fqdn" "t1.$fqdn" "t1.$fqdn:443" $(for l in $extras; do echo "$l.$base"; done); do
      python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$re" "$h" || { ok=0; echo "  should pass: $h"; }
    done
    for h in "evil.example" "$fqdn.evil.example" "a.b.$fqdn" "x$fqdn" "$base" "api.$base" "34.1.2.3"; do
      python3 -c 'import re,sys; sys.exit(0 if re.search(sys.argv[1], sys.argv[2]) else 1)' "$re" "$h" && { ok=0; echo "  should be refused: $h"; }
    done
    (( ok )) && pass "dev Host regex admits <fqdn>, <tenant>.<fqdn>, the cnf extra hosts and refuses 7 planted foreign names" \
             || fail "dev Host regex $re"
  fi
elif [[ "${SPL_TF_ALLOW_SKIP:-0}" == 1 ]]; then
  echo "SKIP: no terraform; Host regex not evaluated"
else
  fail "no terraform (TF_BIN, \$HOME/.local/share/csi-spl/bin/terraform-*, PATH); SPL_TF_ALLOW_SKIP=1 to accept"
fi

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
