#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_deploy_hosted_site (SPL-1985) ships a static website to its own
#          Firebase Hosting site (terraform step 021), from cnf only:
#   1. _hosted_site_cfg picks one site of steps.021-firebase-hosted-sites by
#      name, site_id or placeholder (<project>-<name>); the only one by
#      default; none or several -> FATAL
#   2. firebase.json names the site and serves .output/public; X-Robots-Tag
#      noindex only when the site is noindex
#   3. the DRY_RUN (default) plan names site, sha, host and noindex, and runs
#      no pnpm, no firebase, no clone
#   4. the committed cnf: dev is noindex for every site, every site_id is
#      <project>-<name>, and a customer name is a placeholder (no slug in git)
#   ACTION=<path> runs it against another copy (red control).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
A="${ACTION:-$PROJ_ROOT/src/bash/run/deploy-hosted-site.func.sh}"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
command -v yq >/dev/null && command -v jq >/dev/null || { echo "FAIL: yq and jq are required"; exit 1; }

bash -n "$A" && pass "bash -n" || { fail "bash -n $A"; exit 1; }
do_log() { echo "$*" >&2; }
# shellcheck disable=SC1090
source "$A"

# --- 1. the site out of cnf ---------------------------------------------------
cat >"$T/two.yaml" <<'EOF'
env:
  steps:
    021-firebase-hosted-sites:
      sites:
        ws-hidden-07: {site_id: csi-spl-dev-ws-hidden-07, src_dir: /src/a, noindex: true}
        shop: {site_id: csi-spl-dev-shop, src_dir: /src/b}
EOF
yq 'del(.env.steps."021-firebase-hosted-sites".sites.ws-hidden-07)' "$T/two.yaml" >"$T/one.yaml"
printf 'env:\n  steps: {}\n' >"$T/none.yaml"
cfg() { ENV=dev _hosted_site_cfg "$@" 2>/dev/null | paste -sd' '; }
[[ "$(cfg "$T/two.yaml" csi-spl-dev ws-hidden-07)" == "name=ws-hidden-07 site_id=csi-spl-dev-ws-hidden-07 src_dir=/src/a noindex=1" ]] &&
  pass "a site is picked by its name, noindex true -> 1" || fail "pick by name: '$(cfg "$T/two.yaml" csi-spl-dev ws-hidden-07)'"
# a resolved cnf carries the slug as name, the placeholder only in site_id
sed 's/^        ws-hidden-07:/        realname:/' "$T/two.yaml" >"$T/resolved.yaml"
[[ "$(cfg "$T/resolved.yaml" csi-spl-dev ws-hidden-07)" == "name=realname site_id=csi-spl-dev-ws-hidden-07 src_dir=/src/a noindex=1" ]] &&
  pass "in a resolved cnf the placeholder still picks its site (<project>-<placeholder>)" || fail "pick by placeholder: '$(cfg "$T/resolved.yaml" csi-spl-dev ws-hidden-07)'"
[[ "$(cfg "$T/two.yaml" csi-spl-dev csi-spl-dev-shop)" == "name=shop site_id=csi-spl-dev-shop src_dir=/src/b noindex=0" ]] &&
  pass "a site is picked by its site_id, no noindex -> 0" || fail "pick by site_id: '$(cfg "$T/two.yaml" csi-spl-dev csi-spl-dev-shop)'"
[[ "$(cfg "$T/one.yaml" csi-spl-dev "")" == "name=shop site_id=csi-spl-dev-shop src_dir=/src/b noindex=0" ]] &&
  pass "no SITE and one site: that site" || fail "the only site: '$(cfg "$T/one.yaml" csi-spl-dev "")'"
out=$(ENV=dev _hosted_site_cfg "$T/two.yaml" csi-spl-dev "" 2>&1); rc=$?
((rc == 1)) && grep -q 'name one with SITE=' <<<"$out" && pass "no SITE and two sites: FATAL" || fail "two sites, no SITE: rc $rc '$out'"
out=$(ENV=dev _hosted_site_cfg "$T/two.yaml" csi-spl-dev nosuch 2>&1); rc=$?
((rc == 1)) && grep -q "no site 'nosuch'" <<<"$out" && pass "an unknown SITE: FATAL" || fail "unknown site: rc $rc '$out'"
out=$(ENV=dev _hosted_site_cfg "$T/none.yaml" csi-spl-dev "" 2>&1); rc=$?
((rc == 1)) && pass "no step 021 in cnf: FATAL" || fail "no step: rc $rc '$out'"

# --- 2. firebase.json ---------------------------------------------------------
_hosted_site_firebase_json csi-spl-dev-x 1 >"$T/fb1.json"
_hosted_site_firebase_json csi-spl-dev-x 0 >"$T/fb0.json"
[[ "$(jq -r '.hosting.site + " " + .hosting.public' "$T/fb1.json")" == "csi-spl-dev-x .output/public" ]] &&
  pass "firebase.json names the site and serves .output/public" || fail "firebase.json site/public: $(cat "$T/fb1.json")"
robots() { jq -r '[.hosting.headers[] | select(.source == "**") | .headers[] | select(.key == "X-Robots-Tag") | .value] | join(",")' "$1"; }
[[ "$(robots "$T/fb1.json")" == "noindex, nofollow" ]] && pass "noindex 1: X-Robots-Tag noindex, nofollow on **" || fail "noindex 1 header: '$(robots "$T/fb1.json")'"
[[ -z "$(robots "$T/fb0.json")" ]] && pass "noindex 0: no X-Robots-Tag" || fail "noindex 0 sends '$(robots "$T/fb0.json")'"

grep -qF 'NUXT_PUBLIC_NOINDEX="\"$noindex\""' "$A" && pass "the noindex flag reaches Nuxt as the string '1' (JSON-quoted)" ||
  fail "NUXT_PUBLIC_NOINDEX is not JSON-quoted: Nuxt turns a bare 1 into a number and the site indexes"

grep -qF -- '--config.use-node-version="${FIREBASE_NODE_VERSION:-22.20.0}" dlx firebase-tools' "$A" &&
  pass "firebase-tools runs on a pinned node (the box node 20.19.2 cannot fetch a token)" ||
  fail "firebase-tools runs on the box node: 'Failed to authenticate' on node 20.19.2"

# --- 3. the dry run touches nothing -------------------------------------------
R="$T/site"; git init -q -b main "$R"
SHA=$(git -C "$R" -c user.email=t@example.com -c user.name="FirstName LastName" commit -q --allow-empty -m one && git -C "$R" rev-parse HEAD)
yq ".env.steps.\"021-firebase-hosted-sites\".sites.ws-hidden-07.src_dir = \"$R\"" "$T/two.yaml" >"$T/dry.yaml"
plan=$(
  spl_require_cloud_env() { [[ "$ENV" == dev || "$ENV" == prd ]]; }
  spl_dry_run() { [[ "${DRY_RUN:-1}" == 1 ]]; }
  spl_ld_user_bins() { :; }
  do_require_bin() { :; }
  spl_ld_served() { echo ""; }
  do_spl_cloud_cnf() { export SPL_CNF="$T/dry.yaml" SPL_PROJECT=csi-spl-dev SPL_FQDN=dev.example.com; }
  pnpm() { echo "RAN pnpm"; }; firebase() { echo "RAN firebase"; }
  _hosted_site_clone() { echo "RAN clone"; }
  ENV=dev SITE=ws-hidden-07 do_deploy_hosted_site 2>&1
); rc=$?
((rc == 0)) && grep -q "PLAN dev site csi-spl-dev-ws-hidden-07 ${SHA:0:12}" <<<"$plan" &&
  grep -q 'https://ws-hidden-07.dev.example.com, noindex 1' <<<"$plan" && grep -q 'X-Robots-Tag noindex' <<<"$plan" &&
  pass "the dry run plans site, sha, host and noindex" || fail "dry-run plan (rc $rc): $plan"
grep -q '^RAN' <<<"$plan" && fail "the dry run ran a build, clone or deploy" || pass "the dry run runs no pnpm, firebase or clone"
out=$(spl_require_cloud_env() { [[ "$ENV" == dev || "$ENV" == prd ]] || { echo "FATAL ENV"; return 1; }; }
      ENV=lde do_deploy_hosted_site 2>&1); rc=$?
((rc == 1)) && pass "ENV=lde is refused" || fail "ENV=lde: rc $rc '$out'"

# --- 4. the committed cnf -----------------------------------------------------
if [[ -z "${ACTION:-}" ]]; then
  for env in dev prd; do
    m="$T/merged-$env.yaml"
    yq eval-all '. as $i ireduce ({}; . * $i)' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" "$APP_ROOT/csi-spl-cnf/csi-spl/$env.env.yaml" >"$m"
    n=$(yq '(.env.steps."021-firebase-hosted-sites".sites // {}) | length' "$m")
    bad=$(yq -r ".env.steps.\"021-firebase-hosted-sites\".sites // {} | to_entries[] | select(.value.site_id != \"csi-spl-$env-\" + .key) | .key" "$m")
    [[ -z "$bad" ]] && pass "$env: every site_id is csi-spl-$env-<name> ($n site(s))" || fail "$env: site_id is not csi-spl-$env-<name>: $bad"
    [[ "$env" == prd ]] && continue
    bad=$(yq -r '.env.steps."021-firebase-hosted-sites".sites // {} | to_entries[] | select(.value.noindex != true) | .key' "$m")
    [[ -z "$bad" ]] && pass "dev: every site is noindex" || fail "dev: sites without noindex: $bad"
  done
  t="$APP_ROOT/csi-spl-cnf/csi-spl/dev/tf/021-firebase-hosted-sites.vars.tfvars"
  grep -qE '^sites = \[\{"host": "ws-hidden-[0-9]+\.dev\.' "$t" && pass "the dev tfvars name the site by its placeholder" ||
    fail "the dev 021 tfvars do not carry a placeholder host"
fi

echo "deploy-hosted-site: $fails failure(s)"
exit $((fails > 0))
