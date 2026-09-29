#!/bin/bash
#------------------------------------------------------------------------------
# @description Cut this week's STABLE release (spec 047 W10, SPL-1170): a pin a
# @description self-hoster can check out, with release notes that say what
# @description changed since the last one. Every deploy mints a v<X.Y.Z> tag
# @description (do_release_version), ~5 an hour, so a v-tag is a build, not a
# @description release; the stable train is cut from them once a week by
# @description workflow 55.
# @description   1. the commit: STABLE_FROM (a ref), else the commit the hub at
# @description      STABLE_FROM_URL (or STABLE_FROM_ENV's hub) reports on
# @description      /version - what prd RUNS -, else the highest v-tag
# @description   2. the tag: stable-<YYYY-MM-DD> (UTC), immutable. There is no
# @description      moving `stable` tag (a tag never moves without --force); the
# @description      newest stable is the GitHub release marked latest
# @description   3. the notes, since the previous stable-* tag (first cut: the
# @description      commits of the last STABLE_FIRST_SINCE): the commits by
# @description      kind (feat / fix / perf / other), the DB migrations added
# @description      (forward-only: take a dump first) and the upgrade steps
# @description Nothing new since the last stable (or today's tag already on the
# @description same commit) = exit 0, nothing cut. Today's tag on ANOTHER
# @description commit = FATAL (tags never move).
# @description Writes the notes to STABLE_NOTES_FILE and prints them; `tag=`,
# @description `version=`, `notes_file=` go to $GITHUB_OUTPUT when set.
# @description Dry run unless DRY_RUN=0; DRY_RUN=0 pushes the tag and, unless
# @description STABLE_GH_RELEASE=0, creates the GitHub release (gh, GH_TOKEN).
# @param STABLE_FROM (optional) - the ref to release, default see 1.
# @param STABLE_FROM_URL (optional) - a hub /version URL whose .commit is released
# @param STABLE_FROM_ENV (optional) - dev | prd: that env's hub /version (host from cnf env.dns.api_fqdn)
# @param STABLE_DATE (optional) - YYYY-MM-DD, default today (UTC)
# @param STABLE_FIRST_SINCE (optional) - git --since for the first cut, default "7 days ago"
# @param STABLE_NOTES_FILE (optional) - where the notes go, default a temp file
# @param STABLE_NOTES_MAX (optional) - rows per section, default 100 (the rest is counted)
# @param STABLE_GH_RELEASE (optional) - 1 (default) or 0: no GitHub release
# @param RELEASE_REMOTE (optional) - the remote holding the tags, default origin
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_release_stable
# @example STABLE_FROM_URL=https://<api-host>/version DRY_RUN=0 ./run -a do_release_stable
#------------------------------------------------------------------------------
do_release_stable() {
  do_require_bin git || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local g=(git -C "$APP_PATH") remote="${RELEASE_REMOTE:-origin}"
  local day="${STABLE_DATE:-$(date -u +%Y-%m-%d)}"
  [[ "$day" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || { do_log "FATAL STABLE_DATE must be YYYY-MM-DD, got: '$day'"; return 1; }
  "${g[@]}" fetch -q --force "$remote" '+refs/tags/v*:refs/tags/v*' '+refs/tags/stable-*:refs/tags/stable-*' 2>/dev/null ||
    do_log "WARN cannot fetch the tags from $remote: the answer below uses the local tags"

  local sha
  sha="$(spl_stable_commit)" || return 1
  local tag="stable-$day" version prev
  version="$("${g[@]}" tag --points-at "$sha" -l 'v*' | sed 's/^v//' | spl_version_max)"
  prev="$("${g[@]}" tag -l 'stable-*' | sort | grep -vx "$tag" | tail -1)"

  local have
  have="$("${g[@]}" rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null)"
  if [[ -n "$have" && "$have" != "$sha" ]]; then
    do_log "FATAL $tag already names ${have:0:8}, not ${sha:0:8}: a tag never moves (pass another STABLE_DATE)"; return 1
  elif [[ -n "$have" ]]; then
    do_log "OK $tag already names ${sha:0:8}: nothing to cut"; return 0
  fi
  if [[ -n "$prev" ]] && "${g[@]}" merge-base --is-ancestor "$sha" "$prev"; then
    do_log "OK nothing new since $prev (${sha:0:8} is already in it): nothing to cut"; return 0
  fi

  local notes="${STABLE_NOTES_FILE:-$(mktemp)}"
  spl_stable_notes "$sha" "$prev" "$tag" "$version" >"$notes" || return 1
  cat "$notes"
  if ((dry)); then
    do_log "OK DRY_RUN would tag ${sha:0:8} as $tag${version:+ (v$version)} on $remote; notes in $notes. Re-run with DRY_RUN=0 to cut it."
    return 0
  fi
  "${g[@]}" tag "$tag" "$sha" && "${g[@]}" push -q "$remote" "refs/tags/$tag" ||
    { do_log "FATAL cannot push $tag to $remote"; return 1; }
  if [[ "${STABLE_GH_RELEASE:-1}" != 0 ]]; then
    do_require_bin gh || return 1
    (cd "$APP_PATH" && gh release create "$tag" --verify-tag --latest \
      --title "$tag${version:+ (v$version)}" --notes-file "$notes") ||
      { do_log "FATAL $tag is pushed but the GitHub release was not created: re-run gh release create $tag"; return 1; }
  fi
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    { echo "tag=$tag"; echo "version=$version"; echo "notes_file=$notes"; } >>"$GITHUB_OUTPUT"
  fi
  do_log "OK cut $tag = ${sha:0:8}${version:+ (v$version)} since ${prev:-the start}"
}

# stdout carries ONLY the sha (the caller captures it; ./run's do_log prints
# to stdout, so every log line here goes to stderr - the do_release_version
# trap of run 36372654214).
# spl_stable_commit -> the full sha to release
# (STABLE_FROM > STABLE_FROM_URL > STABLE_FROM_ENV's hub /version > highest v-tag)
spl_stable_commit() {
  local ref="${STABLE_FROM:-}" body v url="${STABLE_FROM_URL:-}"
  if [[ -z "$ref" && -z "$url" && -n "${STABLE_FROM_ENV:-}" ]]; then
    local fqdn
    ENV="$STABLE_FROM_ENV" do_spl_cloud_cnf >&2 || return 1
    fqdn="$(yq -r '.env.dns.api_fqdn // ""' "$SPL_CNF")"
    [[ -n "$fqdn" && "$fqdn" != null ]] || { do_log "FATAL cnf env.dns.api_fqdn is empty for $STABLE_FROM_ENV" >&2; return 1; }
    url="https://$fqdn/version"
  fi
  if [[ -z "$ref" && -n "$url" ]]; then
    do_require_bin curl jq >&2 || return 1
    body="$(curl -fsS --max-time 15 "$url")" || { do_log "FATAL cannot read $url" >&2; return 1; }
    ref="$(jq -r '.commit // ""' <<<"$body")"
    [[ "$ref" =~ ^[0-9a-f]{7,40}$ ]] || { do_log "FATAL $url carries no commit: $body" >&2; return 1; }
    do_log "INFO $url runs ${ref:0:8}: that commit is released" >&2
  fi
  if [[ -z "$ref" ]]; then
    v="$(git -C "$APP_PATH" tag -l 'v*' | sed 's/^v//' | spl_version_max)"
    [[ -n "$v" ]] || { do_log "FATAL no v-tag to release (and no STABLE_FROM)" >&2; return 1; }
    ref="v$v"
  fi
  git -C "$APP_PATH" rev-parse -q --verify "$ref^{commit}" ||
    { do_log "FATAL not a commit here: '$ref' (fetch it first)" >&2; return 1; }
}

# spl_stable_notes <sha> <prev-tag|""> <tag> <version|""> -> markdown on stdout
spl_stable_notes() {
  local sha="$1" prev="$2" tag="$3" version="$4" range=() log
  if [[ -n "$prev" ]]; then range=("$prev..$sha"); else range=(--since="${STABLE_FIRST_SINCE:-7 days ago}" "$sha"); fi
  log="$(git -C "$APP_PATH" log --no-merges --format='%h%x09%s' "${range[@]}")" || return 1
  local n; n="$(grep -c . <<<"$log")"
  echo "# $tag${version:+ (v$version)}"
  echo
  if [[ -n "$prev" ]]; then echo "Commit \`${sha:0:12}\`, $n commits since $prev."
  else echo "Commit \`${sha:0:12}\`, the first stable release: $n commits since ${STABLE_FIRST_SINCE:-7 days ago}."; fi
  # a GitHub release body holds 125 000 characters; ~200 per row
  local kind title max="${STABLE_NOTES_MAX:-100}" more="$prev..$tag"
  [[ -n "$prev" ]] || more="--since='${STABLE_FIRST_SINCE:-7 days ago}' $tag"
  for kind in feat fix perf other; do
    case "$kind" in
      feat) title="Features" ;; fix) title="Fixes" ;; perf) title="Performance" ;; other) title="Other changes" ;;
    esac
    local rows
    rows="$(awk -F'\t' -v k="$kind" '
      { t = $2; sub(/[(:!].*/, "", t) }
      (k == "other" && t != "feat" && t != "fix" && t != "perf") || t == k {
        s = $2; if (length(s) > 200) s = substr(s, 1, 197) "..."; print "- `" $1 "` " s }' <<<"$log")"
    [[ -n "$rows" ]] || continue
    local count; count="$(grep -c . <<<"$rows")"
    echo; echo "## $title ($count)"; echo; head -n "$max" <<<"$rows"
    if ((count > max)); then echo "- ... and $((count - max)) more: \`git log --no-merges $more\`"; fi
  done
  local mig=()
  mapfile -t mig < <(git -C "$APP_PATH" log --no-merges --diff-filter=A --name-only --format= "${range[@]}" \
    -- csi-spl-rdb/src/sql | grep . | sed 's#.*/##' | sort -u)
  echo; echo "## Database migrations (${#mig[@]})"; echo
  if ((${#mig[@]})); then
    echo "Forward-only: there is no downgrade. Take a dump before you upgrade."
    echo; printf -- '- `%s`\n' "${mig[@]}"
  else
    echo "None${prev:+ since $prev}."
  fi
  cat <<EOF

## Upgrade (docker compose)

1. Take a dump of the database (README: Backup, restore and upgrade).
2. \`git fetch --tags && git checkout $tag\`
3. \`docker compose up --build -d\`: hub-init applies the new migrations before the hub starts.

Security fixes land on master first; the next weekly stable carries them.
EOF
}
