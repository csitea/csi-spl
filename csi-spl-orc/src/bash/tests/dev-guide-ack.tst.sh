#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_dev_guide_ack records "<who> read developer-guide.md blob <sha>"
#          in the per-user store, only when confirmed (DEV_GUIDE_ACK=yes, or
#          "yes" on a terminal); dga_check (the pre-push hook's decision)
#          passes an acked coder, a grandfathered tree (born before the cutoff,
#          guide unchanged since) and a HEAD with no guide, and refuses the
#          rest with the one command that fixes it. Any change to the guide's
#          blob asks for a new ack. Throwaway repos, store under the sandbox.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
eq() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (want '$2' got '$3')"; }
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export DEV_GUIDE_ACK_FILE="$T/state/dev-guide-ack.tsv"
unset AGENT_ID SPOOL_AGENT_ID DEV_GUIDE_ACK DEV_GUIDE_ACK_CUTOFF 2>/dev/null || true
G=csi-spl-doc/doc/md/developer-guide.md

R="$T/repo"; mkdir -p "$R/${G%/*}"; git -C "$R" init -q -b c-901-some-lane
echo "guide v1" >"$R/$G"; git -C "$R" add -A
GIT_COMMITTER_DATE=2026-01-01T00:00:00Z git -C "$R" commit -qm v1
V1="$(git -C "$R" rev-parse HEAD:$G)"

act() {  # [env...] -> the action's rc; its log in $T/out
  env APP_PATH="$R" PROJ_PATH="$PROJ_ROOT" "$@" bash -c '
    do_log() { echo "$*"; }
    . "$1/src/bash/run/dev-guide-ack.func.sh"; do_dev_guide_ack' _ "$PROJ_ROOT" </dev/null >"$T/out" 2>&1
}
chk() {  # [env...] -> dga_check's rc; stderr in $T/err, DGA_WHY in $T/why
  env "$@" bash -c '. "$1/src/bash/features/spawn-agents/lib/dev-guide-ack.inc.sh"
    dga_check "$2"; rc=$?; echo "$DGA_WHY" >"$3/why"; exit $rc' _ "$PROJ_ROOT" "$R" "$T" 2>"$T/err"
}

# 1. the action without a confirmation records nothing and says how
act; eq "1. unconfirmed, not a terminal -> rc 1" 1 "$?"
[[ ! -e "$DEV_GUIDE_ACK_FILE" ]] && pass "1. ... nothing recorded" || fail "1. ... nothing recorded"
grep -q "AGENT_ID=c-901 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack" "$T/out" && pass "1. ... prints the command" || fail "1. ... prints the command: $(cat "$T/out")"

# 2. a far-future cutoff, no ack: the tree was born before it and the guide is
#    unchanged -> grandfathered; a past cutoff (tree born after) -> refused
chk DEV_GUIDE_ACK_CUTOFF=2030-01-01T00:00:00Z; eq "2. grandfathered tree, no ack -> pass" 0 "$?"
grep -q grandfathered "$T/why" && pass "2. ... says grandfathered" || fail "2. ... says grandfathered: $(cat "$T/why")"
chk DEV_GUIDE_ACK_CUTOFF=2020-01-01T00:00:00Z; eq "2. red control: tree born after the cutoff, no ack -> refuse" 1 "$?"
grep -q "c-901 has not confirmed.*AGENT_ID=c-901 DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack" "$T/err" \
  && pass "2. ... the refusal names the one command" || fail "2. ... the refusal names the one command: $(cat "$T/err")"

# 3. confirm: one line, who from the lane branch, the guide's blob sha
act DEV_GUIDE_ACK=yes; eq "3. confirmed -> rc 0" 0 "$?"
eq "3. ... one ack line (who, sha)" "c-901	$V1" "$(cut -f2,3 "$DEV_GUIDE_ACK_FILE")"
act; eq "3. ... a second run is already acked, no prompt" 0 "$?"
eq "3. ... and adds no line" 1 "$(wc -l <"$DEV_GUIDE_ACK_FILE")"
chk DEV_GUIDE_ACK_CUTOFF=2020-01-01T00:00:00Z; eq "3. acked coder, tree born after the cutoff -> pass" 0 "$?"
chk DEV_GUIDE_ACK_CUTOFF=2020-01-01T00:00:00Z AGENT_ID=c-902; eq "3. red control: another agent's ack does not count" 1 "$?"

# 4. who: AGENT_ID > SPOOL_AGENT_ID > branch > USER
act DEV_GUIDE_ACK=yes SPOOL_AGENT_ID=g-777; eq "4. SPOOL_AGENT_ID acks" 0 "$?"
act DEV_GUIDE_ACK=yes SPOOL_AGENT_ID=g-777 AGENT_ID=m-778; eq "4. AGENT_ID beats it" 0 "$?"
git -C "$R" switch -q -c topic-without-id
act DEV_GUIDE_ACK=yes USER=dev1; eq "4. no id on the branch -> \$USER" 0 "$?"
eq "4. ... who of each line" "c-901 g-777 m-778 dev1" "$(cut -f2 "$DEV_GUIDE_ACK_FILE" | tr '\n' ' ' | sed 's/ $//')"
git -C "$R" switch -q c-901-some-lane

# 5. a guide change after the cutoff: material, every tree asks again
echo "guide v2" >"$R/$G"; git -C "$R" add -A
GIT_COMMITTER_DATE=2031-01-01T00:00:00Z git -C "$R" commit -qm v2
chk DEV_GUIDE_ACK_CUTOFF=2030-01-01T00:00:00Z; eq "5. guide changed after the cutoff: the old ack and the grandfather both lapse -> refuse" 1 "$?"
act DEV_GUIDE_ACK=yes; eq "5. re-ack the new blob" 0 "$?"
chk DEV_GUIDE_ACK_CUTOFF=2030-01-01T00:00:00Z; eq "5. ... -> pass" 0 "$?"

# 6. a HEAD with no guide (another repo, or before the guide) is never refused
git -C "$R" rm -q "$G"; git -C "$R" commit -qm rm
chk DEV_GUIDE_ACK_CUTOFF=2020-01-01T00:00:00Z AGENT_ID=c-999; eq "6. no guide in HEAD -> pass" 0 "$?"

# 7. the store lives under XDG_STATE_HOME / HOME, never a literal home
eq "7. default store" "$T/h/.local/state/csi-spl/dev-guide-ack.tsv" \
  "$(env -u DEV_GUIDE_ACK_FILE -u XDG_STATE_HOME HOME="$T/h" bash -c '. "$1/src/bash/features/spawn-agents/lib/dev-guide-ack.inc.sh"; dga_store' _ "$PROJ_ROOT")"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }
