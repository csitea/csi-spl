#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the 10 ci distribution-hygiene sweep "retired relay estate
#          (SPL-1910)" keeps the retired relay estate, its client's repo and
#          the box it ran on out of the tree (owner order 2026-10-14: "remove
#          all of the traces for this code from the spool-hub").
#          Runs the workflow's OWN "Sweep" step (extracted with yq), not a copy:
#   1. the real tree (a git-ls-files export) passes the sweep, rc 0
#   2. CONTROL: each banned form planted in a one-file tree fails the sweep
#      under this label: the relay's name (three spellings), its client's
#      repo, the bucket key (two spellings), the retired bucket prefix
#      (SPL-2361) and the box name, any case
#   3. CONTROL: words that only contain the box name's letters (near,
#      linear, kneaded, the Spanish línea) do not trip it
#   The banned words are built from parts at run time, so this file carries
#   none of them and the sweep never has to exclude it.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
LABEL='retired relay estate (SPL-1910)'

fails=0

command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }
git -C "$APP_ROOT" rev-parse --git-dir >/dev/null 2>&1 || { echo "FAIL: not a git checkout (the sweep runs over git ls-files)"; exit 1; }

yq -r '.jobs."distribution-hygiene".steps[] | select(.name == "Sweep") | .run' "$WF" >"$T/sweep.sh"
[[ -s "$T/sweep.sh" ]] && grep -qF "sweep \"$LABEL\"" "$T/sweep.sh" \
  && pass "extracted the workflow's Sweep step, with the $LABEL sweep" || fail "no Sweep step / no $LABEL sweep in $WF"

sweep() { (cd "$1" && bash "$T/sweep.sh" 2>&1); }

# --- 1. the real tree ---------------------------------------------------------
mkdir -p "$T/real"
git -C "$APP_ROOT" ls-files -z | (cd "$APP_ROOT" && tar --null -T - -cf - 2>/dev/null) | tar -xf - -C "$T/real" \
  && pass "exported the tracked tree" || { fail "SETUP: the tree export failed (disk full? TMPDIR=${TMPDIR:-/tmp})"; exit 1; }
out=$(sweep "$T/real"); rc=$?
grep -qxF "ok - $LABEL" <<<"$out" && pass "the real tree is clean under the $LABEL sweep" \
  || { fail "the real tree trips the $LABEL sweep"; grep -A20 -F "::error::hygiene: $LABEL" <<<"$out" | sed 's/^/    | /'; }
[[ $rc -eq 0 ]] && pass "the real tree passes the whole sweep (rc 0)" || fail "the real tree fails the sweep (rc=$rc)"
rm -rf "$T/real"

# --- 2. CONTROL: every banned form fails --------------------------------------
r='rel' n='ne''a' b='bu''cket' c='bn''c-cpt'
plant() { # <id> <text>: a one-file tree holding the text
  mkdir -p "$T/p-$1" && printf 'line one\nsee %s here\n' "$2" >"$T/p-$1/notes.md"
}
for form in "git-$r" "git_$r" "GIT${r^^}" "$n-nfs/x" "relay-$b" "relay_$b" "${c}-all-x" "on box ${n^^} today"; do
  id=$(tr -c 'a-zA-Z0-9' _ <<<"$form")
  plant "$id" "$form" || { fail "CONTROL SETUP: the plant '$id' did not land"; continue; }
  out=$(sweep "$T/p-$id"); rc=$?
  if [[ $rc -ne 0 ]] && grep -qF "::error::hygiene: $LABEL -- 1 line(s)" <<<"$out" && grep -q '^  \./notes\.md:2$' <<<"$out"; then
    pass "CONTROL planted '$id' -> sweep fails at ./notes.md:2"
  else
    fail "CONTROL planted '$id' -> sweep did NOT fail under $LABEL (rc=$rc)"
    echo "$out" | sed 's/^/    | /'
  fi
done

# --- 3. CONTROL: look-alikes stay clean ----------------------------------------
plant lookalike "near the linear, kneaded ${n}r line, una lí${n} nueva" || fail "CONTROL SETUP: the look-alike plant did not land"
out=$(sweep "$T/p-lookalike"); rc=$?
grep -qxF "ok - $LABEL" <<<"$out" && pass "CONTROL look-alike words do not trip the $LABEL sweep" \
  || { fail "CONTROL look-alike words trip the $LABEL sweep"; echo "$out" | sed 's/^/    | /'; }

(( fails == 0 )) && echo "PASS: all $(basename "$0") assertions" || { echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1; }
