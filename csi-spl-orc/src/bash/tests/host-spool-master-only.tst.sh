#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the shared host spool binary (spl_host_spool) is only ever a build
#          of a commit on origin/master (SPL-2041). On 2026-10-15 a lane's full
#          pre-push orc part rebuilt $HOME/.local/share/csi-spl/cloud/prd/bin/spool
#          from its UNLANDED branch twice (15:26Z c-221, 16:5xZ c-224); every
#          later caller on master then KEPT it ("diverged ... and is newer",
#          decided by commit time) until it was rebuilt by hand.
#   1. a lane-branch build, diverged from master and committed later, and a
#      master tree -> build (CONTROL: the previous verdict refuses = keeps it)
#   2. a lane-branch build that descends from the master tree's HEAD -> build
#      (CONTROL: the previous verdict refuses it as "NEWER")
#   3. a master build NEWER than the tree (an older master worktree) -> refuse
#      as today; SPL_SPOOL_REBUILD=1 still overrides
#   4. newer master commits touching no build input -> keep (CLE-35076)
#   5. a lane tree off master never writes the shared path: not on a newer
#      module, not on a dirty module; it gets the shared binary and a WARN;
#      SPL_SPOOL_REBUILD=1 still builds
#   6. no origin/master ref at all -> the previous rules (the diverged case is
#      decided by commit time)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
# Same guards as host-spool-no-rebuild.tst.sh: the pre-push gate exports APP
# and, as a git hook, GIT_DIR; neither may reach the fixture.
export APP=/nonexistent/caller-app
unset TREE_APP SPL_SPOOL_REBUILD SPL_SPOOL_FUNC
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY GIT_PREFIX
# Commit times one minute apart, so "committed later" is real, not a tie.
n=0
g() {
  n=$((n + 1))
  GIT_COMMITTER_DATE="@$((1760000000 + n * 60)) +0000" GIT_AUTHOR_DATE="@$((1760000000 + n * 60)) +0000" \
    git -c user.name=t -c user.email=t@example.com -C "$@"
}

# The app-shaped tree of host-spool-no-rebuild.tst.sh: a stub build.sh that
# counts its runs and writes a "binary" carrying the tree's HEAD.
A="$T/app"
mkdir -p "$A/csi-spl-api/src/bash" "$A/csi-spl-api/src/go/spool-hub-api" "$A/csi-spl-orc"
cat >"$A/csi-spl-api/src/bash/build.sh" <<'EOS'
#!/usr/bin/env bash
echo build >>"$T_BUILDS"
h="$(git -C "$(dirname "$0")" rev-parse HEAD)"
printf '#!/bin/sh\n# commit=%s\necho stub\n' "$h" >"$1" && chmod +x "$1"
EOS
echo 'package main' >"$A/csi-spl-api/src/go/spool-hub-api/main.go"
echo 0.0.1 >"$A/.version"
echo notes >"$A/README.md"
g "$A" init -q -b master && g "$A" add -A && g "$A" commit -qm one
S="$T/state"
: >"$T/builds"
# origin/master as `git fetch` leaves it: a remote-tracking ref, shared by
# every worktree of the repo.
trunk() { git -C "$A" update-ref refs/remotes/origin/master "$1"; }

# Runs FUNC with the orc funcs sourced (SPL_SPOOL_FUNC= a file that redefines
# spl_host_spool_verdict, for the controls). APP_PATH=$A unless TREE_APP.
in_orc() {
  env PROJ_PATH="$A/csi-spl-orc" APP_PATH="${TREE_APP:-$A}" SPL_ORG_APP=csi-spl SPL_STATE_DIR="$S" \
    T_BUILDS="$T/builds" ORC_LIB="$PROJ_ROOT/lib/bash/funcs" SPL_SPOOL_FUNC="${SPL_SPOOL_FUNC:-}" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$ORC_LIB/spl-cloud-cnf.func.sh"
    if [[ -n "$SPL_SPOOL_FUNC" ]]; then source "$SPL_SPOOL_FUNC"; fi
    spl_host_spool_bin_rev() { local c; c="$(sed -n "s/^# commit=//p" "$1" 2>/dev/null)"; [[ -n "$c" ]] && echo "$c unknown"; }
    '"$1"
}
builds() { wc -l <"$T/builds" | tr -d ' '; }
verdict() { in_orc 'spl_host_spool_verdict "$SPL_STATE_DIR/bin/spool"'; }
# Plant the shared binary as if it had been built (clean) from <sha>.
plant() {
  mkdir -p "$S/bin"
  printf '#!/bin/sh\n# commit=%s\necho stub\n' "$1" >"$S/bin/spool"
  chmod +x "$S/bin/spool"
  printf '%s clean\n' "$1" >"$S/bin/spool.src"
}
bin_rev() { sed -n 's/^# commit=//p' "$S/bin/spool"; }
# The previous verdict (master before SPL-2041), for the RED controls.
old="$T/old-verdict.sh"
cat >"$old" <<'EOS'
spl_host_spool_verdict() {
  local bin="$1" head state rev mod stamp
  [[ "${SPL_SPOOL_REBUILD:-0}" == 1 ]] && { echo "build SPL_SPOOL_REBUILD=1"; return 0; }
  [[ -x "$bin" ]] || { echo "build no binary yet"; return 0; }
  [[ -f "$APP_PATH/$SPL_ORG_APP-api/src/bash/build.sh" ]] ||
    { echo "keep $APP_PATH has no $SPL_ORG_APP-api to build from"; return 0; }
  head="$(git -C "$APP_PATH" rev-parse HEAD 2>/dev/null)"
  [[ -n "$head" ]] || { echo "build $APP_PATH is not a git tree"; return 0; }
  read -r rev mod < <(spl_host_spool_bin_rev "$bin") || true
  [[ -n "${rev:-}" ]] || { echo "build the binary carries no vcs.revision"; return 0; }
  if [[ "$rev" == "$head" ]]; then
    state="$(spl_host_spool_tree_state)"
    [[ "$state" == clean ]] || { echo "build the module is modified in $APP_PATH"; return 0; }
    stamp="$(cat "$bin.src" 2>/dev/null)"
    if [[ "$stamp" == "$head clean" || "$mod" == false ]]; then
      echo "keep built from $head"; return 0
    fi
    echo "build built from $head with local changes"; return 0
  fi
  if ! git -C "$APP_PATH" cat-file -e "$rev^{commit}" 2>/dev/null; then
    echo "refuse it was built from ${rev:0:12}, a commit this tree does not know"; return 0
  fi
  if git -C "$APP_PATH" merge-base --is-ancestor "$rev" "$head" 2>/dev/null; then
    if spl_host_spool_inputs_unchanged "$rev" "$head" && [[ "$(spl_host_spool_tree_state)" == clean ]] &&
      [[ "$(cat "$bin.src" 2>/dev/null)" == "$rev clean" || "$mod" == false ]]; then
      echo "keep built from ${rev:0:12}: no build input changed up to ${head:0:12}"; return 0
    fi
    echo "build the tree (${head:0:12}) is newer than the binary (${rev:0:12})"; return 0
  fi
  if git -C "$APP_PATH" merge-base --is-ancestor "$head" "$rev" 2>/dev/null; then
    echo "refuse it was built from ${rev:0:12}, NEWER than this tree's ${head:0:12} ($APP_PATH): a rebuild here would downgrade it"
    return 0
  fi
  if (( $(git -C "$APP_PATH" show -s --format=%ct "$head") >= $(git -C "$APP_PATH" show -s --format=%ct "$rev") )); then
    echo "build the tree (${head:0:12}) diverged from the binary (${rev:0:12}) and is newer"
  else
    echo "refuse it was built from ${rev:0:12}, which diverged from this tree's ${head:0:12} and is newer"
  fi
}
EOS

M1="$(git -C "$A" rev-parse HEAD)"
trunk "$M1"
# A lane worktree, branched off M1, with an unlanded commit in the module.
g "$A" worktree add -q -b lane "$T/lane" "$M1"
# Master moves on (another lane landed a module change) BEFORE the lane commits.
echo '// m2' >>"$A/csi-spl-api/src/go/spool-hub-api/main.go"
g "$A" commit -qam m2
M2="$(git -C "$A" rev-parse HEAD)"
trunk "$M2"
echo '// lane' >>"$T/lane/csi-spl-api/src/go/spool-hub-api/main.go"
g "$T/lane" commit -qam lane
L1="$(git -C "$T/lane" rev-parse HEAD)"

# --- 1. a diverged lane build, committed later, and a master tree -------------
plant "$L1"
v="$(SPL_SPOOL_FUNC="$old" verdict)"
[[ "$v" == "refuse it was built from ${L1:0:12}, which diverged"* ]] &&
  pass "1 CONTROL the previous verdict KEEPS the lane build (refuse: diverged and newer)" || fail "1 control: $v"
v="$(verdict)"
[[ "$v" == build*"not on origin/master"* ]] && pass "1 the verdict says build: not on origin/master" || fail "1 verdict: $v"
in_orc 'spl_host_spool' >/dev/null
eq "1 the master tree rebuilds it" 1 "$(builds)"
eq "1 …from master's HEAD" "$M2" "$(bin_rev)"
eq "1 …stamped clean" "$M2 clean" "$(cat "$S/bin/spool.src")"
in_orc 'spl_host_spool' >/dev/null
eq "1 …and keeps it on the next call" 1 "$(builds)"

# --- 2. a lane build that DESCENDS from the master tree's HEAD -----------------
g "$A" worktree add -q -b lane2 "$T/lane2" "$M2"
echo '// lane2' >>"$T/lane2/csi-spl-api/src/go/spool-hub-api/main.go"
g "$T/lane2" commit -qam lane2
L2="$(git -C "$T/lane2" rev-parse HEAD)"
plant "$L2"
v="$(SPL_SPOOL_FUNC="$old" verdict)"
[[ "$v" == "refuse it was built from ${L2:0:12}, NEWER"* ]] &&
  pass "2 CONTROL the previous verdict KEEPS it as a NEWER build" || fail "2 control: $v"
in_orc 'spl_host_spool' >/dev/null
eq "2 the master tree rebuilds it" 2 "$(builds)"
eq "2 …from master's HEAD" "$M2" "$(bin_rev)"
# The lane lands: the same commit is now on origin/master and is kept.
trunk "$L2"
plant "$L2"
v="$(verdict)"
[[ "$v" == "refuse it was built from ${L2:0:12}, NEWER"* ]] &&
  pass "2 once landed, the same build is a real newer master build: refused as today" || fail "2 landed: $v"
trunk "$M2"

# --- 3. a real master build newer than the tree --------------------------------
g "$A" worktree add -q --detach "$T/old" "$M1"
plant "$M2"
before="$(md5sum <"$S/bin/spool")"
out="$(TREE_APP="$T/old" in_orc 'spl_host_spool && echo "rc=0 SPOOL=$SPL_SPOOL"')"
eq "3 an OLDER master tree builds nothing" 2 "$(builds)"
eq "3 …the binary is untouched" "$before" "$(md5sum <"$S/bin/spool")"
grep -q '^WARN keeping .*NEWER than this tree' <<<"$out" && pass "3 …and the WARN is today's" || fail "3 WARN: $out"
TREE_APP="$T/old" SPL_SPOOL_REBUILD=1 in_orc 'spl_host_spool' >/dev/null
eq "3 SPL_SPOOL_REBUILD=1 still overrides" 3 "$(builds)"

# --- 4. newer master commits outside the build inputs keep the binary ----------
plant "$M2"
echo docs >>"$A/README.md"
g "$A" commit -qam docs
M3="$(git -C "$A" rev-parse HEAD)"
trunk "$M3"
v="$(verdict)"
[[ "$v" == "keep built from ${M2:0:12}: no build input changed"* ]] && pass "4 no build input changed: keep (CLE-35076)" || fail "4 verdict: $v"
in_orc 'spl_host_spool' >/dev/null
eq "4 …nothing built" 3 "$(builds)"

# --- 5. a lane tree off master never writes the shared path --------------------
g "$T/lane2" rebase -q "$M3" >/dev/null 2>&1 || fail "5 fixture rebase"
plant "$M3"
before="$(md5sum <"$S/bin/spool")"
v="$(SPL_SPOOL_FUNC="$old" TREE_APP="$T/lane2" verdict)"
[[ "$v" == build* ]] && pass "5 CONTROL the previous verdict lets a lane tree overwrite the shared binary" || fail "5 control: $v"
out="$(TREE_APP="$T/lane2" in_orc 'spl_host_spool && echo "rc=0 SPOOL=$SPL_SPOOL"')"
eq "5 a lane tree (newer module, not landed) builds nothing" 3 "$(builds)"
eq "5 …the shared binary is untouched" "$before" "$(md5sum <"$S/bin/spool")"
grep -q '^WARN keeping .*not on origin/master' <<<"$out" && pass "5 …a WARN says why" || fail "5 WARN: $out"
grep -q "^rc=0 SPOOL=$S/bin/spool$" <<<"$out" && pass "5 …and the caller gets the shared binary" || fail "5 caller: $out"
echo '// dirty' >>"$T/lane2/csi-spl-api/src/go/spool-hub-api/main.go"
TREE_APP="$T/lane2" in_orc 'spl_host_spool' >/dev/null
eq "5 a lane tree with a DIRTY module builds nothing either" 3 "$(builds)"
g "$T/lane2" checkout -q -- csi-spl-api/src/go/spool-hub-api/main.go
g "$A" worktree add -q -b lane3 "$T/lane3" "$M3"
TREE_APP="$T/lane3" in_orc 'spl_host_spool' >/dev/null
eq "5 a lane tree still AT master keeps the master build" 3 "$(builds)"
TREE_APP="$T/lane2" SPL_SPOOL_REBUILD=1 in_orc 'spl_host_spool' >/dev/null
eq "5 SPL_SPOOL_REBUILD=1 from a lane tree still builds (the operator asked)" 4 "$(builds)"

# --- 6. no origin/master: the previous rules -----------------------------------
git -C "$A" update-ref -d refs/remotes/origin/master
g "$A" worktree add -q -b lane4 "$T/lane4" "$M1"
echo '// lane4' >>"$T/lane4/csi-spl-api/src/go/spool-hub-api/main.go"
g "$T/lane4" commit -qam lane4
L4="$(git -C "$T/lane4" rev-parse HEAD)"
plant "$L4"
v="$(verdict)"
[[ "$v" == "refuse it was built from ${L4:0:12}, which diverged"* ]] &&
  pass "6 no origin/master ref: the diverged case is decided by commit time, as before" || fail "6 verdict: $v"

echo "--- $fails failure(s)"
[[ "$fails" -eq 0 ]]
