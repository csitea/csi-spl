#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the weekly stable release (spec 047 W10, SPL-1170), against a
#          throwaway repo + bare remote (no network, no GitHub release):
#   1. DRY_RUN=1 prints the notes (feat / fix / perf / other, the migrations
#      added, the upgrade steps) and pushes no tag
#   2. DRY_RUN=0 tags the highest v-tag's commit stable-<date> on the remote
#      and writes tag= / version= to GITHUB_OUTPUT
#   3. the same day again = nothing cut, exit 0
#   4. new commits but no new v-tag, next week = "nothing new", no tag
#   5. a new v-tag next week: notes since the previous stable only
#      (CONTROL: the old subjects are absent, the new ones present)
#   6. today's tag already on ANOTHER commit = FATAL (a tag never moves)
#   7. STABLE_FROM_URL: the commit a hub /version reports wins over the
#      highest v-tag
#   8. STABLE_NOTES_MAX caps a section and counts the rest
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com

git init -q --bare "$T/remote.git"
git init -q "$T/w" && git -C "$T/w" remote add origin "$T/remote.git"
commit() {  # <subject> [file] -> sha (runs in $(...): the counter is the repo's own)
  local n; n=$(($(git -C "$T/w" rev-list --count HEAD 2>/dev/null || echo 0) + 1))
  local f="${2:-f$n.txt}"
  mkdir -p "$T/w/$(dirname "$f")"; echo "$n" >"$T/w/$f"
  git -C "$T/w" add "$f" && git -C "$T/w" commit -q -m "$1" && git -C "$T/w" rev-parse HEAD
}
vtag() { git -C "$T/w" tag "v$1" "$2" && git -C "$T/w" push -q origin "refs/tags/v$1"; }
act() {  # env... -> stdout (notes + log lines, as under ./run); stderr to act.err; rc kept
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$T/w" STABLE_GH_RELEASE=0 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }   # to stdout, as ./run prints it
    do_require_bin() { local b; for b in "$@"; do command -v "$b" >/dev/null || return 1; done; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_release_stable' 2>>"$T/act.err"
}
rtag() { git --git-dir="$T/remote.git" rev-parse -q --verify "refs/tags/$1^{commit}"; }

c1=$(commit "feat(hub): old feature one")
c2=$(commit "fix(wui): old fix two")
c3=$(commit "feat(rdb): 0100 a new table" csi-spl-rdb/src/sql/postgres/spool-hub/0100_new_table.sql)
c4=$(commit "perf(hub): faster send")
c5=$(commit "docs: a readme line")
git -C "$T/w" push -q origin HEAD:master
vtag 1.0.0 "$c2"; vtag 1.0.1 "$c5"

# --- 1. dry run ------------------------------------------------------------------
out=$(act STABLE_DATE=2026-10-05); rc=$?
if ((rc == 0)) && grep -q '^# stable-2026-10-05 (v1.0.1)' <<<"$out" && grep -q '^## Features (2)' <<<"$out" \
   && grep -q '^## Fixes (1)' <<<"$out" && grep -q '^## Performance (1)' <<<"$out" && grep -q '^## Other changes (1)' <<<"$out" \
   && grep -q '0100_new_table.sql' <<<"$out" && grep -q 'git checkout stable-2026-10-05' <<<"$out"; then
  pass "dry run: notes by kind, the migration, the upgrade steps"
else
  fail "dry run notes (rc $rc): $out"
fi
[[ -z "$(rtag stable-2026-10-05)" ]] && pass "dry run pushed no tag" || fail "dry run pushed a tag"

# --- 2. cut ------------------------------------------------------------------------
: >"$T/gh.out"
act STABLE_DATE=2026-10-05 DRY_RUN=0 GITHUB_OUTPUT="$T/gh.out" >/dev/null; rc=$?
[[ $rc == 0 && "$(rtag stable-2026-10-05)" == "$c5" ]] && pass "DRY_RUN=0 tags v1.0.1's commit stable-2026-10-05 on the remote" \
  || fail "cut: rc $rc, remote tag '$(rtag stable-2026-10-05)', want $c5"
grep -qx 'tag=stable-2026-10-05' "$T/gh.out" && grep -qx 'version=1.0.1' "$T/gh.out" && pass "GITHUB_OUTPUT tag= + version=" \
  || fail "GITHUB_OUTPUT: $(cat "$T/gh.out")"

# --- 3. same day again -------------------------------------------------------------
out=$(act STABLE_DATE=2026-10-05 DRY_RUN=0); rc=$?
((rc == 0)) && grep -q 'already names' <<<"$out" && pass "same day, same commit: nothing cut, exit 0" || fail "re-run same day: rc $rc"

# --- 4. no new v-tag ---------------------------------------------------------------
c6=$(commit "feat(hub): new feature six")
act STABLE_DATE=2026-10-12 DRY_RUN=0 >/dev/null; rc=$?
((rc == 0)) && [[ -z "$(rtag stable-2026-10-12)" ]] && pass "no new build since the last stable: nothing cut" \
  || fail "no new v-tag: rc $rc, tag '$(rtag stable-2026-10-12)'"

# --- 5. next week ------------------------------------------------------------------
c7=$(commit "fix(hub): new fix seven")
git -C "$T/w" push -q origin HEAD:master; vtag 1.0.2 "$c7"
out=$(act STABLE_DATE=2026-10-12 DRY_RUN=0); rc=$?
if ((rc == 0)) && [[ "$(rtag stable-2026-10-12)" == "$c7" ]] && grep -q 'new feature six' <<<"$out" && grep -q 'new fix seven' <<<"$out" \
   && grep -q '2 commits since stable-2026-10-05' <<<"$out" && grep -q '^## Database migrations (0)' <<<"$out"; then
  pass "next week: v1.0.2 cut, notes since stable-2026-10-05"
else
  fail "next week (rc $rc): $out"
fi
grep -q 'old feature one\|0100_new_table' <<<"$out" && fail "CONTROL: last week's commits leaked into the notes" \
  || pass "CONTROL: last week's commits and migration are not repeated"

# --- 6. a tag never moves ----------------------------------------------------------
c8=$(commit "feat(hub): eight"); vtag 1.0.3 "$c8"
act STABLE_DATE=2026-10-12 DRY_RUN=0 >/dev/null; rc=$?
((rc == 1)) && [[ "$(rtag stable-2026-10-12)" == "$c7" ]] && pass "today's tag on another commit: FATAL, the tag did not move" \
  || fail "moving tag: rc $rc, tag now '$(rtag stable-2026-10-12)'"

# --- 7. STABLE_FROM_URL ------------------------------------------------------------
printf '{"commit":"%s","version":"1.0.2"}' "$c7" >"$T/version.json"
c9=$(commit "feat(hub): nine, built but not on prd"); vtag 1.0.4 "$c9"
out=$(act STABLE_DATE=2026-10-19 STABLE_FROM_URL="file://$T/version.json"); rc=$?
((rc == 0)) && grep -q 'nothing new since stable-2026-10-12' <<<"$out" && pass "STABLE_FROM_URL: the reported commit wins over v1.0.4 (already released)" \
  || fail "STABLE_FROM_URL (rc $rc): $out $(tail -2 "$T/act.err")"
printf '{"commit":"%s"}' "$c9" >"$T/version.json"
out=$(act STABLE_DATE=2026-10-19 STABLE_FROM_URL="file://$T/version.json"); rc=$?
((rc == 0)) && grep -q "Commit \`${c9:0:12}\`" <<<"$out" && pass "STABLE_FROM_URL: the reported commit is the one released" \
  || fail "STABLE_FROM_URL commit: $out"

# --- 8. cap ------------------------------------------------------------------------
out=$(act STABLE_DATE=2026-10-19 STABLE_NOTES_MAX=1); rc=$?
grep -q '^## Features (2)' <<<"$out" && grep -q '^- \.\.\. and 1 more: `git log --no-merges stable-2026-10-12..stable-2026-10-19`' <<<"$out" \
  && pass "STABLE_NOTES_MAX=1: one row, the rest counted" || fail "cap: $out"

echo "fails=$fails"
exit $((fails > 0))
