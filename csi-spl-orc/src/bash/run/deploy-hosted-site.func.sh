#!/bin/bash
#------------------------------------------------------------------------------
# @description Build a static website and deploy it to its OWN Firebase
# @description Hosting site (terraform step 021-firebase-hosted-sites, SPL-1985),
# @description from this box with the env's project SA. The site comes from cnf
# @description steps.021-firebase-hosted-sites.sites.<name> (a customer name is
# @description its private-overlay placeholder, resolved by do_spl_cloud_cnf):
# @description site_id, src_dir (the site's Nuxt repo on this box), noindex.
# @description   1. the commit: SITE_SHA, default the HEAD of src_dir; built
# @description      from a clean clone of it, never from the repo's work tree
# @description      (uncommitted work never ships; the repo is not written)
# @description   2. a flock per site + env (one deploy at a time on this box)
# @description   3. pnpm install --frozen-lockfile; pnpm run generate with
# @description      NUXT_PUBLIC_SITE_URL=https://<name>.<fqdn>, and with
# @description      noindex: NUXT_PUBLIC_NOINDEX=1 + NUXT_PUBLIC_PREVIEW_NOTICES=1
# @description   4. build.json {commit, built_at}; firebase.json for the site,
# @description      noindex adds the header X-Robots-Tag: noindex, nofollow
# @description   5. firebase deploy --only hosting as the project SA key (a
# @description      throwaway firebase config dir: no firebase login is used)
# @description   6. probe <site_id>.web.app: build.json .commit == the sha,
# @description      / -> 200; the custom host too once it serves (a WARN
# @description      until Firebase has verified it and minted its cert)
# @description DRY_RUN=1 (default) prints the plan and touches nothing.
# @param ENV - required: dev or prd
# @param SITE (optional) - the site's cnf name (placeholder or slug) or site_id; default: the only site
# @param SITE_SHA (optional) - the src_dir commit to ship, default its HEAD
# @param DRY_RUN (optional) - 1 (default): print the plan; 0: deploy
# @param DEPLOY_LOCK_WAIT_S / DEPLOY_LOCK_DIR / DEPLOY_WORK_DIR (optional) - as do_deploy_wui
# @param KEEP_WORKTREE (optional) - 1 keeps the build clone for a post-mortem
# @param FIREBASE_NODE_VERSION (optional) - the node firebase-tools runs on, default 22.20.0
# @example ENV=dev ./run -a do_deploy_hosted_site
# @example ENV=dev DRY_RUN=0 SITE=ws-hidden-12 ./run -a do_deploy_hosted_site
#------------------------------------------------------------------------------
do_deploy_hosted_site() {
  spl_require_cloud_env || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_ld_user_bins
  do_require_bin git jq yq curl flock pnpm || return 1
  do_spl_cloud_cnf || return 1
  local cfg name site_id src noindex host sha
  cfg="$(_hosted_site_cfg "$SPL_CNF" "$SPL_PROJECT" "${SITE:-}")" || return 1
  name="$(_hosted_site_val "$cfg" name)"; site_id="$(_hosted_site_val "$cfg" site_id)"
  src="$(_hosted_site_val "$cfg" src_dir)"; noindex="$(_hosted_site_val "$cfg" noindex)"
  host="$name.$SPL_FQDN"
  [[ -d "$src/.git" ]] || { do_log "FATAL cnf src_dir $src of site $site_id is not a git repo on this box"; return 1; }
  sha="$(git -C "$src" rev-parse --verify -q "${SITE_SHA:-HEAD}^{commit}")" ||
    { do_log "FATAL not a commit of $src: '${SITE_SHA:-HEAD}'"; return 1; }

  if ((dry)); then
    echo "deploy-hosted-site PLAN $ENV site $site_id ${sha:0:12} (served $(spl_ld_served "https://$site_id.web.app/build.json" commit | cut -c1-12))"
    echo "  0 lock    hosted-site-$site_id-$ENV (flock), clean clone of $src at ${sha:0:12}"
    echo "  1 build   pnpm install --frozen-lockfile; pnpm run generate (site https://$host, noindex $noindex)"
    echo "  2 stamp   build.json; firebase.json (site $site_id$([[ "$noindex" == 1 ]] && echo ", X-Robots-Tag noindex"))"
    echo "  3 deploy  firebase deploy --only hosting --project $SPL_PROJECT"
    echo "  4 probe   https://$site_id.web.app/build.json .commit == ${sha:0:12}, / -> 200; https://$host/"
    do_log "OK DRY_RUN nothing was deployed. Re-run with DRY_RUN=0 to deploy." >&2
    return 0
  fi

  local key
  key="$(do_gcp_sa_key_file "$SPL_CNF")" || { do_log "FATAL no project SA key for $SPL_PROJECT under \$HOME/.gcp (the gcp-002 key)"; return 1; }
  spl_ld_lock "hosted-site-$site_id" || return 1
  local wt rc=0
  wt="$(_hosted_site_clone "$src" "$sha")" || return 1
  _hosted_site_steps "$wt" "$sha" "$key" "$site_id" "$host" "$noindex" || rc=$?
  if [[ "${KEEP_WORKTREE:-0}" == 1 ]]; then do_log "INFO kept the build clone $wt"; else rm -rf "$wt"; fi
  return "$rc"
}

# _hosted_site_cfg <cnf-yaml> <project> [site] -> key=value lines of the one
# site: name, site_id, src_dir, noindex (1/0). [site] matches a name, a
# site_id, or <project>-<site> (the placeholder, in a resolved cnf); empty =
# the only site. rc 1 with a FATAL when none or several match.
_hosted_site_cfg() {
  local cnf="$1" project="$2" want="${3:-}" n out
  n="$(yq -r '(.env.steps."021-firebase-hosted-sites".sites // {}) | length' "$cnf")" ||
    { do_log "FATAL cannot read steps.021-firebase-hosted-sites from $cnf"; return 1; }
  # one line per matching site: name|site_id|src_dir|true/false
  out="$(WANT="$want" PROJ="$project" yq -r '
      (.env.steps."021-firebase-hosted-sites".sites // {}) | to_entries[] | {"name": .key} + .value
      | select(strenv(WANT) == "" or .name == strenv(WANT) or .site_id == strenv(WANT) or .site_id == (strenv(PROJ) + "-" + strenv(WANT)))
      | .name + "|" + .site_id + "|" + .src_dir + "|" + ((.noindex == true) | tostring)' "$cnf")" || return 1
  if [[ -z "$out" ]]; then
    do_log "FATAL no site '${want:-<any>}' in steps.021-firebase-hosted-sites of $ENV ($n site(s))"; return 1
  fi
  if [[ "$(wc -l <<<"$out")" != 1 ]]; then
    do_log "FATAL $n sites in steps.021-firebase-hosted-sites of $ENV: name one with SITE=<name|site_id>"; return 1
  fi
  local s_name s_id s_src s_noindex
  IFS='|' read -r s_name s_id s_src s_noindex <<<"$out"
  printf 'name=%s\nsite_id=%s\nsrc_dir=%s\nnoindex=%s\n' "$s_name" "$s_id" "$s_src" "$([[ "$s_noindex" == true ]] && echo 1 || echo 0)"
}

# _hosted_site_val <cfg> <key> -> the value of <key> in the cfg lines
_hosted_site_val() { sed -n "/^$2=/{s/^$2=//p;q}" <<<"$1"; }

# _hosted_site_clone <src> <sha> -> the path of a fresh clone of <src> at <sha>
_hosted_site_clone() {
  local parent wt
  parent="${DEPLOY_WORK_DIR:-${TMPDIR:-/tmp}/$SPL_ORG_APP-deploy}"
  mkdir -p "$parent" && wt="$(mktemp -d "$parent/${ENV}-site-${2:0:8}-XXXX")" || return 1
  git clone -q --no-hardlinks "$1" "$wt" && git -C "$wt" -c advice.detachedHead=false checkout -q "$2" ||
    { rm -rf "$wt"; do_log "FATAL cannot clone $1 at ${2:0:12}"; return 1; }
  printf '%s' "$wt"
}

# _hosted_site_firebase_json <site_id> <noindex 1|0> -> firebase.json on stdout
_hosted_site_firebase_json() {
  jq -n --arg site "$1" --argjson noindex "$([[ "$2" == 1 ]] && echo true || echo false)" '{hosting: {
    site: $site, public: ".output/public", ignore: ["firebase.json", "**/.*"],
    headers: ([{source: "/_nuxt/**", headers: [{key: "Cache-Control", value: "public, max-age=31536000, immutable"}]},
               {source: "/build.json", headers: [{key: "Cache-Control", value: "no-cache"}]}]
      + (if $noindex then [{source: "**", headers: [{key: "X-Robots-Tag", value: "noindex, nofollow"}]}] else [] end))}}'
}

# _hosted_site_steps <wt> <sha> <key> <site_id> <host> <noindex> - steps 3..6 above
_hosted_site_steps() {
  local wt="$1" sha="$2" key="$3" site_id="$4" host="$5" noindex="$6" fbcfg rc=0
  (cd "$wt" && pnpm install --frozen-lockfile >/dev/null) || { do_log "FATAL pnpm install failed"; return 1; }
  # The flags go in JSON-quoted: Nuxt parses a NUXT_PUBLIC_* value, so a bare
  # 1 becomes the number 1 and the site's `=== '1'` test never matched (dev
  # served "index, follow"); "\"1\"" stays the string '1'.
  (cd "$wt" && NUXT_PUBLIC_SITE_URL="https://$host" NUXT_PUBLIC_NOINDEX="\"$noindex\"" \
    NUXT_PUBLIC_PREVIEW_NOTICES="\"$noindex\"" pnpm run generate) || { do_log "FATAL pnpm run generate failed"; return 1; }
  [[ -s "$wt/.output/public/index.html" ]] || { do_log "FATAL the build wrote no .output/public/index.html"; return 1; }
  printf '{"commit":"%s","built_at":"%s"}\n' "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$wt/.output/public/build.json"
  _hosted_site_firebase_json "$site_id" "$noindex" >"$wt/firebase.json" || return 1
  fbcfg="$(mktemp -d)" || return 1
  # firebase-tools runs on a pinned node (pnpm fetches it once): on the box's
  # node 20.19.2 its node-fetch 2.7.0 fails every gzip token response with
  # "Premature close" -> "Failed to authenticate" (SPL-1985, n=3; the same key
  # mints a token in gcloud). 20.18 and 22.11 lack require(esm), which the
  # dlx tree's uuid@14 needs; 22.20.0 has both.
  (cd "$wt" && GOOGLE_APPLICATION_CREDENTIALS="$key" XDG_CONFIG_HOME="$fbcfg" \
    pnpm --config.use-node-version="${FIREBASE_NODE_VERSION:-22.20.0}" dlx firebase-tools@13 \
    deploy --only hosting --project "$SPL_PROJECT" --non-interactive) || rc=$?
  rm -rf "$fbcfg"
  ((rc == 0)) || { do_log "FATAL firebase deploy failed (rc $rc)"; return 1; }
  _hosted_site_probe "$sha" "$site_id" "$host"
}

# _hosted_site_probe <sha> <site_id> <host> - the default URL must serve the
# sha; the custom host is probed too, a WARN while Firebase still verifies it
_hosted_site_probe() {
  local sha="$1" u="https://$2.web.app" got code ok=0
  for _ in 1 2 3 4 5 6; do
    got="$(spl_ld_served "$u/build.json?ts=$(date +%s)" commit)"
    [[ "$got" == "$sha" ]] && { ok=1; break; }
    sleep 10
  done
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$u/")"
  ((ok)) && [[ "$code" == 200 ]] || { do_log "FATAL $u does not serve ${sha:0:12} (build.json commit '${got:0:12}', / -> $code)"; return 1; }
  echo "deploy-hosted-site $ENV ok - $u serves ${sha:0:12}, / -> 200"
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "https://$3/" 2>/dev/null)"
  if [[ "$code" == 200 ]]; then echo "deploy-hosted-site $ENV ok - https://$3/ -> 200"
  else do_log "WARN https://$3/ -> ${code:-no answer}: the custom domain is not serving yet (DNS / Firebase verification / cert)"; fi
}
