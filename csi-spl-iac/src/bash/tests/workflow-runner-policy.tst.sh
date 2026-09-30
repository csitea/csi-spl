#!/usr/bin/env bash
#------------------------------------------------------------------------------
# CI load policy (owner escalation 2026-09-30, topic 23d4e8d8): the security
# SCANNERS run on GitHub-hosted runners (ubuntu-latest) -- the repo is public
# and they need no box state -- so they stay off the 4 self-hosted runners that
# DEPLOYS need, and they use cancel-in-progress so a busy trunk keeps only the
# newest sha's scan. DEPLOYS (20/30) must NEVER cancel-in-progress mid-run.
# This fails if a scanner drifts back to self-hosted, loses cancel-in-progress,
# or a deploy becomes cancellable.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
WF_DIR="$APP_ROOT/.github/workflows"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }

# Stateless scanners -> ubuntu-latest + cancel-in-progress: true.
SCANNERS="15_sec-deps-secrets 60_codeql 61_semgrep 62_gosec 63_eslint-security 64_trufflehog 65_iac-checkov 66_hadolint 67_shellcheck 68_dast 70_supply-chain 85_actionlint"
# Deploys -> never cancel a run mid-deploy.
NEVER_CANCEL="20_hub-build-deploy 30_wui-build-deploy"

# real (non-comment) runs-on lines that name a self-hosted runner
selfhosted_lines() { grep -E '^[[:space:]]*runs-on:.*self-hosted' "$1"; }
ubuntu_lines()     { grep -E '^[[:space:]]*runs-on:.*ubuntu-latest' "$1"; }

[[ -d "$WF_DIR" ]] || { fail "no workflows dir at $WF_DIR"; exit 1; }

for name in $SCANNERS; do
  f="$WF_DIR/$name.yml"
  [[ -f "$f" ]] || { fail "scanner $name.yml missing"; continue; }
  if [[ -n "$(selfhosted_lines "$f")" ]]; then
    fail "$name: a scanner job is on self-hosted (must be ubuntu-latest):"; selfhosted_lines "$f" | sed 's/^/      /'
  elif [[ -z "$(ubuntu_lines "$f")" ]]; then
    fail "$name: no ubuntu-latest runner found"
  else
    pass "$name: runs on GitHub-hosted (ubuntu-latest)"
  fi
  if grep -qE 'cancel-in-progress:[[:space:]]*true' "$f"; then
    pass "$name: cancel-in-progress true (only the newest sha's scan survives)"
  else
    fail "$name: scanner lacks cancel-in-progress: true (a busy trunk will queue a scan per push)"
  fi
done

for name in $NEVER_CANCEL; do
  f="$WF_DIR/$name.yml"
  [[ -f "$f" ]] || { fail "deploy $name.yml missing"; continue; }
  if grep -qE 'cancel-in-progress:[[:space:]]*true' "$f"; then
    fail "$name: a DEPLOY must NOT cancel-in-progress (would kill a deploy mid-run)"
  else
    pass "$name: deploy is not cancellable mid-run"
  fi
done

# --- negative controls -------------------------------------------------------
CTL=$(mktemp)
printf 'jobs:\n  s:\n    runs-on: [self-hosted, spool-ci]\n' >"$CTL"
[[ -n "$(selfhosted_lines "$CTL")" ]] \
  && pass "CONTROL: a scanner on self-hosted is detected" \
  || fail "CONTROL: a self-hosted runner was not detected"
printf '# runs-on: self-hosted (this is a comment, must be ignored)\njobs:\n  s:\n    runs-on: ubuntu-latest\n' >"$CTL"
[[ -z "$(selfhosted_lines "$CTL")" ]] \
  && pass "CONTROL: a self-hosted mention in a comment is ignored" \
  || fail "CONTROL: a comment tripped the self-hosted check"
rm -f "$CTL"

[[ "$fails" -eq 0 ]] && echo "PASS: all workflow-runner-policy.tst.sh assertions"
exit "$fails"
