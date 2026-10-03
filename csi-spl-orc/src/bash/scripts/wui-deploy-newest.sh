#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: latest-sha catch-up for the WUI deploy (workflow 30).
#
# Choice, measured 2026-10-03: keep the deploy job's concurrency at
# cancel-in-progress false, so a firebase deploy is never killed once it
# holds the group. GitHub still drops the PENDING deploy when a newer push
# wants that group ("Canceling since a higher priority waiting request",
# hub job 111061298741 on run 37074024656). The quality gate may drop
# superseded runs; a deploy may not. This script is the catch-up, called
# from a job outside that group (if: always()). It dispatches workflow 30
# at trunk head with environment=all when this run did not ship the head
# and no other run is already deploying it. A failed deploy of the head
# is left alone (broken, not starved). Workflow 21 remains the slow
# backstop for a push that never started a run.
#
# Usage: wui-deploy-newest.sh
# Env (all required):
#   SHA            this run's commit, 40 hex
#   TIP            trunk head, 40 hex
#   RUN_ID         this run's id; excluded from the in-flight count
#   DEPLOY_RESULT  success | failure | cancelled | skipped
#   REPO           owner/name
#   APP_PATH       repo root for the path diff
# Prints one line, "dispatch" or "skip <why>", and exits 0.
# Exit 2 on bad input. A gh or git failure skips and exits 0: a catch-up
# must not turn a deploy that already succeeded into a red run.
#------------------------------------------------------------------------------
set -euo pipefail

sha="${SHA:-}"
tip="${TIP:-}"
run_id="${RUN_ID:-}"
result="${DEPLOY_RESULT:-}"
repo="${REPO:-}"
app="${APP_PATH:-}"

hex='^[0-9a-f]{40}$'
[[ "$sha" =~ $hex && "$tip" =~ $hex ]] || { echo "::error::SHA and TIP must be 40 hex" >&2; exit 2; }
[[ "$run_id" =~ ^[0-9]+$ ]] || { echo "::error::RUN_ID must be digits" >&2; exit 2; }
case "$result" in
  success|failure|cancelled|skipped) ;;
  *) echo "::error::DEPLOY_RESULT '$result' is not success|failure|cancelled|skipped" >&2; exit 2 ;;
esac
[[ "$repo" == */* ]] || { echo "::error::REPO must be owner/name" >&2; exit 2; }
[[ -d "$app/.git" || -f "$app/.git" ]] || { echo "::error::APP_PATH is not a git repo" >&2; exit 2; }

say() { printf '%s\n' "$1"; }

# The head's own failure is a broken deploy. Retrying it every run only
# burns runners; 21 reports it and does not re-dispatch either.
if [[ "$sha" == "$tip" && "$result" == failure ]]; then
  say "skip broken"; exit 0
fi
# This run is the head and it shipped, or there was nothing to ship.
if [[ "$sha" == "$tip" && ( "$result" == success || "$result" == skipped ) ]]; then
  say "skip this-run-$result"; exit 0
fi

# 1 when TIP differs from SHA on a path workflow 30 deploys. 0 when it does
# not. A git error skips: the catch-up must not fail the caller.
ahead=""
if [[ "$sha" == "$tip" ]]; then
  ahead=0
else
  set +e
  git -C "$app" diff --quiet "$sha" "$tip" -- \
    csi-spl-wui \
    'csi-spl-cnf/csi-spl/*.env.json' \
    csi-spl-orc/src/bash/scripts/render-wui-firebase-json.sh \
    csi-spl-orc/src/bash/scripts/wait-for-hub-version.sh \
    csi-spl-orc/src/bash/scripts/wui-deploy-newest.sh \
    .github/workflows/30_wui-build-deploy.yml
  grc=$?
  set -e
  if [[ "$grc" -eq 0 ]]; then
    ahead=0
  elif [[ "$grc" -eq 1 ]]; then
    ahead=1
  else
    echo "::warning::git diff failed ($grc); not dispatching" >&2
    say "skip git-diff"; exit 0
  fi
fi

list="$(gh run list --workflow=30_wui-build-deploy.yml --repo "$repo" --branch master --limit 40 \
  --json databaseId,status,conclusion,headSha 2>/dev/null)" || {
  echo "::warning::gh run list failed; not dispatching" >&2
  say "skip gh-list"; exit 0
}

decision="$(python3 -c '
import json, sys
raw, run_id, tip, result, ahead = sys.argv[1:]
try:
    rows = json.loads(raw)
except json.JSONDecodeError:
    print("skip parse"); raise SystemExit
if not isinstance(rows, list):
    print("skip parse"); raise SystemExit
try:
    me = int(run_id)
except ValueError:
    print("skip parse"); raise SystemExit
others = [r for r in rows if int(r.get("databaseId") or 0) != me]
if any(r.get("status") != "completed" for r in others):
    print("skip inflight"); raise SystemExit
at_tip = [r for r in others if (r.get("headSha") or "") == tip and r.get("status") == "completed"]
finished = [r for r in at_tip if r.get("conclusion") in ("success", "failure", "timed_out")]
if finished and finished[0].get("conclusion") == "success":
    print("skip already-succeeded"); raise SystemExit
if finished and finished[0].get("conclusion") in ("failure", "timed_out"):
    print("skip broken"); raise SystemExit
if result == "cancelled" or ahead == "1":
    print("dispatch"); raise SystemExit
print("skip no-wui-input")
' "$list" "$run_id" "$tip" "$result" "$ahead" 2>/dev/null)" || {
  echo "::warning::could not read the run list; not dispatching" >&2
  say "skip parse"; exit 0
}

if [[ "$decision" != "dispatch" ]]; then
  say "$decision"; exit 0
fi

if gh workflow run 30_wui-build-deploy.yml --repo "$repo" --ref master -f environment=all >/dev/null; then
  say "dispatch"
else
  echo "::warning::gh workflow run failed; not failing the caller" >&2
  say "skip gh-run"
fi
exit 0
