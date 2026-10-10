#!/usr/bin/env bash
# test-pre-push-dev-guide.sh — the pre-push hook REFUSES a push to master by a
# coder who has not confirmed reading the developer guide (owner t1 4e373f5d
# msg 56d7073e), and blocks nobody already running. Real `git push` into a
# bare temp remote with the hook as core.hooksPath, a stub gate that passes,
# the real dga lib copied in, the ack store under the sandbox.
#   1. tree born after the cutoff, no ack      -> REFUSED, prints the one command
#   2. that command, then the same push        -> passes
#   3. grandfathered: tree born before the cutoff, guide unchanged -> passes, no ack
#   4. the guide changes after the cutoff       -> the old ack lapses: REFUSED;
#      re-ack -> passes
#   5. SPL_PREPUSH_OVERRIDE=1 does not skip it
#   6. a push to a non-trunk branch is not asked
#   7. a tree without the lib is not asked (fail-open)
#   8. CONTROL: the hook without the block lets the unacked push through
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
unset AGENT_ID SPOOL_AGENT_ID DEV_GUIDE_ACK DEV_GUIDE_ACK_CUTOFF SPL_PREPUSH_OVERRIDE 2>/dev/null || true
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$(cd "$HERE/../hooks" && pwd)/pre-push"
LIB="$(cd "$HERE/../lib" && pwd)/dev-guide-ack.inc.sh"
ACT="$(cd "$HERE/../../../run" && pwd)/dev-guide-ack.func.sh"

fails=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1 ${2:+:: $2}"; fails=$((fails + 1)); }
eq()   { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
ROOT=$(mktemp -d); trap 'rm -rf "$ROOT"' EXIT
export SPL_PREPUSH_LOG_DIR="$ROOT/log" DEV_GUIDE_ACK_FILE="$ROOT/state/dev-guide-ack.tsv"
PAST=2020-01-01T00:00:00Z FUTURE=2030-01-01T00:00:00Z
G=csi-spl-doc/doc/md/developer-guide.md

NEW="$ROOT/hooks-new"; OLD="$ROOT/hooks-old"; mkdir -p "$NEW" "$OLD"
install -m 0755 "$HOOK" "$NEW/pre-push"
sed '/^# Developer-guide ack (owner t1 4e373f5d/,/^fi$/d' "$HOOK" >"$OLD/pre-push"; chmod +x "$OLD/pre-push"
grep -q dga_check "$OLD/pre-push" && fail "control hook still carries the block" || pass "control hook has no dev-guide block"

git init -q --bare "$ROOT/remote.git"
A="$ROOT/a"; git clone -q "$ROOT/remote.git" "$A" 2>/dev/null
git -C "$A" checkout -q -b c-901-lane
mkdir -p "$A/csi-spl-iac" "$A/${G%/*}" "$A/csi-spl-orc/src/bash/features/spawn-agents/lib"
printf '#!/usr/bin/env bash\nexit 0\n' >"$A/csi-spl-iac/run"; chmod +x "$A/csi-spl-iac/run"
cp "$LIB" "$A/csi-spl-orc/src/bash/features/spawn-agents/lib/"
echo "guide v1" >"$A/$G"
git -C "$A" add -A; GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git -C "$A" commit -qm v1
n=0
push() {  # <hooksdir> [env...] -- <refspec>; a fresh commit each time
  local hd="$1"; shift; local e=(); while [ "$1" != -- ]; do e+=("$1"); shift; done; shift
  n=$((n + 1)); git -C "$A" commit -q --allow-empty -m "c$n"
  env "${e[@]}" git -C "$A" -c core.hooksPath="$hd" push -q origin "$@" 2>"$ROOT/err"
}
ack() { env APP_PATH="$A" PROJ_PATH="$A/csi-spl-orc" DEV_GUIDE_ACK=yes "$@" bash -c '
  do_log() { echo "$*"; }; . "$1"; do_dev_guide_ack' _ "$ACT" </dev/null >"$ROOT/ack.out" 2>&1; }

# 1. born after the cutoff, no ack
push "$NEW" DEV_GUIDE_ACK_CUTOFF=$PAST -- HEAD:master; eq "1. no ack, tree born after the cutoff -> REFUSED" 1 "$?"
grep -q "c-901 has not confirmed reading the developer guide" "$ROOT/err" && pass "1. ... says who and why" || fail "1. ... says who and why" "$(cat "$ROOT/err")"
cmd="$(grep -o 'AGENT_ID=c-901 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack' "$ROOT/err")"
eq "1. ... prints the one command" "AGENT_ID=c-901 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack" "$cmd"
grep -q "REFUSE .*no ack by c-901" "$ROOT/log/pre-push.log" && pass "1. ... logged" || fail "1. ... logged"
git -C "$ROOT/remote.git" rev-parse -q --verify master >/dev/null && fail "1. ... remote untouched" || pass "1. ... remote untouched"

# 2. ack, then the same push
ack AGENT_ID=c-901; eq "2. do_dev_guide_ack -> rc 0" 0 "$?"
push "$NEW" DEV_GUIDE_ACK_CUTOFF=$PAST -- HEAD:master; eq "2. acked -> passes" 0 "$?"

# 3. grandfathered (a fresh ack store: nobody acked)
push "$NEW" DEV_GUIDE_ACK_CUTOFF=$FUTURE DEV_GUIDE_ACK_FILE="$ROOT/state/empty.tsv" -- HEAD:master
eq "3. no ack, tree born before the cutoff, guide unchanged -> passes" 0 "$?"
grep -q "DEV-GUIDE .*grandfathered" "$ROOT/log/pre-push.log" && pass "3. ... logged as grandfathered" || fail "3. ... logged as grandfathered"

# 4. the guide changes after the cutoff: material
echo "guide v2" >"$A/$G"; git -C "$A" add -A; GIT_COMMITTER_DATE=2031-01-01T00:00:00Z git -C "$A" commit -qm v2
push "$NEW" DEV_GUIDE_ACK_CUTOFF=$FUTURE -- HEAD:master; eq "4. guide changed after the cutoff: old ack + grandfather lapse -> REFUSED" 1 "$?"
ack AGENT_ID=c-901
push "$NEW" DEV_GUIDE_ACK_CUTOFF=$FUTURE -- HEAD:master; eq "4. re-ack -> passes" 0 "$?"

# 5. the override does not skip it
push "$NEW" DEV_GUIDE_ACK_CUTOFF=$PAST AGENT_ID=c-902 SPL_PREPUSH_OVERRIDE=1 -- HEAD:master
eq "5. SPL_PREPUSH_OVERRIDE=1, no ack -> still REFUSED" 1 "$?"

# 6. not trunk
push "$NEW" DEV_GUIDE_ACK_CUTOFF=$PAST AGENT_ID=c-902 -- HEAD:refs/heads/topic; eq "6. push to a non-trunk branch -> not asked" 0 "$?"

# 8. control before 7 (7 removes the lib)
push "$OLD" DEV_GUIDE_ACK_CUTOFF=$PAST AGENT_ID=c-902 -- HEAD:master; eq "8. CONTROL: without the block the unacked push goes through" 0 "$?"

# 7. no lib in the pushing tree
git -C "$A" rm -q -r csi-spl-orc; git -C "$A" commit -qm nolib
push "$NEW" DEV_GUIDE_ACK_CUTOFF=$PAST AGENT_ID=c-902 -- HEAD:master; eq "7. a tree without the lib -> not asked" 0 "$?"

echo "-- test-pre-push-dev-guide.sh: $fails failed"
[ "$fails" -eq 0 ]
