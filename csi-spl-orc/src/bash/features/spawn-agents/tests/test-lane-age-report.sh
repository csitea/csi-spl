#!/usr/bin/env bash
# test-lane-age-report.sh — the 30-minute lane report (practice 11): one line
#   per live worker lane past the threshold, its push and spool-msg ages, "-"
#   when there is none; role seats, torn-down worktrees and young lanes left
#   out; the latest registry row of an id wins; and it changes nothing.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
R="$T_SCRIPTS/lane-age-report.sh"
now="$(date -u -d '2026-10-03 12:00:00' +%s)"
W="$T_TMP/wt"
mkdir -p "$W/c-050" "$W/c-051" "$W/c-052" "$W/c-002"
git init -q "$W/c-050"
GIT_COMMITTER_DATE="2026-10-03T11:50:00Z" git -C "$W/c-050" -c user.name=FirstName\ LastName \
  -c user.email=dev@example.com commit -q --allow-empty -m one
mkdir -p "$SPOOL_ROOT/c-050/outbox" && echo '{}' >"$SPOOL_ROOT/c-050/outbox/m.json"
touch -d '2026-10-03 11:40:00Z' "$SPOOL_ROOT/c-050/outbox/m.json"
printf '%s\t%s\t%s\t%s\t%s\n' \
  c-050 claude %1 "$W/c-050" 20261003T100000Z \
  c-051 claude %2 "$W/c-051" 20261003T090000Z \
  c-051 claude %2 "$W/c-051" 20261003T110000Z \
  c-052 claude %3 "$W/c-052" 20261003T114500Z \
  c-053 claude %4 "$W/gone" 20261003T080000Z \
  c-002 claude %5 "$W/c-002" 20261003T010000Z \
  >"$SPOOL_ROOT/registry.tsv"
before="$(cd "$T_TMP" && find . -type f -newer "$R" | sort | md5sum)"

out="$(LANE_AGE_NOW="$now" bash "$R" 2>&1)"; rc=$?
eq "exits 0" 0 "$rc"
eq "the old lanes, oldest first, push and msg ages" "c-050 120 10 20
c-051 60 - -" "$out"
hasnt "a role seat is left out" "c-002" "$out"
hasnt "a lane under 30 min is left out" "c-052" "$out"
hasnt "a torn-down worktree is left out" "c-053" "$out"
eq "the threshold is settable" "c-050 120 10 20" "$(LANE_AGE_NOW="$now" LANE_AGE_MIN=90 bash "$R" 2>&1)"
eq "a bad threshold is refused" 64 "$(LANE_AGE_MIN=x bash "$R" >/dev/null 2>&1; echo $?)"
eq "it changed nothing" "$before" "$(cd "$T_TMP" && find . -type f -newer "$R" | sort | md5sum)"
t_done
