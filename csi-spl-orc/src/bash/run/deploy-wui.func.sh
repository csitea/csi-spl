#!/bin/bash
#------------------------------------------------------------------------------
# @description Deploy the WUI to a cloud env's Firebase Hosting site FROM THIS
# @description BOX, no GitHub in the path: what the deploy job of workflow 30
# @description does, step for step (owner order 2026-10-06, t1 916c8696:
# @description "Deploy either from the SAT or from the Think box").
# @description   1. the commit: SHA, default origin/master head; refused unless
# @description      it is on origin/master. Built from a clean detached
# @description      checkout of it, never from the caller's working tree.
# @description   2. cnf steps.019-firebase-static-site.wui_deploy must be true
# @description   3. a flock per env (one WUI deploy per env on this box)
# @description   4. pnpm install --frozen-lockfile, test:unit + typecheck
# @description      (WUI_SUITE=0 skips them: the lane ran them before landing)
# @description   5. do_release_version (mint: push the v-tag, or re-read it)
# @description   6. nuxt generate with this env's values, config.json,
# @description      build.json {commit, built_at, run, version}
# @description   7. render-wui-firebase-json.sh, wait-for-hub-version.sh
# @description   8. firebase deploy --only hosting as the env's project SA key
# @description      (GOOGLE_APPLICATION_CREDENTIALS, a throwaway firebase
# @description      config dir: a firebase login on this box is never used)
# @description   9. probe <site>.web.app (and <fqdn> when 031 routes it):
# @description      /build.json .commit must be the sha, / must be 200
# @description  10. do_publish_docs + do_release_note_ingest (WARN only, as in 30)
# @description DRY_RUN=1 (default) prints the plan and touches nothing.
# @param ENV - required: dev or prd
# @param SHA (optional) - the commit to deploy, default origin/master head; must be on origin/master
# @param DRY_RUN (optional) - 1 (default): print the plan; 0: deploy
# @param WUI_SUITE (optional) - 1 (default): unit tests + typecheck before the mint; 0: skip
# @param HUB_WAIT_S (optional) - seconds to wait for the hub this WUI needs, default 1800
# @param DEPLOY_LOCK_WAIT_S (optional) - seconds to wait for another deploy's lock, default 0 (refuse)
# @param DEPLOY_LOCK_DIR / DEPLOY_WORK_DIR (optional) - lock dir / parent of the checkout, default under $TMPDIR
# @param KEEP_WORKTREE (optional) - 1 keeps the deploy checkout for a post-mortem
# @example ENV=dev ./run -a do_deploy_wui
# @example ENV=dev DRY_RUN=0 ./run -a do_deploy_wui
# @example ENV=prd DRY_RUN=0 SHA=3ce48b5d5 WUI_SUITE=0 ./run -a do_deploy_wui
#------------------------------------------------------------------------------
do_deploy_wui() {
  spl_require_cloud_env || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_ld_user_bins
  do_require_bin git jq curl flock python3 pnpm || return 1
  do_spl_cloud_cnf || return 1
  local sha cfg on
  sha="$(spl_ld_resolve_sha)" || return 1
  cfg="$(_deploy_wui_cfg "$APP_PATH")" || { do_log "FATAL cannot read the $ENV WUI values from cnf"; return 1; }
  on="$(_deploy_wui_val "$cfg" wui_deploy)"
  [[ "$on" == true ]] || { do_log "FATAL cnf steps.019-firebase-static-site.wui_deploy is not true for $ENV: no WUI deploy (site not provisioned or no go)"; return 1; }
  local site fqdn served
  site="$(_deploy_wui_val "$cfg" site)"; fqdn="$(_deploy_wui_val "$cfg" fqdn)"
  served="$(spl_ld_served "https://$site.web.app/build.json" commit)"

  if ((dry)); then
    local v
    v="$(spl_ld_run "$APP_PATH" do_release_version DRY_RUN=1 RELEASE_SHA="$sha" 2>/dev/null | grep -xE '[0-9]\.[0-9]\.[0-9]' | tail -1)"
    echo "deploy-wui PLAN $ENV ${sha:0:12} (served ${served:0:12}${served:+ }${served:-unknown})"
    echo "  0 lock    $SPL_ORG_APP wui-$ENV (flock), clean checkout of ${sha:0:12}"
    echo "  1 suite   pnpm install --frozen-lockfile; test:unit + typecheck (WUI_SUITE=${WUI_SUITE:-1})"
    echo "  2 mint    do_release_version -> v${v:-?} (predicted; the tag is pushed at DRY_RUN=0)"
    echo "  3 build   nuxt generate (site https://$fqdn), config.json, build.json"
    echo "  4 render  render-wui-firebase-json.sh; wait-for-hub-version.sh (https://$(_deploy_wui_val "$cfg" api_fqdn))"
    echo "  5 deploy  firebase deploy --only hosting --project $(_deploy_wui_val "$cfg" project) (site $site)"
    echo "  6 probe   https://$site.web.app/build.json .commit == ${sha:0:12}$([[ "$(_deploy_wui_val "$cfg" lb_route)" == true ]] && echo " and https://$fqdn")"
    echo "  7 after   do_publish_docs, do_release_note_ingest"
    do_log "OK DRY_RUN nothing was deployed. Re-run with DRY_RUN=0 to deploy." >&2
    return 0
  fi

  local key
  key="$(do_gcp_sa_key_file "$SPL_CNF")" || { do_log "FATAL no project SA key for $SPL_PROJECT under \$HOME/.gcp (the gcp-002 key)"; return 1; }
  spl_ld_lock wui || return 1
  spl_ld_checkout "$sha" || return 1
  local rc=0
  _deploy_wui_steps "$SPL_LD_WT" "$sha" "$key" || rc=$?
  spl_ld_cleanup
  return "$rc"
}

# _deploy_wui_cfg <app-path> -> key=value lines: wf 30's "Read this env's values from cnf"
_deploy_wui_cfg() {
  python3 - "$1/$SPL_ORG_APP-cnf/$SPL_ORG_APP/${ENV}.env.json" <<'PY'
import json, sys
e = json.load(open(sys.argv[1]))["env"]
s19 = e["steps"]["019-firebase-static-site"]
s31 = e["steps"].get("031-gcp-hub-ingress", {})
print("wui_deploy=" + str(s19.get("wui_deploy", False)).lower())
print("project=" + e["gcp"]["gcp_project"])
print("site=" + s19["site_id"])
print("fqdn=" + e["dns"]["fqdn"])
print("api_fqdn=" + e["dns"]["api_fqdn"])
print("tenant=" + s19.get("wui_default_tenant", ""))
print("auth_base=" + s19.get("wui_auth_base", ""))
print("lb_route=" + ("true" if s31.get("wui_origin_host") else "false"))
print("default_locale=" + e.get("i18n", {}).get("default_locale", "en"))
print("tenant_hosts=" + ("1" if s19.get("wui_tenant_hosts") else "0"))
perf = e.get("perf", {})
print("perf_rum_enabled=" + ("1" if perf.get("rum_enabled") else "0"))
print("perf_sample_rate=" + str(perf.get("sample_rate", 1)))
print("lobby_task_id=" + str(e.get("hub", {}).get("env", {}).get("SPOOL_HUB_LOBBY_TASK_ID", "")).strip())
wui = e.get("wui", {})
for k in ("repo_web_url", "repo_clone_url", "repo_commit_path", "repo_help_path"):
    print(k + "=" + str(wui.get(k) or "").strip())
print("seo_index=" + ("1" if wui.get("seo_index") else "0"))
PY
}

# _deploy_wui_val <cfg> <key> -> the value of <key> in the cfg lines
_deploy_wui_val() { sed -n "/^$2=/{s/^$2=//p;q}" <<<"$1"; }

# _deploy_wui_generate <wui-dir> <cfg> <version> - nuxt generate with this env's values
_deploy_wui_generate() {
  (cd "$1" && NUXT_PUBLIC_USE_MOCK=0 NUXT_PUBLIC_AUTH_BASE="$(_deploy_wui_val "$2" auth_base)" \
    NUXT_PUBLIC_DEFAULT_LOCALE="$(_deploy_wui_val "$2" default_locale)" \
    NUXT_PUBLIC_SEO_INDEX="$(_deploy_wui_val "$2" seo_index)" \
    NUXT_PUBLIC_SITE_URL="https://$(_deploy_wui_val "$2" fqdn)" NUXT_PUBLIC_APP_VERSION="$3" pnpm run generate)
}

# _deploy_wui_stamp <wui-dir> <cfg> <sha> <version> - config.json + build.json, as wf 30 writes them
_deploy_wui_stamp() {
  local w="$1" c="$2" sha="$3" v="$4" k
  local -a kv=()
  for k in api_fqdn auth_base fqdn tenant tenant_hosts lobby_task_id perf_rum_enabled perf_sample_rate \
           repo_web_url repo_clone_url repo_commit_path repo_help_path; do
    kv+=("CFG_${k^^}=$(_deploy_wui_val "$c" "$k")")
  done
  env "${kv[@]}" ENV_NAME="$ENV" python3 - >"$w/.output/public/config.json" <<'PY' || return 1
import json, os
g = lambda k: os.environ["CFG_" + k]
print(json.dumps({
    "apiBase": "https://" + g("API_FQDN"), "authBase": g("AUTH_BASE"),
    "siteUrl": "https://" + g("FQDN"), "tenant": g("TENANT"),
    "tenantHosts": g("TENANT_HOSTS"), "envName": os.environ["ENV_NAME"],
    "lobbyTaskId": g("LOBBY_TASK_ID"), "perfRum": g("PERF_RUM_ENABLED"),
    "perfSampleRate": g("PERF_SAMPLE_RATE"),
    "repoWebUrl": g("REPO_WEB_URL"), "repoCloneUrl": g("REPO_CLONE_URL"),
    "repoCommitPath": g("REPO_COMMIT_PATH"), "repoHelpPath": g("REPO_HELP_PATH"),
}))
PY
  printf '{"commit":"%s","built_at":"%s","run":"%s","version":"%s"}\n' \
    "$sha" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "local-$(id -un)" "$v" >"$w/.output/public/build.json"
}

# _deploy_wui_steps <wt> <sha> <key-file> - steps 4..10 above
_deploy_wui_steps() {
  local wt="$1" sha="$2" key="$3" cfg w="$1/$SPL_ORG_APP-wui" pre
  cfg="$(_deploy_wui_cfg "$wt")" || return 1
  (cd "$w" && pnpm install --frozen-lockfile >/dev/null) || { do_log "FATAL pnpm install failed"; return 1; }
  if [[ "${WUI_SUITE:-1}" != 0 ]]; then
    (cd "$w" && pnpm run test:unit && pnpm run typecheck) || { do_log "FATAL the WUI suite is red at ${sha:0:12}: no mint, no deploy"; return 1; }
  fi
  pre="$(spl_ld_predict "$wt" "$sha")"
  spl_ld_mint "$wt" "$sha" || return $?
  [[ "$pre" == "$SPL_LD_VERSION" ]] || do_log "INFO minted $SPL_LD_VERSION (predicted ${pre:-none})"
  echo "deploy-wui $ENV release $SPL_LD_VERSION for ${sha:0:12}"
  _deploy_wui_generate "$w" "$cfg" "$SPL_LD_VERSION" || { do_log "FATAL nuxt generate failed"; return 1; }
  _deploy_wui_stamp "$w" "$cfg" "$sha" "$SPL_LD_VERSION" || { do_log "FATAL cannot write config.json / build.json"; return 1; }
  (cd "$wt" && ENV="$ENV" bash csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh) || { do_log "FATAL render-wui-firebase-json.sh failed"; return 1; }

  local cycle
  cycle="$(source "$wt/csi-spl-orc/lib/bash/funcs/spl-release-version.func.sh" && spl_release_cycle_now "$wt")" || cycle=1
  (cd "$wt" && HUB_URL="https://$(_deploy_wui_val "$cfg" api_fqdn)" WANT_VERSION="$(tr -d '[:space:]' <.version)" \
    TIMEOUT_S="${HUB_WAIT_S:-1800}" RELEASE_CYCLE="$cycle" bash csi-spl-orc/src/bash/scripts/wait-for-hub-version.sh) ||
    { do_log "FATAL the $ENV hub is older than this WUI needs: deploy the hub first (do_deploy_hub)"; return 1; }

  local fbcfg rc=0
  fbcfg="$(mktemp -d)" || return 1
  (cd "$w" && GOOGLE_APPLICATION_CREDENTIALS="$key" XDG_CONFIG_HOME="$fbcfg" \
    pnpm dlx firebase-tools@13 deploy --only hosting --project "$(_deploy_wui_val "$cfg" project)" --non-interactive) || rc=$?
  rm -rf "$fbcfg"
  ((rc == 0)) || { do_log "FATAL firebase deploy failed (rc $rc)"; return 1; }

  _deploy_wui_probe "$cfg" "$sha" || return 1
  spl_ld_run "$wt" do_publish_docs ENV="$ENV" DRY_RUN=0 GCP_SA_KEY_FILE="$key" DOCS_SHA="$sha" ||
    do_log "WARN do_publish_docs failed (as in 30, not fatal)"
  spl_ld_run "$wt" do_release_note_ingest ENV="$ENV" DRY_RUN=0 GCP_SA_KEY_FILE="$key" RELEASE_SHA="$sha" ||
    do_log "WARN do_release_note_ingest failed (as in 30, not fatal)"
  echo "deploy-wui $ENV OK https://$(_deploy_wui_val "$cfg" site).web.app/build.json commit=$sha version=$SPL_LD_VERSION"
}

# _deploy_wui_probe <cfg> <sha> - wf 30's "Probe the deployed commit"
_deploy_wui_probe() {
  local cfg="$1" sha="$2" site fqdn u got code ok rc=0 root
  site="$(_deploy_wui_val "$cfg" site)"; fqdn="$(_deploy_wui_val "$cfg" fqdn)"
  local -a urls=("https://$site.web.app")
  if [[ "$(_deploy_wui_val "$cfg" lb_route)" == true ]]; then
    root="$(curl -fsS --max-time 15 "https://$fqdn/" 2>/dev/null)" || root=""
    grep -qi '<html' <<<"$root" && urls+=("https://$fqdn")
  fi
  for u in "${urls[@]}"; do
    ok=0
    for _ in 1 2 3 4 5 6; do
      got="$(spl_ld_served "$u/build.json?ts=$(date +%s)" commit)"
      [[ "$got" == "$sha" ]] && { ok=1; break; }
      sleep 10
    done
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$u/")"
    if ((ok)) && [[ "$code" == 200 ]]; then echo "deploy-wui $ENV ok - $u serves ${sha:0:12}, / -> 200"
    else do_log "FATAL $u does not serve ${sha:0:12} (build.json commit '${got:0:12}', / -> $code)"; rc=1; fi
  done
  return "$rc"
}
