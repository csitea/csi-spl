#!/bin/bash
#------------------------------------------------------------------------------
# @description Mint (or re-read) the release version of one commit: the
# @description number the hub image is tagged with and the WUI footer shows.
# @description Called by the deploy jobs of 20 (hub) and 30 (WUI) at deploy
# @description time, so every deploy carries a new version with no agent
# @description rolling anything by hand. The rule and the race handling live
# @description in lib/bash/funcs/spl-release-version.func.sh:
# @description   - the commit already has a v<X.Y.Z> tag -> that version
# @description   - else one odometer step past the highest v-tag on the remote
# @description     (or .version when a human raised it above every tag),
# @description     claimed by pushing the tag; a lost race takes the next one
# @description   - after 9.9.9 comes 1.0.1 of the next cycle: its tag is
# @description     v1.0.1-c2 (the cycle lives only in the tag name), what is
# @description     printed and shown stays the plain 1.0.1
# @description Prints the bare version on stdout (logs go to stderr), and `version=<v>` plus
# @description `key=<release key>` (the tag minus its v, e.g. 1.0.1-c2) into
# @description $GITHUB_OUTPUT when that is set. Dry run unless DRY_RUN=0: a dry
# @description run prints what it WOULD claim and pushes nothing.
# @param RELEASE_SHA (optional) - the commit to version, default HEAD
# @param RELEASE_REMOTE (optional) - the remote holding the tags, default origin
# @param DRY_RUN (optional) - 1 (default) or 0
# @param RELEASE_TRUNK (optional) - the trunk branch, default master
# @description rc 3 (and `stale=true` in $GITHUB_OUTPUT): the tag was refused
# @description because the commit's .github/workflows differs from trunk head's.
# @example ./run -a do_release_version
# @example RELEASE_SHA=9dff8571 DRY_RUN=0 ./run -a do_release_version
#------------------------------------------------------------------------------
do_release_version() {
  do_require_bin git || return 1
  local dry=1
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  local sha="${RELEASE_SHA:-HEAD}" remote="${RELEASE_REMOTE:-origin}" floor v k latest mine
  floor="$(tr -d '[:space:]' <"$APP_PATH/.version" 2>/dev/null)"

  if ((dry)); then
    sha="$(git -C "$APP_PATH" rev-parse --verify -q "$sha^{commit}")" || { do_log "FATAL not a commit: '$RELEASE_SHA'" >&2; return 1; }
    git -C "$APP_PATH" fetch -q --force "$remote" '+refs/tags/v*:refs/tags/v*' 2>/dev/null ||
      do_log "WARN cannot fetch the v-tags from $remote: the answer below uses the local tags" >&2
    mine="$(git -C "$APP_PATH" tag --points-at "$sha" -l 'v*' | sed 's/^v//' | spl_release_key_min)"
    if [[ -n "$mine" ]]; then
      do_log "OK DRY_RUN ${sha:0:8} already carries v$mine" >&2
      spl_release_key_display "$mine"; return 0
    fi
    latest="$(git -C "$APP_PATH" tag -l 'v*' | sed 's/^v//' | spl_release_key_max)"
    if [[ -z "$latest" ]] || spl_release_key_gt "$floor" "$latest"; then v="$floor"; else v="$(spl_release_key_step "$latest")" || return 1; fi
    do_log "OK DRY_RUN would claim v$v for ${sha:0:8} on $remote (highest tag: ${latest:+v$latest}${latest:-none}, floor .version: $floor). Re-run with DRY_RUN=0 to claim it." >&2
    spl_release_key_display "$v"; return 0
  fi

  # rc 3 = the target is stale against trunk head's workflows (see the lib)
  k="$(spl_release_mint "$APP_PATH" "$sha" "$floor" "$remote")" || return $?
  v="$(spl_release_key_display "$k")" && spl_version_valid "$v" ||
    { do_log "FATAL the minted release key is not d.d.d[-c<N>]: '$k'" >&2; return 1; }
  [[ -n "${GITHUB_OUTPUT:-}" ]] && printf 'version=%s\nkey=%s\n' "$v" "$k" >>"$GITHUB_OUTPUT"
  do_log "OK release version of $(git -C "$APP_PATH" rev-parse --short "$sha") is $v (tag v$k on $remote)" >&2
  echo "$v"
}
