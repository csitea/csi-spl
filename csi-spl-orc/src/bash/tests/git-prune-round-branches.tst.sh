#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_git_prune_round_branches lists one round's review/wip branches
# and deletes only those, only with DRY_RUN=0 (refactor-round-8-plan.md row 10).
#   1. DRY_RUN unset, ROUND=7: a REF line (branch, sha, date) per r7 branch,
#      0 deletes on the remote
#   2. ROUND=7 DRY_RUN=0: exactly the r7 refs gone; master, review/r6-x and
#      the near misses (r17, r70, review/r7 with no dash) kept
#   3. a bad ROUND or DRY_RUN is refused and deletes nothing
#   4. CONTROL: the review pattern widened to review/* deletes review/r6-x,
#      and the keep check of (2) reports it
# The remote is a local bare repo; nothing touches a real origin.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/git-prune-round-branches.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@example.com GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@example.com
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

R7=(review/r7-01-a review/r7-10-b wip/c-163-r7-10-x)
KEEP=(master review/r6-x wip/c-1-r6-y review/r70-z wip/c-2-r17-q wip/c-3-r70 review/r7)

# fixture <name>: a bare remote $T/<name>.git and a clone $T/<name> with every
# branch of R7 and KEEP on the remote, each on its own commit.
fixture() {
  local d="$T/$1" b i=0
  git init -q --bare "$d.git"
  git init -q -b master "$d" && git -C "$d" remote add origin "$d.git"
  for b in "${R7[@]}" "${KEEP[@]}"; do
    i=$((i + 1))
    echo "$i" >"$d/f" && git -C "$d" add f && git -C "$d" commit -qm "c$i"
    git -C "$d" push -q origin "HEAD:refs/heads/$b"
  done
}

# run_prune <func file> <clone> [VAR=value ...]
run_prune() {
  local f="$1" g="$2"
  shift 2
  env -u ROUND -u DRY_RUN PRUNE_GIT_DIR="$g" "$@" bash -c '
    set -uo pipefail
    do_log() { printf "%s\n" "$*"; }
    source "$1"
    do_git_prune_round_branches' _ "$f"
}

heads() { git --git-dir="$1.git" for-each-ref --format='%(refname:short)' refs/heads | sort; }
# kept_all <remote>: 0 when every KEEP branch is still there, else names the gone
kept_all() {
  local b gone=""
  for b in "${KEEP[@]}"; do
    git --git-dir="$1.git" rev-parse -q --verify "refs/heads/$b" >/dev/null || gone+="$b "
  done
  [[ -z "$gone" ]] || { echo "gone: $gone"; return 1; }
}

# 1. dry run by default -------------------------------------------------------
fixture a
before="$(heads "$T/a")"
out="$(run_prune "$FUNC" "$T/a" ROUND=7)"; rc=$?
refs="$(grep -c '^REF ' <<<"$out")"
sha="$(git --git-dir="$T/a.git" rev-parse refs/heads/review/r7-01-a)"
if [[ $rc -eq 0 && "$(heads "$T/a")" == "$before" && "$refs" == 3 && "$out" != *DELETED* \
  && "$out" =~ REF\ review/r7-01-a\ $sha\ [0-9]{4}-[0-9]{2}-[0-9]{2}T && "$out" == *'nothing deleted'* ]]; then
  pass "DRY_RUN unset: 3 REF lines with sha and date, 0 deletes"
else
  fail "dry run: rc=$rc refs=$refs out=$out"
fi

# 2. DRY_RUN=0 deletes exactly the r7 refs ------------------------------------
out="$(run_prune "$FUNC" "$T/a" ROUND=7 DRY_RUN=0)"; rc=$?
want="$(printf '%s\n' "${KEEP[@]}" | sort)"
if [[ $rc -eq 0 && "$(heads "$T/a")" == "$want" && "$(grep -c '^DELETED ' <<<"$out")" == 3 ]]; then
  pass "ROUND=7 DRY_RUN=0: the 3 r7 refs gone; master, review/r6-x and the near misses kept"
else
  fail "delete: rc=$rc heads=$(heads "$T/a" | paste -sd' ' -) out=$out"
fi
kept_all "$T/a" >/dev/null && pass "keep check: every KEEP branch is on the remote" || fail "keep check: $(kept_all "$T/a")"
out="$(run_prune "$FUNC" "$T/a" ROUND=7 DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *'no review/r7-* or wip/*r7* branch'* ]] && pass "a second run finds nothing to do" || fail "second run: rc=$rc out=$out"

# 3. bad inputs ---------------------------------------------------------------
fixture b
before="$(heads "$T/b")"
for args in "" "ROUND=x" "ROUND=0" "ROUND=7 DRY_RUN=2" "ROUND=7 DRY_RUN=no"; do
  # shellcheck disable=SC2086 # the args are separate VAR=value words
  out="$(run_prune "$FUNC" "$T/b" $args)"; rc=$?
  [[ $rc -ne 0 && "$(heads "$T/b")" == "$before" && "$out" == *FATAL* ]] \
    && pass "refused, nothing deleted: '${args}'" || fail "'${args}': rc=$rc out=$out"
done

# 4. CONTROL: a widened pattern deletes the r6 ref and the keep check sees it ---
fixture c
sed 's|"review/r${n}-"\*|"review/"*|' "$FUNC" >"$T/wide.func.sh"
if cmp -s "$FUNC" "$T/wide.func.sh"; then
  fail "control: the sed did not widen the review pattern"
else
  run_prune "$T/wide.func.sh" "$T/c" ROUND=7 DRY_RUN=0 >/dev/null
  if ! kept_all "$T/c" >/dev/null && [[ "$(kept_all "$T/c")" == *review/r6-x* ]]; then
    pass "control: review/* deletes review/r6-x and the keep check fails on it"
  else
    fail "control: a widened pattern was not caught ($(kept_all "$T/c"))"
  fi
fi

if (( fails )); then
  echo "FAILED: $fails"
  exit 1
fi
echo "ALL PASS"
