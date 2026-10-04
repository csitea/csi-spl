#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the release version is minted by CI, collision-free.
#   1. odometer arithmetic: 1.1.0 -> 1.1.1, 1.1.9 -> 1.2.0, 1.9.9 -> 2.0.0,
#      9.9.9 wraps to 1.0.1, 1.10.0 is not a version
#   2. first mint against a remote with no tags = the floor (.version)
#   3. the next commit = one step past the highest tag
#   4. the same commit again = the same version (hub + WUI + dev + prd agree)
#   5. a floor raised above every tag wins (a human's deliberate jump)
#   6. RACE: 8 commits minted in parallel get 8 DISTINCT consecutive versions
#   7. RACE: 6 parallel mints of ONE commit all get the same version
#   8. CONTROL: 8 parallel mints that compute from their own tree without the
#      push lock DO collide, and the duplicate check in (6) sees it
#   9. the action: DRY_RUN=1 claims nothing, DRY_RUN=0 writes GITHUB_OUTPUT
#  10. a LOST race with do_log on stdout (./run's): GITHUB_OUTPUT is still
#      exactly one version=d.d.d line, the same commit's tag is reused;
#      CONTROL: the pre-fix library writes a line GitHub refuses
#  13. a refusal at a commit whose .github/workflows differs from trunk head's
#      (a workflow commit landed after it) is rc 3 + stale=true in
#      GITHUB_OUTPUT, so the deploy stands down; CONTROL: the same refusal at
#      trunk head stays rc 1, a real error (CLE-77950)
#  14. CYCLES (owner: "reaches 9.9.9 ... start all over, from 1.0.1"): release
#      keys order by cycle then X.Y.Z; 9.9.9 -> 1.0.1 of cycle 2 is claimed as
#      tag v1.0.1-c2 beside the cycle-1 v1.0.1, shown as plain 1.0.1 (mint and
#      action, GITHUB_OUTPUT too); the cycle-1 floor no longer wins; a commit
#      re-reads its cycle-2 version; CONTROL: plain-version max ignores the
#      cycle-2 tags and would re-mint 9.9.9's successor forever
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
got=$(lib spl_version_step 9.9.9); [[ "$got" == 1.0.1 ]] && pass "displayed 9.9.9 wraps to 1.0.1" || fail "step 9.9.9 -> '$got', want 1.0.1"
lib spl_version_valid 1.10.0 && fail "1.10.0 accepted" || pass "1.10.0 is not a version (digits rule)"
got=$(printf '1.0.9\n1.1.0\n0.9.9\njunk\n' | lib spl_version_max); [[ "$got" == 1.1.0 ]] && pass "max = 1.1.0" || fail "max='$got'"

# --- a remote and a clone ----------------------------------------------------
git init -q --bare "$T/remote.git"
git init -q "$T/w" && git -C "$T/w" remote add origin "$T/remote.git"
commit() { echo "$1" >"$T/w/f" && git -C "$T/w" add f && git -C "$T/w" commit -qm "$1" && git -C "$T/w" rev-parse HEAD; }
c1=$(commit one); c2=$(commit two)
git -C "$T/w" push -q origin HEAD:refs/heads/master

mint() { lib spl_release_mint "$T/w" "$1" "$2" origin 2>>"$T/mint.err"; }
# A parallel mint gets its OWN clone, as each CI deploy job has its own
# checkout: N mints sharing $T/w raced on its local refs (concurrent
# `fetch --force` of the v-tags, `tag -f`, ref packing), so one mint missed a
# tag another had just written for the SAME commit and claimed the next number
# (wf10 run 36844008515: "2.0.9 2.1.0 2.0.9 ..."). The only shared state left
# is the remote, which is what the lock under test serialises. (CLE-77859)
pmint() { # <job> <sha> <floor>
  git clone -q "$T/remote.git" "$T/job.$1" && lib spl_release_mint "$T/job.$1" "$2" "$3" origin 2>>"$T/mint.err"
}

got=$(mint "$c1" 1.1.0); [[ "$got" == 1.1.0 ]] && pass "no tags yet: the floor 1.1.0" || fail "first mint '$got'"
got=$(mint "$c2" 1.1.0); [[ "$got" == 1.1.1 ]] && pass "next commit: 1.1.1" || fail "second mint '$got'"
got=$(mint "$c1" 1.1.0); [[ "$got" == 1.1.0 ]] && pass "same commit again: 1.1.0 (reused)" || fail "re-mint '$got'"
[[ "$(git --git-dir="$T/remote.git" tag -l 'v*' | wc -l)" == 2 ]] && pass "remote holds exactly 2 tags" || fail "remote tags: $(git --git-dir="$T/remote.git" tag -l | tr '\n' ' ')"
c3=$(commit three)
got=$(mint "$c3" 2.0.0); [[ "$got" == 2.0.0 ]] && pass "floor raised to 2.0.0 wins" || fail "floor jump '$got'"

# --- 6. race: distinct commits ------------------------------------------------
shas=(); for i in 1 2 3 4 5 6 7 8; do shas+=("$(commit "race-$i")"); done
git -C "$T/w" push -q origin HEAD:refs/heads/master
for i in "${!shas[@]}"; do ( pmint "r$i" "${shas[$i]}" 1.1.0 >"$T/r.$i" ) & done; wait
sort "$T"/r.* >"$T/race"
dups=$(uniq -d "$T/race" | wc -l); n=$(grep -c . "$T/race")
want=$(for v in 2.0.1 2.0.2 2.0.3 2.0.4 2.0.5 2.0.6 2.0.7 2.0.8; do echo $v; done)
if [[ $n -eq 8 && $dups -eq 0 && "$(cat "$T/race")" == "$want" ]]; then pass "8 parallel commits -> 8 distinct consecutive versions (2.0.1..2.0.8)"
else fail "parallel mint: n=$n dups=$dups got=$(tr '\n' ' ' <"$T/race")"; fi
for i in "${!shas[@]}"; do
  [[ "$(git --git-dir="$T/remote.git" rev-parse "v$(cat "$T/r.$i")^{commit}")" == "${shas[$i]}" ]] || fail "tag v$(cat "$T/r.$i") does not point at its own commit"
done

# --- 7. race: one commit, many jobs -------------------------------------------
c9=$(commit nine); git -C "$T/w" push -q origin HEAD:refs/heads/master
for i in 1 2 3 4 5 6; do ( pmint "s$i" "$c9" 1.1.0 >"$T/s.$i" ) & done; wait
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

# --- 10. a LOST race, with do_log on STDOUT (the ./run wrapper's) ------------
# run 36372654214 (2026-09-28): the prd leg lost v1.2.4 to the dev leg of the
# SAME commit, logged the retry through do_log -> stdout -> the captured value,
# and GITHUB_OUTPUT got a bare "1.2.4" line. A git shim makes the race
# deterministic: just before this job's tag push, a second clone claims the
# same tag (for the same commit, or for another one).
real_git="$(command -v git)"
git clone -q "$T/remote.git" "$T/other"
mkdir -p "$T/shim"
cat >"$T/shim/git" <<EOF2
#!/bin/sh
case " \$* " in *" push "*refs/tags/v*)
  if [ -n "\$RACE_SHA" ] && [ ! -e "\$RACE_DONE" ]; then
    : >"\$RACE_DONE"
    tag="\${*##*refs/tags/}"
    "$real_git" -C "$T/other" fetch -q origin
    "$real_git" -C "$T/other" push -q origin "\$RACE_SHA:refs/tags/\$tag"
  fi ;;
esac
exec "$real_git" "\$@"
EOF2
chmod +x "$T/shim/git"
act_stdout_log() { # like act, but do_log prints to STDOUT as ./run's does
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/w" PATH="$T/shim:$PATH" RACE_DONE="$T/race.$RANDOM" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "[LOG] $*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_release_version' 2>>"$T/act.err"
}
out_ok() { grep -qvx 'version=[0-9]\.[0-9]\.[0-9]' "$1" && return 1; [[ "$(grep -c . "$1")" == 1 ]]; }

c11=$(commit eleven); git -C "$T/w" push -q origin HEAD:refs/heads/master
: >"$T/gh11"
got=$(act_stdout_log RELEASE_SHA="$c11" DRY_RUN=0 GITHUB_OUTPUT="$T/gh11" RACE_SHA="$c11" | tail -1)
if out_ok "$T/gh11" && [[ "$(cat "$T/gh11")" == version=2.1.1 ]]; then
  pass "the dev leg claimed the tag for the SAME commit first: GITHUB_OUTPUT is exactly version=2.1.1 (its tag, not a new one)"
else fail "same-commit lost race: GITHUB_OUTPUT='$(tr '\n' '|' <"$T/gh11")' last stdout='$got'"; fi

c12=$(commit twelve); c13=$(commit thirteen); git -C "$T/w" push -q origin HEAD:refs/heads/master
: >"$T/gh13"
act_stdout_log RELEASE_SHA="$c13" DRY_RUN=0 GITHUB_OUTPUT="$T/gh13" RACE_SHA="$c12" >/dev/null
if out_ok "$T/gh13" && [[ "$(cat "$T/gh13")" == version=2.1.3 ]]; then
  pass "lost the race to ANOTHER commit: GITHUB_OUTPUT is exactly version=2.1.3 (2.1.2 went to the winner)"
else fail "other-commit lost race: GITHUB_OUTPUT='$(tr '\n' '|' <"$T/gh13")'"; fi

# CONTROL: the pre-fix library (logs on stdout inside the captured function)
# under the same race writes a GITHUB_OUTPUT that GitHub refuses.
sed 's/ >&2//' "$PROJ_ROOT/lib/bash/funcs/spl-release-version.func.sh" >"$T/old-lib.sh"
c14=$(commit fourteen); c15=$(commit fifteen); git -C "$T/w" push -q origin HEAD:refs/heads/master
: >"$T/gh14"
env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/w" PATH="$T/shim:$PATH" RACE_DONE="$T/race.ctl" RACE_SHA="$c14" \
  RELEASE_SHA="$c15" DRY_RUN=0 GITHUB_OUTPUT="$T/gh14" OLD_LIB="$T/old-lib.sh" bash -c '
    do_log() { echo "[LOG] $*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    source "$OLD_LIB"
    spl_version_valid() { return 0; }
    do_release_version' >/dev/null 2>>"$T/act.err"
out_ok "$T/gh14" && fail "CONTROL: the pre-fix library wrote a clean GITHUB_OUTPUT, so this test proves nothing" \
  || pass "CONTROL: the pre-fix library under the same race writes a GITHUB_OUTPUT GitHub refuses ($(tr '\n' '|' <"$T/gh14" | cut -c1-70))"

# --- 11. a non-race REJECTION surfaces git's stderr and fails fast ----------
# SPL-1194 / CLE-001 P0: a shallow WUI deploy's tag push was refused by
# GITHUB_TOKEN ("refusing to allow a GitHub App to create or update workflow
# file"), and the mint HID git's stderr behind "was taken by another deploy"
# and retried 10x. Now: when v$next stays absent (not a lost race) the mint
# prints the WHOLE stderr and stops. A git shim rejects the tag push WITHOUT
# creating the tag; a passthrough for everything else.
mkdir -p "$T/rej"
cat >"$T/rej/git" <<EOF3
#!/bin/sh
case " \$* " in *" push "*refs/tags/v*)
  echo " ! [remote rejected] (refusing to allow a GitHub App to create or update workflow file .github/workflows/30_wui-build-deploy.yml without workflows permission)" >&2
  echo "error: failed to push some refs to 'origin'" >&2
  exit 1 ;;
esac
exec "$real_git" "\$@"
EOF3
chmod +x "$T/rej/git"
c16=$(commit sixteen); git -C "$T/w" push -q origin HEAD:refs/heads/master
: >"$T/rej.err"; rc=0
PATH="$T/rej:$PATH" lib spl_release_mint "$T/w" "$c16" 1.1.0 origin >"$T/rej.out" 2>"$T/rej.err" || rc=$?
if [[ $rc -ne 0 ]] && grep -q 'refusing to allow a GitHub App' "$T/rej.err" \
   && grep -q 'was REJECTED' "$T/rej.err" && ! grep -q 'taken by another deploy' "$T/rej.err"; then
  pass "a non-race push rejection surfaces git's real stderr and fails (not mislabelled 'taken')"
else
  fail "rejection path: rc=$rc err=$(tr '\n' '|' <"$T/rej.err" | cut -c1-180)"
fi
# CONTROL: the SAME commit with a normal git (no shim) mints cleanly, proving
# it is the rejection that fails it above, not the commit.
got=$(mint "$c16" 1.1.0)
[[ "$got" =~ ^[0-9]\.[0-9]\.[0-9]$ ]] && pass "CONTROL: the same commit mints a version once the push is not rejected ($got)" \
  || fail "CONTROL: normal mint of c16 gave '$got'"

# --- 12. the GitHub App tag-push refusal is cured by the REST API path -------
# CLE-77788 / CLE-001 P0: in CI the deploy runs under the default GITHUB_TOKEN
# (a GitHub App token). GitHub refuses that token any ref update whose target
# commit's diff touches .github/workflows/* -- and fetch-depth 0 does NOT cure
# it, because the check is on the ref's target diff, not on object transfer.
# The mint now claims the tag through POST /git/refs, which writes no workflow
# content and is allowed with contents:write. These tests drive that path with
# a curl shim so no network is touched.

# 12a. owner/repo parsing across the URL forms a checkout / an agent produce
opr() { lib spl_github_owner_repo "$1"; }
[[ "$(opr https://github.com/csitea/csi-spl)" == csitea/csi-spl ]] && pass "owner/repo: https" || fail "owner/repo https: '$(opr https://github.com/csitea/csi-spl)'"
[[ "$(opr https://github.com/csitea/csi-spl.git)" == csitea/csi-spl ]] && pass "owner/repo: https .git" || fail "owner/repo https .git"
[[ "$(opr git@github.com:csitea/csi-spl.git)" == csitea/csi-spl ]] && pass "owner/repo: ssh" || fail "owner/repo ssh"
[[ "$(opr https://x-access-token:TOK@github.com/csitea/csi-spl)" == csitea/csi-spl ]] && pass "owner/repo: token-embedded" || fail "owner/repo token-embedded"
[[ -z "$(opr "$T/remote.git")" ]] && pass "owner/repo: a file remote is not github (empty)" || fail "owner/repo file remote: '$(opr "$T/remote.git")'"

# A curl shim: it writes CURL_BODY to the -o target and prints CURL_CODE, so the
# test drives the API return code without a network. do_require_bin is a ./run
# builtin at runtime; stub it here.
mkdir -p "$T/curlshim"
cat >"$T/curlshim/curl" <<'CURLEOF'
#!/bin/sh
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out="$a"; prev="$a"; done
[ -n "$out" ] && printf '%s' "$CURL_BODY" >"$out"
printf '%s' "$CURL_CODE"
CURLEOF
chmod +x "$T/curlshim/curl"

claim_api() { # <code> <body> <owner/repo> <sha> <tag> -> "rc\n<SPL_CLAIM_ERR>"
  PATH="$T/curlshim:$PATH" CURL_CODE="$1" CURL_BODY="$2" \
  bash -c '
    do_log(){ echo "$*" >&2; }
    do_require_bin(){ command -v "$1" >/dev/null; }
    source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-release-version.func.sh"
    spl_claim_tag_api "$1" "$2" "$3" tok; rc=$?
    printf "%s\n%s" "$rc" "$SPL_CLAIM_ERR"' _ "$3" "$4" "$5"
}

# 12b. 201 Created -> claimed (rc 0)
res=$(claim_api 201 '{"ref":"refs/tags/v1.2.0"}' csitea/csi-spl deadbeef v1.2.0)
[[ "$(head -1 <<<"$res")" == 0 ]] && pass "API 201 -> tag claimed (rc 0)" || fail "API 201 rc='$(head -1 <<<"$res")'"

# 12c. 422 "already exists" -> a lost race (rc 2)
res=$(claim_api 422 '{"message":"Reference already exists"}' csitea/csi-spl deadbeef v1.2.0)
[[ "$(head -1 <<<"$res")" == 2 ]] && pass "API 422 already-exists -> lost race (rc 2)" || fail "API 422 rc='$(head -1 <<<"$res")'"

# 12d. a workflow-permission refusal -> hard fail (rc 1), body surfaced
body='{"message":"refusing to allow a GitHub App to create or update workflow file .github/workflows/10_ci-quality.yml without workflows permission"}'
res=$(claim_api 403 "$body" csitea/csi-spl deadbeef v1.2.0)
if [[ "$(head -1 <<<"$res")" == 1 ]] && grep -q 'refusing to allow a GitHub App' <<<"$res"; then
  pass "API 403 workflow refusal -> hard fail (rc 1) with the server message surfaced"
else fail "API 403: rc='$(head -1 <<<"$res")' body='$(tail -n +2 <<<"$res" | cut -c1-80)'"; fi

# 12e. ROUTING + CONTROL: the same workflow-touching commit fails on the old
# push path (an App-token rejection) but is claimed on the new API path.
# The rejection shim from section 11 stands in for the App token on git push.
c17=$(commit seventeen); git -C "$T/w" push -q origin HEAD:refs/heads/master
git -C "$T/w" remote add gh https://github.com/csitea/csi-spl
# old path: file remote, no token -> git push, rejected by the App shim
: >"$T/route.err"; rc=0
PATH="$T/rej:$PATH" bash -c '
  do_log(){ echo "$*" >&2; }
  source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-release-version.func.sh"
  spl_claim_tag "'"$T/w"'" "'"$c17"'" v9.9.0 origin; rc=$?; echo "$SPL_CLAIM_ERR" >&2; exit $rc' >/dev/null 2>"$T/route.err" || rc=$?
if [[ $rc -eq 1 ]] && grep -q 'refusing to allow a GitHub App' "$T/route.err"; then
  pass "CONTROL old path: git push of a workflow-touching commit is refused (rc 1)"
else fail "CONTROL old path: rc=$rc err=$(tr '\n' '|' <"$T/route.err" | cut -c1-120)"; fi
# new path: a github remote + a token -> the REST API (curl shim 201) succeeds
rc=0
PATH="$T/curlshim:$PATH" GITHUB_TOKEN=tok CURL_CODE=201 CURL_BODY='{}' bash -c '
  do_log(){ echo "$*" >&2; }
  do_require_bin(){ command -v "$1" >/dev/null; }
  source "'"$PROJ_ROOT"'/lib/bash/funcs/spl-release-version.func.sh"
  spl_claim_tag "'"$T/w"'" "'"$c17"'" v9.9.0 gh' >/dev/null 2>&1 || rc=$?
[[ $rc -eq 0 ]] && pass "NEW path: a github remote + a token claims the SAME commit via the REST API (rc 0)" \
  || fail "NEW path: API claim rc=$rc"

# --- 13. stale target: refused because trunk head's workflows moved on -------
# CLE-77950: GitHub refuses an Actions token any ref (push OR REST API,
# lightweight or annotated) at a commit whose .github/workflows differs from
# trunk head's -- probe run 36970563047: that commit 403, trunk head 201. The
# rejection shim from section 11 stands in for that refusal.
mkdir -p "$T/w/.github/workflows"
echo a >"$T/w/.github/workflows/x.yml"; git -C "$T/w" add .github && git -C "$T/w" commit -qm wf-a
c18=$(git -C "$T/w" rev-parse HEAD); git -C "$T/w" push -q origin HEAD:refs/heads/master
echo b >"$T/w/.github/workflows/x.yml"; git -C "$T/w" add .github && git -C "$T/w" commit -qm wf-b
c19=$(git -C "$T/w" rev-parse HEAD); git -C "$T/w" push -q origin HEAD:refs/heads/master
: >"$T/stale.out"; rc=0
GITHUB_OUTPUT="$T/stale.out" PATH="$T/rej:$PATH" lib spl_release_mint "$T/w" "$c18" 1.1.0 origin >/dev/null 2>"$T/stale.err" || rc=$?
if [[ $rc -eq 3 ]] && grep -qx 'stale=true' "$T/stale.out" && grep -q 'differs from origin/master' "$T/stale.err" \
   && ! grep -q '^version=' "$T/stale.out"; then
  pass "a refusal at a commit behind trunk head's workflows -> rc 3 + stale=true, no version"
else fail "stale target: rc=$rc out=$(tr '\n' '|' <"$T/stale.out") err=$(tr '\n' '|' <"$T/stale.err" | cut -c1-160)"; fi
# CONTROL: the same refusal at trunk head (workflows equal) is a real error
: >"$T/stale.out"; rc=0
GITHUB_OUTPUT="$T/stale.out" PATH="$T/rej:$PATH" lib spl_release_mint "$T/w" "$c19" 1.1.0 origin >/dev/null 2>"$T/stale.err" || rc=$?
if [[ $rc -eq 1 ]] && ! grep -q 'stale=' "$T/stale.out" && grep -q 'was REJECTED' "$T/stale.err"; then
  pass "CONTROL: the same refusal at trunk head stays rc 1 (a real error, no stand-down)"
else fail "CONTROL stale: rc=$rc out=$(tr '\n' '|' <"$T/stale.out")"; fi

# --- 14. cycles ---------------------------------------------------------------
for c in "9.9.8 9.9.9" "9.9.9 1.0.1-c2" "1.0.9-c2 1.1.0-c2" "9.9.9-c2 1.0.1-c3" "9.9.9-c12 1.0.1-c13"; do
  set -- $c
  got=$(lib spl_release_key_step "$1"); [[ "$got" == "$2" ]] && pass "key step $1 -> $2" || fail "key step $1 -> '$got', want $2"
done
for c in "1.0.1-c2 9.9.9" "1.0.2-c2 1.0.1-c2" "1.0.1-c3 9.9.9-c2" "1.0.1-c10 9.9.9-c9" "8.4.3 8.4.2"; do
  set -- $c
  lib spl_release_key_gt "$1" "$2" && pass "$1 is later than $2" || fail "$1 not later than $2"
  lib spl_release_key_gt "$2" "$1" && fail "$2 later than $1" || pass "$2 is not later than $1"
done
lib spl_release_key_gt 1.0.1-c2 1.0.1-c2 && fail "a key is later than itself" || pass "a key is not later than itself"
for k in 1.0.1-c1 1.0.1-c0 1.0.1-c 1.0.1-c02 1.10.1-c2 v1.0.1-c2; do
  lib spl_release_key_valid "$k" && fail "'$k' accepted as a key" || pass "'$k' is not a key"
done
got=$(printf '9.9.9\n1.0.3-c2\n9.9.8\njunk\n1.0.1-c2\n' | lib spl_release_key_max); [[ "$got" == 1.0.3-c2 ]] && pass "key max = 1.0.3-c2 (cycle first)" || fail "key max='$got'"
got=$(printf '1.0.3-c2\n9.9.9\n1.0.1-c3\n' | lib spl_release_key_min); [[ "$got" == 9.9.9 ]] && pass "key min = 9.9.9 (cycle first)" || fail "key min='$got'"
got=$(lib spl_release_key_display 1.0.1-c2); [[ "$got" == 1.0.1 ]] && pass "1.0.1-c2 displays as 1.0.1" || fail "display '$got'"

git init -q --bare "$T/cyc.git"
git init -q "$T/c" && git -C "$T/c" remote add origin "$T/cyc.git"
ccommit() { echo "$1" >"$T/c/f" && git -C "$T/c" add f && git -C "$T/c" commit -qm "$1" && git -C "$T/c" rev-parse HEAD; }
k0=$(ccommit old-101); k1=$(ccommit c998)
git -C "$T/c" tag v1.0.1 "$k0"; git -C "$T/c" tag v9.9.8 "$k1"
k2=$(ccommit c999); k3=$(ccommit wrap); k4=$(ccommit after)
git -C "$T/c" push -q origin HEAD:refs/heads/master 'refs/tags/v*:refs/tags/v*'
cmint() { lib spl_release_mint "$T/c" "$1" "$2" origin 2>>"$T/mint.err"; }
got=$(cmint "$k2" 8.4.0); [[ "$got" == 9.9.9 ]] && pass "cycle 1 ends at 9.9.9" || fail "9.9.9 mint '$got'"
got=$(cmint "$k3" 8.4.0)
if [[ "$got" == 1.0.1 && "$(git --git-dir="$T/cyc.git" rev-parse 'v1.0.1-c2^{commit}')" == "$k3" \
      && "$(git --git-dir="$T/cyc.git" rev-parse 'v1.0.1^{commit}')" == "$k0" ]]; then
  pass "after 9.9.9: shows 1.0.1, claims v1.0.1-c2, the cycle-1 v1.0.1 untouched"
else fail "wrap mint '$got' tags=$(git --git-dir="$T/cyc.git" tag | tr '\n' ' ')"; fi
got=$(cmint "$k4" 8.4.0); [[ "$got" == 1.0.2 && -n "$(git --git-dir="$T/cyc.git" tag -l v1.0.2-c2)" ]] \
  && pass "cycle 2 continues 1.0.2 (v1.0.2-c2); the cycle-1 floor 8.4.0 does not win" || fail "cycle-2 next '$got'"
got=$(cmint "$k3" 8.4.0); [[ "$got" == 1.0.1 ]] && pass "the wrap commit re-reads 1.0.1" || fail "wrap re-read '$got'"
k5=$(ccommit act); git -C "$T/c" push -q origin HEAD:refs/heads/master; echo 8.4.0 >"$T/c/.version"
cact() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/c" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_release_version' 2>>"$T/act.err"
}
got=$(cact RELEASE_SHA="$k5"); [[ "$got" == 1.0.3 ]] && pass "action DRY_RUN in cycle 2 says 1.0.3" || fail "cycle-2 dry run '$got'"
: >"$T/gh2.out"
got=$(cact RELEASE_SHA="$k5" DRY_RUN=0 GITHUB_OUTPUT="$T/gh2.out")
[[ "$got" == 1.0.3 && "$(cat "$T/gh2.out")" == version=1.0.3 && -n "$(git --git-dir="$T/cyc.git" tag -l v1.0.3-c2)" ]] \
  && pass "action DRY_RUN=0 claims v1.0.3-c2, GITHUB_OUTPUT version=1.0.3 (plain)" || fail "cycle-2 live '$got' out='$(cat "$T/gh2.out")'"
got=$(lib eval 'spl_version_step "$(git -C "'"$T/c"'" tag -l "v*" | sed "s/^v//" | spl_version_max)"')
[[ "$got" == 1.0.1 ]] && pass "CONTROL: plain-version max ignores the cycle-2 tags (would re-mint 1.0.1 forever)" \
  || fail "CONTROL plain max: '$got'"

echo "--- $fails failure(s)"
[[ $fails -eq 0 ]]
