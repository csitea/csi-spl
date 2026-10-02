#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Supply-chain: every third-party GitHub Action in .github/workflows is pinned
# to a full 40-hex commit SHA, not a movable tag (@v4) or branch. A tag can be
# re-pointed at malicious code after review (the tj-actions/changed-files
# compromise, 2025); a SHA cannot. Local reusable workflows (uses: ./...) and
# the GITHUB_TOKEN-only actions are exempt only by being local.
#
# PENDING lists workflow files a live lane still owns this round; they are
# pinned in a later commit and removed from PENDING then. The control below
# proves the check actually catches an unpinned ref.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF_DIR="$APP_ROOT/.github/workflows"

fails=0

# Files not yet enforced (owned by another lane / awaiting a go this round).
# 20/30 are now pinned and enforced (CLE-77788 cleared them after its release-tag
# fix landed + both deploys proved green); nothing is pending.
PENDING=()
is_pending() { local b; for b in ${PENDING[@]+"${PENDING[@]}"}; do [[ "$1" == "$b" ]] && return 0; done; return 1; }

# Print any external `uses:` whose ref is not a 40-hex SHA, one "file:line: ref"
# per finding. Local (./…) and docker:// refs are not tag-pinnable here.
unpinned_in() {
  local file="$1"
  awk '
    match($0, /^[[:space:]]*(- )?uses:[[:space:]]*/) {
      s = substr($0, RLENGTH + 1)
      sub(/[[:space:]]*#.*$/, "", s)
      if (s ~ /^\.\//) next            # local reusable workflow
      if (s ~ /^docker:\/\//) next     # digest-pinned elsewhere
      n = split(s, a, "@")
      if (n < 2) next
      ref = a[n]
      if (ref !~ /^[0-9a-f]{40}$/) print FILENAME ":" NR ": " s
    }
  ' "$file"
}

[[ -d "$WF_DIR" ]] || { fail "no workflows dir at $WF_DIR"; exit 1; }

# --- negative control: a planted @v4 ref is caught ---------------------------
CTL=$(mktemp)
printf 'jobs:\n  x:\n    steps:\n      - uses: actions/checkout@v4\n' >"$CTL"
if [[ -n "$(unpinned_in "$CTL")" ]]; then
  pass "CONTROL: an unpinned actions/checkout@v4 is detected"
else
  fail "CONTROL: the checker missed an unpinned @v4 ref"
fi
rm -f "$CTL"

# --- every enforced workflow file is fully SHA-pinned ------------------------
enforced=0
for f in "$WF_DIR"/*.yml; do
  b=$(basename "$f")
  is_pending "$b" && continue
  enforced=$((enforced + 1))
  bad=$(unpinned_in "$f")
  if [[ -z "$bad" ]]; then
    pass "$b: all third-party actions pinned to a SHA"
  else
    fail "$b: unpinned action(s):"
    sed 's/^/      /' <<<"$bad"
  fi
done
[[ "$enforced" -gt 0 ]] && pass "enforced SHA-pinning on $enforced workflow file(s)" \
  || fail "no workflow files were enforced"

[[ "$fails" -eq 0 ]] && echo "PASS: all workflow-actions-sha-pinned.tst.sh assertions"
exit "$fails"
