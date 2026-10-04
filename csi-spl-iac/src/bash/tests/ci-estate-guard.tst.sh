#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Fork portability, estate guard (spec 072 A34, research 12 C2/C4): a workflow
# that reads or changes OUR live estate (probes our hosts, tags from our prd,
# dispatches our deploys, backs up our DB, DAST-scans our dev) runs only on an
# estate repo. Every root job of those workflows carries the guard
#   if: vars.SPOOL_ESTATE == 'true' || github.repository == '<origin repo>'
# so a fork with no variables shows them as skipped, not run. The origin-repo
# fallback keeps this repo running until the A13 action sets SPOOL_ESTATE here.
#
# What it asserts:
#   1. each live-estate workflow: every job with no needs:, and every job whose
#      if: uses always()/cancelled()/failure() (those run past a skipped
#      parent), carries the guard;
#   2. every workflow with a cron: or workflow_run: trigger, or one that reads
#      our cnf hosts, is either live-estate or exempt with a reason below; a new
#      unclassified one is red;
#   3. wf 20's call of wf 22 also needs needs.deploy.result == 'success' (a
#      skipped deploy smokes nothing) and the guard.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
WF_DIR="${WF_DIR:-$APP_ROOT/.github/workflows}"

fails=0
GUARD="vars.SPOOL_ESTATE == 'true'"

# The live-estate workflows (spec 072 F23).
ESTATE="00 21 22 31 40 45 55 68"
# Scheduled or cnf-reading, yet touch no live host; the reason is the review.
declare -A EXEMPT=(
  [10]="CI suites: reads cnf as test input, probes no host"
  [15]="dependency + secret scan of the tree, no host"
  [20]="hub deploy: skips without the WIF variables; its call of 22 is asserted below"
  [30]="WUI deploy: skips without the WIF variables"
  [56]="GHCR image publish: builds the tree, pushes to the repo owner's own registry, no host"
  [60]="CodeQL scan of the tree, no host"
)

# Print "file: job" for every job that must carry the guard and does not.
unguarded_jobs() {
  awk -v guard="$GUARD" '
    function flush() {
      if (cur != "" && (!has_needs || status_fn) && index(cond, guard) == 0) print FILENAME ": " cur
    }
    /^jobs:[[:space:]]*$/ { injobs=1; next }
    injobs && /^[a-zA-Z]/ { injobs=0 }
    injobs && match($0, /^  [a-zA-Z0-9_-]+:[[:space:]]*$/) {
      flush(); cur=$0; sub(/:.*/,"",cur); gsub(/ /,"",cur); has_needs=0; status_fn=0; cond=""
    }
    injobs && /^    needs:/ { has_needs=1 }
    injobs && /^    if:/ {
      cond=$0
      if (cond ~ /always\(\)|cancelled\(\)|failure\(\)/) status_fn=1
    }
    END { flush() }
  ' "$1"
}

# Is this workflow scheduled, run by another workflow, or a reader of our cnf?
needs_classifying() {
  grep -qE '^[[:space:]]*-?[[:space:]]*cron:|^[[:space:]]+workflow_run:|csi-spl-cnf/|BASE_DOMAIN' "$1"
}

# first_match <glob results...> - the first existing path, or nothing.
first_match() { [[ -e "$1" ]] && printf '%s\n' "$1"; }

[[ -d "$WF_DIR" ]] || { fail "no workflows dir at $WF_DIR"; exit 1; }

# --- controls -----------------------------------------------------------------
CTL=$(mktemp -d)
printf 'on:\n  schedule:\n    - cron: "1 * * * *"\njobs:\n  a:\n    runs-on: ubuntu-latest\n' >"$CTL/u.yml"
[[ -n "$(unguarded_jobs "$CTL/u.yml")" ]] \
  && pass "CONTROL: a root job with no guard is detected" \
  || fail "CONTROL: the checker missed an unguarded root job"
printf "jobs:\n  a:\n    if: %s\n  b:\n    needs: a\n    if: always()\n" "$GUARD" >"$CTL/a.yml"
[[ "$(unguarded_jobs "$CTL/a.yml")" == *": b" ]] \
  && pass "CONTROL: an always() child with no guard is detected" \
  || fail "CONTROL: the checker missed an always() child"
printf "jobs:\n  a:\n    if: %s || github.repository == 'x/y'\n  b:\n    needs: a\n" "$GUARD" >"$CTL/g.yml"
[[ -z "$(unguarded_jobs "$CTL/g.yml")" ]] \
  && pass "CONTROL: a guarded root job and its plain child pass" \
  || fail "CONTROL: a guarded workflow was wrongly flagged"
needs_classifying "$CTL/u.yml" \
  && pass "CONTROL: a cron workflow needs classifying" \
  || fail "CONTROL: a cron workflow was not seen"
rm -rf "$CTL"

# --- 1. every live-estate workflow is guarded ---------------------------------
for id in $ESTATE; do
  f=$(first_match "$WF_DIR/${id}_"*.yml)
  [[ -n "$f" ]] || { fail "live-estate workflow $id not found"; continue; }
  miss=$(unguarded_jobs "$f")
  if [[ -z "$miss" ]]; then
    pass "$(basename "$f"): every root job carries the estate guard"
  else
    fail "$(basename "$f"): job(s) with no estate guard ($GUARD):"
    sed 's/^/      /' <<<"$miss"
  fi
done

# --- 2. no scheduled or cnf-reading workflow is unclassified ------------------
n=0
for f in "$WF_DIR"/*.yml; do
  b=$(basename "$f"); id=${b%%_*}; n=$((n + 1))
  needs_classifying "$f" || continue
  if [[ " $ESTATE " == *" $id "* ]]; then
    :
  elif [[ -n "${EXEMPT[$id]:-}" ]]; then
    pass "$b: exempt (${EXEMPT[$id]})"
  else
    fail "$b: scheduled, workflow_run or cnf-reading but neither guarded (ESTATE) nor EXEMPT with a reason"
  fi
done
[[ "$n" -gt 0 ]] && pass "classified $n workflow file(s)" || fail "no workflow files found"

# --- 3. wf 20 calls wf 22 only after a successful deploy, on the estate -------
f20=$(first_match "$WF_DIR"/20_*.yml)
if [[ -n "$f20" ]]; then
  cond=$(awk '/^  [a-zA-Z0-9_-]+:/{c=""} /^    if:/{c=$0} /^    uses: .*22_deploy-verify/{print c}' "$f20")
  [[ "$cond" == *"needs.deploy.result == 'success'"* ]] \
    && pass "wf 20 calls 22 only after a successful deploy" \
    || fail "wf 20's call of 22 lacks needs.deploy.result == 'success' (a skipped deploy still smokes)"
  [[ "$cond" == *"$GUARD"* ]] \
    && pass "wf 20's call of 22 carries the estate guard" \
    || fail "wf 20's call of 22 lacks the estate guard ($GUARD)"
else
  fail "wf 20 not found"
fi

[[ "$fails" -eq 0 ]] && echo "PASS: all ci-estate-guard.tst.sh assertions"
exit "$fails"
