#!/usr/bin/env bash
#------------------------------------------------------------------------------
# @description The language check of new WUI text through Google Cloud
# @description Translation v3 (SPL-6174; owner HUM-10 msg 36b3ff7f: "google
# @description translationd Api 's are now available - use them - better and
# @description cheaper"). It replaces the agy language review as the required
# @description check; the rule's one home is the fleet CLAUDE.md source
# @description 20-spawn-an-agent.md (Language rule).
# @description For each non-English locale file (LANG_GCT_FILES, else every
# @description one that differs from LANG_GCT_BASE; an en.json change asks
# @description every locale), the keys it adds or changes and the keys whose
# @description en source changed go through the API: a fresh en -> <lang>
# @description translation (the reference, placeholders kept as
# @description translate="no") and the written text <lang> -> en (the back
# @description translation). Mark: match = the text equals the reference after
# @description normalisation (NFC, case folded, whitespace collapsed, trailing
# @description punctuation dropped), else differs: an exact compare against a
# @description fresh translation needs no similarity threshold, and a
# @description "differs" row is for the author to read and fold in by hand.
# @description A locale string whose {placeholders} differ from its en
# @description source is a FAILURE (mark placeholder), whatever the API says.
# @description The report, one row per key, goes to
# @description LANG_GCT_OUT_DIR/<run id>.json; commit it with the locale
# @description change and put the printed line in the commit body:
# @description   Lang-review: gct <run id>
# @description which the pre-push part wui-lang-review and CI workflow 10
# @description check (csi-spl-iac check-pre-push-lang-review.func.sh).
# @description Identity: the env's project SA from its key
# @description ($HOME/.gcp/.<org>/key-<project>.json), its token minted in a
# @description throwaway CLOUDSDK_CONFIG (CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE,
# @description --account = the key's client_email) and handed to the script
# @description on fd 3; never the owner account, never ~/.config/gcloud, the
# @description token in no argv, env, file or log. A refusal prints the API's
# @description status and message and the grant it needs.
# @description Exit 0 checked, 1 a placeholder failure (report written), 2 no
# @description key, no token, or an API error (no report).
# @param ENV (optional) - whose project SA calls the API, default dev
# @param LANG_GCT_BASE (optional) - the rev the locale files are compared with, default origin/master
# @param LANG_GCT_FILES (optional) - space-separated locale files (repo-relative); default every changed one
# @param LANG_GCT_TREE (optional) - the checkout, default $APP_PATH
# @param LANG_GCT_LOCALES (optional) - the repo-relative locales dir holding en.json; default the one dir all LANG_GCT_FILES share, else csi-spl-wui/i18n/locales
# @param LANG_GCT_OUT_DIR (optional) - default <tree>/<locales dir's parent>/lang-review (csi-spl: csi-spl-wui/i18n/lang-review)
# @param LANG_GCT_ENDPOINT (optional) - default https://translation.googleapis.com; https only (http on 127.0.0.1 for tests)
# @example ENV=dev ./run -a do_spl_lang_review_gct
# @example ENV=prd LANG_GCT_FILES=csi-spl-wui/i18n/locales/fi.json ./run -a do_spl_lang_review_gct
# @example ENV=dev LANG_GCT_TREE=/opt/<org>/<repo> LANG_GCT_FILES="x-wui/i18n/locales/de.json x-wui/i18n/locales/fi.json" ./run -a do_spl_lang_review_gct
#------------------------------------------------------------------------------

# spl_lgct_header <key> <account>: "Authorization: Bearer <token>" on stdout
# (to a fd, never a variable), minted as the SA of <key> in a throwaway
# CLOUDSDK_CONFIG.
spl_lgct_header() {
  ( CLOUDSDK_CONFIG="$(umask 077; mktemp -d)" || exit 1
    trap 'rm -rf -- "${CLOUDSDK_CONFIG:?}"' EXIT
    export CLOUDSDK_CONFIG CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE="$1"
    account="$2"
    gcloud auth print-access-token --account="${account}" 2> >(sed 's/^/lang-review-gct: gcloud: /' >&2) |
      sed -n 's/^\([A-Za-z0-9._-]\{20,\}\)$/Authorization: Bearer \1/p' )
}

# spl_lgct_locales <file>...: the locales dir on stdout: LANG_GCT_LOCALES,
# else the one dir every file shares, else csi-spl-wui/i18n/locales; two
# dirs and no LANG_GCT_LOCALES is a FATAL, return 2 (SPL-6208).
spl_lgct_locales() {
  local f d dir="${LANG_GCT_LOCALES:-}"
  [[ -n "$dir" ]] && { printf '%s\n' "${dir%/}"; return 0; }
  for f in "$@"; do
    d="$(dirname -- "$f")"
    [[ -z "$dir" || "$d" == "$dir" ]] && { dir="$d"; continue; }
    do_log "FATAL lang-review-gct: LANG_GCT_FILES span two locales dirs ($dir, $d); set LANG_GCT_LOCALES" >&2
    return 2
  done
  printf '%s\n' "${dir:-csi-spl-wui/i18n/locales}"
}

do_spl_lang_review_gct() {
  local env="${ENV:-dev}" tree="${LANG_GCT_TREE:-$APP_PATH}" key account project rc
  local out="${LANG_GCT_OUT_DIR:-}" files=() org_app locales
  org_app="$(basename "${PROJ_PATH:-x-orc}")"; org_app="${org_app%-orc}"
  read -r -a files <<<"${LANG_GCT_FILES:-}"
  locales="$(spl_lgct_locales "${files[@]}")" || return 2
  [[ -n "$out" ]] || out="$tree/$(dirname -- "$locales")/lang-review"
  # the env's cnf (env.gcp.gcp_project) names the project, so the key
  key="$(ENV="$env" do_gcp_sa_key_file "$APP_PATH/${org_app}-cnf/${org_app}")" ||
    { do_log "FATAL lang-review-gct: no project SA key for $env (\$HOME/.gcp/.<org>/key-<project>.json); never the owner account"; return 2; }
  account="$(do_gcp_sa_key_email "$key")" || { do_log "FATAL lang-review-gct: no client_email in the SA key of $env"; return 2; }
  project="$(jq -r '.project_id // ""' "$key" 2>/dev/null)"
  [[ -n "$project" ]] || { do_log "FATAL lang-review-gct: no project_id in the SA key of $env"; return 2; }
  do_log "INFO lang-review-gct: Cloud Translation v3 in $project as its project SA, base ${LANG_GCT_BASE:-origin/master}"
  python3 -I "$PROJ_PATH/src/bash/scripts/lang-review-gct.py" --tree "$tree" --locales "$locales" \
    --base "${LANG_GCT_BASE:-origin/master}" --out-dir "$out" --project "$project" \
    --endpoint "${LANG_GCT_ENDPOINT:-https://translation.googleapis.com}" "${files[@]}" \
    3< <(spl_lgct_header "$key" "$account")
  rc=$?
  case "$rc" in
    0) do_log "OK lang-review-gct: checked; commit the report with the locale change and its 'Lang-review: gct <run id>' line" ;;
    1) do_log "FAIL lang-review-gct: a placeholder differs from en (see the report)" ;;
    *) do_log "FATAL lang-review-gct: no report (see the line above)" ;;
  esac
  return "$rc"
}
