#!/bin/bash
#------------------------------------------------------------------------------
# @description The Docs section's publish (owner, prd t1 9f0d751c): a step of
# @description the WUI deploy (workflow 30, dev then prd) that uploads every
# @description tracked *.md of the repo at the deployed commit - the module
# @description READMEs, csi-spl-doc incl. specs/ (the git-spec docs) - to the
# @description env's docs bucket (iac step 051-gcs-docs), repo paths as the
# @description object keys, plus tree.json: {v, sha, files: [{path, title}]},
# @description the index the WUI's /docs explorer and the git-spec linking
# @description lane read. The hub serves both (GET /v1/docs/<repo path>) to
# @description signed-in members; the bucket itself is private.
# @description Skipped: agent-instruction files (CLAUDE.md, GEMINI.md,
# @description AGENTS.md), anything under node_modules/, tpl-gen/ or bin/, the
# @description WUI's built help copy (src/public/help-md: doc/help is
# @description published from its source) and a path the hub would refuse.
# @description The upload mirrors: an object no longer in the repo is deleted.
# @description No docs bucket in cnf for ENV (051 not applied yet) = an INFO
# @description and rc 0, so the deploy step lands before the bucket does.
# @description As the env's project service account, never the owner account.
# @param ENV - required: dev or prd
# @param DRY_RUN (optional) - 1 (default): stage and print tree.json, upload nothing; 0: upload
# @param DOCS_SHA (optional) - the commit tree.json names, default HEAD
# @param GCP_ACCOUNT (optional) - pinned via do_gcp_pin_account
# @example ENV=dev ./run -a do_publish_docs
# @example ENV=prd DRY_RUN=0 ./run -a do_publish_docs
#------------------------------------------------------------------------------
do_publish_docs() {
  do_require_bin git jq || return 1
  spl_require_cloud_env || return 1
  local dry="${DRY_RUN:-1}" g=(git -C "$APP_PATH") sha
  sha="$("${g[@]}" rev-parse -q --verify "${DOCS_SHA:-HEAD}^{commit}" 2>/dev/null)" ||
    { do_log "FATAL DOCS_SHA is not a commit in $APP_PATH: '${DOCS_SHA:-HEAD}'"; return 1; }

  local d
  d="$(mktemp -d)" || return 1
  # shellcheck disable=SC2064
  trap "rm -rf '$d'; trap - RETURN" RETURN
  spl_docs_stage "$d/stage" "$sha" || return 1
  local n
  n="$(jq '.files | length' "$d/stage/tree.json")"
  ((n > 0)) || { do_log "FATAL no .md to publish in $APP_PATH"; return 1; }

  if [[ "$dry" != 0 ]]; then
    cat "$d/stage/tree.json"
    do_log "INFO DRY_RUN: $n doc(s) of ${sha:0:8} staged, nothing uploaded (DRY_RUN=0 uploads them)" >&2
    return 0
  fi

  do_require_bin yq gcloud || return 1
  do_spl_cloud_cnf || return 1
  local bucket
  bucket="$(yq -r '.env.steps."051-gcs-docs".docs_bucket_name // ""' "$SPL_CNF")"
  if [[ -z "$bucket" || "$bucket" == null ]]; then
    do_log "INFO no docs bucket in cnf for $ENV (steps.051-gcs-docs.docs_bucket_name): nothing published"
    return 0
  fi
  do_gcp_pin_account "$SPL_CNF" || return 1
  do_gcp_require_live_account "$GCP_ACCOUNT" || return 1
  spl_docs_upload "$d/stage" "$bucket" || { do_log "FATAL upload to gs://$bucket failed"; return 1; }
  printf '{"env":"%s","bucket":"%s","sha":"%s","docs":%d}\n' "$ENV" "$bucket" "${sha:0:8}" "$n"
  do_log "OK $n doc(s) of ${sha:0:8} published to gs://$bucket"
}

# spl_docs_stage <dir> <sha> -> <dir>/<repo path> for every published .md and
# <dir>/tree.json. The hub's key rule (internal/hub/docs.go ValidDocsPath):
# segments of [A-Za-z0-9._-], none starting with a dot, ending in .md.
spl_docs_stage() {
  local out="$1" sha="$2" p title files="$1.files.jsonl"
  mkdir -p "$out" || return 1
  : >"$files"
  while IFS= read -r -d '' p; do
    case "/$p" in
      */CLAUDE.md | */GEMINI.md | */AGENTS.md) continue ;;
      */node_modules/* | /tpl-gen/* | */bin/* | /csi-spl-wui/src/public/help-md/*) continue ;;
    esac
    if ! [[ "$p" =~ ^[A-Za-z0-9_-][A-Za-z0-9._-]*(/[A-Za-z0-9_-][A-Za-z0-9._-]*)*\.md$ ]] || ((${#p} > 512)); then
      do_log "WARN skipped (not a docs path): $p"
      continue
    fi
    [[ -f "$APP_PATH/$p" ]] || continue
    mkdir -p "$out/$(dirname "$p")" && cp "$APP_PATH/$p" "$out/$p" || return 1
    title="$(sed -n '/^#[[:space:]]\{1,\}[^[:space:]]/{s/^#[[:space:]]\{1,\}\(.*[^[:space:]]\)[[:space:]]*$/\1/p;q;}' "$out/$p")"
    jq -cn --arg path "$p" --arg title "$title" '{path: $path} + (if $title != "" then {title: $title} else {} end)' >>"$files" || return 1
  done < <(git -C "$APP_PATH" ls-files -z -- '*.md')
  jq -s --arg sha "$sha" '{v: 1, sha: $sha, files: .}' "$files" >"$out/tree.json" || return 1
  rm -f "$files"
}

# spl_docs_upload <dir> <bucket>: mirror <dir> onto the bucket (deletes what
# the repo no longer holds), as the pinned project SA.
spl_docs_upload() {
  gcloud storage rsync "$1" "gs://$2" --recursive --delete-unmatched-destination-objects \
    --account="$GCP_ACCOUNT" --quiet
}
