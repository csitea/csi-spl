#!/bin/bash
#------------------------------------------------------------------------------
# The release version is MINTED BY CI at deploy time, never rolled by hand
# (owner, 2026-09-27: "so many updates and the version is 1.0.1"; the WUI went
# to prd ~105 times that day at one version and 7 hub commits sat off prd,
# because the hub only shipped on a hand-made tag bump).
#
# The counter is the remote's git tags `v<X.Y.Z>`, one per deployed commit:
#   - a commit that already carries a v-tag reuses it, so the hub (20) and the
#     WUI (30) deploying the same sha, and its dev and prd jobs, all get ONE
#     version, and a re-run or a dispatch rollback gets the same number back;
#   - otherwise next = one odometer step past the highest v-tag (each digit
#     0-9, carry at 9: 1.1.9 -> 1.2.0), and the tag is PUSHED to claim it.
#     Tags never move without --force, so the remote is the lock: when two
#     lanes race for the same number, one push wins and the loser re-reads the
#     tags and takes the next. No lane computes a version from its own tree,
#     so parallel lanes cannot collide.
#   - .version (the FLOOR) only matters when it is HIGHER than every tag: that
#     is how a human asks for a deliberate jump (e.g. 2.0.0). It stays equal to
#     cnf hub.image.tag (hub-version-tag-parity) and odometer-legal
#     (hub-version-digits).
#------------------------------------------------------------------------------

# spl_version_valid <v> -> 0 when <v> is an odometer version (three 0-9 digits)
spl_version_valid() { [[ "${1:-}" =~ ^[0-9]\.[0-9]\.[0-9]$ ]]; }

# spl_version_step <v> -> the next odometer value; rc 1 on 9.9.9 or a bad value
spl_version_step() {
  spl_version_valid "${1:-}" || return 1
  local a b c
  IFS=. read -r a b c <<<"$1"
  c=$((c + 1))
  if ((c > 9)); then c=0; b=$((b + 1)); fi
  if ((b > 9)); then b=0; a=$((a + 1)); fi
  ((a > 9)) && return 1
  echo "$a.$b.$c"
}

# spl_version_gt <a> <b> -> 0 when a > b (both odometer-valid)
spl_version_gt() {
  spl_version_valid "${1:-}" && spl_version_valid "${2:-}" || return 1
  ((10#${1//./} > 10#${2//./}))
}

# spl_version_max -> the highest odometer version among stdin lines ("" if none)
spl_version_max() {
  local v best=""
  while IFS= read -r v; do
    spl_version_valid "$v" || continue
    if [[ -z "$best" ]] || spl_version_gt "$v" "$best"; then best="$v"; fi
  done
  echo "$best"
}

# spl_version_min -> the lowest odometer version among stdin lines ("" if none)
spl_version_min() {
  local v best=""
  while IFS= read -r v; do
    spl_version_valid "$v" || continue
    if [[ -z "$best" ]] || spl_version_gt "$best" "$v"; then best="$v"; fi
  done
  echo "$best"
}

# spl_github_owner_repo <remote-url> -> "owner/repo" on stdout when the URL is a
# github.com remote (https, ssh, or token-embedded), nothing otherwise. Used to
# decide whether a tag can be claimed through the GitHub REST API.
spl_github_owner_repo() {
  local url="${1:-}" rest owner repo
  case "$url" in *github.com[:/]*) ;; *) return 0 ;; esac
  rest="${url%.git}"
  rest="${rest#*github.com}"
  rest="${rest#[:/]}"
  owner="${rest%%/*}"; rest="${rest#*/}"; repo="${rest%%/*}"
  [[ -n "$owner" && -n "$repo" ]] && echo "$owner/$repo"
}

# Why the tag is claimed through the REST API and not `git push` in CI:
# the deploy runs under the workflow's default GITHUB_TOKEN, a GitHub App
# installation token. GitHub refuses that token any ref update whose TARGET
# COMMIT's diff touches a .github/workflows/* file, unless the App carries the
# `workflows` permission -- and a workflow cannot grant its own GITHUB_TOKEN
# that scope (it is not one of the permissions: keys). The check is on the ref's
# target diff, not on object transfer, so `fetch-depth: 0` does NOT cure it (the
# commit's own diff still touches a workflow file). Creating the tag through
# `POST /repos/{owner}/{repo}/git/refs` against a commit that already exists on
# the remote writes no workflow-file content, so it needs only `contents: write`
# and is allowed. (CLE-77788 / CLE-001 P0; earlier SPL-1194 tried fetch-depth 0.)
#
# ...EXCEPT when the target's .github/workflows differs from trunk head's: the
# API is refused too (403 "Resource not accessible by integration"), lightweight
# AND annotated (probe run 36970563047, 2026-10-02, contents:write token: the
# same commit 403, trunk head 201). That happens whenever a workflow-touching
# commit lands between a push and its deploy's mint -- 3 hub deploys in a row
# on 2026-10-02 05:24..05:41Z (CLE-77950). Only a token with the `workflows`
# permission could tag such a commit; without one, spl_release_mint reports it
# as rc 3 (stale target) so the deploy stands down for a trunk-head run.
#
# spl_claim_tag_api <owner/repo> <sha> <tag> <token> -> claim the lightweight
# tag on GitHub. rc 0 = created, 2 = it already exists (a lost race), 1 = a real
# refusal. The server's response body is left in SPL_CLAIM_ERR either way.
spl_claim_tag_api() {
  local owner_repo="$1" sha="$2" tag="$3" token="$4" code tmp
  SPL_CLAIM_ERR=""
  do_require_bin curl || { SPL_CLAIM_ERR="curl not found"; return 1; }
  tmp="$(mktemp)"
  code="$(curl -sS -o "$tmp" -w '%{http_code}' \
    -X POST \
    -H "Authorization: Bearer $token" \
    -H "Accept: application/vnd.github+json" \
    -H "X-GitHub-Api-Version: 2022-11-28" \
    "https://api.github.com/repos/$owner_repo/git/refs" \
    -d "{\"ref\":\"refs/tags/$tag\",\"sha\":\"$sha\"}" 2>>"$tmp")"
  SPL_CLAIM_ERR="$(cat "$tmp")"; rm -f "$tmp"
  case "$code" in
    201) return 0 ;;
    # 422 "Reference already exists" is the lost race; a 422 for any other
    # reason (e.g. the sha is unknown to the remote) is a real error.
    422) grep -qi 'already exists' <<<"$SPL_CLAIM_ERR" && return 2
         SPL_CLAIM_ERR="HTTP 422: $SPL_CLAIM_ERR"; return 1 ;;
    *)   SPL_CLAIM_ERR="HTTP $code: $SPL_CLAIM_ERR"; return 1 ;;
  esac
}

# spl_claim_tag_push <dir> <sha> <tag> <remote> -> claim the tag with a plain
# git push (the local / full-permission path, e.g. an agent on an SSH remote).
# Same rc contract as the API variant; git's whole stderr lands in SPL_CLAIM_ERR.
spl_claim_tag_push() {
  local dir="$1" sha="$2" tag="$3" remote="$4" out
  SPL_CLAIM_ERR=""
  if out="$(git -C "$dir" push -q "$remote" "$sha:refs/tags/$tag" 2>&1)"; then
    return 0
  fi
  SPL_CLAIM_ERR="$out"
  # A real race leaves $tag on the remote NOW (another lane claimed it) -> 2.
  # Anything else (the ref never appears) is a genuine rejection -> 1.
  git -C "$dir" ls-remote --tags "$remote" "refs/tags/$tag" 2>/dev/null | grep -q "refs/tags/$tag$" && return 2
  return 1
}

# spl_workflows_stale <dir> <sha> <remote> -> 0 when <sha>'s .github/workflows
# tree differs from the remote trunk head's (RELEASE_TRUNK, default master): the
# one case GitHub refuses an Actions token any ref at <sha>. Fetches trunk head
# into refs/remotes/<remote>/<trunk>; rc 1 (not stale, or cannot tell) otherwise.
spl_workflows_stale() {
  local dir="$1" sha="$2" remote="$3" trunk="${RELEASE_TRUNK:-master}" mine head
  git -C "$dir" fetch -q "$remote" "+refs/heads/$trunk:refs/remotes/$remote/$trunk" 2>/dev/null || return 1
  mine="$(git -C "$dir" rev-parse -q --verify "$sha:.github/workflows" 2>/dev/null)"
  head="$(git -C "$dir" rev-parse -q --verify "refs/remotes/$remote/$trunk:.github/workflows" 2>/dev/null)"
  [[ -n "$head" && "$mine" != "$head" ]]
}

# spl_claim_tag <dir> <sha> <tag> <remote> -> claim the tag by the API when the
# remote is github.com AND a token is in the environment (CI), else by git push.
# rc 0 created / 2 lost race / 1 refused; SPL_CLAIM_ERR carries the detail.
spl_claim_tag() {
  local dir="$1" sha="$2" tag="$3" remote="$4" url owner_repo token
  url="$(git -C "$dir" remote get-url "$remote" 2>/dev/null)"
  owner_repo="$(spl_github_owner_repo "$url")"
  token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  if [[ -n "$owner_repo" && -n "$token" ]]; then
    spl_claim_tag_api "$owner_repo" "$sha" "$tag" "$token"
  else
    spl_claim_tag_push "$dir" "$sha" "$tag" "$remote"
  fi
}

# stdout carries ONLY the version: every log line goes to stderr, because the
# ./run do_log prints to stdout and the caller captures this function's
# stdout (run 36372654214, 2026-09-28: a lost race logged an INFO line into
# the captured value and GITHUB_OUTPUT refused it).
# spl_release_mint <git-dir> <sha> <floor> [remote] -> prints the version for
# <sha>, claiming a new tag on <remote> (default origin) when it has none.
# rc 1 on a bad argument, or when no tag could be claimed after 10 attempts;
# rc 3 when the claim was refused because <sha>'s .github/workflows differs from
# trunk head's (see spl_workflows_stale) -- `stale=true` then goes to
# $GITHUB_OUTPUT too, so a deploy can stand down for a trunk-head run.
spl_release_mint() {
  local dir="$1" sha="$2" floor="$3" remote="${4:-origin}"
  local i mine latest next rc
  spl_version_valid "$floor" || { do_log "FATAL the floor (.version) is not an odometer version: '$floor'" >&2; return 1; }
  sha="$(git -C "$dir" rev-parse --verify -q "$sha^{commit}")" || { do_log "FATAL not a commit: '$2'" >&2; return 1; }
  for i in 1 2 3 4 5 6 7 8 9 10; do
    git -C "$dir" fetch -q --force "$remote" '+refs/tags/v*:refs/tags/v*' 2>/dev/null ||
      { do_log "FATAL cannot fetch the v-tags from $remote" >&2; return 1; }
    # already minted for this commit: the LOWEST of its v-tags, so every
    # reader agrees even in the (theoretical) case of two
    mine="$(git -C "$dir" tag --points-at "$sha" -l 'v*' | sed 's/^v//' | spl_version_min)"
    [[ -n "$mine" ]] && { echo "$mine"; return 0; }
    latest="$(git -C "$dir" tag -l 'v*' | sed 's/^v//' | spl_version_max)"
    if [[ -z "$latest" ]] || spl_version_gt "$floor" "$latest"; then next="$floor"
    else next="$(spl_version_step "$latest")" || { do_log "FATAL the odometer is full at $latest" >&2; return 1; }
    fi
    # Claim v$next on the remote (REST API under a CI GitHub App token, else git
    # push -- see spl_claim_tag). rc 0 = ours, 2 = a lost race, 1 = refused.
    spl_claim_tag "$dir" "$sha" "v$next" "$remote"; rc=$?
    if ((rc == 0)); then
      git -C "$dir" tag -f "v$next" "$sha" >/dev/null 2>&1
      echo "$next"; return 0
    fi
    # A lost race (2): another lane took v$next -- re-read and take the next
    # number. Print the WHOLE server/git message (the old code kept only the
    # last line, hiding the reason above it).
    if ((rc == 2)); then
      do_log "INFO v$next was claimed by another deploy (attempt $i), taking the next. remote said:" >&2
      do_log "$(sed 's/^/    /' <<<"$SPL_CLAIM_ERR")" >&2
      sleep "$((RANDOM % 3))"
      continue
    fi
    # A genuine refusal (1): v$next was NOT claimed by anyone. Surface it and
    # stop pretending it was "taken" -- e.g. a GitHub App token refused the ref
    # because the commit's diff touches .github/workflows/* (the bug this fix
    # cures by routing CI through the REST API). (CLE-77788 / CLE-001 P0.)
    if spl_workflows_stale "$dir" "$sha" "$remote"; then
      do_log "WARN claim of tag v$next for ${sha:0:8} was REFUSED: its .github/workflows differs from $remote/${RELEASE_TRUNK:-master} (a workflow commit landed after it), and GitHub refuses an Actions token any ref there. Deploy trunk head instead: it carries this commit. remote said:" >&2
      do_log "$(sed 's/^/    /' <<<"$SPL_CLAIM_ERR")" >&2
      [[ -n "${GITHUB_OUTPUT:-}" ]] && echo "stale=true" >>"$GITHUB_OUTPUT"
      return 3
    fi
    do_log "FATAL claim of tag v$next on $remote was REJECTED and v$next does not exist there -- this is not a lost race. remote said:" >&2
    do_log "$(sed 's/^/    /' <<<"$SPL_CLAIM_ERR")" >&2
    return 1
  done
  do_log "FATAL could not claim a version tag on $remote after 10 attempts" >&2
  return 1
}
