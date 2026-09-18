#!/bin/bash
#------------------------------------------------------------------------------
# @description Write the effective config of one env to a file: all.env.yaml
# @description deep-merged under <env>.env.yaml, plus the derived
# @description env.dns.fqdn. Every consumer that needs the domain reads THIS,
# @description never a literal.
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
    yq '(.env | select(.hub != null)) |= (
      .hub.env.SPOOL_HUB_ENV = (.hub.env.SPOOL_HUB_ENV // .ENV) |
      .hub.env.SPOOL_HUB_FILES_BUCKET = (.hub.env.SPOOL_HUB_FILES_BUCKET // .steps."050-gcs-files".files_bucket_name) |
      .hub.env.SPOOL_HUB_TENANT_HOST_PATTERN = (.hub.env.SPOOL_HUB_TENANT_HOST_PATTERN // ("{tenant}." + .dns.fqdn)))' >"$out" || return 1
  local base
  base=$(yq -r '.env.dns.BASE_DOMAIN // ""' "$out")
  [[ -n "$base" && "$base" != null ]] || { echo "do_spl_merged_cnf: env.dns.BASE_DOMAIN is empty" >&2; return 1; }
}
