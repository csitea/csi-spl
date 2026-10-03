#!/bin/bash
#------------------------------------------------------------------------------
# @description Print the release-note line of one commit (spec 065 7.2 / 7.3):
# @description   <sha> v<X.Y.Z> <link>
# @description the line every "released to dev / prd" post carries, one per
# @description sha, so nobody hand-builds the URL. The link is
# @description https://<env.dns.fqdn>/releases/<full sha>, the WUI host of ENV
# @description read from the cnf (do_spl_cloud_cnf), never a literal host.
# @description The version is the FIRST v-tag that contains the commit (the
# @description deploy that shipped it, as the release_note table records it);
# @description a commit no deploy has shipped yet prints `unreleased` in that
# @description field, with a WARN on stderr, and still exits 0: the link
# @description works before the deploy (7.2).
# @description An unknown sha, or a SHA that is not 7..40 hex, is FATAL, rc 1.
# @description Only the line goes to stdout; every log line goes to stderr.
# @param SHA - required: the commit, a 7..40 char hex sha or prefix
# @param ENV - required: dev or prd, the WUI the commit was released to
# @param RELEASE_REMOTE (optional) - the remote holding the tags, default origin
# @example SHA=9f175b2e ENV=prd ./run -a do_release_note_link
#------------------------------------------------------------------------------
do_release_note_link() {
  do_require_bin git yq || return 1
  spl_require_cloud_env >&2 || return 1
  local want="${SHA:-}" remote="${RELEASE_REMOTE:-origin}" g=(git -C "$APP_PATH")
  [[ "$want" =~ ^[0-9a-fA-F]{7,40}$ ]] ||
    { do_log "FATAL SHA must be a 7..40 char hex sha, got: '$want'" >&2; return 1; }
  do_spl_cloud_cnf >&2 || return 1
  local fqdn
  fqdn="$(yq -r '.env.dns.fqdn // ""' "$SPL_CNF")"
  [[ -n "$fqdn" && "$fqdn" != null ]] || { do_log "FATAL cnf env.dns.fqdn is empty for $ENV" >&2; return 1; }

  "${g[@]}" fetch -q --force "$remote" master '+refs/tags/v*:refs/tags/v*' 2>/dev/null ||
    do_log "WARN cannot fetch master and the v-tags from $remote: the answer below uses the local refs" >&2
  local sha
  sha="$("${g[@]}" rev-parse -q --verify "$want^{commit}" 2>/dev/null)" ||
    { do_log "FATAL not a commit in $APP_PATH: '$want' (unknown or ambiguous sha)" >&2; return 1; }

  local v
  v="$("${g[@]}" tag --contains "$sha" -l 'v*' | sed 's/^v//' | spl_version_min)"
  if [[ -n "$v" ]]; then
    v="v$v"
  else
    v=unreleased
    do_log "WARN ${sha:0:8} is in no v-tag yet: no deploy has shipped it" >&2
  fi
  echo "${sha:0:8} $v https://$fqdn/releases/$sha"
}
