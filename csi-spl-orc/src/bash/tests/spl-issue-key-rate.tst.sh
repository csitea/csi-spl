#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_key_rate measures the fleet's issue key rate on trunk
# (owner Q6 A, spec 135 section 9; csi-spl-doc/doc/md/lane-issue-and-docs.md
# section 4). A throwaway repo with one commit of each kind proves what counts:
# a key in any subject scope or a Closes: trailer cites; only the landed-fix
# rule's forms close (the parser of issue-close-landed.py); a body mention, a
# merge, a revert and a commit older than the window do not count as citing.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

R="$T/repo"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com -c commit.gpgsign=false "$@" >/dev/null; }
c() { g commit -q --allow-empty "$@"; }
git init -q -b master "$R"
GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' c -m 'feat(orc, SPL-9): old, outside the window'
c -m 'feat(orc, SPL-1): closes by its scope'
c -m 'docs(spec, SPL-2): cites, never closes'
c -m 'chore: closes by its trailer' -m 'Closes: SPL-3'
c -m 'fix(orc): a body mention only' -m 'This is about SPL-4.'
c -m 'tidy the thing'
c -m 'Revert "feat(orc, SPL-1): closes by its scope"'
g checkout -q -b side; c -m 'test(orc): on a side branch'; g checkout -q master
g merge -q --no-ff -m 'Merge branch side' side

out="$(python3 "$PROJ_ROOT/src/bash/scripts/issue-key-rate.py" "$R" master '1 year ago')"; rc=$?
v() { jq -r "$1" <<<"$out"; }
[[ $rc -eq 0 && "$(v .commits)" == 7 ]] && pass "7 commits in the window: the old one and the merge left out" || fail "commits (rc=$rc): $out"
[[ "$(v .cite)" == 3 && "$(v .cite_pct)" == 42.9 ]] && pass "cite: a scope key of any type, or a Closes: trailer (3 of 7)" || fail "cite: $out"
[[ "$(v .close)" == 2 && "$(v .close_pct)" == 28.6 ]] && pass "close: only the landed-fix rule's forms, the docs scope does not (2 of 7)" || fail "close: $out"
[[ "$(v '.uncited_by_type | tojson')" == '{"other":2,"fix":1,"test":1}' ]] &&
  pass "uncited by type: the body mention (fix), the plain subject and the revert (other), the side commit (test)" || fail "by type: $out"

out="$(python3 "$PROJ_ROOT/src/bash/scripts/issue-key-rate.py" "$R" master '2000-01-01T00:00:00Z' | jq -r .commits)"
[[ "$out" == 8 ]] && pass "control: a wider window counts the old commit" || fail "control window: $out"
mkdir -p "$T/empty"; git init -q -b master "$T/empty"; git -C "$T/empty" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m x --date 2020-01-01T00:00:00Z
GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' git -C "$T/empty" -c user.name=t -c user.email=t@example.com commit -q --amend --allow-empty -m x
out="$(python3 "$PROJ_ROOT/src/bash/scripts/issue-key-rate.py" "$T/empty" master '1 day ago')"
[[ "$(jq -r '.commits, .cite_pct' <<<"$out" | paste -sd' ')" == "0 null" ]] && pass "no commits in the window: rate null, no division by zero" || fail "empty: $out"

# The action: the JSON line, one OK line, and a history row when asked.
SNIPPET="APP_PATH=$R; do_spl_issue_key_rate" in_orc KEY_RATE_REF=master KEY_RATE_SINCE='1 year ago' KEY_RATE_HISTORY="$T/h/history.tsv" >"$T/o" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -q '^OK key rate on master since 1 year ago: 7 commits, 3 cite an issue key (42.9%), 2 close one (28.6%)$' "$T/o" &&
  [[ "$(cut -f2- "$T/h/history.tsv")" == $'1 year ago\t7\t3\t2\t42.9\t28.6' ]] &&
  pass "action: the OK line and one history row" || fail "action (rc=$rc): $(cat "$T/o") / $(cat "$T/h/history.tsv" 2>/dev/null)"
SNIPPET="APP_PATH=$R; do_spl_issue_key_rate" in_orc KEY_RATE_REF=nope >"$T/o" 2>&1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'FATAL no such ref' "$T/o" && pass "an unknown ref is refused" || fail "bad ref (rc=$rc): $(cat "$T/o")"

# The weekly cron refuses a worktree, and its manifest row is weekly.
case "$PROJ_ROOT" in
  *-wt/*) out="$(bash "$PROJ_ROOT/src/bash/scripts/issue-key-rate-cron.sh" 2>&1)"; rc=$?
    [[ $rc -eq 2 && "$out" == *'agent worktree'* ]] && pass "cron: refused in an agent worktree" || fail "cron worktree (rc=$rc): $out" ;;
esac
grep -qE '^issue-key-rate +\| [0-9]+ [0-9]+ \* \* [0-6] +\| src/bash/scripts/issue-key-rate-cron.sh ' "$PROJ_ROOT/cnf/box-crons/box-crons.manifest" &&
  pass "the manifest runs it weekly" || fail "manifest row"

echo "spl-issue-key-rate: $fails failure(s)"
exit "$fails"
