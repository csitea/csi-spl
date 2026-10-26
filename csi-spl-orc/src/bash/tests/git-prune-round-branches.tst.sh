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
#   5. ROUND="7,8" (and ROUNDS="7 8"): both rounds' refs listed in one run,
#      DRY_RUN=0 deletes exactly those; master and r6 kept; ROUND=7 alone
#      leaves r8 alone (round 9 plan row 08)
#   6. a bad list (ROUND="7,x", "7,0", ",", ROUND and ROUNDS both set) is
#      refused and deletes nothing
#   7. lane-prefixed <id>-r7-* and review/<id>-r7-* are listed and deleted;
#      the near misses (c-1434-r7, x-143-r7, c-143-r70) kept (round 10 row 09)
#   8. an unlanded tip and a squash-landed tip (commits not cherry-equal to
#      master) print KEEP <branch> <n> unlanded and stay with DRY_RUN=0;
#      PRUNE_UNLANDED=1 deletes them
#   9. CONTROLS: without the lane-prefix match the lane branches are missed;
#      without the cherry check the unlanded tip is deleted
#  10. a round named by its branch prefix (ROUND=r01, sdlc, b01, or the
#      zero-padded 01 = r01): its review, wip and lane-prefixed refs listed
#      and deleted; the near misses (r1, r010, sdlcx, b011, review/sdlc with
#      no dash) kept; a bad prefix (r0, 00, Sdlc, review/sdlc, sdlc*) refused
#  11. PRUNE_ALL_MERGED=1 (SPL-3609) on a planted remote: merged and
#      one-commit squash-merged heads and a done lane's head are listed and,
#      with DRY_RUN=0, deleted in batches; master, ruleset*, a protected
#      branch, a live lane's branch and its review/ slug, an unlanded and a
#      multi-commit squash tip are KEPT with their reason; DRY_RUN=0 is
#      refused when the lane map (failed, hub not ok) or the protected list
#      cannot be read; a WARN line before the map's JSON is skipped; ROUND,
#      PRUNE_UNLANDED=1, a bad PRUNE_BATCH refused
#  12. CONTROLS: without the live-lane check the live lane's branches are
#      deleted; without the cherry check the unlanded tip is deleted
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
R8=(review/r8-02-c wip/c-200-r8-02-y)

# fixture <name> [extra branch ...]: a bare remote $T/<name>.git and a clone
# $T/<name> with every branch of R7, KEEP and the extras on the remote, each
# on its own commit; master ends on the last one, so every tip is landed.
fixture() {
  local d="$T/$1" b i=0
  shift
  git init -q --bare "$d.git"
  git init -q -b master "$d" && git -C "$d" remote add origin "$d.git"
  for b in "${R7[@]}" "${KEEP[@]}" "$@"; do
    i=$((i + 1))
    echo "$i" >"$d/f" && git -C "$d" add f && git -C "$d" commit -qm "c$i"
    git -C "$d" push -q origin "HEAD:refs/heads/$b"
  done
  git -C "$d" push -q origin HEAD:refs/heads/master
}

# side <clone> <branch> <file>...: push <branch> = master + one commit per
# file (a new file each), off trunk; master does not move.
side() {
  local d="$1" b="$2" f
  shift 2
  git -C "$d" checkout -q -b "$b" master
  for f in "$@"; do echo "$f" >"$d/$f" && git -C "$d" add "$f" && git -C "$d" commit -qm "$f"; done
  git -C "$d" push -q origin "HEAD:refs/heads/$b"
  git -C "$d" checkout -q master
}

# run_prune <func file> <clone> [VAR=value ...]
run_prune() {
  local f="$1" g="$2"
  shift 2
  env -u ROUND -u ROUNDS -u DRY_RUN PRUNE_GIT_DIR="$g" "$@" bash -c '
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
[[ $rc -eq 0 && "$out" == *'no review/r7-*, wip/*r7* or [review/]<id>-r7-* branch'* ]] && pass "a second run finds nothing to do" || fail "second run: rc=$rc out=$out"

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
sed 's|"review/${p}-"\*|"review/"*|' "$FUNC" >"$T/wide.func.sh"
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

# 5. several rounds in one run -----------------------------------------------
fixture m "${R8[@]}"
before="$(heads "$T/m")"
out="$(run_prune "$FUNC" "$T/m" ROUND=7)"; rc=$?
[[ $rc -eq 0 && "$(grep -c '^REF ' <<<"$out")" == 3 && "$out" != *r8-* ]] \
  && pass "ROUND=7 alone lists the 3 r7 refs, no r8 ref" || fail "single round on the multi fixture: rc=$rc out=$out"
out="$(run_prune "$FUNC" "$T/m" ROUND="7,8")"; rc=$?
got="$(grep '^REF ' <<<"$out" | cut -d' ' -f2 | sort)"
want="$(printf '%s\n' "${R7[@]}" "${R8[@]}" | sort)"
if [[ $rc -eq 0 && "$got" == "$want" && "$(heads "$T/m")" == "$before" && "$out" == *'nothing deleted'* ]]; then
  pass "ROUND=\"7,8\" dry run: the 5 r7 + r8 refs listed, 0 deletes"
else
  fail "ROUND=\"7,8\" dry run: rc=$rc got=$(paste -sd' ' - <<<"$got") out=$out"
fi
out2="$(run_prune "$FUNC" "$T/m" ROUNDS="7 8")"; rc=$?
[[ $rc -eq 0 && "$(grep '^REF ' <<<"$out2")" == "$(grep '^REF ' <<<"$out")" ]] \
  && pass "ROUNDS=\"7 8\" lists the same refs as ROUND=\"7,8\"" || fail "ROUNDS=\"7 8\": rc=$rc out=$out2"
out="$(run_prune "$FUNC" "$T/m" ROUND="7,8" DRY_RUN=0)"; rc=$?
want="$(printf '%s\n' "${KEEP[@]}" | sort)"
if [[ $rc -eq 0 && "$(heads "$T/m")" == "$want" && "$(grep -c '^DELETED ' <<<"$out")" == 5 ]] && kept_all "$T/m" >/dev/null; then
  pass "ROUND=\"7,8\" DRY_RUN=0: the 5 r7 + r8 refs gone; master and r6 kept"
else
  fail "ROUND=\"7,8\" delete: rc=$rc heads=$(heads "$T/m" | paste -sd' ' -) out=$out"
fi

# 6. bad round lists ----------------------------------------------------------
fixture n "${R8[@]}"
before="$(heads "$T/n")"
for args in "ROUND=7,x" "ROUND=7,0" "ROUND=," "ROUNDS=8,-1" "ROUND=7 ROUNDS=8"; do
  # shellcheck disable=SC2086 # the args are separate VAR=value words
  out="$(run_prune "$FUNC" "$T/n" $args DRY_RUN=0)"; rc=$?
  [[ $rc -ne 0 && "$(heads "$T/n")" == "$before" && "$out" == *FATAL* ]] \
    && pass "refused, nothing deleted: '${args} DRY_RUN=0'" || fail "'${args}': rc=$rc out=$out"
done

# 7. lane-prefixed branches ---------------------------------------------------
LANE7=(c-143-r7-09-x review/c-104-r7-02-y m-946-r7-01)
NEAR=(c-1434-r7-x x-143-r7-y c-143-r70-x review/c-104-r17-y)
fixture l "${LANE7[@]}" "${NEAR[@]}"
out="$(run_prune "$FUNC" "$T/l" ROUND=7)"; rc=$?
got="$(grep '^REF ' <<<"$out" | cut -d' ' -f2 | sort)"
want="$(printf '%s\n' "${R7[@]}" "${LANE7[@]}" | sort)"
[[ $rc -eq 0 && "$got" == "$want" ]] \
  && pass "ROUND=7 lists the 3 lane-prefixed refs too, no near miss" || fail "lane-prefixed: rc=$rc got=$(paste -sd' ' - <<<"$got")"
out="$(run_prune "$FUNC" "$T/l" ROUND=7 DRY_RUN=0)"; rc=$?
want="$(printf '%s\n' "${KEEP[@]}" "${NEAR[@]}" | sort)"
[[ $rc -eq 0 && "$(heads "$T/l")" == "$want" ]] \
  && pass "ROUND=7 DRY_RUN=0 deletes the lane-prefixed refs; near misses kept" || fail "lane-prefixed delete: rc=$rc heads=$(heads "$T/l" | paste -sd' ' -)"

# 8. unlanded and squash-landed tips ------------------------------------------
fixture u
side "$T/u" wip/c-9-r7-unlanded u1 u2
side "$T/u" review/r7-05-squash s1 s2
# master lands s1+s2 as ONE squash commit: same tree, not cherry-equal
git -C "$T/u" checkout -q master && echo s1 >"$T/u/s1" && echo s2 >"$T/u/s2"
git -C "$T/u" add s1 s2 && git -C "$T/u" commit -qm squash && git -C "$T/u" push -q origin HEAD:refs/heads/master
out="$(run_prune "$FUNC" "$T/u" ROUND=7)"; rc=$?
if [[ $rc -eq 0 && "$out" == *'KEEP wip/c-9-r7-unlanded 2 unlanded'* && "$out" == *'KEEP review/r7-05-squash 2 unlanded'* \
  && "$(grep -c '^REF ' <<<"$out")" == 3 && "$out" == *'3 branch(es) listed, 2 kept unlanded'* ]]; then
  pass "dry run: KEEP lines for the unlanded and the squash-landed tip, 3 REF"
else
  fail "unlanded dry run: rc=$rc out=$out"
fi
out="$(run_prune "$FUNC" "$T/u" ROUND=7 DRY_RUN=0)"; rc=$?
want="$(printf '%s\n' "${KEEP[@]}" wip/c-9-r7-unlanded review/r7-05-squash | sort)"
[[ $rc -eq 0 && "$(heads "$T/u")" == "$want" && "$(grep -c '^DELETED ' <<<"$out")" == 3 ]] \
  && pass "DRY_RUN=0: the 3 landed r7 refs gone, the 2 KEEP tips stay" || fail "unlanded delete: rc=$rc heads=$(heads "$T/u" | paste -sd' ' -) out=$out"
out="$(run_prune "$FUNC" "$T/u" ROUND=7 DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *'nothing to delete'* && "$out" != *DELETED* ]] \
  && pass "a second run deletes nothing, keeps the 2" || fail "unlanded second run: rc=$rc out=$out"
out="$(run_prune "$FUNC" "$T/u" ROUND=7 DRY_RUN=0 PRUNE_UNLANDED=1)"; rc=$?
want="$(printf '%s\n' "${KEEP[@]}" | sort)"
[[ $rc -eq 0 && "$(heads "$T/u")" == "$want" && "$(grep -c '^DELETED ' <<<"$out")" == 2 ]] \
  && pass "PRUNE_UNLANDED=1 deletes the 2 unlanded tips" || fail "PRUNE_UNLANDED=1: rc=$rc out=$out"

# 9. CONTROLS: the old matcher and no cherry check -----------------------------
fixture cl "${LANE7[@]}"
sed '/\[acgmq\]-\[0-9\]{3}-\$/d' "$FUNC" >"$T/nolane.func.sh"
if cmp -s "$FUNC" "$T/nolane.func.sh"; then
  fail "control: the sed did not drop the lane-prefix match"
else
  out="$(run_prune "$T/nolane.func.sh" "$T/cl" ROUND=7)"
  [[ "$(grep -c '^REF ' <<<"$out")" == 3 && "$out" != *c-143-r7-09-x* ]] \
    && pass "control: without the lane-prefix match the 3 lane refs are missed" || fail "control lane: $out"
fi
fixture cu
side "$T/cu" wip/c-9-r7-unlanded u1
sed 's|u="$(prune_round_unlanded [^)]*)"|u=0|' "$FUNC" >"$T/nocherry.func.sh"
if cmp -s "$FUNC" "$T/nocherry.func.sh"; then
  fail "control: the sed did not drop the cherry check"
else
  run_prune "$T/nocherry.func.sh" "$T/cu" ROUND=7 DRY_RUN=0 >/dev/null
  git --git-dir="$T/cu.git" rev-parse -q --verify refs/heads/wip/c-9-r7-unlanded >/dev/null \
    && fail "control: without the cherry check the unlanded tip survived" \
    || pass "control: without the cherry check the unlanded tip is deleted"
fi

# 10. rounds named by their branch prefix ------------------------------------
NAMED=(review/r01-01 review/r01-10-x wip/c-5-r01-y review/sdlc-07-2 wip/c-247-c002-sdlc-seat review/c-104-sdlc-02 review/b01-03 m-946-b01-04)
NEARN=(review/r1-x review/r010-x wip/c-6-r010 review/sdlcx-1 wip/c-7-sdlcx review/sdlc review/b011-x)
fixture nm "${NAMED[@]}" "${NEARN[@]}"
before="$(heads "$T/nm")"
for args in "ROUND=r01,sdlc,b01" "ROUNDS=01 sdlc b01" "ROUND=r01,01,sdlc,b01,sdlc"; do
  out="$(run_prune "$FUNC" "$T/nm" "$args")"; rc=$?
  got="$(grep '^REF ' <<<"$out" | cut -d' ' -f2 | sort)"
  want="$(printf '%s\n' "${NAMED[@]}" | sort)"
  [[ $rc -eq 0 && "$got" == "$want" && "$(heads "$T/nm")" == "$before" ]] \
    && pass "$args dry run: the 8 named-round refs listed, no near miss" || fail "$args: rc=$rc got=$(paste -sd' ' - <<<"$got") out=$out"
done
out="$(run_prune "$FUNC" "$T/nm" ROUND=sdlc)"; rc=$?
got="$(grep '^REF ' <<<"$out" | cut -d' ' -f2 | sort | paste -sd' ' -)"
[[ $rc -eq 0 && "$got" == "review/c-104-sdlc-02 review/sdlc-07-2 wip/c-247-c002-sdlc-seat" ]] \
  && pass "ROUND=sdlc lists only the 3 sdlc refs" || fail "ROUND=sdlc: rc=$rc got=$got"
out="$(run_prune "$FUNC" "$T/nm" ROUND=1)"; rc=$?
got="$(grep '^REF ' <<<"$out" | cut -d' ' -f2 | paste -sd' ' -)"
[[ $rc -eq 0 && "$got" == "review/r1-x" ]] && pass "ROUND=1 lists review/r1-x only, no r01 ref" || fail "ROUND=1: rc=$rc got=$got"
out="$(run_prune "$FUNC" "$T/nm" ROUND="r01,sdlc,b01" DRY_RUN=0)"; rc=$?
want="$(printf '%s\n' "${R7[@]}" "${KEEP[@]}" "${NEARN[@]}" | sort)"
[[ $rc -eq 0 && "$(heads "$T/nm")" == "$want" && "$(grep -c '^DELETED ' <<<"$out")" == 8 ]] \
  && pass "ROUND=r01,sdlc,b01 DRY_RUN=0: the 8 refs gone, near misses kept" || fail "named delete: rc=$rc heads=$(heads "$T/nm" | paste -sd' ' -) out=$out"
fixture nb
before="$(heads "$T/nb")"
for args in "ROUND=r0" "ROUND=00" "ROUND=r00" "ROUND=Sdlc" "ROUND=review/sdlc" "ROUND=sdlc*" "ROUND=sdlc-1" "ROUND=r" "ROUND=7,c"; do
  out="$(run_prune "$FUNC" "$T/nb" "$args" DRY_RUN=0)"; rc=$?
  [[ $rc -ne 0 && "$(heads "$T/nb")" == "$before" && "$out" == *FATAL* ]] \
    && pass "refused, nothing deleted: '${args} DRY_RUN=0'" || fail "'${args}': rc=$rc out=$out"
done

# 11. PRUNE_ALL_MERGED=1 -----------------------------------------------------
# amfix <name>: a remote with master, landed heads (merged, ruleset-proof/c-1,
# release/x, the live lane c-500-lane-x and review/lane-x, the done lane's
# c-501-old), a one-commit squash-landed head, a two-commit squash-landed head
# and an unlanded head
AM_DEL=(review/merged-a wip/merged-b c-501-old review/squash-one)
AM_KEEP=(master ruleset-proof/c-1 release/x c-500-lane-x review/lane-x wip/unlanded-z review/squash-two)
amfix() {
  local d="$T/$1" b i=0
  git init -q --bare "$d.git"
  git init -q -b master "$d" && git -C "$d" remote add origin "$d.git"
  for b in review/merged-a wip/merged-b c-501-old ruleset-proof/c-1 release/x c-500-lane-x review/lane-x; do
    i=$((i + 1))
    echo "$i" >"$d/f" && git -C "$d" add f && git -C "$d" commit -qm "c$i"
    git -C "$d" push -q origin "HEAD:refs/heads/$b"
  done
  git -C "$d" push -q origin HEAD:refs/heads/master
  side "$d" wip/unlanded-z z1
  side "$d" review/squash-one o1
  side "$d" review/squash-two t1 t2
  git -C "$d" checkout -q master && echo o1 >"$d/o1" && echo t1 >"$d/t1" && echo t2 >"$d/t2"
  git -C "$d" add o1 && git -C "$d" commit -qm o1-squash && git -C "$d" add t1 t2 && git -C "$d" commit -qm t-squash
  git -C "$d" push -q origin HEAD:refs/heads/master
}
LANES_OK='{"hub":"ok","lanes":[{"agent_id":"c-500","agent_box":"b1","branch":"c-500-lane-x","state":"live"},{"agent_id":"c-501","agent_box":"b2","branch":"c-501-old","state":"done"}]}'
AM_ENV=(PRUNE_ALL_MERGED=1 "PRUNE_LANES_CMD=printf '%s' '$LANES_OK'" "PRUNE_PROTECTED_CMD=echo release/x")
amfix am
before="$(heads "$T/am")"
out="$(run_prune "$FUNC" "$T/am" "${AM_ENV[@]}")"; rc=$?
got="$(grep '^REF ' <<<"$out" | cut -d' ' -f2 | sort)"
want="$(printf '%s\n' "${AM_DEL[@]}" | sort)"
if [[ $rc -eq 0 && "$got" == "$want" && "$(heads "$T/am")" == "$before" && "$out" == *'KEEP master trunk'* \
  && "$out" == *'KEEP ruleset-proof/c-1 ruleset'* && "$out" == *'KEEP release/x protected'* \
  && "$out" == *'KEEP c-500-lane-x live-lane c-500@b1'* && "$out" == *'KEEP review/lane-x live-lane c-500@b1'* \
  && "$out" == *'KEEP wip/unlanded-z unlanded 1'* && "$out" == *'KEEP review/squash-two unlanded 2'* \
  && "$out" == *'DELETE 4, KEEP 7 (live-lane 2, protected 1, ruleset 1, trunk 1, unlanded 2), nothing deleted'* ]]; then
  pass "all merged dry run: 4 REF (merged, squash of one, done lane), 7 KEEP by reason, 0 deletes"
else
  fail "all merged dry run: rc=$rc got=$(paste -sd' ' - <<<"$got") out=$out"
fi
out="$(run_prune "$FUNC" "$T/am" "${AM_ENV[@]}" DRY_RUN=0 PRUNE_BATCH=3)"; rc=$?
want="$(printf '%s\n' "${AM_KEEP[@]}" | sort)"
[[ $rc -eq 0 && "$(heads "$T/am")" == "$want" && "$(grep -c '^DELETED ' <<<"$out")" == 4 && "$out" == *'deleted 4 branch(es) in batches of 3'* ]] \
  && pass "all merged DRY_RUN=0 PRUNE_BATCH=3: the 4 gone in 2 pushes, the 7 KEEP stay" \
  || fail "all merged delete: rc=$rc heads=$(heads "$T/am" | paste -sd' ' -) out=$out"
out="$(run_prune "$FUNC" "$T/am" "${AM_ENV[@]}" DRY_RUN=0)"; rc=$?
[[ $rc -eq 0 && "$out" == *'nothing to delete, KEEP 7'* && "$out" != *DELETED* ]] \
  && pass "all merged: a second run deletes nothing" || fail "all merged second run: rc=$rc out=$out"
amfix ar
before="$(heads "$T/ar")"
out="$(run_prune "$FUNC" "$T/ar" "${AM_ENV[@]}" "PRUNE_LANES_CMD=echo 'WARN keeping x'; printf '%s\n' '$LANES_OK'")"; rc=$?
[[ $rc -eq 0 && "$out" == *'KEEP c-500-lane-x live-lane c-500@b1'* && "$out" != *'WARN the fleet lane map'* ]] \
  && pass "all merged: a WARN line before the lane map JSON is skipped, the live lane still KEPT" || fail "lane map after a WARN line: rc=$rc out=$out"
for bad in "PRUNE_LANES_CMD=exit 1" "PRUNE_LANES_CMD=echo '{\"hub\":\"LOCAL-ONLY\",\"lanes\":[]}'" "PRUNE_LANES_CMD=echo not-json" "PRUNE_PROTECTED_CMD=exit 1"; do
  out="$(run_prune "$FUNC" "$T/ar" "${AM_ENV[@]}" "$bad" DRY_RUN=0)"; rc=$?
  [[ $rc -ne 0 && "$(heads "$T/ar")" == "$before" && "$out" == *'DRY_RUN=0 refused'* ]] \
    && pass "all merged DRY_RUN=0 refused, nothing deleted: '$bad'" || fail "'$bad': rc=$rc out=$out"
done
out="$(run_prune "$FUNC" "$T/ar" "${AM_ENV[@]}" "PRUNE_LANES_CMD=exit 1")"; rc=$?
[[ $rc -eq 0 && "$out" == *'WARN the fleet lane map'* && "$(grep -c '^REF ' <<<"$out")" == 6 ]] \
  && pass "all merged dry run with no lane map: WARN, the live lane's 2 heads listed, nothing deleted" || fail "dry no lane map: rc=$rc out=$out"
for args in "ROUND=7" "PRUNE_UNLANDED=1" "PRUNE_BATCH=0" "PRUNE_BATCH=x" "DRY_RUN=2"; do
  dr=0; [[ "$args" == DRY_RUN=* ]] && dr="${args#DRY_RUN=}"
  out="$(run_prune "$FUNC" "$T/ar" "${AM_ENV[@]}" DRY_RUN="$dr" "$args")"; rc=$?
  [[ $rc -ne 0 && "$(heads "$T/ar")" == "$before" && "$out" == *FATAL* ]] \
    && pass "all merged refused, nothing deleted: '$args'" || fail "'$args': rc=$rc out=$out"
done

# 12. CONTROLS: no live-lane check, no cherry check ---------------------------
sed 's|^  hit="$(awk .*|  hit=""|' "$FUNC" >"$T/nolive.func.sh"
if cmp -s "$FUNC" "$T/nolive.func.sh"; then
  fail "control: the sed did not drop the live-lane check"
else
  amfix al
  run_prune "$T/nolive.func.sh" "$T/al" "${AM_ENV[@]}" DRY_RUN=0 >/dev/null
  git --git-dir="$T/al.git" rev-parse -q --verify refs/heads/c-500-lane-x >/dev/null \
    && fail "control: without the live-lane check the live lane's branch survived" \
    || pass "control: without the live-lane check the live lane's branch is deleted"
fi
sed 's|then u="$(prune_round_unlanded [^)]*)"|then u=0|' "$FUNC" >"$T/amnocherry.func.sh"
if cmp -s "$FUNC" "$T/amnocherry.func.sh"; then
  fail "control: the sed did not drop the all-merged cherry check"
else
  amfix ac
  run_prune "$T/amnocherry.func.sh" "$T/ac" "${AM_ENV[@]}" DRY_RUN=0 >/dev/null
  git --git-dir="$T/ac.git" rev-parse -q --verify refs/heads/wip/unlanded-z >/dev/null \
    && fail "control: without the cherry check the unlanded tip survived" \
    || pass "control: without the cherry check the unlanded tip is deleted"
fi

if (( fails )); then
  echo "FAILED: $fails"
  exit 1
fi
echo "ALL PASS"
