#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the WUI hosting, exactly as csi-rel (owner 2026-09-19): env.dns.fqdn
#          is the 019 Firebase site's custom domain, its DNS comes from
#          csi-rel's script (pinned by hash), and the WUI deploy workflow.
#          There is NO load balancer: the M1 031 hub LB (WUI route, Cloud
#          Armor, Host regex) was deprovisioned in both envs and its step
#          removed; this test fails if the step or its cnf block comes back.
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
# and the DNS comes from csi-rel's script (unchanged)
for env in dev prd; do
  grep -qx 'bind_custom_domain = true' "$CNF/$env/tf/019-firebase-static-site.vars.tfvars" \
    && pass "$env 019 binds env.dns.fqdn as a Firebase custom domain (csi-rel)" || fail "$env 019 bind_custom_domain is not true"
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

# --- no load balancer (owner 2026-09-19, "exactly csi-rel") -------------------
[[ ! -e "$TFD/031-gcp-hub-ingress" ]] && pass "no 031 load-balancer step in src/terraform" || fail "031-gcp-hub-ingress is back"
for env in dev prd; do
  python3 -c 'import json,sys; sys.exit(0 if "031-gcp-hub-ingress" not in json.load(open(sys.argv[1]))["env"]["steps"] else 1)' "$CNF/$env.env.json" \
    && pass "$env cnf has no 031 block" || fail "$env cnf still has steps.031-gcp-hub-ingress"
done
grep -rlE 'google_compute_(global_forwarding_rule|url_map|backend_service|security_policy|target_https_proxy)' "$TFD" >/dev/null 2>&1 \
  && fail "a terraform step declares a load-balancer resource" || pass "no step declares a forwarding rule, url map, backend service, proxy or Cloud Armor policy"

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

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
