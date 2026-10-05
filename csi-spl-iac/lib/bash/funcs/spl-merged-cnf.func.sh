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
# @description env.hub.env.SPOOL_HUB_DEFAULT_LOCALE defaults to env.i18n.default_locale
# @description (spec 021): the hub's mail fallback and the WUI's unprefixed locale
# @description are one cnf value; a literal wins.
# @description env.hub.env.SPOOL_HUB_WORKSPACE_DOCS_BUCKET is
# @description steps.052-gcs-workspace-docs.bucket_prefix + "{tenant}" (spec 075):
# @description the hub names each workspace's docs bucket exactly as 052 does; a
# @description literal wins, no bucket_prefix = no variable (the routes are off).
# @description env.steps in all.env.yaml holds the step settings every cloud env
# @description shares (spec 072 A44); an env file without env.steps of its own
# @description (lde: no terraform) gets no env.steps at all.
# @description steps.036-spl-demo-workspace.demo_{enabled,workspace} are
# @description env.demo.{enabled,workspace} (077 iac audit): the step that runs
# @description do_spl_demo_workspace_create reads the same one cnf block.
# @description env.hub.env.SPOOL_HUB_DEMO_{ENABLED,WORKSPACE,PROVIDERS,MAX_LIVE}
# @description are env.demo.{enabled,workspace,providers,max_live} (spec 077
# @description T023): the demo is one cnf block, never a hub.env literal.
# @description steps.120-github-general-secrets.gh_repo defaults to
# @description steps.017-github-wif-deploy.github_repository: one key per fact.
# @param $1 - the cnf dir holding all.env.yaml and <env>.env.yaml
# @param $2 - env: dev, prd or lde
# @param $3 - output yaml path
# @example do_spl_merged_cnf "$APP_PATH/csi-spl-cnf/csi-spl" dev /tmp/dev.yaml
#------------------------------------------------------------------------------
do_spl_merged_cnf() {
  local dir="${1:?cnf dir}" env="${2:?env}" out="${3:?out}"
  [[ -f "$dir/all.env.yaml" && -f "$dir/$env.env.yaml" ]] || {
    echo "do_spl_merged_cnf: missing $dir/all.env.yaml or $dir/$env.env.yaml" >&2; return 1; }
  local own_steps
  own_steps=$(yq '.env.steps | tag' "$dir/$env.env.yaml") || return 1
  yq eval-all '. as $i ireduce ({}; . * $i)' "$dir/all.env.yaml" "$dir/$env.env.yaml" |
    yq "$( [[ "$own_steps" == '!!map' ]] && echo . || echo 'del(.env.steps)' )" |
    yq '(.env | select(.steps."017-github-wif-deploy".github_repository != null)) |= (
      .steps."120-github-general-secrets".gh_repo = (.steps."120-github-general-secrets".gh_repo // .steps."017-github-wif-deploy".github_repository))' |
    yq '.env.dns.fqdn = (select(.env.dns.env_subdomain != "") | .env.dns.env_subdomain + "." + .env.dns.BASE_DOMAIN) // .env.dns.BASE_DOMAIN' |
    yq '.env.dns.api_fqdn = (.env.dns.api_fqdn // ((select(.env.dns.env_subdomain != "") | .env.dns.env_subdomain + ".api." + .env.dns.BASE_DOMAIN) // ("api." + .env.dns.BASE_DOMAIN)))' |
    yq '(.env | select(.steps."019-firebase-static-site".wui_auth_base != null)) |= (
      .dns.api_fqdn as $a |
      with(.steps."019-firebase-static-site".wui_auth_base | select(test("\{api_fqdn\}")); . |= sub("\{api_fqdn\}"; $a)))' |
    yq '(.env | select(.hub != null)) |= (
      .hub.env.SPOOL_HUB_ENV = (.hub.env.SPOOL_HUB_ENV // .ENV) |
      .hub.env.SPOOL_HUB_FILES_BUCKET = (.hub.env.SPOOL_HUB_FILES_BUCKET // .steps."050-gcs-files".files_bucket_name) |
      with(select(.steps."051-gcs-docs".publish_enabled == true and .steps."051-gcs-docs".docs_bucket_name != null);
        .hub.env.SPOOL_HUB_DOCS_BUCKET = (.hub.env.SPOOL_HUB_DOCS_BUCKET // .steps."051-gcs-docs".docs_bucket_name)) |
      with(select(.steps."052-gcs-workspace-docs".bucket_prefix != null);
        .hub.env.SPOOL_HUB_WORKSPACE_DOCS_BUCKET = (.hub.env.SPOOL_HUB_WORKSPACE_DOCS_BUCKET // (.steps."052-gcs-workspace-docs".bucket_prefix + "{tenant}"))) |
      .hub.env.SPOOL_HUB_TENANT_HOST_PATTERN = (.hub.env.SPOOL_HUB_TENANT_HOST_PATTERN // ("{tenant}." + .dns.fqdn)))' |
    yq '(.env | select(.hub != null and .i18n.default_locale != null)) |= (
      .hub.env.SPOOL_HUB_DEFAULT_LOCALE = (.hub.env.SPOOL_HUB_DEFAULT_LOCALE // .i18n.default_locale))' |
    yq '(.env | select(.hub != null and .demo != null)) |= (
      .hub.env.SPOOL_HUB_DEMO_ENABLED = (.demo.enabled | tostring) |
      .hub.env.SPOOL_HUB_DEMO_WORKSPACE = (.demo.workspace | tostring) |
      .hub.env.SPOOL_HUB_DEMO_PROVIDERS = (.demo.providers | join(",")) |
      .hub.env.SPOOL_HUB_DEMO_MAX_LIVE = (.demo.max_live | tostring))' |
    yq '(.env | select(.demo != null and .steps."036-spl-demo-workspace" != null)) |= (
      .steps."036-spl-demo-workspace".demo_enabled = .demo.enabled |
      .steps."036-spl-demo-workspace".demo_workspace = (.demo.workspace | tostring))' |
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
