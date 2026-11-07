#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: workflow 26 (SPL-4961) fills the release notes on EVERY master push,
#          dev and prd, without a deploy and without a new secret.
#   1. the trigger: push to master with no path filter
#   2. it deploys nothing: its one ./run action is do_release_note_ingest, and
#      no line starts a hub or WUI deploy
#   3. the secrets are the two project keys that exist already
#   4. dev and prd run apart: fail-fast off, one concurrency group per env,
#      a running ingest is never cancelled
#   5. the whole history and the tags are checked out (a version is read from
#      the v-tags that contain the commit); only master's commits go in
#   6. the ingest step's REAL script, read out of the workflow with yq and run
#      against a stub ./run: DRY_RUN=0, RELEASE_SHA = the pushed commit
#   7. a run that never started loses nothing: the next one's window carries
#      the commits of the runs before it
#   8. a failed ingest leaves the run green, as in 20 and 30: a red run holds the
#      close of the lane that pushed (accepted-close rc 7, nothing supersedes it)
# Every shape check has its RED control: the same check on a planted copy.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
wf="$APP_ROOT/.github/workflows/26_release-notes-ingest.yml"
command -v yq >/dev/null || { echo "SKIP: no yq"; exit 0; }
[[ -f "$wf" ]] || { fail "no workflow at $wf"; exit 1; }

# wf_findings <file> -> one line per broken rule, nothing when all hold
wf_findings() {
  local f="$1" j='.jobs.ingest'
  [[ "$(yq -r '.on.push.branches[]' "$f" | paste -sd' ')" == master ]] || echo "trigger: not push to master"
  [[ "$(yq -r '.on.push.paths // "" | length' "$f")" == 0 ]] || echo "trigger: a paths filter"
  [[ "$(yq -r '.on.push["paths-ignore"] // "" | length' "$f")" == 0 ]] || echo "trigger: a paths-ignore filter"
  [[ "$(grep -oE 'run -a [a-z_]+' "$f" | sort -u)" == "run -a do_release_note_ingest" ]] || echo "action: not only do_release_note_ingest"
  grep -qE '^[^#]*(do_deploy|do_build_push|firebase|gcloud run|_hub-build-deploy|_wui-build-deploy)' "$f" && echo "deploy: a deploy line"
  [[ "$(grep -oE "secrets(\.[A-Z_]+|\[format\('[A-Z_{}0-9]+')" "$f" | sort -u)" == "secrets[format('GCP_KEY_CSI_SPL_{0}'" ]] || echo "secret: not only the project keys"
  [[ "$(yq -r "$j.strategy.matrix.environment[]" "$f" | paste -sd' ')" == "dev prd" ]] || echo "matrix: not dev prd"
  [[ "$(yq -r "$j.strategy[\"fail-fast\"]" "$f")" == false ]] || echo "fail-fast: not off"
  [[ "$(yq -r "$j.concurrency.group" "$f")" == *'matrix.environment'* ]] || echo "concurrency: not per env"
  [[ "$(yq -r "$j.concurrency[\"cancel-in-progress\"]" "$f")" == false ]] || echo "concurrency: cancels a running ingest"
  [[ "$(yq -r "$j.steps[] | select(.uses // \"\" | test(\"actions/checkout\")) | .with[\"fetch-depth\"]" "$f")" == 0 ]] || echo "checkout: not the whole history"
  [[ "$(yq -r "$j.if" "$f")" == *"github.ref == 'refs/heads/master'"* ]] || echo "guard: another branch could ingest"
  [[ "$(yq -r "$j.steps[] | select(.name == \"Ingest the release notes (do_release_note_ingest)\") | .[\"continue-on-error\"]" "$f")" == true ]] || echo "ingest: a failure reds the run"
}

out=$(wf_findings "$wf")
[[ -z "$out" ]] && pass "workflow 26 holds every rule" || fail "workflow 26: $out"

# --- RED controls: each planted defect is named ------------------------------
ctl() { # <what> <expected finding> <sed expression>
  local found
  sed -E "$3" "$wf" >"$T/planted.yml"
  cmp -s "$wf" "$T/planted.yml" && { fail "CONTROL $1: the plant changed nothing"; return; }
  found=$(wf_findings "$T/planted.yml")
  if [[ "$found" == *"$2"* ]]; then pass "CONTROL $1 -> '$2'"; else fail "CONTROL $1: not caught: $found"; fi
}
ctl "a paths filter"       "trigger: a paths filter"           "s|^    branches: \[master\]|    branches: [master]\n    paths: ['csi-spl-api/**']|"
ctl "another branch"       "trigger: not push to master"       "s|^    branches: \[master\]|    branches: [master, main]|"
ctl "a second action"      "action: not only"                  "s|^(        run: )DRY_RUN=0.*|\1./run -a do_deploy_hub|"
ctl "a deploy line"        "deploy: a deploy line"             "s|^(        run: rm -rf.*)|\1; gcloud run deploy x|"
ctl "a new secret"         "secret: not only"                  "s|^(      ENV: .*)|\1\n      X: \${{ secrets.NEW_TOKEN }}|"
ctl "prd alone"            "matrix: not dev prd"               "s|environment: \[dev, prd\]|environment: [prd]|"
ctl "fail-fast on"         "fail-fast: not off"                "s|fail-fast: false|fail-fast: true|"
ctl "one group for both"   "concurrency: not per env"          "s|group: release-notes-ingest-.*|group: release-notes-ingest|"
ctl "cancel in progress"   "concurrency: cancels"              "s|cancel-in-progress: false|cancel-in-progress: true|"
ctl "a shallow checkout"   "checkout: not the whole history"   "s|fetch-depth: 0|fetch-depth: 1|"
ctl "any branch dispatch"  "guard: another branch"             "s/ && github.ref == 'refs\/heads\/master'//"
ctl "a failure reds"       "ingest: a failure reds the run"    "/^        continue-on-error: true$/d"

# --- 6. the ingest step's real script ----------------------------------------
yq -r '.jobs.ingest.steps[] | select(.name == "Ingest the release notes (do_release_note_ingest)") | .run' "$wf" >"$T/step.sh"
[[ -s "$T/step.sh" ]] || { fail "no ingest step in $wf"; exit 1; }
mkdir -p "$T/w"
cat >"$T/w/run" <<'SH'
#!/bin/sh
echo "DRY_RUN=$DRY_RUN RELEASE_SHA=$RELEASE_SHA $*"
SH
chmod +x "$T/w/run"
got=$(cd "$T/w" && env GITHUB_SHA=0123456789abcdef bash "$T/step.sh")
[[ "$got" == "DRY_RUN=0 RELEASE_SHA=0123456789abcdef -a do_release_note_ingest" ]] &&
  pass "the step sends for real, from the pushed commit" || fail "step: '$got'"

# --- 7. a run that never started loses nothing --------------------------------
REPO="$T/repo"
git init -q -b master "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name "FirstName LastName"
commit() { echo "$1" >>"$REPO/f.md"; git -C "$REPO" add f.md && git -C "$REPO" commit -qm "docs: $1" && git -C "$REPO" rev-parse HEAD; }
A=$(commit one); B=$(commit two); C=$(commit three)
rows() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$REPO" RELEASE_REMOTE=no-such-remote ENV=dev "$@" bash -c '
    set -uo pipefail
    do_log() { :; }
    do_require_bin() { :; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_release_note_ingest' 2>/dev/null
}
# the runs for A and B were replaced while pending; only C's run starts
out=$(rows RELEASE_SHA="$C")
[[ "$(jq -r '.notes[].sha' <<<"$out" | paste -sd' ')" == "$C $B $A" ]] &&
  pass "only the newest run starts -> its window carries the two runs it replaced" || fail "window: '$out'"
[[ "$(jq -r '[.notes[] | has("version")] | any' <<<"$out")" == false ]] &&
  pass "commits no tag contains yet go in without a version" || fail "version on an untagged row: $out"
# a later ingest brings the version; the row is the same sha
git -C "$REPO" tag v1.0.1 "$C"
out=$(rows RELEASE_SHA="$C")
[[ "$(jq -r '.notes[].version' <<<"$out" | sort -u)" == v1.0.1 ]] &&
  pass "once a tag contains them, the next ingest carries the version" || fail "gain: '$out'"
# CONTROL: a window of 1 is what WOULD lose a commit
out=$(rows RELEASE_SHA="$C" RELEASE_NOTE_DEPTH=1)
[[ "$(jq -r '.notes[].sha' <<<"$out" | paste -sd' ')" == "$C" ]] &&
  pass "CONTROL: a window of 1 drops the replaced runs' commits" || fail "control window: '$out'"
dflt=$(sed -n 's/.*depth="\${RELEASE_NOTE_DEPTH:-\([0-9]*\)}".*/\1/p' "$PROJ_ROOT/src/bash/run/release-note-ingest.func.sh")
[[ "$dflt" == 500 ]] && pass "the action's default window is 500" || fail "default window: '$dflt'"

echo "release-notes-ingest-wf26: $fails failure(s)"
((fails == 0))
