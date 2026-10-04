#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 010 T022 + T051 -- the browser sign-in URLs of a cloud env are
#          DERIVED by do_spl_merged_cnf, never written as literals:
#          APP_URL = https://<fqdn> (the WUI); env.dns.api_fqdn = api.<base>,
#          or <env_subdomain>.api.<base>; every <P>_REDIRECT_URI =
#          <APP_URL>/api/v1/auth/<p>/callback (the WUI host the IdP clients
#          authorise; owner 2026-09-19: no console change); COOKIE_DOMAIN
#          "{base_domain}" -> <base>,
#          which spans the WUI, the API host and every tenant host. A literal
#          value in <env>.env.yaml wins (lde keeps its localhost URLs).
#
#          CONTROL: dev's committed values would pass the value checks even
#          if they were literals, so a scratch cnf with a DIFFERENT
#          env_subdomain must move every derived URL with it, and a planted
#          literal redirect URI must survive the merge untouched.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

CNF="$APP_ROOT/csi-spl-cnf/csi-spl"
# shellcheck disable=SC1091
source "$PROJ_ROOT/lib/bash/funcs/spl-merged-cnf.func.sh"
PROVIDERS="GOOGLE FACEBOOK MICROSOFT LINKEDIN XAI"
tmp=$(mktemp -d)

# check_derived <label> <merged yaml> -> asserts every auth URL follows the fqdn
check_derived() {
  local label="$1" m="$2" fqdn api base sub app p lp got
  fqdn=$(yq -r '.env.dns.fqdn' "$m")
  api=$(yq -r '.env.dns.api_fqdn' "$m")
  base=$(yq -r '.env.dns.BASE_DOMAIN' "$m")
  sub=$(yq -r '.env.dns.env_subdomain // ""' "$m")
  if [[ -n "$sub" ]]; then want_api="$sub.api.$base"; else want_api="api.$base"; fi
  [[ "$api" == "$want_api" ]] && pass "$label api_fqdn is $want_api" || fail "$label api_fqdn: $api (want $want_api)"
  app=$(yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_APP_URL' "$m")
  [[ "$app" == "https://$fqdn" ]] && pass "$label APP_URL is https://<fqdn> ($app)" || fail "$label APP_URL: $app (fqdn $fqdn)"
  got=$(yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_COOKIE_DOMAIN' "$m")
  [[ "$got" == "$base" ]] && pass "$label COOKIE_DOMAIN is the base domain" || fail "$label COOKIE_DOMAIN: $got (base $base)"
  # the cookie must reach the API host and the WUI host (browser domain-match)
  for h in "$api" "$fqdn"; do
    [[ "$h" == "$got" || "$h" == *".$got" ]] && pass "$label cookie Domain=$got reaches $h" || fail "$label cookie Domain=$got misses $h"
  done
  for p in $PROVIDERS; do
    lp=$(tr '[:upper:]' '[:lower:]' <<<"$p")
    got=$(yq -r ".env.auth.social.env.SPOOL_HUB_AUTH_${p}_REDIRECT_URI" "$m")
    [[ "$got" == "https://$fqdn/api/v1/auth/$lp/callback" ]] && pass "$label $p redirect URI on the WUI host" || fail "$label $p redirect URI: $got"
  done
  yq -r '.env.auth.social.env[]' "$m" | grep -E 'PLACEHOLDER-(wui-origin|[a-z]+-redirect-uri)|\{fqdn\}|\{base_domain\}' >/dev/null \
    && fail "$label a URL placeholder or {fqdn}/{base_domain} token survived the merge" || pass "$label no URL placeholder or token survives"
}

for env in dev prd; do
  y="$CNF/$env.env.yaml"
  grep -qE '^\s*SPOOL_HUB_AUTH_(APP_URL|[A-Z]+_REDIRECT_URI):' "$y" \
    && fail "$env.env.yaml carries a literal APP_URL / redirect URI" || pass "$env.env.yaml carries no literal APP_URL / redirect URI"
  do_spl_merged_cnf "$CNF" "$env" "$tmp/$env.yaml" || { fail "$env: cannot merge cnf"; continue; }
  check_derived "$env" "$tmp/$env.yaml"
done

# T053: the WUI auth base is "" (same-origin) or derived from api_fqdn, never a
# literal host in the yaml; after the merge it is "" or exactly https://<api_fqdn>
for env in dev prd; do
  raw=$(yq -r '.env.steps."019-firebase-static-site".wui_auth_base // ""' "$CNF/$env.env.yaml")
  [[ -z "$raw" || "$raw" == "https://{api_fqdn}" ]] && pass "$env wui_auth_base is '' or https://{api_fqdn} ('$raw')" || fail "$env wui_auth_base literal: '$raw'"
  got=$(yq -r '.env.steps."019-firebase-static-site".wui_auth_base // ""' "$tmp/$env.yaml")
  api=$(yq -r '.env.dns.api_fqdn' "$tmp/$env.yaml")
  [[ -z "$got" || "$got" == "https://$api" ]] && pass "$env merged wui_auth_base is '' or https://<api_fqdn> ('$got')" || fail "$env merged wui_auth_base: '$got'"
done

# lde: its literal localhost URLs and host-only cookie win over the derivation
do_spl_merged_cnf "$CNF" lde "$tmp/lde.yaml" || fail "lde: cannot merge cnf"
for k in APP_URL COOKIE_DOMAIN $(printf '%s_REDIRECT_URI ' $PROVIDERS); do
  want=$(yq -r ".env.auth.social.env.SPOOL_HUB_AUTH_$k // \"\"" "$CNF/lde.env.yaml")
  [[ -n "$want" ]] || want=$(yq -r ".env.auth.social.env.SPOOL_HUB_AUTH_$k" "$CNF/all.env.yaml")
  got=$(yq -r ".env.auth.social.env.SPOOL_HUB_AUTH_$k" "$tmp/lde.yaml")
  [[ "$got" == "$want" ]] && pass "lde keeps its own $k ($got)" || fail "lde $k: got '$got', want '$want'"
done

# --- control: another subdomain moves every URL; a literal survives -----------
mkdir -p "$tmp/cnf"
cp "$CNF/all.env.yaml" "$CNF/dev.env.yaml" "$tmp/cnf/"
yq -i '.env.dns.env_subdomain = "ctl"' "$tmp/cnf/dev.env.yaml"
do_spl_merged_cnf "$tmp/cnf" dev "$tmp/ctl.yaml" || fail "control: cannot merge"
[[ "$(yq -r '.env.dns.fqdn' "$tmp/ctl.yaml")" == ctl.* ]] && check_derived "control ctl" "$tmp/ctl.yaml" || fail "control: fqdn did not move"
# control: the {api_fqdn} token in wui_auth_base follows the subdomain too
yq -i '.env.steps."019-firebase-static-site".wui_auth_base = "https://{api_fqdn}"' "$tmp/cnf/dev.env.yaml"
do_spl_merged_cnf "$tmp/cnf" dev "$tmp/ctl2.yaml" || fail "control: cannot merge (auth base)"
got=$(yq -r '.env.steps."019-firebase-static-site".wui_auth_base' "$tmp/ctl2.yaml")
[[ "$got" == "https://$(yq -r '.env.dns.api_fqdn' "$tmp/ctl2.yaml")" && "$got" == https://ctl.api.* ]] \
  && pass "control: wui_auth_base https://{api_fqdn} -> $got" || fail "control: wui_auth_base -> '$got'"
yq -i '.env.auth.social.env.SPOOL_HUB_AUTH_XAI_REDIRECT_URI = "https://literal.example.com/cb"' "$tmp/cnf/dev.env.yaml"
do_spl_merged_cnf "$tmp/cnf" dev "$tmp/lit.yaml" || fail "control: cannot merge the literal"
[[ "$(yq -r '.env.auth.social.env.SPOOL_HUB_AUTH_XAI_REDIRECT_URI' "$tmp/lit.yaml")" == "https://literal.example.com/cb" ]] \
  && pass "control: a literal redirect URI in <env>.env.yaml wins" || fail "control: the literal redirect URI was overwritten"
rm -rf "$tmp"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
