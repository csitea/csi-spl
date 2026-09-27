#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the release version is minted by CI, collision-free.
#   1. odometer arithmetic: 1.1.0 -> 1.1.1, 1.1.9 -> 1.2.0, 1.9.9 -> 2.0.0,
#      9.9.9 refuses, 1.10.0 is not a version
#   2. first mint against a remote with no tags = the floor (.version)
#   3. the next commit = one step past the highest tag
#   4. the same commit again = the same version (hub + WUI + dev + prd agree)
#   5. a floor raised above every tag wins (a human's deliberate jump)
#   6. RACE: 8 commits minted in parallel get 8 DISTINCT consecutive versions
#   7. RACE: 6 parallel mints of ONE commit all get the same version
#   8. CONTROL: 8 parallel mints that compute from their own tree without the
#      push lock DO collide, and the duplicate check in (6) sees it
#   9. the action: DRY_RUN=1 claims nothing, DRY_RUN=0 writes GITHUB_OUTPUT
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

lib() {
  bash -c '
    do_log() { echo "$*" >&2; }
    source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-release-version.func.sh"
    "$@"' _ "$@"
}

# --- 1. odometer ------------------------------------------------------------
for c in "1.1.0 1.1.1" "1.1.9 1.2.0" "1.9.9 2.0.0" "0.9.9 1.0.0"; do
  set -- $c
  got=$(lib spl_version_step "$1"); [[ "$got" == "$2" ]] && pass "step $1 -> $2" || fail "step $1 -> '$got', want $2"
done
lib spl_version_step 9.9.9 >/dev/null 2>&1 && fail "9.9.9 must refuse" || pass "9.9.9 refuses (odometer full)"
lib spl_version_valid 1.10.0 && fail "1.10.0 accepted" || pass "1.10.0 is not a version (digits rule)"
got=$(printf '1.0.9\n1.1.0\n0.9.9\njunk\n' | lib spl_version_max); [[ "$got" == 1.1.0 ]] && pass "max = 1.1.0" || fail "max='$got'"

# --- a remote and a clone ----------------------------------------------------
git init -q --bare "$T/remote.git"
git init -q "$T/w" && git -C "$T/w" remote add origin "$T/remote.git"
commit() { echo "$1" >"$T/w/f" && git -C "$T/w" add f && git -C "$T/w" commit -qm "$1" && git -C "$T/w" rev-parse HEAD; }
c1=$(commit one); c2=$(commit two)
git -C "$T/w" push -q origin HEAD:refs/heads/master

mint() { lib spl_release_mint "$T/w" "$1" "$2" origin 2>>"$T/mint.err"; }

got=$(mint "$c1" 1.1.0); [[ "$got" == 1.1.0 ]] && pass "no tags yet: the floor 1.1.0" || fail "first mint '$got'"
got=$(mint "$c2" 1.1.0); [[ "$got" == 1.1.1 ]] && pass "next commit: 1.1.1" || fail "second mint '$got'"
got=$(mint "$c1" 1.1.0); [[ "$got" == 1.1.0 ]] && pass "same commit again: 1.1.0 (reused)" || fail "re-mint '$got'"
[[ "$(git --git-dir="$T/remote.git" tag -l 'v*' | wc -l)" == 2 ]] && pass "remote holds exactly 2 tags" || fail "remote tags: $(git --git-dir="$T/remote.git" tag -l | tr '\n' ' ')"
c3=$(commit three)
got=$(mint "$c3" 2.0.0); [[ "$got" == 2.0.0 ]] && pass "floor raised to 2.0.0 wins" || fail "floor jump '$got'"

# --- 6. race: distinct commits ------------------------------------------------
shas=(); for i in 1 2 3 4 5 6 7 8; do shas+=("$(commit "race-$i")"); done
for i in "${!shas[@]}"; do ( mint "${shas[$i]}" 1.1.0 >"$T/r.$i" ) & done; wait
sort "$T"/r.* >"$T/race"
dups=$(uniq -d "$T/race" | wc -l); n=$(grep -c . "$T/race")
want=$(for v in 2.0.1 2.0.2 2.0.3 2.0.4 2.0.5 2.0.6 2.0.7 2.0.8; do echo $v; done)
if [[ $n -eq 8 && $dups -eq 0 && "$(cat "$T/race")" == "$want" ]]; then pass "8 parallel commits -> 8 distinct consecutive versions (2.0.1..2.0.8)"
else fail "parallel mint: n=$n dups=$dups got=$(tr '\n' ' ' <"$T/race")"; fi
for i in "${!shas[@]}"; do
  [[ "$(git --git-dir="$T/remote.git" rev-parse "v$(cat "$T/r.$i")^{commit}")" == "${shas[$i]}" ]] || fail "tag v$(cat "$T/r.$i") does not point at its own commit"
done

# --- 7. race: one commit, many jobs -------------------------------------------
c9=$(commit nine)
for i in 1 2 3 4 5 6; do ( mint "$c9" 1.1.0 >"$T/s.$i" ) & done; wait
if [[ "$(cat "$T"/s.* | sort -u)" == 2.0.9 && "$(git --git-dir="$T/remote.git" tag --points-at "$c9" | wc -l)" == 1 ]]; then
  pass "6 parallel jobs on one commit -> one version (2.0.9), one tag"
else fail "same-commit race: $(cat "$T"/s.* | tr '\n' ' ') tags=$(git --git-dir="$T/remote.git" tag --points-at "$c9" | tr '\n' ' ')"; fi

# --- 8. CONTROL: without the push lock the same race collides -----------------
naive() { lib eval 'spl_version_step "$(git -C "'"$T/w"'" tag -l "v*" | sed "s/^v//" | spl_version_max)"'; }
for i in 1 2 3 4 5 6 7 8; do ( naive >"$T/n.$i" ) & done; wait
ndups=$(cat "$T"/n.* | sort | uniq -d | wc -l)
[[ $ndups -ge 1 ]] && pass "CONTROL: computing from the tree without the push lock collides ($(cat "$T"/n.* | sort | uniq -c | awk '{print $1"x "$2}' | tr '\n' ' '))" \
  || fail "CONTROL did not collide: the duplicate check proves nothing"

# --- 9. the action ------------------------------------------------------------
c10=$(commit ten); echo 1.1.0 >"$T/w/.version"
act() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/w" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_release_version' 2>>"$T/act.err"
}
before=$(git --git-dir="$T/remote.git" tag | wc -l)
got=$(act RELEASE_SHA="$c10")
[[ "$got" == 2.1.0 && "$(git --git-dir="$T/remote.git" tag | wc -l)" == "$before" ]] && pass "DRY_RUN (default) says 2.1.0 and claims nothing" || fail "dry run: '$got'"
: >"$T/gh.out"
got=$(act RELEASE_SHA="$c10" DRY_RUN=0 GITHUB_OUTPUT="$T/gh.out")
[[ "$got" == 2.1.0 && "$(cat "$T/gh.out")" == version=2.1.0 ]] && pass "DRY_RUN=0 claims v2.1.0 and writes version=2.1.0 to GITHUB_OUTPUT" || fail "live: '$got' out='$(cat "$T/gh.out")'"
got=$(act RELEASE_SHA="$c10")
[[ "$got" == 2.1.0 ]] && pass "DRY_RUN on a tagged commit re-reads 2.1.0" || fail "dry re-read '$got'"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
