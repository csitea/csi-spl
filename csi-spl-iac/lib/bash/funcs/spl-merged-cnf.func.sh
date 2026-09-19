#!/bin/bash
#------------------------------------------------------------------------------
# @description Write the effective config of one env to a file: all.env.yaml
# @description deep-merged under <env>.env.yaml, plus the derived
# @description env.dns.fqdn. Every consumer that needs the domain reads THIS,
# @description never a literal. Cloud envs also get env.hub.image.ref (the
# @description image 030 runs, from 028 + hub.image).
# @description env.dns.api_fqdn is the hub's API host (owner 2026-09-19, no LB):
# @description api.<BASE_DOMAIN>, or <env_subdomain>.api.<BASE_DOMAIN>; a literal wins.
# @description env.auth.social.env (spec 010 T022, T051) is derived too: every
# @description "{fqdn}" / "{base_domain}" in a value is expanded; APP_URL still at
# @description its PLACEHOLDER- default becomes https://<fqdn> (the WUI), and every
# @description <P>_REDIRECT_URI still at PLACEHOLDER- becomes
# @description <APP_URL>/api/v1/auth/<p>/callback: the WUI host, which the IdP
# @description clients authorise and Firebase rewrites to the hub (owner
# @description 2026-09-19: no console change). A literal wins (lde).
# @description steps.019-firebase-static-site.wui_auth_base (the WUI's
# @description NUXT_PUBLIC_AUTH_BASE, spec 010 T053) expands "{api_fqdn}", so the
# @description cnf says "https://{api_fqdn}" and never the host; "" = same-origin.
# @param $1 - the cnf dir holding all.env.yaml and <env>.env.yaml
# @param $2 - env: dev, prd or lde
# @param $3 - output yaml path
# @example do_spl_merged_cnf "$APP_PATH/csi-spl-cnf/csi-spl" dev /tmp/dev.yaml
#------------------------------------------------------------------------------
do_spl_merged_cnf() {
  local dir="${1:?cnf dir}" env="${2:?env}" out="${3:?out}"
  [[ -f "$dir/all.env.yaml" && -f "$dir/$env.env.yaml" ]] || {
    echo "do_spl_merged_cnf: missing $dir/all.env.yaml or $dir/$env.env.yaml" >&2; return 1; }
  yq eval-all '. as $i ireduce ({}; . * $i)' "$dir/all.env.yaml" "$dir/$env.env.yaml" |
    yq '.env.dns.fqdn = (select(.env.dns.env_subdomain != "") | .env.dns.env_subdomain + "." + .env.dns.BASE_DOMAIN) // .env.dns.BASE_DOMAIN' |
    yq '.env.dns.api_fqdn = (.env.dns.api_fqdn // ((select(.env.dns.env_subdomain != "") | .env.dns.env_subdomain + ".api." + .env.dns.BASE_DOMAIN) // ("api." + .env.dns.BASE_DOMAIN)))' |
    yq '(.env | select(.steps."019-firebase-static-site".wui_auth_base != null)) |= (
      .dns.api_fqdn as $a |
      with(.steps."019-firebase-static-site".wui_auth_base | select(test("\{api_fqdn\}")); . |= sub("\{api_fqdn\}"; $a)))' |
    yq '(.env | select(.hub != null)) |= (
      .hub.env.SPOOL_HUB_ENV = (.hub.env.SPOOL_HUB_ENV // .ENV) |
      .hub.env.SPOOL_HUB_FILES_BUCKET = (.hub.env.SPOOL_HUB_FILES_BUCKET // .steps."050-gcs-files".files_bucket_name) |
      .hub.env.SPOOL_HUB_TENANT_HOST_PATTERN = (.hub.env.SPOOL_HUB_TENANT_HOST_PATTERN // ("{tenant}." + .dns.fqdn)))' |
    yq '(.env | select(.hub.image.tag != null and .steps."028-gcp-artifact-registry" != null)) |= (
      .hub.image.ref = (.gcp.gcp_region + "-docker.pkg.dev/" + .gcp.gcp_project + "/" +
        .steps."028-gcp-artifact-registry".repository_id + "/" + .hub.image.name + ":" + (.hub.image.tag | tostring)))' |
    yq '(.env | select(.auth.social.env != null)) |= (
      .dns.fqdn as $f | .dns.BASE_DOMAIN as $b |
      with(.auth.social.env[] | select(tag == "!!str") | select(test("\{fqdn\}")); . |= sub("\{fqdn\}"; $f)) |
      with(.auth.social.env[] | select(tag == "!!str") | select(test("\{base_domain\}")); . |= sub("\{base_domain\}"; $b)) |
      with(.auth.social.env.SPOOL_HUB_AUTH_APP_URL | select(test("^PLACEHOLDER-")); . = "https://" + $f) |
      .auth.social.env.SPOOL_HUB_AUTH_APP_URL as $app |
      with(.auth.social.env[] | select(key | test("^SPOOL_HUB_AUTH_[A-Z]+_REDIRECT_URI$")) | select(test("^PLACEHOLDER-"));
        . = $app + "/api/v1/auth/" + (key | sub("^SPOOL_HUB_AUTH_"; "") | sub("_REDIRECT_URI$"; "") | downcase) + "/callback"))' >"$out" || return 1
  local base
  base=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$out")
  [[ -n "$base" && "$base" != null ]] || { echo "do_spl_merged_cnf: env.dns.BASE_DOMAIN is empty" >&2; return 1; }
}
