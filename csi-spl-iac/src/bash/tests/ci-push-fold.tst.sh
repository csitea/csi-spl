#!/usr/bin/env bash
#------------------------------------------------------------------------------
# CI volume A6 (SPL-6385, spec 016 ci-volume-2026-11-24.md section 3): the small
# per-push workflows are folded into ONE push workflow.
#
# Before: 15 (deps + secrets), 25 (commit links), 26 (release notes ingest) and
# 64 (trufflehog) each started a run on every push to master: four runs per
# push. After: 16_push-checks.yml is the only one of the five on push; it calls
# the other four as reusable workflows (workflow_call), so each keeps its own
# steps, if:, permissions and concurrency, and the steps live in one file.
#
# Asserted:
#   1. exactly one of the five starts on push, 16, on master, no path filter
#      (a secret can land in any file)
#   2. 16 has exactly the four jobs, each calling one of the four files; 25 and
#      26 get exactly the keys they read (never every secret), 15 and 64 none;
#      15 gets actions: read for its scope step
#      and the name of the run list its "last green run" base is read from
#   3. each called file has workflow_call; 15 keeps its nightly and its
#      push_scope dispatch; 25, 26 and 64 keep their dispatch
#   4. the concurrency sits on the JOB in the called files (a job-level group
#      holds when called; 15 and 64 still cancel a superseded scan, 25 and 26
#      never cancel), and no workflow-level concurrency is left that could
#      cancel the whole caller run
#   5. gitleaks and trufflehog run on every push: their scan steps carry no if:
# RED controls: each planted defect is named by the same check.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
WF="$APP_ROOT/.github/workflows"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
command -v yq >/dev/null || { echo "FAIL: yq is required"; exit 1; }

FOLD=16_push-checks.yml
CALLED="15_sec-deps-secrets.yml 25_commit-links.yml 26_release-notes-ingest.yml 64_trufflehog.yml"
S15='./.github/workflows/15_sec-deps-secrets.yml'

# called_findings <dir> -> the rules on the four called files
called_findings() {
  local d="$1" f
  for f in $CALLED; do
    [[ -f "$d/$f" ]] || continue
    [[ "$(yq '.on | has("workflow_call")' "$d/$f")" == true ]] || echo "call: $f has no workflow_call"
    [[ "$(yq '.on | has("workflow_dispatch")' "$d/$f")" == true ]] || echo "dispatch: $f lost its workflow_dispatch"
    [[ "$(yq '.concurrency // "" | length' "$d/$f")" == 0 ]] || echo "concurrency: $f has a workflow-level group"
  done
  f="$d/15_sec-deps-secrets.yml"
  [[ "$(yq '.on.schedule[0].cron' "$f")" == '17 3 * * *' ]] || echo "nightly: 15 lost its schedule"
  [[ "$(yq '.on.workflow_dispatch.inputs | has("push_scope")' "$f")" == true ]] || echo "dispatch: 15 lost push_scope"
  [[ "$(yq '.jobs."sec-scan".concurrency."cancel-in-progress"' "$f")" == true ]] || echo "concurrency: 15 no longer cancels a superseded scan"
  [[ "$(yq -r '.jobs."sec-scan".concurrency.group' "$f")" == 'sec-scan-${{ github.ref }}' ]] || echo "concurrency: 15's group changed"
  [[ "$(yq '.jobs."sec-scan".steps[] | select(.name == "gitleaks (full history)") | has("if")' "$f")" == false ]] || echo "gitleaks: gated"
  f="$d/64_trufflehog.yml"
  [[ "$(yq '.jobs.trufflehog.concurrency."cancel-in-progress"' "$f")" == true ]] || echo "concurrency: 64 no longer cancels a superseded scan"
  [[ "$(yq -r '.jobs.trufflehog.concurrency.group' "$f")" == 'sec-trufflehog-${{ github.ref }}' ]] || echo "concurrency: 64's group changed"
  [[ "$(yq '.jobs.trufflehog.steps[] | select(.name == "trufflehog (control + verified scan)") | has("if")' "$f")" == false ]] || echo "trufflehog: gated"
  f="$d/25_commit-links.yml"
  [[ "$(yq '.jobs.check.concurrency."cancel-in-progress"' "$f")" == false ]] || echo "concurrency: 25 may cancel a check"
  [[ "$(yq -r '.jobs.check.concurrency.group' "$f")" == 'commit-links-${{ github.sha }}' ]] || echo "concurrency: 25's group changed"
  f="$d/26_release-notes-ingest.yml"
  [[ "$(yq '.jobs.ingest.concurrency."cancel-in-progress"' "$f")" == false ]] || echo "concurrency: 26 may cancel an ingest"
}

# fold_findings <dir> -> one line per broken rule, nothing when all hold
fold_findings() {
  local d="$1" f n on="" c
  for f in $FOLD $CALLED; do
    [[ -f "$d/$f" ]] || { echo "missing: $f"; continue; }
    [[ "$(yq '.on | has("push")' "$d/$f")" == true ]] && on="$on $f"
  done
  [[ "${on# }" == "$FOLD" ]] || echo "push: the workflows on push are '${on# }', want '$FOLD' alone"
  called_findings "$d"
  f="$d/$FOLD"; [[ -f "$f" ]] || return 0
  [[ "$(yq -r '.on.push.branches[]' "$f" | paste -sd' ')" == master ]] || echo "push: 16 is not on master alone"
  [[ "$(yq '.on.push | has("paths") or has("paths-ignore")' "$f")" == false ]] || echo "push: 16 has a path filter"
  [[ "$(yq '.concurrency // "" | length' "$f")" == 0 ]] || echo "concurrency: 16 has a workflow-level group"
  n=$(yq -r '.jobs[].uses' "$f" | sort | paste -sd' ')
  [[ "$n" == "$(for c in $CALLED; do echo "./.github/workflows/$c"; done | sort | paste -sd' ')" ]] ||
    echo "jobs: 16 calls '$n', want the four"
  # each call passes exactly the keys its file reads, never every secret
  local want
  for c in 25_commit-links.yml 26_release-notes-ingest.yml 64_trufflehog.yml 15_sec-deps-secrets.yml; do
    case "$c" in
      25_*) want=GCP_KEY_CSI_SPL_PRD ;;
      26_*) want="GCP_KEY_CSI_SPL_DEV GCP_KEY_CSI_SPL_PRD" ;;
      *) want="" ;;
    esac
    [[ "$(yq -r ".jobs[] | select(.uses == \"./.github/workflows/$c\") | .secrets // {} | (select(tag == \"!!map\") | keys | .[]), select(tag == \"!!str\")" "$f" | sort | paste -sd' ')" == "$want" ]] ||
      echo "secrets: the $c call does not pass exactly '$want'"
    [[ -z "$want" || "$(yq -r ".on.workflow_call.secrets // {} | keys | .[]" "$d/$c" | sort | paste -sd' ')" == "$want" ]] ||
      echo "secrets: $c does not declare '$want' for workflow_call"
  done
  [[ "$(yq -r ".jobs[] | select(.uses == \"$S15\") | .permissions.actions" "$f")" == read ]] ||
    echo "permissions: the 15 call lacks actions: read (its scope step lists runs)"
  [[ "$(yq -r ".jobs[] | select(.uses == \"$S15\") | .with.runs_of" "$f")" == "$FOLD" ]] ||
    echo "scope: the 15 call does not read its base from the runs of $FOLD"
}

out=$(fold_findings "$WF")
[[ -z "$out" ]] && pass "one push workflow ($FOLD) carries 15, 25, 26 and 64" || fail "fold: $out"

# --- RED controls: each planted defect is named ------------------------------
ctl() { # <what> <expected finding> <file> <yq expression>
  local found
  rm -rf "$T/wf"; cp -r "$WF" "$T/wf"
  yq -i "$4" "$T/wf/$3" || { fail "CONTROL $1: the plant did not apply"; return; }
  cmp -s "$WF/$3" "$T/wf/$3" && { fail "CONTROL $1: the plant changed nothing"; return; }
  found=$(fold_findings "$T/wf")
  if [[ "$found" == *"$2"* ]]; then pass "CONTROL $1 -> '$2'"; else fail "CONTROL $1: not caught: $found"; fi
}
if [[ -f "$WF/$FOLD" ]]; then
  ctl "25 back on push"    "push: the workflows on push are" 25_commit-links.yml     '.on.push.branches = ["master"]'
  ctl "15 back on push"    "push: the workflows on push are" 15_sec-deps-secrets.yml '.on.push.branches = ["master"]'
  ctl "16 off push"        "push: the workflows on push are" $FOLD                   'del(.on.push)'
  ctl "16 path filter"     "push: 16 has a path filter"      $FOLD                   '.on.push.paths = ["csi-spl-api/**"]'
  ctl "a job dropped"      "jobs: 16 calls"                  $FOLD                   'del(.jobs.trufflehog)'
  ctl "26 without secrets" "secrets: the 26_release"         $FOLD                   'del(.jobs."release-notes".secrets)'
  ctl "every secret to 25" "secrets: the 25_commit"          $FOLD                   '.jobs."commit-links".secrets = "inherit"'
  ctl "64 given a key"     "secrets: the 64_trufflehog"      $FOLD                   '.jobs.trufflehog.secrets.GCP_KEY_CSI_SPL_PRD = "x"'
  ctl "15 call no actions" "permissions: the 15 call"        $FOLD                   'del(.jobs."sec-scan".permissions.actions)'
  ctl "15 base from wf 15" "scope: the 15 call"              $FOLD                   'del(.jobs."sec-scan".with)'
  ctl "16 run-level group" "concurrency: 16 has"             $FOLD                   '.concurrency.group = "x"'
  ctl "64 not callable"    "call: 64_trufflehog.yml has no"  64_trufflehog.yml       'del(.on.workflow_call)'
  ctl "25 lost dispatch"   "dispatch: 25_commit-links.yml"   25_commit-links.yml     'del(.on.workflow_dispatch)'
  ctl "15 nightly gone"    "nightly: 15 lost"                15_sec-deps-secrets.yml 'del(.on.schedule)'
  ctl "15 run-level group" "concurrency: 15_sec-deps"        15_sec-deps-secrets.yml '.concurrency.group = "x"'
  ctl "64 never cancels"   "concurrency: 64 no longer"       64_trufflehog.yml       '.jobs.trufflehog.concurrency."cancel-in-progress" = false'
  ctl "25 cancels"         "concurrency: 25 may cancel"      25_commit-links.yml     '.jobs.check.concurrency."cancel-in-progress" = true'
  ctl "gitleaks gated"     "gitleaks: gated"                 15_sec-deps-secrets.yml '(.jobs."sec-scan".steps[] | select(.name == "gitleaks (full history)") | .if) = "false"'
  ctl "trufflehog gated"   "trufflehog: gated"               64_trufflehog.yml       '(.jobs.trufflehog.steps[] | select(.name == "trufflehog (control + verified scan)") | .if) = "false"'
fi

echo "---"; (( fails == 0 )) && echo "PASS: all ci-push-fold.tst.sh assertions" || { echo "ci-push-fold: $fails failed"; exit 1; }
