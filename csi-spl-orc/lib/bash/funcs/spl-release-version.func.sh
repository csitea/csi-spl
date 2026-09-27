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

# spl_release_mint <git-dir> <sha> <floor> [remote] -> prints the version for
# <sha>, claiming a new tag on <remote> (default origin) when it has none.
# rc 1 on a bad argument, or when no tag could be claimed after 10 attempts.
spl_release_mint() {
  local dir="$1" sha="$2" floor="$3" remote="${4:-origin}"
  local i mine latest next out
  spl_version_valid "$floor" || { do_log "FATAL the floor (.version) is not an odometer version: '$floor'"; return 1; }
  sha="$(git -C "$dir" rev-parse --verify -q "$sha^{commit}")" || { do_log "FATAL not a commit: '$2'"; return 1; }
  for i in 1 2 3 4 5 6 7 8 9 10; do
    git -C "$dir" fetch -q --force "$remote" '+refs/tags/v*:refs/tags/v*' 2>/dev/null ||
      { do_log "FATAL cannot fetch the v-tags from $remote"; return 1; }
    # already minted for this commit: the LOWEST of its v-tags, so every
    # reader agrees even in the (theoretical) case of two
    mine="$(git -C "$dir" tag --points-at "$sha" -l 'v*' | sed 's/^v//' | spl_version_min)"
    [[ -n "$mine" ]] && { echo "$mine"; return 0; }
    latest="$(git -C "$dir" tag -l 'v*' | sed 's/^v//' | spl_version_max)"
    if [[ -z "$latest" ]] || spl_version_gt "$floor" "$latest"; then next="$floor"
    else next="$(spl_version_step "$latest")" || { do_log "FATAL the odometer is full at $latest"; return 1; }
    fi
    if out="$(git -C "$dir" push -q "$remote" "$sha:refs/tags/v$next" 2>&1)"; then
      git -C "$dir" tag -f "v$next" "$sha" >/dev/null 2>&1
      echo "$next"; return 0
    fi
    do_log "INFO v$next was taken by another deploy (attempt $i): $(tail -1 <<<"$out")"
    sleep "$((RANDOM % 3))"
  done
  do_log "FATAL could not claim a version tag on $remote after 10 attempts"
  return 1
}
